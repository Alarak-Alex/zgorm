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
        conds: std.ArrayList(Cond) = .empty,
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

        /// Frees the builder if no error is pending, and returns the pending
        /// error otherwise. Terminal operations call this first.
        fn startTerminal(q: *Self) Error!void {
            if (q.err) |e| {
                q.deinit();
                return e;
            }
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
            q.for_update = true;
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
        fn buildWhere(q: *Self, w: *std.Io.Writer) !void {
            for (q.conds.items, 0..) |cond, i| {
                if (i == 0) {
                    try w.writeAll(" WHERE ");
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

        fn run(q: *Self, sql: []const u8) Error!pq.Result {
            const conn = q.sess.acquire() catch |e| {
                q.deinit();
                return e;
            };
            const res = conn.execParams(sql, q.args.items) catch |e| {
                q.sess.captureError(conn);
                q.sess.releaseConn(conn);
                q.deinit();
                return e;
            };
            q.sess.releaseConn(conn);
            q.deinit();
            return res;
        }

        // -------------------------------------------------------- terminals

        /// Executes the query and returns all matching rows.
        pub fn all(q: *Self, out_gpa: std.mem.Allocator) Error![]T {
            try q.startTerminal();
            const sql = q.buildSelectSql(false) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            var res = try q.run(sql);
            defer res.deinit();

            const rows = out_gpa.alloc(T, res.rows.len) catch return error.OutOfMemory;
            var ok = true;
            for (res.rows, 0..) |row, i| {
                rows[i] = value.scanRow(T, table, &res, row, out_gpa) catch {
                    ok = false;
                    break;
                };
            }
            if (!ok) {
                value.freeSlice(T, rows[0..0], out_gpa);
                return error.TypeMismatch;
            }
            return rows;
        }

        /// Executes the query and returns the first row, if any.
        pub fn first(q: *Self) Error!?T {
            try q.startTerminal();
            if (q.limit_n == null) q.limit_n = 1;
            const sql = q.buildSelectSql(false) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            var res = try q.run(sql);
            defer res.deinit();
            if (res.rows.len == 0) return null;
            return try value.scanRow(T, table, &res, res.rows[0], q.sess.gpa);
        }

        /// `SELECT count(*)` with the configured conditions.
        pub fn count(q: *Self) Error!i64 {
            try q.startTerminal();
            const sql = q.buildSelectSql(true) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            var res = try q.run(sql);
            defer res.deinit();
            if (res.rows.len == 0 or res.rows[0][0] == null) return 0;
            return std.fmt.parseInt(i64, res.rows[0][0].?, 10) catch 0;
        }

        /// True when at least one row matches.
        pub fn exists(q: *Self) Error!bool {
            try q.startTerminal();
            q.limit_n = 1;
            const sql = q.buildSelectSql(false) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            var res = try q.run(sql);
            defer res.deinit();
            return res.rows.len > 0;
        }

        /// `DELETE FROM table WHERE ...`, returns affected rows.
        pub fn delete(q: *Self) Error!i64 {
            try q.startTerminal();
            var aw: std.Io.Writer.Allocating = .init(q.a());
            const w = &aw.writer;
            w.print("DELETE FROM {s}", .{try quoteIdent(q.a(), table.name)}) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            q.buildWhere(w) catch {
                q.deinit();
                return error.OutOfMemory;
            };
            var res = try q.run(aw.writer.buffered());
            defer res.deinit();
            return res.affected;
        }
    };
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
            const n = std.fmt.parseInt(usize, frag[i + 1 .. j], 10) catch 0;
            try w.print("${d}", .{n + base});
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
}

test "quoteIdent escapes quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\"users\"", try quoteIdent(a, "users"));
    try testing.expectEqualStrings("\"we\"\"ird\"", try quoteIdent(a, "we\"ird"));
}
