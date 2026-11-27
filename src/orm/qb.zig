//! GORM-style query builder.
//!
//! Conditions are AND-combined; `orWhere` starts an OR group. `limit`,
//! `offset`, `order_by`, `group_by`, `having`, `for_update` map 1:1 onto SQL.
//! Placeholder indices in user fragments (`$1`, `$2`, ...) are renumbered
//! automatically as conditions chain up.
//!
//! Terminal operations (`all`, `first`, `count`, `exists`, `delete`) consume
//! the builder and release its scratch memory.
//!
//! SQL text helpers live in `sqlutil.zig`; association preloading in
//! `preload.zig`. Both are re-exported here for compatibility.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const session_mod = @import("session.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const sqlutil = @import("sql.zig");
const preload = @import("preload.zig");

pub const Error = pq.Error;

// SQL helpers (canonical home: sqlutil.zig).
pub const QuotedIdent = sqlutil.QuotedIdent;
pub const quoted = sqlutil.quoted;
pub const quoteIdent = sqlutil.quoteIdent;
pub const writeRenumbered = sqlutil.writeRenumbered;
pub const softDeleteStampSql = sqlutil.softDeleteStampSql;
const writeNamed = sqlutil.writeNamed;
const DefaultSelectPrefix = sqlutil.DefaultSelectPrefix;

// Preload helpers (canonical home: preload.zig).
pub const validatePreloadPath = preload.validatePreloadPath;
pub const applyPreloadPath = preload.applyPreloadPath;
pub const ColumnOfT = preload.ColumnOfT;
pub const FieldOfT = preload.FieldOfT;

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

        sess: *session_mod.Session,
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
            const frag = std.fmt.allocPrint(q.a(), "{s} = $1", .{sqlutil.quoteIdent(q.a(), col) catch return q.errOut()}) catch return q.errOut();
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
            w.writeAll(sqlutil.quoteIdent(q.a(), col) catch return q.errOut()) catch return q.errOut();
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
                    try w.print(" WHERE {s} IS NULL", .{sqlutil.quoted(del_col.name)});
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
                try sqlutil.writeRenumbered(w, cond.frag, cond.args_start + param_offset);
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
                    try w.print("{s} AS (", .{try sqlutil.quoteIdent(q.a(), cte.name)});
                    try sqlutil.writeRenumbered(w, cte.sql, cte.args_start);
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
                            try w.writeAll(try sqlutil.quoteIdent(q.a(), col));
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
                            try w.writeAll(try sqlutil.quoteIdent(q.a(), col));
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
                try sqlutil.writeRenumbered(w, join_clause.sql, join_clause.args_start);
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
                    try sqlutil.writeRenumbered(w, having_clause.frag, having_clause.args_start);
                    try w.writeByte(')');
                }
                for (q.unions.items) |union_clause| {
                    try w.writeAll(if (union_clause.all) " UNION ALL " else " UNION ");
                    try sqlutil.writeRenumbered(w, union_clause.sql, union_clause.args_start);
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
                        sqlutil.quoted(table.name),
                        sqlutil.quoted(del_col.name),
                        softDeleteStampSql(value.columnFieldType(T, del_col)),
                    });
                } else {
                    try w.print("DELETE FROM {s}", .{sqlutil.quoted(table.name)});
                }
            } else {
                try w.print("DELETE FROM {s}", .{sqlutil.quoted(table.name)});
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
                    try w.writeAll(try sqlutil.quoteIdent(q.a(), name));
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
            w.print("UPDATE {s} SET ", .{sqlutil.quoted(table.name)}) catch return error.OutOfMemory;
            inline for (info.@"struct".field_names, 0..) |field_name, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                comptime var column_name: ?[]const u8 = null;
                inline for (table.columns) |col| {
                    if (comptime std.mem.eql(u8, col.field_name, field_name)) column_name = col.name;
                }
                if (column_name == null) @compileError("zgorm: update field is not a model column: " ++ field_name);
                w.print("{s} = ${d}", .{ sqlutil.quoted(column_name.?), i + 1 }) catch return error.OutOfMemory;
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

        sess: *session_mod.Session,
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
            session_mod.Session.callHook(T, "afterFind", &model, r.sess) catch |err| {
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

const testing = std.testing;

const SoftDeleteTestModel = struct {
    id: ?i64 = null,
    deleted_at: ?@import("time.zig").Time = null,

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

test {
    _ = sqlutil;
    _ = preload;
}
