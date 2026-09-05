const std = @import("std");
const dialect_mod = @import("dialect.zig");
const schema = @import("../../orm/schema.zig");
const types = @import("types.zig");

pub fn Association(
    comptime Db: type,
    comptime dialect: dialect_mod.Dialect,
    comptime M: type,
    comptime field_name: []const u8,
) type {
    const assoc = comptime schema.tableOf(M).assoc(field_name) orelse
        @compileError("zgorm: unknown association " ++ field_name);
    const Child = assoc.model;
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
            var arena_state = std.heap.ArenaAllocator.init(a.db.backend.gpa);
            defer arena_state.deinit();
            const sql = std.fmt.allocPrint(arena_state.allocator(), "SELECT count(*) FROM {s} WHERE {s} = ?", .{
                try quoteIdent(arena_state.allocator(), assoc.join_table),
                try quoteIdent(arena_state.allocator(), assoc.join_foreign_key),
            }) catch return error.OutOfMemory;
            var result = try a.db.execArgs(sql, .{@field(a.parent, assoc.primary_key)});
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
            var arena_state = std.heap.ArenaAllocator.init(a.db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const prefix = if (dialect == .mysql) "INSERT IGNORE INTO" else "INSERT INTO";
            const suffix = if (dialect == .sqlite) " ON CONFLICT DO NOTHING" else "";
            const sql = std.fmt.allocPrint(arena, "{s} {s} ({s}, {s}) VALUES (?, ?){s}", .{
                prefix,
                try quoteIdent(arena, assoc.join_table),
                try quoteIdent(arena, assoc.join_foreign_key),
                try quoteIdent(arena, assoc.join_association_key),
                suffix,
            }) catch return error.OutOfMemory;
            var result = try a.db.execArgs(sql, .{
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
            try a.clear();
            for (children) |*child| try a.append(child);
        }

        fn deleteJoin(a: *Self, child_key: anytype) types.Error!void {
            var arena_state = std.heap.ArenaAllocator.init(a.db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const sql = if (@TypeOf(child_key) == @TypeOf(null))
                std.fmt.allocPrint(arena, "DELETE FROM {s} WHERE {s} = ?", .{
                    try quoteIdent(arena, assoc.join_table),
                    try quoteIdent(arena, assoc.join_foreign_key),
                }) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(arena, "DELETE FROM {s} WHERE {s} = ? AND {s} = ?", .{
                    try quoteIdent(arena, assoc.join_table),
                    try quoteIdent(arena, assoc.join_foreign_key),
                    try quoteIdent(arena, assoc.join_association_key),
                }) catch return error.OutOfMemory;
            var result = if (@TypeOf(child_key) == @TypeOf(null))
                try a.db.execArgs(sql, .{@field(a.parent, assoc.primary_key)})
            else
                try a.db.execArgs(sql, .{ @field(a.parent, assoc.primary_key), child_key });
            result.deinit();
        }
    };
}

fn quoteIdent(gpa: std.mem.Allocator, ident: []const u8) types.Error![]const u8 {
    const quote: u8 = if (ident.len == 0) return error.InvalidColumn else '"';
    _ = quote;
    var output: std.Io.Writer.Allocating = .init(gpa);
    const w = &output.writer;
    const delimiter: u8 = '`';
    try w.writeByte(delimiter);
    for (ident) |ch| {
        if (ch == 0) return error.InvalidColumn;
        try w.writeByte(ch);
        if (ch == delimiter) try w.writeByte(ch);
    }
    try w.writeByte(delimiter);
    return w.buffered();
}
