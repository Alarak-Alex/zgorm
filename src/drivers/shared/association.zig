const std = @import("std");
const dialect_mod = @import("dialect.zig");
const schema = @import("../../orm/schema.zig");
const types = @import("types.zig");
const value = @import("../../orm/value.zig");

/// Compile-time backtick-quoted identifier (matches the historical quoting
/// used by this module for join tables across all dialects).
fn QuotedIdent(comptime name: []const u8) type {
    comptime var len: usize = 2;
    inline for (name) |ch| len += if (ch == '`') 2 else 1;
    return struct {
        pub const value: [len]u8 = blk: {
            var out: [len]u8 = undefined;
            var n: usize = 0;
            out[n] = '`';
            n += 1;
            for (name) |ch| {
                if (ch == '`') {
                    out[n] = '`';
                    n += 1;
                }
                out[n] = ch;
                n += 1;
            }
            out[n] = '`';
            break :blk out;
        };
    };
}

pub fn Association(
    comptime Db: type,
    comptime dialect: dialect_mod.Dialect,
    comptime M: type,
    comptime field_name: []const u8,
) type {
    const assoc = comptime schema.tableOf(M).assoc(field_name) orelse
        @compileError("zgorm: unknown association " ++ field_name);
    const Child = assoc.model;
    const join_table_q = QuotedIdent(assoc.join_table).value;
    const join_fk_q = QuotedIdent(assoc.join_foreign_key).value;
    const join_ak_q = QuotedIdent(assoc.join_association_key).value;
    const count_sql = "SELECT count(*) FROM " ++ join_table_q ++ " WHERE " ++ join_fk_q ++ " = ?";
    const join_insert_head = "INSERT INTO " ++ join_table_q ++ " (" ++ join_fk_q ++ ", " ++ join_ak_q ++ ") VALUES ";
    const join_insert_tail = if (dialect == .mysql)
        " ON DUPLICATE KEY UPDATE " ++ join_fk_q ++ " = " ++ join_fk_q
    else
        " ON CONFLICT DO NOTHING";
    const append_sql = join_insert_head ++ "(?, ?)" ++ join_insert_tail;
    const delete_join_sql = "DELETE FROM " ++ join_table_q ++ " WHERE " ++ join_fk_q ++ " = ?";
    const delete_join_child_sql = delete_join_sql ++ " AND " ++ join_ak_q ++ " = ?";
    return struct {
        const Self = @This();

        db: *Db,
        parent: *M,

        pub fn count(a: *Self) types.Error!i64 {
            if (assoc.kind != .many_to_many) {
                var query = a.db.query(Child).whereEq(assoc.foreign_key, @field(a.parent, assoc.primary_key));
                if (assoc.polymorphic_type.len > 0)
                    query = query.whereEq(assoc.polymorphic_type, assoc.polymorphic_value);
                return query.count();
            }
            var result = try a.db.execArgs(count_sql, .{@field(a.parent, assoc.primary_key)});
            defer result.deinit();
            if (result.rows.len != 1 or result.rows[0].len != 1 or result.rows[0][0] == null)
                return error.ProtocolViolation;
            return std.fmt.parseInt(i64, result.rows[0][0].?, 10) catch return error.TypeMismatch;
        }

        pub fn append(a: *Self, child: *Child) types.Error!void {
            if (assoc.kind != .many_to_many) {
                const parent_key = @field(a.parent, assoc.primary_key);
                switch (@typeInfo(@TypeOf(parent_key))) {
                    .optional => @field(child, assoc.foreign_key) = parent_key orelse return error.NullValue,
                    else => @field(child, assoc.foreign_key) = parent_key,
                }
                if (assoc.polymorphic_type.len > 0)
                    @field(child, assoc.polymorphic_type) = assoc.polymorphic_value;
                try a.db.save(child);
                return;
            }
            try a.db.save(child);
            var result = try a.db.execArgs(append_sql, .{
                @field(a.parent, assoc.primary_key),
                @field(child, assoc.association_key),
            });
            result.deinit();
        }

        pub fn clear(a: *Self) types.Error!void {
            if (assoc.kind != .many_to_many) {
                var query = a.db.query(Child).whereEq(assoc.foreign_key, @field(a.parent, assoc.primary_key));
                if (assoc.polymorphic_type.len > 0)
                    query = query.whereEq(assoc.polymorphic_type, assoc.polymorphic_value);
                _ = try query.delete();
                return;
            }
            try a.deleteJoin(null);
        }

        pub fn delete(a: *Self, child: *Child) types.Error!void {
            if (assoc.kind != .many_to_many) {
                try a.db.delete(child);
                return;
            }
            try a.deleteJoin(@field(child, assoc.association_key));
        }

        pub fn replace(a: *Self, children: []Child) types.Error!void {
            var tx = try a.db.begin();
            errdefer tx.rollback() catch {};
            const Keys = value.AutoKeys(Child);
            const keys = try Keys.capture(a.db.backend.gpa, children);
            defer a.db.backend.gpa.free(keys);
            errdefer Keys.restore(children, keys);
            try a.clear();
            if (assoc.kind != .many_to_many) {
                for (children) |*child| try a.append(child);
                return tx.commit();
            }
            // Save children first (backfills their pks), then insert all join
            // rows in chunked multi-row statements instead of one per child.
            for (children) |*child| try a.db.save(child);
            var arena_state = std.heap.ArenaAllocator.init(a.db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const chunk_rows = @max(@as(usize, 1), dialect.maxParameters() / 2);
            var i: usize = 0;
            while (i < children.len) {
                const end = @min(i + chunk_rows, children.len);
                const chunk = children[i..end];
                var sql: std.Io.Writer.Allocating = .init(arena);
                const w = &sql.writer;
                w.writeAll(join_insert_head) catch return error.OutOfMemory;
                const params = arena.alloc(types.Param, chunk.len * 2) catch return error.OutOfMemory;
                var np: usize = 0;
                for (chunk, 0..) |*child, r| {
                    if (r > 0) w.writeAll(", ") catch return error.OutOfMemory;
                    w.writeAll("(?, ?)") catch return error.OutOfMemory;
                    params[np] = try value.toParam(@field(a.parent, assoc.primary_key), arena);
                    np += 1;
                    params[np] = try value.toParam(@field(child, assoc.association_key), arena);
                    np += 1;
                }
                w.writeAll(join_insert_tail) catch return error.OutOfMemory;
                var result = try a.db.runParams(w.buffered(), params[0..np], 0);
                result.deinit();
                i = end;
            }
            try tx.commit();
        }

        fn deleteJoin(a: *Self, child_key: anytype) types.Error!void {
            var result = if (@TypeOf(child_key) == @TypeOf(null))
                try a.db.execArgs(delete_join_sql, .{@field(a.parent, assoc.primary_key)})
            else
                try a.db.execArgs(delete_join_child_sql, .{ @field(a.parent, assoc.primary_key), child_key });
            result.deinit();
        }
    };
}
