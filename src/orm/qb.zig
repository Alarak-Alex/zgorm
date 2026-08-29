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
const pq = @import("../pq.zig");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const time_mod = @import("time.zig");
const value = @import("value.zig");

pub const Error = pq.Error;

pub fn Query(comptime T: type) type {
    const table = comptime schema.tableOf(T);
    return struct {
        const Self = @This();

        const Cond = struct {
            frag: []const u8,
            is_or: bool = false,
            args_start: usize,
        };

        sess: *db_mod.Session,
        /// True when the query owns its (heap) session — one-shot Db queries.
        owns_session: bool = false,
        arena: *std.heap.ArenaAllocator,
        err: ?Error = null,

        cols: ?[]const []const u8 = null,
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
        having_cond: ?Cond = null,
        limit_n: ?i64 = null,
        offset_n: ?i64 = null,
        for_update_flag: bool = false,

        fn a(q: *Self) std.mem.Allocator {
            return q.arena.allocator();
        }

        pub fn deinit(q: *Self) void {
            if (q.freed) return;
            q.freed = true;
            const gpa = q.sess.gpa;
            const arena = q.arena;
            const sess = q.sess;
            const owns_session = q.owns_session;
            q.conds.deinit(gpa);
            q.args.deinit(gpa);
            arena.deinit();
            gpa.destroy(arena);
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

        pub fn distinct(q: *Self) *Self {
            q.is_distinct = true;
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
                .@"struct" => |si| si.fields.len,
                .pointer => |pi| switch (pi.size) {
                    .slice => values.len,
                    .one => switch (@typeInfo(pi.child)) {
                        .array => |ai| ai.len,
                        .@"struct" => |si| if (si.is_tuple) si.fields.len else 1,
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

        // ------------------------------------------------------------ build

        /// Writes `WHERE ...` (or nothing when no conditions) into `w`.
        /// Prepends the soft-delete filter unless unscoped.
        fn buildWhere(q: *Self, w: *std.Io.Writer) !void {
            var wrote_filter = false;
            if (comptime table.softDeletable()) {
                if (!q.unscoped_flag) {
                    const del_col = table.columns[table.deleted_at_index.?];
                    try w.print(" WHERE {s} IS NULL", .{try quoteIdent(q.a(), del_col.name)});
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
                const base = cond.args_start;
                try writeRenumbered(w, cond.frag, base);
                try w.writeByte(')');
            }
        }

        fn buildSelectSql(q: *Self, count_mode: bool) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            if (count_mode) {
                try w.print("SELECT count(*) FROM {s}", .{try quoteIdent(q.a(), table.name)});
            } else {
                try w.writeAll("SELECT ");
                if (q.is_distinct) try w.writeAll("DISTINCT ");
                if (q.cols) |cols| {
                    for (cols, 0..) |c, i| {
                        if (i > 0) try w.writeAll(", ");
                        const quoted = try quoteIdent(q.a(), c);
                        try w.writeAll(quoted);
                    }
                } else {
                    try w.writeByte('*');
                }
                try w.print(" FROM {s}", .{try quoteIdent(q.a(), table.name)});
            }
            try q.buildWhere(w);
            if (!count_mode) {
                if (q.groups.items.len > 0) {
                    try w.writeAll(" GROUP BY ");
                    for (q.groups.items, 0..) |g, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(g);
                    }
                }
                if (q.having_cond) |h| {
                    try w.writeAll(" HAVING (");
                    try writeRenumbered(w, h.frag, h.args_start);
                    try w.writeByte(')');
                }
                if (q.orders.items.len > 0) {
                    try w.writeAll(" ORDER BY ");
                    for (q.orders.items, 0..) |o, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.writeAll(o);
                    }
                }
                if (q.limit_n) |n| try w.print(" LIMIT {d}", .{n});
                if (q.offset_n) |n| try w.print(" OFFSET {d}", .{n});
                if (q.for_update_flag) try w.writeAll(" FOR UPDATE");
            }
            return aw.writer.buffered();
        }

        fn buildDeleteSql(q: *Self) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            if (comptime table.softDeletable()) {
                if (!q.unscoped_flag) {
                    const del_col = table.columns[table.deleted_at_index.?];
                    try w.print("UPDATE {s} SET {s} = {s}", .{
                        try quoteIdent(q.a(), table.name),
                        try quoteIdent(q.a(), del_col.name),
                        softDeleteStampSql(value.columnFieldType(T, del_col)),
                    });
                } else {
                    try w.print("DELETE FROM {s}", .{try quoteIdent(q.a(), table.name)});
                }
            } else {
                try w.print("DELETE FROM {s}", .{try quoteIdent(q.a(), table.name)});
            }
            try q.buildWhere(w);
            return aw.writer.buffered();
        }

        fn run(q: *Self, sql: []const u8) Error!pq.Result {
            const conn = try q.sess.acquire();
            const res = conn.execParams(sql, q.args.items) catch |e| {
                q.sess.captureError(conn);
                q.sess.releaseConn(conn);
                return e;
            };
            q.sess.releaseConn(conn);
            return res;
        }

        // -------------------------------------------------------- terminals

        /// Executes the query and returns all matching rows.
        pub fn all(q: *Self, out_gpa: std.mem.Allocator) Error![]T {
            q.startTerminal() catch |e| {
                q.deinit();
                return e;
            };
            errdefer q.deinit();
            const sql = q.buildSelectSql(false) catch return error.OutOfMemory;
            var res = try q.run(sql);
            defer res.deinit();

            const rows = out_gpa.alloc(T, res.rows.len) catch return error.OutOfMemory;
            var decoded: usize = 0;
            errdefer {
                // Free every fully decoded row plus the row array itself.
                for (rows[0..decoded]) |*r| value.freeValue(T, r.*, out_gpa);
                out_gpa.free(rows);
            }
            for (res.rows, 0..) |row, i| {
                rows[i] = try value.scanRow(T, table, &res, row, out_gpa);
                decoded = i + 1;
                try db_mod.Session.callHook(T, "afterFind", &rows[i], q.sess);
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
            if (q.limit_n == null) q.limit_n = 1;
            const sql = q.buildSelectSql(false) catch return error.OutOfMemory;
            var res = try q.run(sql);
            defer res.deinit();
            if (res.rows.len == 0) {
                q.deinit();
                return null;
            }
            var one = [1]T{try value.scanRow(T, table, &res, res.rows[0], q.sess.gpa)};
            errdefer value.freeValue(T, one[0], q.sess.gpa);
            try db_mod.Session.callHook(T, "afterFind", &one[0], q.sess);
            try q.applyPreloads(&one, q.sess.gpa);
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
            const sql = q.buildSelectSql(true) catch return error.OutOfMemory;
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
            const sql = q.buildSelectSql(false) catch return error.OutOfMemory;
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
    };
}

/// SQL expression used to stamp a soft-delete `deleted_at` column. Uses the
/// database clock so all writers agree on time.
pub fn softDeleteStampSql(comptime FType: type) []const u8 {
    const E = if (@typeInfo(FType) == .optional) @typeInfo(FType).optional.child else FType;
    return switch (E) {
        time_mod.Time => "now()",
        i64 => "(extract(epoch from now()) * 1000000)::bigint",
        else => @compileError("zorm: deleted_at must be zorm.Time or i64"),
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
                @compileError("zorm: preload('" ++ path ++ "'): '" ++ seg ++
                    "' is not a declared association of " ++ @typeName(model) ++
                    " (declare it via `pub const zorm = .{ .has_many = ... }` or `.belongs_to = ...`)");
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
    const Child = assoc.model;
    const child_table = comptime schema.tableOf(Child);

    switch (assoc.kind) {
        .has_many => {
            const pkc = comptime schema.tableOf(M).pk() orelse
                @compileError("zorm: has_many requires the parent model to declare a primary key");
            var ids: std.ArrayList(i64) = .empty;
            defer ids.deinit(gpa);
            var parent_indexes: std.ArrayList(usize) = .empty;
            defer parent_indexes.deinit(gpa);
            for (rows, 0..) |*r, ri| {
                if (asIFieldOf(M, pkc.field_name, @field(r, pkc.field_name))) |id| {
                    ids.append(gpa, id) catch return error.OutOfMemory;
                    parent_indexes.append(gpa, ri) catch return error.OutOfMemory;
                }
            }
            if (ids.items.len == 0) return;

            // Children are decoded into a scratch arena and deep copied into
            // `gpa`; the originals die with the arena.
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var children = try queryChildren(Child, child_table, assoc.foreign_key, ids.items, s, arena);
            defer children.deinit(arena);

            // Per-parent slices are allocated independently so the result
            // owns a freeable slice per row.
            const ChildSliceT = @TypeOf(@field(@as(M, undefined), assoc.field_name));
            const slices = gpa.alloc(ChildSliceT, rows.len) catch return error.OutOfMemory;
            defer gpa.free(slices);
            var fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(fill);
            var counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(counts);
            @memset(counts, 0);

            var owners = gpa.alloc(usize, children.items.len) catch return error.OutOfMemory;
            defer gpa.free(owners);
            for (children.items, 0..) |*c, ci| {
                const fk = asIFieldOf(Child, assoc.foreign_key, @field(c, assoc.foreign_key));
                var owner: ?usize = null;
                if (fk) |k| {
                    for (ids.items, 0..) |id, ii| {
                        if (id == k) {
                            owner = parent_indexes.items[ii];
                            break;
                        }
                    }
                }
                owners[ci] = owner orelse std.math.maxInt(usize);
                if (owner) |pi| counts[pi] += 1;
            }
            for (rows, 0..) |_, pi| {
                slices[pi] = gpa.alloc(Child, counts[pi]) catch return error.OutOfMemory;
                fill[pi] = 0;
            }
            for (children.items, 0..) |*c, ci| {
                if (owners[ci] != std.math.maxInt(usize)) {
                    const pi = owners[ci];
                    slices[pi][fill[pi]] = try value.deepCopy(Child, c.*, gpa);
                    fill[pi] += 1;
                }
            }
            // Assign before applying nested preloads so they mutate the rows.
            for (rows, 0..) |*r, pi| {
                @field(r, assoc.field_name) = slices[pi];
            }
            if (nested.len > 0) {
                for (slices, 0..) |child_rows, pi| {
                    _ = pi;
                    try applyPreloadPath(Child, child_rows, nested, s, gpa);
                }
            }
        },
        .belongs_to => {
            var ids: std.ArrayList(i64) = .empty;
            defer ids.deinit(gpa);
            for (rows) |*r| {
                if (asIFieldOf(M, assoc.foreign_key, @field(r, assoc.foreign_key))) |id| {
                    ids.append(gpa, id) catch return error.OutOfMemory;
                }
            }
            if (ids.items.len == 0) return;

            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            var children = try queryChildren(Child, child_table, assoc.primary_key, ids.items, s, arena);
            defer children.deinit(arena);

            // One deep copy per row; nested preloads mutate these copies.
            const FieldT = FieldOfT(M, assoc.field_name);
            const copies = gpa.alloc(FieldT, rows.len) catch return error.OutOfMemory;
            defer gpa.free(copies);
            var has = gpa.alloc(bool, rows.len) catch return error.OutOfMemory;
            defer gpa.free(has);

            for (rows, 0..) |*r, ri| {
                const fk = asIFieldOf(M, assoc.foreign_key, @field(r, assoc.foreign_key));
                has[ri] = false;
                if (fk == null) continue;
                @field(r, assoc.field_name) = null;
                for (children.items) |*c| {
                    const pk = asIFieldOf(Child, assoc.primary_key, @field(c, assoc.primary_key));
                    if (pk != null and pk.? == fk.?) {
                        // Deep copy: several rows may reference the same
                        // child, so each gets its own strings.
                        copies[ri] = try value.deepCopy(Child, c.*, gpa);
                        has[ri] = true;
                        break;
                    }
                }
            }

            if (nested.len > 0) {
                var selected: std.ArrayList(Child) = .empty;
                defer selected.deinit(gpa);
                var index = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
                defer gpa.free(index);
                for (rows, 0..) |_, ri| {
                    if (has[ri]) {
                        index[ri] = selected.items.len;
                        selected.append(gpa, copies[ri].?) catch return error.OutOfMemory;
                    }
                }
                try applyPreloadPath(Child, selected.items, nested, s, gpa);
                for (rows, 0..) |*r, ri| {
                    if (has[ri]) @field(r, assoc.field_name) = selected.items[index[ri]];
                }
                return;
            }
            for (rows, 0..) |*r, ri| {
                if (has[ri]) @field(r, assoc.field_name) = copies[ri];
            }
        },
    }
}

/// Runs `SELECT * FROM child WHERE key_col IN (...)` and decodes rows into
/// `arena`.
fn queryChildren(
    comptime Child: type,
    comptime child_table: schema.Table,
    key_column: []const u8,
    ids: []const i64,
    s: *db_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("SELECT * FROM {s} WHERE {s} IN (", .{
        try quoteIdent(arena, child_table.name),
        try quoteIdent(arena, key_column),
    }) catch return error.OutOfMemory;
    for (ids, 0..) |_, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("${d}", .{i + 1}) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;

    const params = arena.alloc(pq.Param, ids.len) catch return error.OutOfMemory;
    for (ids, 0..) |id, i| {
        params[i] = try value.toParam(id, arena);
    }

    const conn = try s.acquire();
    var res = conn.execParams(aw.writer.buffered(), params) catch |e| {
        s.captureError(conn);
        s.releaseConn(conn);
        return e;
    };
    s.releaseConn(conn);
    defer res.deinit();

    var items: std.ArrayList(Child) = .empty;
    for (res.rows) |row| {
        var child = try value.scanRow(Child, child_table, &res, row, arena);
        try db_mod.Session.callHook(Child, "afterFind", &child, s);
        items.append(arena, child) catch return error.OutOfMemory;
    }
    return items;
}

fn asIFieldOf(comptime M: type, comptime name: []const u8, field_value: FieldOfT(M, name)) ?i64 {
    return asI64(FieldOfT(M, name), field_value);
}

fn asI64(comptime FT: type, v: FT) ?i64 {
    return switch (@typeInfo(FT)) {
        .int => std.math.cast(i64, v),
        .optional => |oi| if (v) |x| asI64(oi.child, x) else null,
        else => null,
    };
}

/// Resolves the struct field type `name` on model `M`.
pub fn FieldOfT(comptime M: type, comptime name: []const u8) type {
    inline for (@typeInfo(M).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("zorm: model " ++ @typeName(M) ++ " has no field " ++ name);
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
pub fn writeRenumbered(w: *std.Io.Writer, frag: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < frag.len) {
        if (frag[i] == '$' and i + 1 < frag.len and frag[i + 1] >= '0' and frag[i + 1] <= '9') {
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
        } else {
            try w.writeByte(frag[i]);
            i += 1;
        }
    }
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

test "quoteIdent escapes quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\"users\"", try quoteIdent(a, "users"));
    try testing.expectEqualStrings("\"we\"\"ird\"", try quoteIdent(a, "we\"ird"));
}

test "association IDs outside i64 are ignored" {
    try testing.expectEqual(@as(?i64, null), asI64(u64, std.math.maxInt(u64)));
}

const SoftDeleteTestModel = struct {
    id: ?i64 = null,
    deleted_at: ?time_mod.Time = null,

    pub const zorm = .{ .table = "records" };
};

test "for update and soft delete SQL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var q = Query(SoftDeleteTestModel){
        .sess = undefined,
        .arena = &arena_state,
    };
    _ = q.for_update();
    try testing.expect(q.for_update_flag);
    try testing.expectEqualStrings(
        "UPDATE \"records\" SET \"deleted_at\" = now() WHERE \"deleted_at\" IS NULL",
        try q.buildDeleteSql(),
    );

    q.unscoped_flag = true;
    try testing.expectEqualStrings("DELETE FROM \"records\"", try q.buildDeleteSql());
}
