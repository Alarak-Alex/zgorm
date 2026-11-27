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
        arena: std.heap.ArenaAllocator,
        conditions: std.ArrayList(Fragment) = .empty,
        joins: std.ArrayList(Fragment) = .empty,
        ctes: std.ArrayList(Fragment) = .empty,
        unions: std.ArrayList(Fragment) = .empty,
        having_fragments: std.ArrayList(Fragment) = .empty,
        orders: std.ArrayList([]const u8) = .empty,
        groups: std.ArrayList([]const u8) = .empty,
        columns: []const []const u8 = &.{},
        raw_columns: []const []const u8 = &.{},
        preload_flags: [table.assocs.len]bool = @splat(false),
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
            const query = db.backend.gpa.create(Self) catch @panic("zgorm: out of memory");
            query.* = .{
                .db = db,
                .arena = std.heap.ArenaAllocator.init(db.backend.gpa),
            };
            return query;
        }

        pub fn deinit(q: *Self) void {
            if (q.consumed) return;
            q.consumed = true;
            const gpa = q.db.backend.gpa;
            q.arena.deinit();
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
            @compileError("zgorm: unknown association " ++ field_name);
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
            if (comptime !table.hasColumn(column)) @compileError("zgorm: unknown column " ++ column);
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
            if (comptime !table.hasColumn(column)) @compileError("zgorm: unknown column " ++ column);
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
            var param_count: usize = 0;
            for (q.ctes.items) |f| param_count += f.params.len;
            for (q.joins.items) |f| param_count += f.params.len;
            for (q.conditions.items) |f| param_count += f.params.len;
            for (q.having_fragments.items) |f| param_count += f.params.len;
            for (q.unions.items) |f| param_count += f.params.len;
            params.ensureTotalCapacity(q.allocator(), param_count) catch return error.OutOfMemory;
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
            try q.appendWhere(w, &params, true);
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
                if (q.limit_value) |limit_value| {
                    try w.print(" LIMIT {d}", .{limit_value});
                } else if (dialect == .mysql and q.offset_value != null) {
                    try w.writeAll(" LIMIT 18446744073709551615");
                }
                if (q.offset_value) |offset_value| try w.print(" OFFSET {d}", .{offset_value});
                if (q.for_update_flag) try w.writeAll(" FOR UPDATE");
            }
            return .{ .sql = w.buffered(), .params = params.items };
        }

        fn appendWhere(q: *Self, w: *std.Io.Writer, params: *std.ArrayList(types.Param), include_scope: bool) Error!void {
            const scoped = include_scope and !q.unscoped_flag and table.softDeletable();
            if (q.conditions.items.len == 0 and !scoped) return;
            try w.writeAll(" WHERE ");
            if (scoped) {
                try writeIdent(w, table.columns[table.deleted_at_index.?].name);
                try w.writeAll(" IS NULL");
                if (q.conditions.items.len == 0) return;
                try w.writeAll(" AND (");
            }
            for (q.conditions.items, 0..) |fragment_value, i| {
                if (i > 0) try w.writeAll(if (fragment_value.or_with_previous) " OR " else " AND ");
                try w.writeByte('(');
                try appendFragment(w, params, q.allocator(), fragment_value);
                try w.writeByte(')');
            }
            if (scoped) try w.writeByte(')');
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
                @compileError("zgorm: query update expects a named struct");
            if (info.@"struct".field_names.len == 0) return error.InvalidQuery;
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            var params: std.ArrayList(types.Param) = .empty;
            try w.writeAll("UPDATE ");
            try writeIdent(w, table.name);
            try w.writeAll(" SET ");
            inline for (info.@"struct".field_names, 0..) |field_name, i| {
                if (comptime !table.hasColumn(field_name)) @compileError("zgorm: unknown column " ++ field_name);
                if (i != 0) try w.writeAll(", ");
                try writeIdent(w, field_name);
                try w.writeAll(" = ?");
                try params.append(q.allocator(), try value.toParam(@field(sets, field_name), q.allocator()));
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
            var column_map: [table.columns.len]?usize = undefined;
            value.buildColumnMap(table, result.columns, &column_map);
            for (result.rows, 0..) |row, i| {
                output[i] = try value.scanCellsMapped(T, table, result.columns, row, &column_map, gpa);
                initialized += 1;
                try q.db.runAfterFind(&output[i]);
            }
            inline for (table.assocs, 0..) |association, index| {
                if (q.preload_flags[index]) try q.loadAssociations(output, association, gpa);
            }
            return output;
        }

        fn loadAssociations(
            q: *Self,
            rows: []T,
            comptime association: schema.Assoc,
            gpa: std.mem.Allocator,
        ) Error!void {
            if (association.primary_keys.len != 1)
                return error.InvalidQuery;
            if (association.kind == .many_to_many)
                return loadManyToManyBatch(q, rows, association, gpa);
            return loadSingleAssociationBatch(q, rows, association, gpa);
        }

        fn SharedJoinedChild(comptime Child: type, comptime ParentKey: type) type {
            return struct {
                child: Child,
                parent_key: ParentKey,
            };
        }

        fn keyPresent(comptime K: type, value_: K) bool {
            return switch (@typeInfo(K)) {
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
                    else => blk: {
                        // Cross-width integer keys compare numerically.
                        if (@typeInfo(A) == .int and @typeInfo(B) == .int) {
                            const ia = std.math.cast(i128, a) orelse break :blk false;
                            const ib = std.math.cast(i128, b) orelse break :blk false;
                            break :blk ia == ib;
                        }
                        break :blk false;
                    },
                },
            };
        }

        fn loadSingleAssociationBatch(q: anytype, rows: anytype, comptime assoc: schema.Assoc, gpa: std.mem.Allocator) Error!void {
            const Parent = @TypeOf(rows[0]);
            const Child = assoc.model;
            const parent_key = if (assoc.kind == .belongs_to) assoc.foreign_key else assoc.primary_key;
            const child_key = if (assoc.kind == .belongs_to) assoc.primary_key else assoc.foreign_key;
            const ParentKey = @TypeOf(@field(@as(Parent, undefined), parent_key));

            var keys: std.ArrayList(ParentKey) = .empty;
            defer keys.deinit(gpa);
            keys.ensureTotalCapacity(gpa, rows.len) catch return error.OutOfMemory;
            if (comptime assoc.kind == .belongs_to and value.keyMapType(ParentKey) != null) {
                // Deduplicate the IN list when many parents share one child.
                var seen: value.keyMapType(ParentKey).? = .init(gpa);
                defer seen.deinit();
                for (rows) |*parent| {
                    const key = @field(parent, parent_key);
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
                    const key = @field(parent, parent_key);
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
            var child_query = q.db.query(Child).whereIn(child_key, keys.items);
            if (q.unscoped_flag) _ = child_query.unscoped();
            if (assoc.polymorphic_type.len > 0)
                child_query = child_query.whereEq(assoc.polymorphic_type, assoc.polymorphic_value);
            const children = try child_query.all(arena);

            if (assoc.kind == .has_many) {
                const slices = gpa.alloc(@TypeOf(@field(@as(Parent, undefined), assoc.field_name)), rows.len) catch
                    return error.OutOfMemory;
                defer gpa.free(slices);
                const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
                defer gpa.free(fill);
                const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
                defer gpa.free(counts);
                @memset(counts, 0);
                const owners = gpa.alloc(usize, children.len) catch return error.OutOfMemory;
                defer gpa.free(owners);
                const ChildKey = @TypeOf(@field(@as(Child, undefined), child_key));
                if (comptime value.keysHashable(ParentKey, ChildKey)) {
                    var map: value.keyMapType(ParentKey).? = .init(gpa);
                    defer map.deinit();
                    for (rows, 0..) |*parent, parent_index| {
                        if (value.normalizedKey(ParentKey, @field(parent, parent_key))) |k| {
                            const gop = map.getOrPut(k) catch return error.OutOfMemory;
                            if (!gop.found_existing) gop.value_ptr.* = parent_index;
                        }
                    }
                    for (children, 0..) |*child, child_index| {
                        owners[child_index] = std.math.maxInt(usize);
                        if (value.normalizedKey(ChildKey, @field(child, child_key))) |k| {
                            if (map.get(k)) |parent_index| {
                                owners[child_index] = parent_index;
                                counts[parent_index] += 1;
                            }
                        }
                    }
                } else {
                    for (children, 0..) |*child, child_index| {
                        owners[child_index] = std.math.maxInt(usize);
                        for (rows, 0..) |*parent, parent_index| {
                            if (keyEqual(
                                ChildKey,
                                @field(child, child_key),
                                ParentKey,
                                @field(parent, parent_key),
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
                for (children, 0..) |*child, child_index| {
                    const owner = owners[child_index];
                    if (owner != std.math.maxInt(usize)) {
                        slices[owner][fill[owner]] = try value.deepCopy(Child, child.*, gpa);
                        fill[owner] += 1;
                    }
                }
                return;
            }

            const ChildKey = @TypeOf(@field(@as(Child, undefined), child_key));
            if (comptime value.keysHashable(ParentKey, ChildKey)) {
                var map: value.keyMapType(ChildKey).? = .init(gpa);
                defer map.deinit();
                for (children, 0..) |*child, child_index| {
                    if (value.normalizedKey(ChildKey, @field(child, child_key))) |k| {
                        const gop = map.getOrPut(k) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = child_index;
                    }
                }
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    if (value.normalizedKey(ParentKey, @field(parent, parent_key))) |k| {
                        if (map.get(k)) |child_index| {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, children[child_index], gpa);
                        }
                    }
                }
            } else {
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    for (children) |*child| {
                        if (keyEqual(
                            ChildKey,
                            @field(child, child_key),
                            ParentKey,
                            @field(parent, parent_key),
                        )) {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, child.*, gpa);
                            break;
                        }
                    }
                }
            }
        }

        fn loadManyToManyBatch(q: anytype, rows: anytype, comptime assoc: schema.Assoc, gpa: std.mem.Allocator) Error!void {
            const Parent = @TypeOf(rows[0]);
            const Child = assoc.model;
            const child_table = comptime schema.tableOf(Child);
            const ParentKey = @TypeOf(@field(@as(Parent, undefined), assoc.primary_key));
            const Joined = SharedJoinedChild(Child, ParentKey);

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
            var sql: std.Io.Writer.Allocating = .init(arena);
            const w = &sql.writer;
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
            for (keys.items, 0..) |_, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeByte('?') catch return error.OutOfMemory;
            }
            try w.writeByte(')');
            if (child_table.deleted_at_index) |index| {
                if (!q.unscoped_flag) {
                    try w.writeAll(" AND ");
                    try writeQualifiedIdent(w, child_table.name, child_table.columns[index].name);
                    try w.writeAll(" IS NULL");
                }
            }
            const params = arena.alloc(types.Param, keys.items.len) catch return error.OutOfMemory;
            for (keys.items, 0..) |key, i| params[i] = try value.toParam(key, arena);
            var result = try q.db.runParams(w.buffered(), params, q.timeout_ms);
            defer result.deinit();
            const key_index = result.colIndex("__zgorm_parent_key") orelse return error.ProtocolViolation;
            var column_map: [child_table.columns.len]?usize = undefined;
            value.buildColumnMap(child_table, result.columns, &column_map);

            var joined: std.ArrayList(Joined) = .empty;
            joined.ensureTotalCapacity(arena, result.rows.len) catch return error.OutOfMemory;
            for (result.rows) |row| {
                var item = Joined{
                    .child = try value.scanCellsMapped(Child, child_table, result.columns, row, &column_map, arena),
                    .parent_key = try value.decodeCell(
                        ParentKey,
                        row[key_index],
                        result.columns[key_index].type_oid,
                        result.columns[key_index].format,
                        arena,
                    ),
                };
                try q.db.runAfterFind(&item.child);
                joined.appendAssumeCapacity(item);
            }

            const slices = gpa.alloc(@TypeOf(@field(@as(Parent, undefined), assoc.field_name)), rows.len) catch
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

        const Key = [table.pk_indexes.len][]const u8;
        const KeyContext = struct {
            pub fn hash(_: @This(), key: Key) u32 {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHashStrat(&hasher, key, .Deep);
                return @truncate(hasher.final());
            }

            pub fn eql(_: @This(), left: Key, right: Key, _: usize) bool {
                for (left, right) |a, b| if (!std.mem.eql(u8, a, b)) return false;
                return true;
            }
        };
        // Insertion order preserves the locking SELECT's order, including across write chunks.
        const KeySet = std.ArrayHashMapUnmanaged(Key, bool, KeyContext, true);
        const Mutation = enum { update, delete };
        const model_columns = blk: {
            var names: [table.columns.len][]const u8 = undefined;
            for (table.columns, 0..) |column, i| names[i] = column.name;
            break :blk names;
        };
        const key_columns = blk: {
            var names: [table.pk_indexes.len][]const u8 = undefined;
            for (table.pk_indexes, 0..) |column_index, i| names[i] = table.columns[column_index].name;
            break :blk names;
        };

        // Both reads append the real primary-key columns after any projected fields.
        fn rowKey(row: types.Result.Row) Error!Key {
            var key: Key = undefined;
            if (row.len < key.len) return error.InvalidModel;
            for (&key, row[row.len - key.len ..]) |*part, cell| part.* = cell orelse return error.InvalidModel;
            return key;
        }

        fn lockedKeyFilter(q: *Self, keys: []const Key) Error!Fragment {
            var aw: std.Io.Writer.Allocating = .init(q.allocator());
            const w = &aw.writer;
            const params = try q.allocator().alloc(types.Param, keys.len * key_columns.len);
            try w.writeByte('(');
            for (key_columns, 0..) |column, i| {
                if (i != 0) try w.writeAll(", ");
                try writeIdent(w, column);
            }
            try w.writeAll(") IN (");
            for (keys, 0..) |key, row_index| {
                if (row_index != 0) try w.writeAll(", ");
                try w.writeByte('(');
                inline for (table.pk_indexes, 0..) |column_index, i| {
                    if (i != 0) try w.writeAll(", ");
                    try w.writeByte('?');
                    // Bind the text-protocol value directly so a model codec or hook cannot change the key.
                    params[row_index * key.len + i] = .{ .data = key[i], .kind = switch (table.columns[column_index].kind) {
                        .integer, .boolean => .signed,
                        .unsigned => .unsigned,
                        .float => .float,
                        .bytes => .bytes,
                        else => .text,
                    } };
                }
                try w.writeByte(')');
            }
            try w.writeByte(')');
            return .{ .sql = w.buffered(), .params = params };
        }

        fn lockReturningRows(q: *Self, required: []const []const u8) Error!types.Result {
            // Preserve the original select list for positional ORDER BY expressions.
            const leading = if (q.columns.len == 0 and q.orders.items.len != 0) &model_columns else q.columns;
            q.columns = try std.mem.concat(q.allocator(), []const u8, &.{ leading, required });
            if (q.joins.items.len != 0) {
                const expressions = try q.allocator().alloc([]const u8, q.columns.len);
                for (q.columns, 0..) |column, i| {
                    var aw: std.Io.Writer.Allocating = .init(q.allocator());
                    if (i >= leading.len or table.hasColumn(column)) {
                        try writeQualifiedIdent(&aw.writer, table.name, column);
                    } else try writeIdent(&aw.writer, column);
                    expressions[i] = aw.writer.buffered();
                }
                q.raw_columns = expressions;
            }
            q.for_update_flag = true;
            const selection = try q.buildSelect(false);
            return q.db.runParams(selection.sql, selection.params, q.timeout_ms);
        }

        fn mysqlReturning(q: *Self, comptime operation: Mutation, sets: anytype, gpa: std.mem.Allocator) Error![]T {
            if (q.build_error) |err| return err;
            if (key_columns.len == 0) return error.InvalidModel;
            // Aggregates, unions and a CTE shadowing the target can produce rows outside the locked base table.
            if (q.raw_columns.len != 0 or q.is_distinct or q.ctes.items.len != 0 or q.groups.items.len != 0 or
                q.having_fragments.items.len != 0 or q.unions.items.len != 0) return error.InvalidQuery;
            const set_count = @typeInfo(@TypeOf(sets)).@"struct".field_names.len;
            if (operation == .update) {
                if (set_count == 0) return error.InvalidQuery;
                inline for (key_columns) |column| if (@hasField(@TypeOf(sets), column)) return error.InvalidQuery;
            }
            if (set_count + key_columns.len > dialect.maxParameters()) return error.InvalidQuery;
            const chunk_size = (dialect.maxParameters() - set_count) / key_columns.len;
            const projection = if (q.returning_columns.len != 0) q.returning_columns else &model_columns;
            const output_columns = try std.mem.concat(q.allocator(), []const u8, &.{ projection, &key_columns });
            var tx = try q.db.begin();
            errdefer tx.rollback() catch {};
            var locked = try q.lockReturningRows(if (operation == .delete) output_columns else &key_columns);
            defer locked.deinit();
            var keys: KeySet = .empty;
            for (locked.rows) |row| {
                const entry = try keys.getOrPut(q.allocator(), try rowKey(row));
                if (entry.found_existing) {
                    if (q.joins.items.len == 0) return error.InvalidModel;
                    continue;
                }
                entry.value_ptr.* = false;
                locked.rows[entry.index] = row;
            }
            locked.rows = locked.rows[0..keys.count()];
            q.raw_columns = &.{};
            q.joins.clearRetainingCapacity();
            q.orders.clearRetainingCapacity();
            q.limit_value = null;
            q.offset_value = null;
            q.columns = output_columns;

            const output = if (operation == .delete) deleted: {
                const start = locked.columns.len - output_columns.len;
                locked.columns = locked.columns[start..][0..projection.len];
                for (locked.rows) |*row| row.* = row.*[start..][0..projection.len];
                const rows = try q.decodeRows(&locked, gpa);
                errdefer value.freeSlice(T, rows, gpa);
                _ = try q.mutateLockedKeys(operation, sets, keys.keys(), chunk_size);
                break :deleted rows;
            } else updated: {
                const filters = try q.mutateLockedKeys(operation, sets, keys.keys(), chunk_size);
                break :updated try q.readUpdatedRows(&locked, &keys, filters, projection.len, gpa);
            };
            errdefer value.freeSlice(T, output, gpa);
            try tx.commit();
            return output;
        }

        fn mutateLockedKeys(q: *Self, comptime operation: Mutation, sets: anytype, keys: []const Key, chunk_size: usize) Error![]const Fragment {
            var filters: std.ArrayList(Fragment) = .empty;
            var chunks = std.mem.window(Key, keys, chunk_size, chunk_size);
            while (chunks.next()) |chunk| {
                const filter = try q.lockedKeyFilter(chunk);
                if (operation == .update) try filters.append(q.allocator(), filter);
                q.conditions.clearRetainingCapacity();
                try q.conditions.append(q.allocator(), filter);
                const mutation = if (operation == .delete) try q.buildDelete(false) else try q.buildUpdate(sets, false);
                var write = try q.db.runParams(mutation.sql, mutation.params, q.timeout_ms);
                defer write.deinit();
                if (write.affected > chunk.len or (operation == .delete and write.affected != chunk.len)) return error.InvalidModel;
            }
            return filters.items;
        }

        fn readUpdatedRows(q: *Self, locked: *types.Result, keys: *KeySet, filters: []const Fragment, projection_len: usize, gpa: std.mem.Allocator) Error![]T {
            if (filters.len == 0) return gpa.alloc(T, 0);
            var results = try std.ArrayList(types.Result).initCapacity(q.allocator(), filters.len);
            defer for (results.items) |*result| result.deinit();
            {
                // A user can update deleted_at, so the readback must include every captured key.
                const original_scope = q.unscoped_flag;
                q.unscoped_flag = true;
                defer q.unscoped_flag = original_scope;
                var start: usize = 0;
                for (filters) |filter| {
                    q.conditions.items[0] = filter;
                    const select_sql = try q.buildSelect(false);
                    const result = try q.db.runParams(select_sql.sql, select_sql.params, q.timeout_ms);
                    results.appendAssumeCapacity(result);
                    const end = start + filter.params.len / key_columns.len;
                    if (result.rows.len != end - start) return error.InvalidModel;
                    for (result.rows) |row| {
                        const pos = keys.getIndex(try rowKey(row)) orelse return error.InvalidModel;
                        if (pos < start or pos >= end or keys.values()[pos]) return error.InvalidModel;
                        keys.values()[pos] = true;
                        locked.rows[pos] = row;
                    }
                    start = end;
                }
            }
            locked.columns = results.items[0].columns[0..projection_len];
            return q.decodeRows(locked, gpa);
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
            if (comptime dialect == .mysql) return q.mysqlReturning(.delete, .{}, gpa);
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
            if (comptime dialect == .mysql) return q.mysqlReturning(.update, sets, gpa);
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
