//! GORM-style query builder.
//!
//! Conditions are AND-combined; `orWhere` starts an OR group. `limit`,
//! `offset`, `order_by`, `group_by`, `having`, `for_update` map 1:1 onto SQL.
//! Placeholder indices in user fragments (`$1`, `$2`, ...) are renumbered
//! automatically as conditions chain up.
//!
//! Terminal operations (`all`, `first`, `count`, `exists`, `delete`) consume
//! the builder and release its scratch memory.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const time_mod = @import("time.zig");
const value = @import("value.zig");

pub const Error = pq.Error;

pub const DryRun = struct {
    sql: []u8,
    params: []pq.Param,
    gpa: std.mem.Allocator,

    pub fn deinit(d: *DryRun) void {
        for (d.params) |param| if (param.data.len > 0) d.gpa.free(param.data);
        d.gpa.free(d.params);
        d.gpa.free(d.sql);
    }
};

fn writeNamed(w: *std.Io.Writer, frag: []const u8, comptime field_names: []const [:0]const u8, start: usize) !void {
    var i: usize = 0;
    while (i < frag.len) {
        const ch = frag[i];
        if (ch == '\'' or ch == '"') {
            i = try copyQuoted(w, frag, i);
            continue;
        }
        if (ch == ':') {
            if (i + 1 < frag.len and frag[i + 1] == ':') {
                try w.writeAll("::");
                i += 2;
                continue;
            }
            var end = i + 1;
            while (end < frag.len and (std.ascii.isAlphanumeric(frag[end]) or frag[end] == '_')) end += 1;
            if (end == i + 1) return error.InvalidQuery;
            const name = frag[i + 1 .. end];
            var found = false;
            for (field_names, 0..) |field_name, field_index| {
                if (std.mem.eql(u8, name, field_name)) {
                    try w.print("${d}", .{start + field_index + 1});
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidQuery;
            i = end;
            continue;
        }
        var j = i + 1;
        while (j < frag.len and frag[j] != ':' and frag[j] != '\'' and frag[j] != '"') j += 1;
        try w.writeAll(frag[i..j]);
        i = j;
    }
}

pub fn Query(comptime T: type) type {
    const table = comptime schema.tableOf(T);
    return struct {
        const Self = @This();

        const Cond = struct {
            frag: []const u8,
            is_or: bool = false,
            args_start: usize,
        };

        const Fragment = struct {
            sql: []const u8,
            args_start: usize,
        };

        const Cte = struct {
            name: []const u8,
            sql: []const u8,
            args_start: usize,
            recursive: bool,
        };

        const Union = struct {
            sql: []const u8,
            args_start: usize,
            all: bool,
        };

        sess: *db_mod.Session,
        /// True when the query owns its (heap) session — one-shot Db queries.
        owns_session: bool = false,
        arena: std.heap.ArenaAllocator,
        err: ?Error = null,

        cols: ?[]const []const u8 = null,
        returning_cols: ?[]const []const u8 = null,
        raw_cols: ?[]const []const u8 = null,
        distinct_on_cols: ?[]const []const u8 = null,
        hint_text: ?[]const u8 = null,
        is_distinct: bool = false,
        /// Comptime-verified association field names to preload.
        preloads: std.ArrayList([]const u8) = .empty,
        /// When true, soft-deleted rows are included and terminal `delete`
        /// performs a real DELETE.
        unscoped_flag: bool = false,
        conds: std.ArrayList(Cond) = .empty,
        freed: bool = false,
        args: std.ArrayList(pq.Param) = .empty,
        orders: std.ArrayList([]const u8) = .empty,
        groups: std.ArrayList([]const u8) = .empty,
        joins: std.ArrayList(Fragment) = .empty,
        ctes: std.ArrayList(Cte) = .empty,
        unions: std.ArrayList(Union) = .empty,
        having_cond: ?Cond = null,
        limit_n: ?i64 = null,
        offset_n: ?i64 = null,
        for_update_flag: bool = false,
        timeout_ms: u64 = 0,

        fn a(q: *Self) std.mem.Allocator {
            return q.arena.allocator();
        }

        pub fn deinit(q: *Self) void {
            if (q.freed) return;
            q.freed = true;
            const gpa = q.sess.gpa;
            q.arena.deinit();
            const sess = q.sess;
            const owns_session = q.owns_session;
            q.conds.deinit(gpa);
            q.joins.deinit(gpa);
            q.ctes.deinit(gpa);
            q.unions.deinit(gpa);
            q.args.deinit(gpa);

            if (owns_session) gpa.destroy(sess);
            gpa.destroy(q);
        }

        /// Surfaces a pending builder error. The caller must `q.deinit()`.
        fn startTerminal(q: *Self) Error!void {
            if (q.err) |e| return e;
        }

        // ------------------------------------------------------------ chain

        pub fn select(q: *Self, cols: []const []const u8) *Self {
            q.cols = cols;
            return q;
        }

        /// Selects trusted SQL expressions without identifier quoting. This
        /// covers CASE, window functions, JSON, and array operators.
        pub fn selectRaw(q: *Self, expressions: []const []const u8) *Self {
            q.raw_cols = expressions;
            return q;
        }

        pub fn distinctOn(q: *Self, cols: []const []const u8) *Self {
            q.distinct_on_cols = cols;
            return q;
        }

        /// Adds a PostgreSQL optimizer hint comment after SELECT.
        pub fn hint(q: *Self, text: []const u8) *Self {
            q.hint_text = text;
            return q;
        }

        /// Applies a reusable query scope.
        pub fn scope(q: *Self, apply: anytype) *Self {
            return apply(q);
        }

        /// Adds a trusted JOIN fragment, e.g. `JOIN teams ON teams.id = users.team_id`.
        pub fn join(q: *Self, sql: []const u8, args: anytype) *Self {
            return q.addFragment(&q.joins, sql, args);
        }

        /// Adds `EXISTS (<subquery>)` as a parameterized predicate.
        pub fn whereExists(q: *Self, sql: []const u8, args: anytype) *Self {
            const frag = std.fmt.allocPrint(q.a(), "EXISTS ({s})", .{sql}) catch return q.errOut();
            return q.addCond(frag, args, false);
        }

        pub fn with(q: *Self, name: []const u8, sql: []const u8, args: anytype) *Self {
            return q.addCte(name, sql, args, false);
        }

        pub fn withRecursive(q: *Self, name: []const u8, sql: []const u8, args: anytype) *Self {
            return q.addCte(name, sql, args, true);
        }

        pub fn unionWith(q: *Self, sql: []const u8, args: anytype) *Self {
            return q.addUnion(sql, args, false);
        }

        pub fn unionAll(q: *Self, sql: []const u8, args: anytype) *Self {
            return q.addUnion(sql, args, true);
        }

        /// Adds a predicate using `:field` placeholders from a struct.
        pub fn whereNamed(q: *Self, frag: []const u8, named: anytype) *Self {
            const info = @typeInfo(@TypeOf(named));
            if (info != .@"struct" or info.@"struct".is_tuple)
                @compileError("zgorm: whereNamed expects a named struct");
            const start = q.args.items.len;
            inline for (info.@"struct".field_names) |field_name| {
                const param = value.toParam(@field(named, field_name), q.a()) catch return q.errOut();
                q.args.append(q.sess.gpa, param) catch return q.errOut();
            }
            var aw: std.Io.Writer.Allocating = .init(q.a());
            writeNamed(&aw.writer, frag, info.@"struct".field_names, start) catch {
                q.err = error.InvalidQuery;
                return q;
            };
            q.conds.append(q.sess.gpa, .{
                .frag = aw.writer.buffered(),
                .args_start = 0,
            }) catch return q.errOut();
            return q;
        }

        /// Configures columns emitted by mutation RETURNING clauses.
        pub fn returning(q: *Self, cols: []const []const u8) *Self {
            q.returning_cols = cols;
            return q;
        }

        pub fn distinct(q: *Self) *Self {
            q.is_distinct = true;
            return q;
        }

        /// Applies a client-side deadline to this terminal operation.
        pub fn timeout(q: *Self, timeout_ms: u64) *Self {
            q.timeout_ms = timeout_ms;
            return q;
        }

        /// Adds a condition combined with AND. Placeholders in `frag` must be
        /// numbered starting at $1 for this condition's own args.
        pub fn where(q: *Self, frag: []const u8, args: anytype) *Self {
            return q.addCond(frag, args, false);
        }

        /// Includes soft-deleted rows in the query (models with a
        /// `deleted_at` column); terminal `delete` becomes a hard DELETE.
        pub fn unscoped(q: *Self) *Self {
            q.unscoped_flag = true;
            return q;
        }

        /// Eager-loads a declared association (`has_many` fills the slice
        /// field; `belongs_to` fills the optional field). Supports nested
        /// paths: `preload("posts.comments")` preloads the comments of the
        /// preloaded posts. The whole path is checked at compile time.
        pub fn preload(q: *Self, comptime path: []const u8) *Self {
            comptime validatePreloadPath(T, path);
            q.preloads.append(q.a(), path) catch return q.errOut();
            return q;
        }

        /// Preloads an association through the association metadata. The
        /// result contract matches `preload`; singular and many-to-many
        /// associations use their configured join keys.
        pub fn joinPreload(q: *Self, comptime path: []const u8) *Self {
            return q.preload(path);
        }

        /// Adds a condition combined with OR with everything before it.
        pub fn orWhere(q: *Self, frag: []const u8, args: anytype) *Self {
            return q.addCond(frag, args, true);
        }

        /// `col = $n` shorthand.
        pub fn whereEq(q: *Self, col: []const u8, val: anytype) *Self {
            const frag = std.fmt.allocPrint(q.a(), "{s} = $1", .{quoteIdent(q.a(), col) catch return q.errOut()}) catch return q.errOut();
            return q.addCond(frag, .{val}, false);
        }

        /// `col IN (...)` from a tuple or slice of values.
        pub fn whereIn(q: *Self, col: []const u8, values: anytype) *Self {
            const Vals = @TypeOf(values);
            const n: usize = switch (@typeInfo(Vals)) {
                .@"struct" => |si| si.field_names.len,
                .pointer => |pi| switch (pi.size) {
                    .slice => values.len,
                    .one => switch (@typeInfo(pi.child)) {
                        .array => |ai| ai.len,
                        .@"struct" => |si| if (si.is_tuple) si.field_names.len else 1,
                        else => 1,
                    },
                    else => 1,
                },
                else => 1,
            };
            if (n == 0) {
                const frag = q.a().dupe(u8, "1 = 0") catch return q.errOut();
                return q.addCond(frag, .{}, false);
            }
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            w.writeAll(quoteIdent(q.a(), col) catch return q.errOut()) catch return q.errOut();
            w.writeAll(" IN (") catch return q.errOut();
            for (0..n) |i| {
                if (i > 0) w.writeAll(", ") catch return q.errOut();
                w.print("${d}", .{i + 1}) catch return q.errOut();
            }
            w.writeByte(')') catch return q.errOut();
            return q.addCond(aw.writer.buffered(), values, false);
        }

        pub fn order_by(q: *Self, expr: []const u8) *Self {
            q.orders.append(q.a(), expr) catch return q.errOut();
            return q;
        }

        pub fn group_by(q: *Self, expr: []const u8) *Self {
            q.groups.append(q.a(), expr) catch return q.errOut();
            return q;
        }

        pub fn having(q: *Self, frag: []const u8, args: anytype) *Self {
            const params = value.argsToParams(args, q.a()) catch return q.errOut();
            const start = q.args.items.len;
            q.args.appendSlice(q.sess.gpa, params) catch return q.errOut();
            q.having_cond = .{ .frag = frag, .args_start = start };
            return q;
        }

        pub fn limit(q: *Self, n: i64) *Self {
            q.limit_n = n;
            return q;
        }

        pub fn offset(q: *Self, n: i64) *Self {
            q.offset_n = n;
            return q;
        }

        pub fn for_update(q: *Self) *Self {
            q.for_update_flag = true;
            return q;
        }

        fn errOut(q: *Self) *Self {
            q.err = error.OutOfMemory;
            return q;
        }

        fn addCond(q: *Self, frag: []const u8, args: anytype, is_or: bool) *Self {
            const params = value.argsToParams(args, q.a()) catch return q.errOut();
            const start = q.args.items.len;
            q.args.appendSlice(q.sess.gpa, params) catch return q.errOut();
            q.conds.append(q.sess.gpa, .{
                .frag = frag,
                .is_or = is_or,
                .args_start = start,
            }) catch return q.errOut();
            return q;
        }

        fn addFragment(q: *Self, list: *std.ArrayList(Fragment), sql: []const u8, args: anytype) *Self {
            const params = value.argsToParams(args, q.a()) catch return q.errOut();
            const start = q.args.items.len;
            q.args.appendSlice(q.sess.gpa, params) catch return q.errOut();
            list.append(q.sess.gpa, .{ .sql = sql, .args_start = start }) catch return q.errOut();
            return q;
        }

        fn addCte(q: *Self, name: []const u8, sql: []const u8, args: anytype, recursive: bool) *Self {
            const params = value.argsToParams(args, q.a()) catch return q.errOut();
            const start = q.args.items.len;
            q.args.appendSlice(q.sess.gpa, params) catch return q.errOut();
            q.ctes.append(q.sess.gpa, .{ .name = name, .sql = sql, .args_start = start, .recursive = recursive }) catch return q.errOut();
            return q;
        }

        fn addUnion(q: *Self, sql: []const u8, args: anytype, union_all: bool) *Self {
            const params = value.argsToParams(args, q.a()) catch return q.errOut();
            const start = q.args.items.len;
            q.args.appendSlice(q.sess.gpa, params) catch return q.errOut();
            q.unions.append(q.sess.gpa, .{ .sql = sql, .args_start = start, .all = union_all }) catch return q.errOut();
            return q;
        }

        // ------------------------------------------------------------ build

        /// Writes `WHERE ...` (or nothing when no conditions) into `w`.
        /// Prepends the soft-delete filter unless unscoped.
        fn buildWhere(q: *Self, w: *std.Io.Writer) !void {
            return q.buildWhereOffset(w, 0);
        }

        fn buildWhereOffset(q: *Self, w: *std.Io.Writer, param_offset: usize) !void {
            var wrote_filter = false;
            if (comptime table.softDeletable()) {
                if (!q.unscoped_flag) {
                    const del_col = table.columns[table.deleted_at_index.?];
                    try w.print(" WHERE {s} IS NULL", .{quoted(del_col.name)});
                    wrote_filter = true;
                }
            }
            for (q.conds.items, 0..) |cond, i| {
                if (i == 0) {
                    try w.writeAll(if (wrote_filter) " AND " else " WHERE ");
                } else {
                    try w.writeAll(if (cond.is_or) " OR " else " AND ");
                }
                try w.writeByte('(');
                try writeRenumbered(w, cond.frag, cond.args_start + param_offset);
                try w.writeByte(')');
            }
        }

        const SelectMode = enum { normal, count, exists, count_inner };

        fn buildSelectSql(q: *Self, mode: SelectMode) ![]const u8 {
            const count_mode = mode == .count;
            const exists_mode = mode == .exists;
            const inner_mode = mode == .count_inner;
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            if (q.ctes.items.len > 0) {
                var recursive = false;
                for (q.ctes.items) |cte| recursive = recursive or cte.recursive;
                try w.writeAll(if (recursive) "WITH RECURSIVE " else "WITH ");
                for (q.ctes.items, 0..) |cte, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{s} AS (", .{try quoteIdent(q.a(), cte.name)});
                    try writeRenumbered(w, cte.sql, cte.args_start);
                    try w.writeByte(')');
                }
                try w.writeByte(' ');
            }

            const default_select = !count_mode and !exists_mode and
                q.hint_text == null and
                q.distinct_on_cols == null and
                !q.is_distinct and
                q.raw_cols == null and
                q.cols == null;
            if (default_select) {
                try w.writeAll(DefaultSelectPrefix(T).value[0..]);
            } else {
                try w.writeAll("SELECT ");
                if (!count_mode and q.hint_text != null) try w.print("/*+ {s} */ ", .{q.hint_text.?});
                if (count_mode) {
                    try w.writeAll("count(*)");
                } else if (exists_mode) {
                    try w.writeAll("1");
                } else {
                    if (q.distinct_on_cols) |cols| {
                        try w.writeAll("DISTINCT ON (");
                        for (cols, 0..) |col, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(try quoteIdent(q.a(), col));
                        }
                        try w.writeAll(") ");
                    } else if (q.is_distinct) {
                        try w.writeAll("DISTINCT ");
                    }
                    if (q.raw_cols) |expressions| {
                        for (expressions, 0..) |expression, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(expression);
                        }
                    } else if (q.cols) |cols| {
                        for (cols, 0..) |col, i| {
                            if (i > 0) try w.writeAll(", ");
                            try w.writeAll(try quoteIdent(q.a(), col));
                        }
                    } else {
                        try w.writeByte('*');
                    }
                }
                try w.writeAll(" FROM ");
                try w.writeAll(QuotedIdent(table.name).value[0..]);
            }
            for (q.joins.items) |join_clause| {
                try w.writeByte(' ');
                try writeRenumbered(w, join_clause.sql, join_clause.args_start);
            }
            try q.buildWhere(w);
            if (!count_mode) {
                if (q.groups.items.len > 0) {
                    try w.writeAll(" GROUP BY ");
                    for (q.groups.items, 0..) |group, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(group);
                    }
                }
                if (q.having_cond) |having_clause| {
                    try w.writeAll(" HAVING (");
                    try writeRenumbered(w, having_clause.frag, having_clause.args_start);
                    try w.writeByte(')');
                }
                for (q.unions.items) |union_clause| {
                    try w.writeAll(if (union_clause.all) " UNION ALL " else " UNION ");
                    try writeRenumbered(w, union_clause.sql, union_clause.args_start);
                }
                if (!exists_mode and !inner_mode and q.orders.items.len > 0) {
                    try w.writeAll(" ORDER BY ");
                    for (q.orders.items, 0..) |order, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(order);
                    }
                }
                if (!inner_mode) {
                    if (q.limit_n) |limit_value| try w.print(" LIMIT {d}", .{limit_value});
                    if (q.offset_n) |offset_value| try w.print(" OFFSET {d}", .{offset_value});
                    if (q.for_update_flag) try w.writeAll(" FOR UPDATE");
                }
            }
            return aw.writer.buffered();
        }

        /// count(*) over the configured query. Grouping/HAVING/UNION change the
        /// row set, so wrap the full query in a subquery rather than dropping
        /// those clauses (which would silently count the wrong rows).
        fn buildCountSql(q: *Self) ![]const u8 {
            if (q.groups.items.len == 0 and q.having_cond == null and q.unions.items.len == 0)
                return q.buildSelectSql(.count);
            const inner = try q.buildSelectSql(.count_inner);
            var aw: std.Io.Writer.Allocating = .init(q.a());
            aw.writer.print("SELECT count(*) FROM ({s}) AS _zgorm_count", .{inner}) catch return error.OutOfMemory;
            return aw.writer.buffered();
        }

        fn buildDeleteSql(q: *Self) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            if (comptime table.softDeletable()) {
                if (!q.unscoped_flag) {
                    const del_col = table.columns[table.deleted_at_index.?];
                    try w.print("UPDATE {s} SET {s} = {s}", .{
                        quoted(table.name),
                        quoted(del_col.name),
                        softDeleteStampSql(value.columnFieldType(T, del_col)),
                    });
                } else {
                    try w.print("DELETE FROM {s}", .{quoted(table.name)});
                }
            } else {
                try w.print("DELETE FROM {s}", .{quoted(table.name)});
            }
            try q.buildWhere(w);
            return aw.writer.buffered();
        }

        fn writeReturning(q: *Self, w: *std.Io.Writer) !void {
            try w.writeAll(" RETURNING ");
            if (q.returning_cols) |cols| {
                if (cols.len == 0) return error.InvalidQuery;
                for (cols, 0..) |name, i| {
                    if (i > 0) try w.writeAll(", ");
                    try w.writeAll(try quoteIdent(q.a(), name));
                }
            } else {
                try w.writeByte('*');
            }
        }

        fn run(q: *Self, sql: []const u8) Error!pq.Result {
            return q.sess.runExecTimeout(sql, q.args.items, q.timeout_ms);
        }

        /// Starts pull-based model decoding. The returned iterator owns the
        /// pooled connection until EOF or `deinit`.
        pub fn stream(q: *Self, out_gpa: std.mem.Allocator) Error!ModelRows(T) {
            q.startTerminal() catch |err| {
                q.deinit();
                return err;
            };
            if (q.preloads.items.len != 0) {
                q.deinit();
                return error.ProtocolViolation;
            }
            const sql = q.buildSelectSql(.normal) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            const sess = q.sess;
            const owns_session = q.owns_session;
            const conn = sess.acquire() catch |err| {
                q.deinit();
                return err;
            };
            // Streaming keeps a cursor open on this connection. Inside a
            // transaction the session is pinned to that same connection, so
            // any other statement (or a hook query) would overlap the cursor,
            // and committing would return the connection while the iterator
            // still holds it. Refuse streaming on a pinned session; use all().
            if (sess.pinned == conn) {
                sess.releaseConn(conn);
                q.deinit();
                return error.ProtocolViolation;
            }
            const rows = conn.queryParamsStream(sql, q.args.items) catch |err| {
                sess.releaseConn(conn);
                q.deinit();
                return err;
            };
            var column_map: [table.columns.len]?usize = undefined;
            value.buildColumnMap(table, rows.columns, &column_map);
            q.owns_session = false;
            q.deinit();
            return .{
                .sess = sess,
                .conn = conn,
                .rows = rows,
                .owns_session = owns_session,
                .out_gpa = out_gpa,
                .column_map = column_map,
            };
        }

        // -------------------------------------------------------- terminals

        /// Builds SQL and bind parameters without executing the query.
        pub fn dryRun(q: *Self, out_gpa: std.mem.Allocator) Error!DryRun {
            q.startTerminal() catch |err| {
                q.deinit();
                return err;
            };
            errdefer q.deinit();
            const built = q.buildSelectSql(.normal) catch return error.OutOfMemory;
            const sql = out_gpa.dupe(u8, built) catch return error.OutOfMemory;
            errdefer out_gpa.free(sql);
            const params = out_gpa.alloc(pq.Param, q.args.items.len) catch return error.OutOfMemory;
            var copied: usize = 0;
            errdefer {
                for (params[0..copied]) |param| if (param.data.len > 0) out_gpa.free(param.data);
                out_gpa.free(params);
            }
            for (q.args.items, 0..) |param, i| {
                params[i] = param;
                if (param.data.len > 0) params[i].data = out_gpa.dupe(u8, param.data) catch return error.OutOfMemory;
                copied += 1;
            }
            q.deinit();
            return .{ .sql = sql, .params = params, .gpa = out_gpa };
        }

        /// Returns PostgreSQL's EXPLAIN result. `analyze` executes the query.
        pub fn explain(q: *Self, analyze: bool) Error!pq.Result {
            q.startTerminal() catch |err| {
                q.deinit();
                return err;
            };
            errdefer q.deinit();
            const built = q.buildSelectSql(.normal) catch return error.OutOfMemory;
            var aw: std.Io.Writer.Allocating = .init(q.a());
            aw.writer.print("EXPLAIN ({s}, FORMAT TEXT) {s}", .{
                if (analyze) "ANALYZE true" else "ANALYZE false",
                built,
            }) catch return error.OutOfMemory;
            const result = try q.run(aw.writer.buffered());
            q.deinit();
            return result;
        }

        /// Executes the query and returns all matching rows.
        pub fn all(q: *Self, out_gpa: std.mem.Allocator) Error![]T {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            const sql = q.buildSelectSql(.normal) catch return error.OutOfMemory;
            const rows = try q.sess.runModels(T, sql, q.args.items, q.timeout_ms, out_gpa);
            errdefer {
                for (rows) |row| value.freeValue(T, row, out_gpa);
                out_gpa.free(rows);
            }
            try q.applyPreloads(rows, out_gpa);
            q.deinit();
            return rows;
        }

        /// Executes the query and returns the first row, if any.
        pub fn first(q: *Self) Error!?T {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            // Always limit to one row: a user-supplied larger limit would decode
            // extra rows whose heap fields first() never frees.
            q.limit_n = 1;
            const sql = q.buildSelectSql(.normal) catch return error.OutOfMemory;
            const out_gpa = q.sess.gpa;
            const rows = try q.sess.runModels(T, sql, q.args.items, q.timeout_ms, out_gpa);
            defer out_gpa.free(rows);
            if (rows.len == 0) {
                q.deinit();
                return null;
            }
            var one = [1]T{rows[0]};
            errdefer value.freeValue(T, one[0], out_gpa);
            try q.applyPreloads(&one, out_gpa);
            q.deinit();
            return one[0];
        }

        /// `SELECT count(*)` with the configured conditions.
        pub fn count(q: *Self) Error!i64 {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            const sql = q.buildCountSql() catch return error.OutOfMemory;
            var res = try q.run(sql);
            defer res.deinit();
            const out: i64 = if (res.rows.len == 0)
                0
            else blk: {
                if (res.rows[0].len == 0 or res.columns.len == 0)
                    return error.ProtocolViolation;
                break :blk try value.decodeCell(
                    i64,
                    res.rows[0][0],
                    res.columns[0].type_oid,
                    res.columns[0].format,
                    q.sess.gpa,
                );
            };
            q.deinit();
            return out;
        }

        /// True when at least one row matches.
        pub fn exists(q: *Self) Error!bool {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            q.limit_n = 1;
            const sql = q.buildSelectSql(.exists) catch return error.OutOfMemory;
            var res = try q.run(sql);
            defer res.deinit();
            const out = res.rows.len > 0;
            q.deinit();
            return out;
        }

        fn applyPreloads(q: *Self, rows: []T, gpa: std.mem.Allocator) Error!void {
            if (q.preloads.items.len == 0 or rows.len == 0) return;
            for (q.preloads.items) |path| {
                try applyPreloadPath(T, rows, path, q.sess, gpa);
            }
        }

        /// `DELETE FROM table WHERE ...`, returns affected rows.
        pub fn delete(q: *Self) Error!i64 {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            const sql = q.buildDeleteSql() catch return error.OutOfMemory;
            var res = try q.run(sql);
            defer res.deinit();
            const affected = res.affected;
            q.deinit();
            return affected;
        }

        /// Deletes matching rows and returns their post-mutation values.
        pub fn deleteReturning(q: *Self, out_gpa: std.mem.Allocator) Error![]T {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            const base = q.buildDeleteSql() catch return error.OutOfMemory;
            w.writeAll(base) catch return error.OutOfMemory;
            q.writeReturning(w) catch return error.OutOfMemory;
            const rows = try q.sess.runModels(T, aw.writer.buffered(), q.args.items, q.timeout_ms, out_gpa);
            q.deinit();
            return rows;
        }

        /// Updates matching rows from a struct/tuple and returns the rows.
        pub fn updateReturning(q: *Self, sets: anytype, out_gpa: std.mem.Allocator) Error![]T {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            const query_gpa = q.sess.gpa;
            const info = @typeInfo(@TypeOf(sets));
            if (info != .@"struct" or info.@"struct".field_names.len == 0)
                @compileError("zgorm: updateReturning expects a non-empty struct");
            var params: std.ArrayList(pq.Param) = .empty;
            defer params.deinit(query_gpa);
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            w.print("UPDATE {s} SET ", .{quoted(table.name)}) catch return error.OutOfMemory;
            inline for (info.@"struct".field_names, 0..) |field_name, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                comptime var column_name: ?[]const u8 = null;
                inline for (table.columns) |col| {
                    if (comptime std.mem.eql(u8, col.field_name, field_name)) column_name = col.name;
                }
                if (column_name == null) @compileError("zgorm: update field is not a model column: " ++ field_name);
                w.print("{s} = ${d}", .{ quoted(column_name.?), i + 1 }) catch return error.OutOfMemory;
                params.append(q.sess.gpa, try value.toParam(@field(sets, field_name), q.a())) catch return error.OutOfMemory;
            }
            q.buildWhereOffset(w, info.@"struct".field_names.len) catch return error.OutOfMemory;
            q.writeReturning(w) catch return error.OutOfMemory;
            params.appendSlice(q.sess.gpa, q.args.items) catch return error.OutOfMemory;
            const rows = try q.sess.runModels(T, aw.writer.buffered(), params.items, q.timeout_ms, out_gpa);
            q.deinit();
            return rows;
        }
    };
}

pub fn ModelRows(comptime T: type) type {
    const table = comptime schema.tableOf(T);
    return struct {
        const Self = @This();

        sess: *db_mod.Session,
        conn: *pq.Conn,
        rows: *pq.Rows,
        owns_session: bool,
        out_gpa: std.mem.Allocator,
        column_map: [table.columns.len]?usize,
        closed: bool = false,

        fn close(r: *Self) void {
            if (r.closed) return;
            r.closed = true;
            r.rows.deinit();
            r.sess.releaseConn(r.conn);
            if (r.owns_session) r.sess.gpa.destroy(r.sess);
        }

        /// Decodes and returns one model. The caller owns it and releases it
        /// with `zgorm.free(T, value, allocator)`.
        pub fn next(r: *Self) Error!?T {
            if (r.closed) return null;
            const raw = r.rows.next() catch |err| {
                r.close();
                return err;
            } orelse {
                r.close();
                return null;
            };
            var model = value.scanCellsMapped(T, table, r.rows.columns, raw, &r.column_map, r.out_gpa) catch |err| {
                r.close();
                return err;
            };
            db_mod.Session.callHook(T, "afterFind", &model, r.sess) catch |err| {
                value.freeValue(T, model, r.out_gpa);
                r.close();
                return err;
            };
            return model;
        }

        /// Writes all remaining rows as CSV while retaining constant result
        /// memory. This consumes and closes the iterator.
        pub fn exportCsv(r: *Self, writer: *std.Io.Writer) !void {
            defer r.close();
            try r.rows.writeCsv(writer);
        }

        pub fn deinit(r: *Self) void {
            r.close();
        }
    };
}

/// SQL expression used to stamp a soft-delete `deleted_at` column. Uses the
/// database clock so all writers agree on time.
pub fn softDeleteStampSql(comptime FType: type) []const u8 {
    const E = if (@typeInfo(FType) == .optional) @typeInfo(FType).optional.child else FType;
    return switch (E) {
        time_mod.Time => "now()",
        i64 => "(extract(epoch from now()) * 1000000)::bigint",
        else => @compileError("zgorm: deleted_at must be zgorm.Time or i64"),
    };
}

/// Compile-time validation of a (possibly dotted) preload path against
/// model `M`: every segment must be a declared association of the previous
/// segment's model.
pub fn validatePreloadPath(comptime M: type, comptime path: []const u8) void {
    comptime {
        @setEvalBranchQuota(200_000);
        var model = M;
        var rest = path;
        while (rest.len > 0) {
            const dot = std.mem.indexOfScalar(u8, rest, '.');
            const seg = if (dot) |d| rest[0..d] else rest;
            const tbl = schema.tableOf(model);
            var found: ?schema.Assoc = null;
            for (tbl.assocs) |a| {
                if (std.mem.eql(u8, a.field_name, seg)) found = a;
            }
            if (found == null) {
                @compileError("zgorm: preload('" ++ path ++ "'): '" ++ seg ++
                    "' is not a declared association of " ++ @typeName(model) ++
                    " (declare it via `pub const zgorm = .{ .has_many = ... }` or `.belongs_to = ...`)");
            }
            model = found.?.model;
            rest = if (dot) |d| rest[d + 1 ..] else "";
        }
    }
}

/// Applies a (possibly dotted) preload path to decoded rows of model `M`.
/// Runs one query per association level (batched over all rows).
pub fn applyPreloadPath(
    comptime M: type,
    rows: []M,
    path: []const u8,
    s: *db_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const tbl = comptime schema.tableOf(M);
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const seg = if (dot) |d| path[0..d] else path;
    const nested: []const u8 = if (dot) |d| path[d + 1 ..] else "";
    inline for (tbl.assocs) |assoc| {
        if (std.mem.eql(u8, assoc.field_name, seg)) {
            try loadAssoc(M, rows, assoc, nested, s, gpa);
        }
    }
}

fn loadAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *db_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    if (assoc.primary_keys.len != assoc.foreign_keys.len)
        @compileError("zgorm: association primary_keys and foreign_keys must have equal length");
    if (assoc.primary_keys.len > 1)
        return loadCompositeAssoc(M, rows, assoc, nested, s, gpa);

    switch (assoc.kind) {
        .many_to_many => return loadManyToMany(M, rows, assoc, nested, s, gpa),
        .belongs_to, .has_one, .has_many => return loadSingleAssoc(M, rows, assoc, nested, s, gpa),
    }
}

fn loadSingleAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *db_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    const child_table = comptime schema.tableOf(Child);
    const parent_key = if (comptime assoc.kind == .belongs_to) assoc.foreign_key else assoc.primary_key;
    const child_key = if (comptime assoc.kind == .belongs_to) assoc.primary_key else assoc.foreign_key;
    const parent_col = comptime ColumnOfT(M, parent_key);
    const child_col = comptime ColumnOfT(Child, child_key);
    const ParentKey = value.columnFieldType(M, parent_col);

    var keys: std.ArrayList(ParentKey) = .empty;
    defer keys.deinit(gpa);
    keys.ensureTotalCapacity(gpa, rows.len) catch return error.OutOfMemory;
    if (comptime assoc.kind == .belongs_to and value.keyMapType(ParentKey) != null) {
        // Many parents can reference the same child; deduplicate the IN list
        // so fan-in doesn't bloat the SQL and parameter count.
        var seen: value.keyMapType(ParentKey).? = .init(gpa);
        defer seen.deinit();
        for (rows) |*parent| {
            const key = value.getColumn(parent, parent_col);
            if (value.normalizedKey(ParentKey, key)) |nk| {
                const gop = seen.getOrPut(nk) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0;
                    keys.appendAssumeCapacity(key);
                }
            }
        }
    } else {
        for (rows) |*parent| {
            const key = value.getColumn(parent, parent_col);
            if (keyPresent(ParentKey, key)) keys.appendAssumeCapacity(key);
        }
    }
    if (keys.items.len == 0) {
        if (assoc.kind != .has_many) {
            for (rows) |*parent| @field(parent, assoc.field_name) = null;
        }
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var children = try queryChildrenForKeys(
        Child,
        child_table,
        child_key,
        keys.items,
        assoc.polymorphic_type,
        assoc.polymorphic_value,
        s,
        arena,
    );
    defer children.deinit(arena);
    if (nested.len > 0) try applyPreloadPath(Child, children.items, nested, s, arena);

    switch (assoc.kind) {
        .has_many => {
            const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
                return error.OutOfMemory;
            defer gpa.free(slices);
            const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(fill);
            const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(counts);
            @memset(counts, 0);

            const owners = gpa.alloc(usize, children.items.len) catch return error.OutOfMemory;
            defer gpa.free(owners);
            const ChildKey = value.columnFieldType(Child, child_col);
            if (comptime value.keysHashable(ParentKey, ChildKey)) {
                var map: value.keyMapType(ParentKey).? = .init(gpa);
                defer map.deinit();
                for (rows, 0..) |*parent, parent_index| {
                    if (value.normalizedKey(ParentKey, value.getColumn(parent, parent_col))) |k| {
                        const gop = map.getOrPut(k) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = parent_index;
                    }
                }
                for (children.items, 0..) |*child, child_index| {
                    owners[child_index] = std.math.maxInt(usize);
                    if (value.normalizedKey(ChildKey, value.getColumn(child, child_col))) |k| {
                        if (map.get(k)) |parent_index| {
                            owners[child_index] = parent_index;
                            counts[parent_index] += 1;
                        }
                    }
                }
            } else {
                for (children.items, 0..) |*child, child_index| {
                    owners[child_index] = std.math.maxInt(usize);
                    for (rows, 0..) |*parent, parent_index| {
                        if (keyEqual(
                            ChildKey,
                            value.getColumn(child, child_col),
                            ParentKey,
                            value.getColumn(parent, parent_col),
                        )) {
                            owners[child_index] = parent_index;
                            counts[parent_index] += 1;
                            break;
                        }
                    }
                }
            }
            for (rows, 0..) |*parent, parent_index| {
                slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
                // Zero so a mid-fill error path frees only initialized slots.
                @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
                fill[parent_index] = 0;
                @field(parent, assoc.field_name) = slices[parent_index];
            }
            for (children.items, 0..) |*child, child_index| {
                const owner = owners[child_index];
                if (owner != std.math.maxInt(usize)) {
                    slices[owner][fill[owner]] = try value.deepCopy(Child, child.*, gpa);
                    fill[owner] += 1;
                }
            }
        },
        .belongs_to, .has_one => {
            const ChildKey = value.columnFieldType(Child, child_col);
            if (comptime value.keysHashable(ParentKey, ChildKey)) {
                var map: value.keyMapType(ChildKey).? = .init(gpa);
                defer map.deinit();
                for (children.items, 0..) |*child, child_index| {
                    if (value.normalizedKey(ChildKey, value.getColumn(child, child_col))) |k| {
                        const gop = map.getOrPut(k) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = child_index;
                    }
                }
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    if (value.normalizedKey(ParentKey, value.getColumn(parent, parent_col))) |k| {
                        if (map.get(k)) |child_index| {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, children.items[child_index], gpa);
                        }
                    }
                }
            } else {
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    for (children.items) |*child| {
                        if (keyEqual(
                            ChildKey,
                            value.getColumn(child, child_col),
                            ParentKey,
                            value.getColumn(parent, parent_col),
                        )) {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, child.*, gpa);
                            break;
                        }
                    }
                }
            }
        },
        .many_to_many => unreachable,
    }
}

fn loadManyToMany(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *db_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    const child_table = comptime schema.tableOf(Child);
    const ParentKey = FieldOfT(M, assoc.primary_key);

    var keys: std.ArrayList(ParentKey) = .empty;
    defer keys.deinit(gpa);
    keys.ensureTotalCapacity(gpa, rows.len) catch return error.OutOfMemory;
    for (rows) |*parent| {
        const key = @field(parent, assoc.primary_key);
        if (keyPresent(ParentKey, key)) keys.appendAssumeCapacity(key);
    }
    if (keys.items.len == 0) {
        for (rows) |*parent| @field(parent, assoc.field_name) = &.{};
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var joined = try queryJoinedChildren(
        M,
        Child,
        child_table,
        assoc,
        keys.items,
        s,
        arena,
    );
    defer joined.deinit(arena);

    const child_rows = arena.alloc(Child, joined.items.len) catch return error.OutOfMemory;
    for (joined.items, 0..) |item, i| child_rows[i] = item.child;
    if (nested.len > 0) try applyPreloadPath(Child, child_rows, nested, s, arena);
    for (joined.items, 0..) |*item, i| item.child = child_rows[i];

    const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
        return error.OutOfMemory;
    defer gpa.free(slices);
    const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
    defer gpa.free(fill);
    const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
    defer gpa.free(counts);
    @memset(counts, 0);

    const owners = gpa.alloc(usize, joined.items.len) catch return error.OutOfMemory;
    defer gpa.free(owners);
    if (comptime value.keyMapType(ParentKey) != null) {
        var map: value.keyMapType(ParentKey).? = .init(gpa);
        defer map.deinit();
        for (rows, 0..) |*parent, parent_index| {
            if (value.normalizedKey(ParentKey, @field(parent, assoc.primary_key))) |k| {
                const gop = map.getOrPut(k) catch return error.OutOfMemory;
                if (!gop.found_existing) gop.value_ptr.* = parent_index;
            }
        }
        for (joined.items, 0..) |item, child_index| {
            owners[child_index] = std.math.maxInt(usize);
            if (value.normalizedKey(ParentKey, item.parent_key)) |k| {
                if (map.get(k)) |parent_index| {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                }
            }
        }
    } else {
        for (joined.items, 0..) |item, child_index| {
            owners[child_index] = std.math.maxInt(usize);
            for (rows, 0..) |*parent, parent_index| {
                if (keyEqual(ParentKey, item.parent_key, ParentKey, @field(parent, assoc.primary_key))) {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                    break;
                }
            }
        }
    }
    for (rows, 0..) |*parent, parent_index| {
        slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
        // Zero so a mid-fill error path frees only initialized slots.
        @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
        fill[parent_index] = 0;
        @field(parent, assoc.field_name) = slices[parent_index];
    }
    for (joined.items, 0..) |*item, child_index| {
        const owner = owners[child_index];
        if (owner != std.math.maxInt(usize)) {
            slices[owner][fill[owner]] = try value.deepCopy(Child, item.child, gpa);
            fill[owner] += 1;
        }
    }
}

fn loadCompositeAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *db_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    if (assoc.kind == .has_one or assoc.kind == .many_to_many)
        @compileError("zgorm: composite has-one and many-to-many keys are not supported");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const child_keys = if (assoc.kind == .belongs_to) assoc.primary_keys else assoc.foreign_keys;
    const parent_keys = if (assoc.kind == .belongs_to) assoc.foreign_keys else assoc.primary_keys;
    var children = try queryCompositeChildren(M, Child, rows, child_keys, parent_keys, s, arena);
    defer children.deinit(arena);
    if (nested.len > 0) try applyPreloadPath(Child, children.items, nested, s, arena);

    if (assoc.kind == .has_many) {
        const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
            return error.OutOfMemory;
        defer gpa.free(slices);
        const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
        defer gpa.free(fill);
        const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
        defer gpa.free(counts);
        @memset(counts, 0);
        const owners = gpa.alloc(usize, children.items.len) catch return error.OutOfMemory;
        defer gpa.free(owners);
        if (comptime compositeHashable(Child, child_keys, M, parent_keys)) {
            var map: std.StringHashMap(usize) = .init(gpa);
            defer map.deinit();
            var kbuf: std.ArrayList(u8) = .empty;
            defer kbuf.deinit(gpa);
            for (rows, 0..) |*parent, parent_index| {
                kbuf.clearRetainingCapacity();
                if (!try appendCompositeKey(M, parent_keys, parent.*, &kbuf, gpa)) continue;
                const key_copy = arena.dupe(u8, kbuf.items) catch return error.OutOfMemory;
                const gop = map.getOrPut(key_copy) catch return error.OutOfMemory;
                if (!gop.found_existing) gop.value_ptr.* = parent_index;
            }
            for (children.items, 0..) |*child, child_index| {
                owners[child_index] = std.math.maxInt(usize);
                kbuf.clearRetainingCapacity();
                if (!try appendCompositeKey(Child, child_keys, child.*, &kbuf, gpa)) continue;
                if (map.get(kbuf.items)) |parent_index| {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                }
            }
        } else {
            for (children.items, 0..) |*child, child_index| {
                owners[child_index] = std.math.maxInt(usize);
                for (rows, 0..) |*parent, parent_index| {
                    if (compositeKeyEqual(Child, child.*, child_keys, M, parent.*, parent_keys)) {
                        owners[child_index] = parent_index;
                        counts[parent_index] += 1;
                        break;
                    }
                }
            }
        }
        for (rows, 0..) |*parent, parent_index| {
            slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
            // Zero so a mid-fill error path frees only initialized slots.
            @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
            fill[parent_index] = 0;
            @field(parent, assoc.field_name) = slices[parent_index];
        }
        for (children.items, 0..) |*child, child_index| {
            const owner = owners[child_index];
            if (owner != std.math.maxInt(usize)) {
                slices[owner][fill[owner]] = try value.deepCopy(Child, child.*, gpa);
                fill[owner] += 1;
            }
        }
        return;
    }

    if (comptime compositeHashable(Child, child_keys, M, parent_keys)) {
        var map: std.StringHashMap(usize) = .init(gpa);
        defer map.deinit();
        var kbuf: std.ArrayList(u8) = .empty;
        defer kbuf.deinit(gpa);
        for (children.items, 0..) |*child, child_index| {
            kbuf.clearRetainingCapacity();
            if (!try appendCompositeKey(Child, child_keys, child.*, &kbuf, gpa)) continue;
            const key_copy = arena.dupe(u8, kbuf.items) catch return error.OutOfMemory;
            const gop = map.getOrPut(key_copy) catch return error.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = child_index;
        }
        for (rows) |*parent| {
            @field(parent, assoc.field_name) = null;
            kbuf.clearRetainingCapacity();
            if (!try appendCompositeKey(M, parent_keys, parent.*, &kbuf, gpa)) continue;
            if (map.get(kbuf.items)) |child_index| {
                @field(parent, assoc.field_name) = try value.deepCopy(Child, children.items[child_index], gpa);
            }
        }
    } else {
        for (rows) |*parent| {
            @field(parent, assoc.field_name) = null;
            for (children.items) |*child| {
                if (compositeKeyEqual(Child, child.*, child_keys, M, parent.*, parent_keys)) {
                    @field(parent, assoc.field_name) = try value.deepCopy(Child, child.*, gpa);
                    break;
                }
            }
        }
    }
}

fn keyPresent(comptime T: type, value_: T) bool {
    return switch (@typeInfo(T)) {
        .optional => if (value_) |unwrapped| keyPresent(@TypeOf(unwrapped), unwrapped) else false,
        else => true,
    };
}

fn keyEqual(comptime A: type, a: A, comptime B: type, b: B) bool {
    if (A == B) {
        return switch (@typeInfo(A)) {
            .pointer => |info| if (info.size == .slice and info.child == u8)
                std.mem.eql(u8, a, b)
            else
                std.meta.eql(a, b),
            else => std.meta.eql(a, b),
        };
    }
    return switch (@typeInfo(A)) {
        .optional => if (a) |unwrapped| keyEqual(@TypeOf(unwrapped), unwrapped, B, b) else false,
        else => switch (@typeInfo(B)) {
            .optional => if (b) |unwrapped| keyEqual(A, a, @TypeOf(unwrapped), unwrapped) else false,
            else => intKeyEqual(A, a, B, b),
        },
    };
}

/// Cross-width/signedness integer keys compare numerically (SQL coerces them),
/// so an i32 foreign key still matches an i64 primary key.
fn intKeyEqual(comptime A: type, a: A, comptime B: type, b: B) bool {
    if (@typeInfo(A) == .int and @typeInfo(B) == .int) {
        const ia = std.math.cast(i128, a) orelse return false;
        const ib = std.math.cast(i128, b) orelse return false;
        return ia == ib;
    }
    return false;
}

fn compositeKeyEqual(
    comptime Left: type,
    left: Left,
    comptime left_keys: []const []const u8,
    comptime Right: type,
    right: Right,
    comptime right_keys: []const []const u8,
) bool {
    if (left_keys.len != right_keys.len) return false;
    inline for (left_keys, 0..) |left_key, i| {
        if (!keyEqual(
            @TypeOf(@field(left, left_key)),
            @field(left, left_key),
            @TypeOf(@field(right, right_keys[i])),
            @field(right, right_keys[i]),
        )) return false;
    }
    return true;
}

/// True when every composite key position has an identical, hashable
/// normalized type on both sides, so matching can use a hash map.
fn compositeHashable(
    comptime L: type,
    comptime lkeys: []const []const u8,
    comptime R: type,
    comptime rkeys: []const []const u8,
) bool {
    if (lkeys.len != rkeys.len) return false;
    for (lkeys, 0..) |lk, i| {
        const LT = value.UnwrappedKey(@TypeOf(@field(@as(L, undefined), lk)));
        const RT = value.UnwrappedKey(@TypeOf(@field(@as(R, undefined), rkeys[i])));
        if (LT != RT) return false;
        // Only types with an unambiguous, compile-safe byte serialization.
        // Floats (±0.0), >64-bit ints and signed enums fall back to linear
        // matching via compositeKeyEqual.
        switch (@typeInfo(LT)) {
            .int => |info| if (info.bits > 64) return false,
            .bool => {},
            .@"enum" => |e| if (e.is_signed) return false,
            .pointer => |p| if (!(p.size == .slice and p.child == u8)) return false,
            else => return false,
        }
    }
    return true;
}

/// Serializes a composite key to canonical bytes. Returns false when any
/// component is null (such a row can never match, mirroring `keyEqual`).
fn appendCompositeKey(
    comptime M: type,
    comptime keys: []const []const u8,
    m: M,
    buf: *std.ArrayList(u8),
    buf_alloc: std.mem.Allocator,
) Error!bool {
    inline for (keys) |k| {
        const FT = @TypeOf(@field(m, k));
        const nk = value.normalizedKey(FT, @field(m, k)) orelse return false;
        const U = value.UnwrappedKey(FT);
        switch (@typeInfo(U)) {
            .int => |info| {
                var b: [8]u8 = undefined;
                const wide: u64 = if (info.signedness == .signed) @bitCast(@as(i64, nk)) else @as(u64, nk);
                std.mem.writeInt(u64, &b, wide, .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .bool => buf.append(buf_alloc, @intFromBool(nk)) catch return error.OutOfMemory,
            .@"enum" => {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @backingInt(nk), .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .float => {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(@as(f64, nk)), .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .pointer => {
                var lb: [8]u8 = undefined;
                std.mem.writeInt(u64, &lb, nk.len, .big);
                buf.appendSlice(buf_alloc, &lb) catch return error.OutOfMemory;
                buf.appendSlice(buf_alloc, nk) catch return error.OutOfMemory;
            },
            else => return error.UnsupportedType,
        }
    }
    return true;
}

fn JoinedChild(comptime Child: type, comptime ParentKey: type) type {
    return struct {
        child: Child,
        parent_key: ParentKey,
    };
}

fn queryChildrenForKeys(
    comptime Child: type,
    comptime child_table: schema.Table,
    key_column: []const u8,
    keys: anytype,
    extra_column: []const u8,
    extra_value: []const u8,
    s: *db_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    if (keys.len == 0) return .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("SELECT * FROM {s} WHERE {s} IN (", .{
        quoted(child_table.name),
        try quoteIdent(arena, key_column),
    }) catch return error.OutOfMemory;
    for (keys, 0..) |_, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("${d}", .{i + 1}) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;

    const extra = extra_column.len > 0;
    const params = arena.alloc(pq.Param, keys.len + @intFromBool(extra)) catch return error.OutOfMemory;
    for (keys, 0..) |key, i| params[i] = try value.toParam(key, arena);
    if (extra) {
        w.print(" AND {s} = ${d}", .{
            try quoteIdent(arena, extra_column),
            keys.len + 1,
        }) catch return error.OutOfMemory;
        params[keys.len] = try value.toParam(extra_value, arena);
    }
    return queryChildrenSql(Child, child_table, w.buffered(), params, s, arena);
}

fn queryChildrenSql(
    comptime Child: type,
    comptime child_table: schema.Table,
    sql: []const u8,
    params: []const pq.Param,
    s: *db_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    var res = try s.runExec(sql, params);
    defer res.deinit();

    var column_map: [child_table.columns.len]?usize = undefined;
    value.buildColumnMap(child_table, res.columns, &column_map);
    var items: std.ArrayList(Child) = .empty;
    items.ensureTotalCapacity(arena, res.rows.len) catch return error.OutOfMemory;
    for (res.rows) |row| {
        var child = try value.scanCellsMapped(Child, child_table, res.columns, row, &column_map, arena);
        try db_mod.Session.callHook(Child, "afterFind", &child, s);
        items.appendAssumeCapacity(child);
    }
    return items;
}

fn queryJoinedChildren(
    comptime Parent: type,
    comptime Child: type,
    comptime child_table: schema.Table,
    comptime assoc: schema.Assoc,
    keys: anytype,
    s: *db_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(JoinedChild(Child, FieldOfT(Parent, assoc.primary_key))) {
    const ParentKey = FieldOfT(Parent, assoc.primary_key);
    const Joined = JoinedChild(Child, ParentKey);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("SELECT ") catch return error.OutOfMemory;
    inline for (child_table.columns, 0..) |column, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        try writeQualifiedIdent(w, child_table.name, column.name);
    }
    w.writeAll(", ") catch return error.OutOfMemory;
    try writeQualifiedIdent(w, assoc.join_table, assoc.join_foreign_key);
    w.writeAll(" AS ") catch return error.OutOfMemory;
    try writeIdent(w, "__zgorm_parent_key");
    w.writeAll(" FROM ") catch return error.OutOfMemory;
    try writeIdent(w, child_table.name);
    w.writeAll(" JOIN ") catch return error.OutOfMemory;
    try writeIdent(w, assoc.join_table);
    w.writeAll(" ON ") catch return error.OutOfMemory;
    try writeQualifiedIdent(w, assoc.join_table, assoc.join_association_key);
    w.writeAll(" = ") catch return error.OutOfMemory;
    try writeQualifiedIdent(w, child_table.name, assoc.association_key);
    w.writeAll(" WHERE ") catch return error.OutOfMemory;
    try writeQualifiedIdent(w, assoc.join_table, assoc.join_foreign_key);
    w.writeAll(" IN (") catch return error.OutOfMemory;
    for (keys, 0..) |_, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("${d}", .{i + 1}) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;

    const params = arena.alloc(pq.Param, keys.len) catch return error.OutOfMemory;
    for (keys, 0..) |key, i| params[i] = try value.toParam(key, arena);
    var res = try s.runExec(w.buffered(), params);
    defer res.deinit();

    var key_index: ?usize = null;
    for (res.columns, 0..) |column, i| {
        if (std.mem.eql(u8, column.name, "__zgorm_parent_key")) {
            key_index = i;
            break;
        }
    }
    const key_column = key_index orelse return error.ProtocolViolation;
    var column_map: [child_table.columns.len]?usize = undefined;
    value.buildColumnMap(child_table, res.columns, &column_map);
    var items: std.ArrayList(Joined) = .empty;
    items.ensureTotalCapacity(arena, res.rows.len) catch return error.OutOfMemory;
    for (res.rows) |row| {
        var item = Joined{
            .child = try value.scanCellsMapped(Child, child_table, res.columns, row, &column_map, arena),
            .parent_key = try value.decodeCell(
                ParentKey,
                row[key_column],
                res.columns[key_column].type_oid,
                res.columns[key_column].format,
                arena,
            ),
        };
        try db_mod.Session.callHook(Child, "afterFind", &item.child, s);
        items.appendAssumeCapacity(item);
    }
    return items;
}

fn queryCompositeChildren(
    comptime Parent: type,
    comptime Child: type,
    rows: []Parent,
    comptime child_keys: []const []const u8,
    comptime parent_keys: []const []const u8,
    s: *db_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    if (rows.len == 0) return .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("SELECT * FROM {s} WHERE ", .{quoted(schema.tableOf(Child).name)}) catch
        return error.OutOfMemory;
    const params = arena.alloc(pq.Param, rows.len * child_keys.len) catch return error.OutOfMemory;
    var param_index: usize = 0;
    for (rows, 0..) |row, row_index| {
        if (row_index > 0) w.writeAll(" OR ") catch return error.OutOfMemory;
        w.writeByte('(') catch return error.OutOfMemory;
        inline for (child_keys, 0..) |child_key, key_index| {
            if (key_index > 0) w.writeAll(" AND ") catch return error.OutOfMemory;
            try writeIdent(w, child_key);
            w.print(" = ${d}", .{param_index + 1}) catch return error.OutOfMemory;
            params[param_index] = try value.toParam(@field(row, parent_keys[key_index]), arena);
            param_index += 1;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    return queryChildrenSql(Child, schema.tableOf(Child), w.buffered(), params, s, arena);
}

fn asI64(comptime FT: type, v: FT) ?i64 {
    return switch (@typeInfo(FT)) {
        .int => std.math.cast(i64, v),
        .optional => |oi| if (v) |x| asI64(oi.child, x) else null,
        else => null,
    };
}

/// Resolves a model column by Zig field name or SQL column name.
pub fn ColumnOfT(comptime M: type, comptime name: []const u8) schema.Column {
    inline for (schema.tableOf(M).columns) |column| {
        if (comptime std.mem.eql(u8, column.field_name, name) or
            std.mem.eql(u8, column.name, name)) return column;
    }
    @compileError("zgorm: model " ++ @typeName(M) ++ " has no field " ++ name);
}

/// Resolves the leaf field type, including embedded model fields.
pub fn FieldOfT(comptime M: type, comptime name: []const u8) type {
    return value.columnFieldType(M, ColumnOfT(M, name));
}

/// A compile-time quoted SQL identifier. Model and column metadata are
/// comptime values, so hot paths can reuse these bytes without allocation.
pub fn QuotedIdent(comptime name: []const u8) type {
    comptime var escaped_len: usize = 2;
    inline for (name) |ch| escaped_len += if (ch == '"') 2 else 1;
    return struct {
        pub const value: [escaped_len]u8 = blk: {
            var out: [escaped_len]u8 = undefined;
            var n: usize = 0;
            out[n] = '"';
            n += 1;
            for (name) |ch| {
                if (ch == '"') {
                    out[n] = '"';
                    n += 1;
                }
                out[n] = ch;
                n += 1;
            }
            out[n] = '"';
            break :blk out;
        };
    };
}

/// Zero-allocation access to a compile-time quoted identifier, for hot paths
/// where the name comes from comptime model metadata.
pub fn quoted(comptime name: []const u8) []const u8 {
    return &QuotedIdent(name).value;
}

fn DefaultSelectPrefix(comptime T: type) type {
    const table = schema.tableOf(T);
    return struct {
        pub const value = "SELECT * FROM " ++ QuotedIdent(table.name).value;
    };
}

fn writeIdent(w: *std.Io.Writer, identifier: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, identifier, i, '"')) |q| {
        try w.writeAll(identifier[i..q]);
        try w.writeAll("\"\"");
        i = q + 1;
    }
    try w.writeAll(identifier[i..]);
    try w.writeByte('"');
}

fn writeQualifiedIdent(w: *std.Io.Writer, relation: []const u8, column: []const u8) !void {
    try writeIdent(w, relation);
    try w.writeByte('.');
    try writeIdent(w, column);
}

/// Quotes an SQL identifier, escaping embedded double quotes.
pub fn quoteIdent(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '"') == null) {
        return std.fmt.allocPrint(arena, "\"{s}\"", .{name});
    }
    const out = try arena.alloc(u8, name.len * 2 + 2);
    out[0] = '"';
    var n: usize = 1;
    for (name) |ch| {
        if (ch == '"') {
            out[n] = '"';
            n += 1;
        }
        out[n] = ch;
        n += 1;
    }
    out[n] = '"';
    return out[0 .. n + 1];
}

/// Copies `frag` into `w`, shifting every `$N` placeholder by `base`.
/// Placeholders inside single/double-quoted literals are left untouched.
pub fn writeRenumbered(w: *std.Io.Writer, frag: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < frag.len) {
        const ch = frag[i];
        if (ch == '\'' or ch == '"') {
            i = try copyQuoted(w, frag, i);
            continue;
        }
        if (ch == '$' and i + 1 < frag.len and frag[i + 1] >= '0' and frag[i + 1] <= '9') {
            var j = i + 1;
            while (j < frag.len and frag[j] >= '0' and frag[j] <= '9') j += 1;
            const n = std.fmt.parseInt(usize, frag[i + 1 .. j], 10) catch {
                try w.writeAll(frag[i..j]);
                i = j;
                continue;
            };
            if (n == 0 or n > std.math.maxInt(usize) - base) {
                try w.writeAll(frag[i..j]);
            } else {
                try w.print("${d}", .{n + base});
            }
            i = j;
            continue;
        }
        // Plain run (including a non-placeholder '$') up to the next quote or
        // placeholder start.
        var j = i + 1;
        while (j < frag.len) {
            const c2 = frag[j];
            if (c2 == '\'' or c2 == '"') break;
            if (c2 == '$' and j + 1 < frag.len and frag[j + 1] >= '0' and frag[j + 1] <= '9') break;
            j += 1;
        }
        try w.writeAll(frag[i..j]);
        i = j;
    }
}

/// Copies a single/double-quoted run (handling doubled-quote escapes)
/// verbatim, returning the index just past the closing quote.
fn copyQuoted(w: *std.Io.Writer, frag: []const u8, start: usize) !usize {
    const q = frag[start];
    try w.writeByte(q);
    var i = start + 1;
    while (i < frag.len) {
        try w.writeByte(frag[i]);
        if (frag[i] == q) {
            if (i + 1 < frag.len and frag[i + 1] == q) {
                try w.writeByte(frag[i + 1]);
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return i;
}

const testing = std.testing;

test "placeholder renumbering" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRenumbered(&w, "age > $1 AND name LIKE $2", 3);
    try testing.expectEqualStrings("age > $4 AND name LIKE $5", w.buffered());
    var edge_buf: [256]u8 = undefined;
    var edge_writer: std.Io.Writer = .fixed(&edge_buf);
    try writeRenumbered(&edge_writer, "$0 $99999999999999999999999999999999999999", 3);
    try testing.expectEqualStrings("$0 $99999999999999999999999999999999999999", edge_writer.buffered());
}

test "placeholder renumbering skips quoted literals" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRenumbered(&w, "note = '$100' AND id = $1", 3);
    try testing.expectEqualStrings("note = '$100' AND id = $4", w.buffered());

    var buf2: [256]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try writeRenumbered(&w2, "x = \"a$1b\" AND y = $2", 1);
    try testing.expectEqualStrings("x = \"a$1b\" AND y = $3", w2.buffered());

    var buf3: [256]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&buf3);
    try writeRenumbered(&w3, "s = 'it''s $1' AND id = $1", 5);
    try testing.expectEqualStrings("s = 'it''s $1' AND id = $6", w3.buffered());
}

test "cross-width integer association keys match numerically" {
    try testing.expect(keyEqual(i32, @as(i32, 7), i64, @as(i64, 7)));
    try testing.expect(keyEqual(i64, @as(i64, 7), i32, @as(i32, 7)));
    try testing.expect(!keyEqual(i32, @as(i32, 7), i64, @as(i64, 8)));
    try testing.expect(keyEqual(?i32, @as(?i32, 7), i64, @as(i64, 7)));
    try testing.expect(!keyEqual(?i32, @as(?i32, null), i64, @as(i64, 7)));
    try testing.expect(keyEqual(u32, @as(u32, 9), i64, @as(i64, 9)));
}

test "quoteIdent escapes quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\"users\"", try quoteIdent(a, "users"));
    try testing.expectEqualStrings("\"we\"\"ird\"", try quoteIdent(a, "we\"ird"));
    try testing.expectEqualStrings("\"users\"", QuotedIdent("users").value[0..]);
    try testing.expectEqualStrings("\"we\"\"ird\"", QuotedIdent("we\"ird").value[0..]);
}

test "association IDs outside i64 are ignored" {
    try testing.expectEqual(@as(?i64, null), asI64(u64, std.math.maxInt(u64)));
}

const SoftDeleteTestModel = struct {
    id: ?i64 = null,
    deleted_at: ?time_mod.Time = null,

    pub const zgorm = .{ .table = "records" };
};

test "for update and soft delete SQL" {
    var q = Query(SoftDeleteTestModel){
        .sess = undefined,
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    defer q.arena.deinit();
    _ = q.for_update();
    try testing.expect(q.for_update_flag);
    try testing.expectEqualStrings(
        "UPDATE \"records\" SET \"deleted_at\" = now() WHERE \"deleted_at\" IS NULL",
        try q.buildDeleteSql(),
    );

    q.unscoped_flag = true;
    try testing.expectEqualStrings("DELETE FROM \"records\"", try q.buildDeleteSql());
}
