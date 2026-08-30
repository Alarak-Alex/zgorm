//! Query builder shared by the MySQL and SQLite database adapters.

const std = @import("std");
const dialect_mod = @import("dialect.zig");
const schema = @import("../../orm/schema.zig");
const value = @import("../../orm/value.zig");
const types = @import("types.zig");

pub const Error = types.Error;

pub const DryRun = struct {
    sql: []u8,
    params: []types.Param,
    gpa: std.mem.Allocator,

    pub fn deinit(d: *DryRun) void {
        for (d.params) |param| {
            if (param.data.len > 0) d.gpa.free(param.data);
            if (param.canonical.len > 0) d.gpa.free(param.canonical);
        }
        d.gpa.free(d.params);
        d.gpa.free(d.sql);
        d.* = undefined;
    }
};

const Fragment = struct {
    sql: []const u8,
    params: []const types.Param = &.{},
    or_with_previous: bool = false,
};

pub fn Query(comptime Db: type, comptime dialect: dialect_mod.Dialect, comptime T: type) type {
    const table = comptime schema.tableOf(T);
    return struct {
        const Self = @This();

        db: *Db,
        arena: *std.heap.ArenaAllocator,
        conditions: std.ArrayList(Fragment) = .empty,
        joins: std.ArrayList(Fragment) = .empty,
        ctes: std.ArrayList(Fragment) = .empty,
        unions: std.ArrayList(Fragment) = .empty,
        having_fragments: std.ArrayList(Fragment) = .empty,
        orders: std.ArrayList([]const u8) = .empty,
        groups: std.ArrayList([]const u8) = .empty,
        columns: []const []const u8 = &.{},
        raw_columns: []const []const u8 = &.{},
        preload_flags: [table.assocs.len]bool = [_]bool{false} ** table.assocs.len,
        is_distinct: bool = false,
        recursive: bool = false,
        unscoped_flag: bool = false,
        for_update_flag: bool = false,
        returning_columns: []const []const u8 = &.{},
        hint_text: []const u8 = "",
        limit_value: ?usize = null,
        offset_value: ?usize = null,
        timeout_ms: u64 = 0,
        consumed: bool = false,
        build_error: ?Error = null,

        pub fn init(db: *Db) *Self {
            const arena = db.backend.gpa.create(std.heap.ArenaAllocator) catch @panic("zorm: out of memory");
            arena.* = std.heap.ArenaAllocator.init(db.backend.gpa);
            const query = db.backend.gpa.create(Self) catch @panic("zorm: out of memory");
            query.* = .{ .db = db, .arena = arena };
            return query;
        }

        pub fn deinit(q: *Self) void {
            if (q.consumed) return;
            q.consumed = true;
            const gpa = q.db.backend.gpa;
            q.arena.deinit();
            gpa.destroy(q.arena);
            gpa.destroy(q);
        }

        fn allocator(q: *Self) std.mem.Allocator {
            return q.arena.allocator();
        }

        fn fail(q: *Self, err: Error) *Self {
            if (q.build_error == null) q.build_error = err;
            return q;
        }

        fn fragment(q: *Self, sql: []const u8, args: anytype) Fragment {
            const params = value.argsToParams(args, q.allocator()) catch |err| {
                _ = q.fail(err);
                return .{ .sql = sql };
            };
            return .{ .sql = sql, .params = params };
        }

        pub fn hint(q: *Self, text: []const u8) *Self {
            q.hint_text = text;
            return q;
        }

        pub fn scope(q: *Self, apply: anytype) *Self {
            return apply(q);
        }
        pub fn select(q: *Self, columns: []const []const u8) *Self {
            q.columns = columns;
            return q;
        }

        pub fn selectRaw(q: *Self, expressions: []const []const u8) *Self {
            q.raw_columns = expressions;
            return q;
        }

        pub fn preload(q: *Self, comptime field_name: []const u8) *Self {
            inline for (table.assocs, 0..) |association, index| {
                if (comptime std.mem.eql(u8, association.field_name, field_name)) {
                    q.preload_flags[index] = true;
                    return q;
                }
            }
            @compileError("zorm: unknown association " ++ field_name);
        }

        pub fn distinct(q: *Self) *Self {
            q.is_distinct = true;
            return q;
        }

        pub fn distinctOn(q: *Self, _: []const []const u8) *Self {
            if (!dialect.supportsDistinctOn()) return q.fail(error.InvalidQuery);
            return q.fail(error.InvalidQuery);
        }

        fn addCondition(q: *Self, sql: []const u8, args: anytype, or_with_previous: bool) *Self {
            var condition = q.fragment(sql, args);
            condition.or_with_previous = or_with_previous;
            q.conditions.append(q.allocator(), condition) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn where(q: *Self, sql: []const u8, args: anytype) *Self {
            return q.addCondition(sql, args, false);
        }

        pub fn orWhere(q: *Self, sql: []const u8, args: anytype) *Self {
            return q.addCondition(sql, args, true);
        }

        pub fn whereEq(q: *Self, comptime column: []const u8, needle: anytype) *Self {
            if (comptime !table.hasColumn(column)) @compileError("zorm: unknown column " ++ column);
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            writeIdent(&aw.writer, column) catch return q.fail(error.OutOfMemory);
            aw.writer.writeAll(" = ?") catch return q.fail(error.OutOfMemory);
            return q.where(aw.writer.buffered(), .{needle});
        }

        pub fn whereExists(q: *Self, sql: []const u8, args: anytype) *Self {
            const wrapped = std.fmt.allocPrint(q.allocator(), "EXISTS ({s})", .{sql}) catch return q.fail(error.OutOfMemory);
            return q.where(wrapped, args);
        }

        pub fn whereIn(q: *Self, comptime column: []const u8, values: anytype) *Self {
            if (comptime !table.hasColumn(column)) @compileError("zorm: unknown column " ++ column);
            const params = value.argsToParams(values, q.allocator()) catch |err| return q.fail(err);
            if (params.len == 0) return q.where("1 = 0", .{});
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            writeIdent(&aw.writer, column) catch return q.fail(error.OutOfMemory);
            aw.writer.writeAll(" IN (") catch return q.fail(error.OutOfMemory);
            for (params, 0..) |_, i| {
                if (i != 0) aw.writer.writeAll(", ") catch return q.fail(error.OutOfMemory);
                aw.writer.writeByte('?') catch return q.fail(error.OutOfMemory);
            }
            aw.writer.writeByte(')') catch return q.fail(error.OutOfMemory);
            q.conditions.append(q.allocator(), .{ .sql = aw.writer.buffered(), .params = params }) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn returning(q: *Self, columns: []const []const u8) *Self {
            q.returning_columns = columns;
            return q;
        }

        pub fn join(q: *Self, sql: []const u8, args: anytype) *Self {
            q.joins.append(q.allocator(), q.fragment(sql, args)) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn with(q: *Self, name: []const u8, sql: []const u8, args: anytype) *Self {
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            writeIdent(&aw.writer, name) catch return q.fail(error.OutOfMemory);
            aw.writer.print(" AS ({s})", .{sql}) catch return q.fail(error.OutOfMemory);
            q.ctes.append(q.allocator(), q.fragment(aw.writer.buffered(), args)) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn withRecursive(q: *Self, name: []const u8, sql: []const u8, args: anytype) *Self {
            q.recursive = true;
            return q.with(name, sql, args);
        }

        pub fn unionWith(q: *Self, sql: []const u8, args: anytype) *Self {
            q.unions.append(q.allocator(), q.fragment("UNION ", .{})) catch return q.fail(error.OutOfMemory);
            q.unions.append(q.allocator(), q.fragment(sql, args)) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn unionAll(q: *Self, sql: []const u8, args: anytype) *Self {
            q.unions.append(q.allocator(), q.fragment("UNION ALL ", .{})) catch return q.fail(error.OutOfMemory);
            q.unions.append(q.allocator(), q.fragment(sql, args)) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn groupBy(q: *Self, columns: []const []const u8) *Self {
            q.groups.appendSlice(q.allocator(), columns) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn having(q: *Self, sql: []const u8, args: anytype) *Self {
            q.having_fragments.append(q.allocator(), q.fragment(sql, args)) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn orderBy(q: *Self, expressions: []const []const u8) *Self {
            q.orders.appendSlice(q.allocator(), expressions) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn order_by(q: *Self, expression: []const u8) *Self {
            q.orders.append(q.allocator(), expression) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn group_by(q: *Self, expression: []const u8) *Self {
            q.groups.append(q.allocator(), expression) catch return q.fail(error.OutOfMemory);
            return q;
        }

        pub fn limit(q: *Self, row_limit: usize) *Self {
            q.limit_value = row_limit;
            return q;
        }

        pub fn offset(q: *Self, row_offset: usize) *Self {
            q.offset_value = row_offset;
            return q;
        }

        pub fn timeout(q: *Self, timeout_ms: u64) *Self {
            q.timeout_ms = timeout_ms;
            return q;
        }

        pub fn unscoped(q: *Self) *Self {
            q.unscoped_flag = true;
            return q;
        }

        pub fn forUpdate(q: *Self) *Self {
            if (!dialect.supportsForUpdate()) return q.fail(error.InvalidQuery);
            q.for_update_flag = true;
            return q;
        }

        pub fn for_update(q: *Self) *Self {
            return q.forUpdate();
        }

        fn buildSelect(q: *Self, count_only: bool) Error!struct { sql: []const u8, params: []const types.Param } {
            if (q.build_error) |err| return err;
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            var params: std.ArrayList(types.Param) = .empty;
            if (q.ctes.items.len > 0) {
                try w.writeAll(if (q.recursive) "WITH RECURSIVE " else "WITH ");
                for (q.ctes.items, 0..) |fragment_value, i| {
                    if (i != 0) try w.writeAll(", ");
                    try appendFragment(w, &params, q.allocator(), fragment_value);
                }
                try w.writeByte(' ');
            }
            try w.writeAll("SELECT ");
            if (q.hint_text.len > 0 and !count_only) try w.print("/*+ {s} */ ", .{q.hint_text});
            if (q.is_distinct and !count_only) try w.writeAll("DISTINCT ");
            if (count_only) {
                try w.writeAll("count(*)");
            } else if (q.raw_columns.len > 0) {
                for (q.raw_columns, 0..) |expression, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(expression);
                }
            } else if (q.columns.len > 0) {
                for (q.columns, 0..) |column, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeIdent(w, column);
                }
            } else {
                inline for (table.columns, 0..) |column, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeIdent(w, column.name);
                }
            }
            try w.writeAll(" FROM ");
            try writeIdent(w, table.name);
            for (q.joins.items) |fragment_value| {
                try w.writeByte(' ');
                try appendFragment(w, &params, q.allocator(), fragment_value);
            }
            var wrote_where = false;
            for (q.conditions.items) |fragment_value| {
                try w.writeAll(if (!wrote_where)
                    " WHERE ("
                else if (fragment_value.or_with_previous)
                    " OR ("
                else
                    " AND (");
                try appendFragment(w, &params, q.allocator(), fragment_value);
                try w.writeByte(')');
                wrote_where = true;
            }
            if (!q.unscoped_flag) if (table.deleted_at_index) |index| {
                try w.writeAll(if (wrote_where) " AND " else " WHERE ");
                try writeIdent(w, table.columns[index].name);
                try w.writeAll(" IS NULL");
            };
            if (q.groups.items.len > 0) {
                try w.writeAll(" GROUP BY ");
                for (q.groups.items, 0..) |group, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(group);
                }
            }
            for (q.having_fragments.items, 0..) |fragment_value, i| {
                try w.writeAll(if (i == 0) " HAVING (" else " AND (");
                try appendFragment(w, &params, q.allocator(), fragment_value);
                try w.writeByte(')');
            }
            for (q.unions.items) |fragment_value| {
                try w.writeByte(' ');
                try appendFragment(w, &params, q.allocator(), fragment_value);
            }
            if (!count_only and q.orders.items.len > 0) {
                try w.writeAll(" ORDER BY ");
                for (q.orders.items, 0..) |order, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeAll(order);
                }
            }
            if (!count_only) {
                if (q.limit_value) |limit_value| try w.print(" LIMIT {d}", .{limit_value});
                if (q.offset_value) |offset_value| try w.print(" OFFSET {d}", .{offset_value});
                if (q.for_update_flag) try w.writeAll(" FOR UPDATE");
            }
            return .{ .sql = w.buffered(), .params = params.items };
        }

        fn appendWhere(q: *Self, w: *std.Io.Writer, params: *std.ArrayList(types.Param), include_scope: bool) Error!void {
            var wrote_where = false;
            for (q.conditions.items) |fragment_value| {
                try w.writeAll(if (!wrote_where)
                    " WHERE ("
                else if (fragment_value.or_with_previous)
                    " OR ("
                else
                    " AND (");
                try appendFragment(w, params, q.allocator(), fragment_value);
                try w.writeByte(')');
                wrote_where = true;
            }
            if (include_scope and !q.unscoped_flag) if (table.deleted_at_index) |index| {
                try w.writeAll(if (wrote_where) " AND " else " WHERE ");
                try writeIdent(w, table.columns[index].name);
                try w.writeAll(" IS NULL");
            };
        }

        fn appendReturning(q: *Self, w: *std.Io.Writer) Error!void {
            try w.writeAll(" RETURNING ");
            if (q.returning_columns.len > 0) {
                for (q.returning_columns, 0..) |column, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeIdent(w, column);
                }
            } else {
                inline for (table.columns, 0..) |column, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeIdent(w, column.name);
                }
            }
        }

        fn buildDelete(q: *Self, returning_rows: bool) Error!struct { sql: []const u8, params: []const types.Param } {
            if (q.build_error) |err| return err;
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            var params: std.ArrayList(types.Param) = .empty;
            if (!q.unscoped_flag and table.deleted_at_index != null) {
                try w.writeAll("UPDATE ");
                try writeIdent(w, table.name);
                try w.writeAll(" SET ");
                try writeIdent(w, table.columns[table.deleted_at_index.?].name);
                try w.writeAll(" = CURRENT_TIMESTAMP");
            } else {
                try w.writeAll("DELETE FROM ");
                try writeIdent(w, table.name);
            }
            try q.appendWhere(w, &params, true);
            if (returning_rows) try q.appendReturning(w);
            return .{ .sql = w.buffered(), .params = params.items };
        }

        fn buildUpdate(q: *Self, sets: anytype, returning_rows: bool) Error!struct { sql: []const u8, params: []const types.Param } {
            if (q.build_error) |err| return err;
            const Sets = @TypeOf(sets);
            const info = @typeInfo(Sets);
            if (info != .@"struct" or info.@"struct".is_tuple)
                @compileError("zorm: query update expects a named struct");
            if (info.@"struct".fields.len == 0) return error.InvalidQuery;
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            var params: std.ArrayList(types.Param) = .empty;
            try w.writeAll("UPDATE ");
            try writeIdent(w, table.name);
            try w.writeAll(" SET ");
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (comptime !table.hasColumn(field.name)) @compileError("zorm: unknown column " ++ field.name);
                if (i != 0) try w.writeAll(", ");
                try writeIdent(w, field.name);
                try w.writeAll(" = ?");
                try params.append(q.allocator(), try value.toParam(@field(sets, field.name), q.allocator()));
            }
            try q.appendWhere(w, &params, true);
            if (returning_rows) try q.appendReturning(w);
            return .{ .sql = w.buffered(), .params = params.items };
        }

        fn decodeRows(q: *Self, result: *types.Result, gpa: std.mem.Allocator) Error![]T {
            const output = gpa.alloc(T, result.rows.len) catch return error.OutOfMemory;
            var initialized: usize = 0;
            errdefer {
                for (output[0..initialized]) |item| value.freeValue(T, item, gpa);
                gpa.free(output);
            }
            for (result.rows, 0..) |row, i| {
                output[i] = try value.scanRow(T, table, result, row, gpa);
                initialized += 1;
                try q.db.runAfterFind(&output[i]);
                inline for (table.assocs, 0..) |association, index| {
                    if (q.preload_flags[index]) try q.loadAssociation(&output[i], association, gpa);
                }
            }
            return output;
        }

        fn loadAssociation(q: *Self, parent: *T, comptime association: schema.Assoc, gpa: std.mem.Allocator) Error!void {
            const Child = association.model;
            switch (association.kind) {
                .belongs_to => {
                    const foreign = @field(parent, association.foreign_key);
                    switch (@typeInfo(@TypeOf(foreign))) {
                        .optional => {
                            const key = foreign orelse {
                                @field(parent, association.field_name) = null;
                                return;
                            };
                            @field(parent, association.field_name) =
                                try q.db.query(Child).whereEq(association.primary_key, key).first(gpa);
                        },
                        else => @field(parent, association.field_name) =
                            try q.db.query(Child).whereEq(association.primary_key, foreign).first(gpa),
                    }
                },
                .has_one => {
                    @field(parent, association.field_name) = try q.db.query(Child)
                        .whereEq(association.foreign_key, @field(parent, association.primary_key))
                        .first(gpa);
                },
                .has_many => {
                    @field(parent, association.field_name) = try q.db.query(Child)
                        .whereEq(association.foreign_key, @field(parent, association.primary_key))
                        .all(gpa);
                },
                .many_to_many => {
                    const child_table = comptime schema.tableOf(Child);
                    const arena = q.allocator();
                    var join_sql: std.Io.Writer.Allocating = .init(arena);
                    const jw = &join_sql.writer;
                    try jw.writeAll("JOIN ");
                    try writeIdent(jw, association.join_table);
                    try jw.writeAll(" ON ");
                    try writeQualifiedIdent(jw, child_table.name, association.association_key);
                    try jw.writeAll(" = ");
                    try writeQualifiedIdent(jw, association.join_table, association.join_association_key);
                    var where_sql: std.Io.Writer.Allocating = .init(arena);
                    try writeQualifiedIdent(&where_sql.writer, association.join_table, association.join_foreign_key);
                    try where_sql.writer.writeAll(" = ?");
                    const selected = arena.alloc([]const u8, child_table.columns.len) catch return error.OutOfMemory;
                    inline for (child_table.columns, 0..) |column, index| {
                        var expression: std.Io.Writer.Allocating = .init(arena);
                        try writeQualifiedIdent(&expression.writer, child_table.name, column.name);
                        selected[index] = expression.writer.buffered();
                    }
                    @field(parent, association.field_name) = try q.db.query(Child)
                        .selectRaw(selected)
                        .join(join_sql.writer.buffered(), .{})
                        .where(where_sql.writer.buffered(), .{@field(parent, association.primary_key)})
                        .all(gpa);
                },
            }
        }

        fn buildPkSelect(q: *Self, models: []const T) Error!struct { sql: []const u8, params: []const types.Param } {
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            var params: std.ArrayList(types.Param) = .empty;
            try w.writeAll("SELECT ");
            inline for (table.columns, 0..) |column, i| {
                if (i != 0) try w.writeAll(", ");
                try writeIdent(w, column.name);
            }
            try w.writeAll(" FROM ");
            try writeIdent(w, table.name);
            try w.writeAll(" WHERE ");
            for (models, 0..) |*model, model_index| {
                if (model_index != 0) try w.writeAll(" OR ");
                try w.writeByte('(');
                inline for (table.pk_indexes, 0..) |column_index, key_index| {
                    if (key_index != 0) try w.writeAll(" AND ");
                    const column = table.columns[column_index];
                    try writeIdent(w, column.name);
                    try w.writeAll(" = ?");
                    try params.append(q.allocator(), try value.toParam(value.getColumn(model, column), q.allocator()));
                }
                try w.writeByte(')');
            }
            return .{ .sql = w.buffered(), .params = params.items };
        }

        pub fn all(q: *Self, gpa: std.mem.Allocator) Error![]T {
            defer q.deinit();
            const built = try q.buildSelect(false);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            return q.decodeRows(&result, gpa);
        }

        pub fn first(q: *Self, gpa: std.mem.Allocator) Error!?T {
            q.limit_value = 1;
            const rows = try q.all(gpa);
            if (rows.len == 0) {
                gpa.free(rows);
                return null;
            }
            const first_value = rows[0];
            gpa.free(rows);
            return first_value;
        }

        pub fn count(q: *Self) Error!i64 {
            defer q.deinit();
            const built = try q.buildSelect(true);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            if (result.rows.len != 1 or result.rows[0].len != 1) return error.TypeMismatch;
            return value.decodeCell(i64, result.rows[0][0], 0, 0, q.db.backend.gpa) catch error.TypeMismatch;
        }

        pub fn exists(q: *Self) Error!bool {
            return (try q.count()) > 0;
        }

        pub fn delete(q: *Self) Error!i64 {
            defer q.deinit();
            const built = try q.buildDelete(false);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            return result.affected;
        }

        pub fn deleteReturning(q: *Self, gpa: std.mem.Allocator) Error![]T {
            defer q.deinit();
            if (comptime dialect == .mysql) {
                try q.db.backend.beginTransaction();
                errdefer q.db.backend.rollback() catch {};
                q.for_update_flag = true;
                const selected = try q.buildSelect(false);
                var selected_result = try q.db.runParams(selected.sql, selected.params, q.timeout_ms);
                defer selected_result.deinit();
                const output = try q.decodeRows(&selected_result, gpa);
                errdefer value.freeSlice(T, output, gpa);
                const mutation = try q.buildDelete(false);
                var mutation_result = try q.db.runParams(mutation.sql, mutation.params, q.timeout_ms);
                mutation_result.deinit();
                try q.db.backend.commit();
                return output;
            }
            const built = try q.buildDelete(true);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            return q.decodeRows(&result, gpa);
        }

        pub fn update(q: *Self, sets: anytype) Error!i64 {
            defer q.deinit();
            const built = try q.buildUpdate(sets, false);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            return result.affected;
        }

        pub fn updateReturning(q: *Self, sets: anytype, gpa: std.mem.Allocator) Error![]T {
            defer q.deinit();
            if (comptime dialect == .mysql) {
                try q.db.backend.beginTransaction();
                errdefer q.db.backend.rollback() catch {};
                q.for_update_flag = true;
                const selected = try q.buildSelect(false);
                var selected_result = try q.db.runParams(selected.sql, selected.params, q.timeout_ms);
                defer selected_result.deinit();
                const before = try q.decodeRows(&selected_result, gpa);
                errdefer value.freeSlice(T, before, gpa);
                const mutation = try q.buildUpdate(sets, false);
                var mutation_result = try q.db.runParams(mutation.sql, mutation.params, q.timeout_ms);
                mutation_result.deinit();
                if (before.len == 0) {
                    try q.db.backend.commit();
                    return before;
                }
                const selected_after = try q.buildPkSelect(before);
                var after_result = try q.db.runParams(selected_after.sql, selected_after.params, q.timeout_ms);
                defer after_result.deinit();
                const after = try q.decodeRows(&after_result, gpa);
                value.freeSlice(T, before, gpa);
                try q.db.backend.commit();
                return after;
            }
            const built = try q.buildUpdate(sets, true);
            var result = try q.db.runParams(built.sql, built.params, q.timeout_ms);
            defer result.deinit();
            return q.decodeRows(&result, gpa);
        }

        pub fn dryRun(q: *Self, gpa: std.mem.Allocator) Error!DryRun {
            defer q.deinit();
            const built = try q.buildSelect(false);
            const sql = gpa.dupe(u8, built.sql) catch return error.OutOfMemory;
            errdefer gpa.free(sql);
            const params = gpa.alloc(types.Param, built.params.len) catch return error.OutOfMemory;
            errdefer gpa.free(params);
            for (built.params, 0..) |param, i| {
                params[i] = param;
                params[i].data = gpa.dupe(u8, param.data) catch return error.OutOfMemory;
                params[i].canonical = gpa.dupe(u8, param.canonical) catch return error.OutOfMemory;
            }
            return .{ .sql = sql, .params = params, .gpa = gpa };
        }

        pub fn explain(q: *Self, analyze: bool) Error!types.Result {
            defer q.deinit();
            const built = try q.buildSelect(false);
            const prefix = switch (dialect) {
                .mysql => if (analyze) "EXPLAIN ANALYZE " else "EXPLAIN ",
                .sqlite => if (analyze) "EXPLAIN " else "EXPLAIN QUERY PLAN ",
                .postgresql => unreachable,
            };
            const sql = std.fmt.allocPrint(q.allocator(), "{s}{s}", .{ prefix, built.sql }) catch return error.OutOfMemory;
            return q.db.runParams(sql, built.params, q.timeout_ms);
        }

        fn writeIdent(w: *std.Io.Writer, identifier: []const u8) !void {
            const quote = dialect.identifierQuote();
            try w.writeByte(quote);
            for (identifier) |ch| {
                try w.writeByte(ch);
                if (ch == quote) try w.writeByte(ch);
            }
            try w.writeByte(quote);
        }

        fn writeQualifiedIdent(w: *std.Io.Writer, relation: []const u8, column: []const u8) !void {
            try writeIdent(w, relation);
            try w.writeByte('.');
            try writeIdent(w, column);
        }
    };
}

fn appendFragment(
    w: *std.Io.Writer,
    params: *std.ArrayList(types.Param),
    allocator: std.mem.Allocator,
    fragment: Fragment,
) !void {
    try w.writeAll(fragment.sql);
    try params.appendSlice(allocator, fragment.params);
}
