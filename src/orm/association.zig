//! Typed association manager: append / replace / delete / clear / count over
//! belongs_to, has_one, has_many and many_to_many relations.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const session_mod = @import("session.zig");
const qb_mod = @import("qb.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const crud_sql = @import("session/crud_sql.zig");

pub const Error = pq.Error;

fn associationColumn(comptime M: type, comptime name: []const u8) schema.Column {
    inline for (schema.tableOf(M).columns) |column| {
        if (comptime std.mem.eql(u8, column.field_name, name) or
            std.mem.eql(u8, column.name, name)) return column;
    }
    @compileError("zgorm: association primary key '" ++ name ++ "' is not a model column");
}

pub fn Association(comptime M: type, comptime field_name: []const u8) type {
    const assoc = comptime schema.tableOf(M).assoc(field_name) orelse
        @compileError("zgorm: unknown association " ++ field_name);
    const Child = assoc.model;
    const join_table_q = qb_mod.QuotedIdent(assoc.join_table).value;
    const join_fk_q = qb_mod.QuotedIdent(assoc.join_foreign_key).value;
    const join_ak_q = qb_mod.QuotedIdent(assoc.join_association_key).value;
    const count_sql = "SELECT count(*) FROM " ++ join_table_q ++ " WHERE " ++ join_fk_q ++ " = $1";
    const join_insert_head = "INSERT INTO " ++ join_table_q ++ " (" ++ join_fk_q ++ ", " ++ join_ak_q ++ ") VALUES ";
    const append_sql = join_insert_head ++ "($1, $2) ON CONFLICT DO NOTHING";
    const clear_sql = "DELETE FROM " ++ join_table_q ++ " WHERE " ++ join_fk_q ++ " = $1";
    const delete_sql = "DELETE FROM " ++ join_table_q ++ " WHERE " ++ join_fk_q ++ " = $1 AND " ++ join_ak_q ++ " = $2";
    return struct {
        sess: session_mod.Session,
        parent: *M,

        pub fn count(a: *@This()) Error!i64 {
            if (assoc.kind == .many_to_many) {
                var res = try a.sess.exec(count_sql, .{value.getColumn(a.parent, associationColumn(M, assoc.primary_key))});
                defer res.deinit();
                return try value.decodeCell(i64, res.rows[0][0], res.columns[0].type_oid, res.columns[0].format, a.sess.gpa);
            }
            var query = a.sess.query(Child).whereEq(assoc.foreign_key, value.getColumn(a.parent, associationColumn(M, assoc.primary_key)));
            if (assoc.polymorphic_type.len > 0)
                query = query.whereEq(assoc.polymorphic_type, assoc.polymorphic_value);
            return query.count();
        }

        pub fn append(a: *@This(), child: *Child) Error!void {
            if (assoc.kind != .many_to_many) {
                const parent_key = value.getColumn(a.parent, associationColumn(M, assoc.primary_key));
                switch (@typeInfo(@TypeOf(parent_key))) {
                    .optional => {
                        const key = parent_key orelse return error.TypeMismatch;
                        @field(child, assoc.foreign_key) = key;
                    },
                    else => @field(child, assoc.foreign_key) = parent_key,
                }
                if (assoc.polymorphic_type.len > 0)
                    @field(child, assoc.polymorphic_type) = assoc.polymorphic_value;
                try a.sess.save(child);
                return;
            }
            try a.sess.save(child);
            var res = try a.sess.exec(append_sql, .{
                @field(a.parent, assoc.primary_key),
                @field(child, assoc.association_key),
            });
            res.deinit();
        }

        pub fn clear(a: *@This()) Error!void {
            if (assoc.kind == .many_to_many) {
                var res = try a.sess.exec(clear_sql, .{@field(a.parent, assoc.primary_key)});
                res.deinit();
                return;
            }
            var query = a.sess.query(Child).whereEq(assoc.foreign_key, @field(a.parent, assoc.primary_key));
            if (assoc.polymorphic_type.len > 0)
                query = query.whereEq(assoc.polymorphic_type, assoc.polymorphic_value);
            _ = try query.delete();
        }

        pub fn delete(a: *@This(), child: *Child) Error!void {
            if (assoc.kind != .many_to_many) {
                _ = try a.sess.delete(child);
                return;
            }
            var res = try a.sess.exec(delete_sql, .{
                @field(a.parent, assoc.primary_key),
                @field(child, assoc.association_key),
            });
            res.deinit();
        }

        pub fn replace(a: *@This(), children: []Child) Error!void {
            try a.clear();
            if (assoc.kind != .many_to_many) {
                for (children) |*child| try a.append(child);
                return;
            }
            for (children) |*child| try a.sess.save(child);
            if (children.len == 0) return;
            var arena_state = std.heap.ArenaAllocator.init(a.sess.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const chunk_rows = @max(@as(usize, 1), crud_sql.max_params / 2);
            var i: usize = 0;
            while (i < children.len) {
                const end = @min(i + chunk_rows, children.len);
                const chunk = children[i..end];
                var b = crud_sql.SqlBuf.init(arena);
                const w = b.w();
                w.writeAll(join_insert_head) catch return error.OutOfMemory;
                const params = arena.alloc(pq.Param, chunk.len * 2) catch return error.OutOfMemory;
                var np: usize = 0;
                for (chunk, 0..) |*child, r| {
                    if (r > 0) w.writeAll(", ") catch return error.OutOfMemory;
                    w.print("(${d}, ${d})", .{ np + 1, np + 2 }) catch return error.OutOfMemory;
                    params[np] = try value.toParam(@field(a.parent, assoc.primary_key), arena);
                    np += 1;
                    params[np] = try value.toParam(@field(child, assoc.association_key), arena);
                    np += 1;
                }
                w.writeAll(" ON CONFLICT DO NOTHING") catch return error.OutOfMemory;
                var res = try a.sess.runExec(b.slice(), params[0..np]);
                res.deinit();
                i = end;
            }
        }
    };
}
