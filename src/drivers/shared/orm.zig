//! Full typed ORM shared by the SQLite and MySQL drivers.

const std = @import("std");
const schema = @import("../../orm/schema.zig");
const value = @import("../../orm/value.zig");
const types = @import("types.zig");
const dialect_mod = @import("dialect.zig");
const query_mod = @import("query.zig");
const association_mod = @import("association.zig");
const backend_mod = @import("backend.zig");
const plugins = @import("plugins.zig");

pub const Dialect = dialect_mod.Dialect;

pub const OnConflict = struct {
    columns: []const []const u8 = &.{},
    update: []const []const u8 = &.{},
};
pub const RetryOptions = struct {
    max_attempts: u8 = 3,
    base_delay_ms: u64 = 10,
    max_delay_ms: u64 = 1_000,
    retry_connection_errors: bool = true,
};
pub const Error = types.Error;

const SqlBuf = struct {
    aw: std.Io.Writer.Allocating,

    fn init(gpa: std.mem.Allocator) SqlBuf {
        return .{ .aw = .init(gpa) };
    }

    fn writer(buf: *SqlBuf) *std.Io.Writer {
        return &buf.aw.writer;
    }

    fn slice(buf: *SqlBuf) []const u8 {
        return buf.aw.writer.buffered();
    }
};

pub fn Orm(comptime Backend: type, comptime dialect: Dialect) type {
    comptime backend_mod.assertBackend(Backend);
    return struct {
        const Self = @This();
        backend: *Backend,
        observer: types.Observer = .{},
        plugin_registry: plugins.Registry = .{},

        pub fn init(backend: *Backend) Self {
            return .{ .backend = backend };
        }

        pub fn setObserver(db: *Self, observer: types.Observer) void {
            db.observer = observer;
        }

        pub fn addPlugin(db: *Self, plugin: plugins.Plugin) bool {
            return db.plugin_registry.add(plugin);
        }

        pub fn exec(db: *Self, sql: []const u8) Error!void {
            var result = try db.execRaw(sql);
            result.deinit();
        }

        pub fn execRaw(db: *Self, sql: []const u8) Error!types.Result {
            return db.runParams(sql, &.{}, 0);
        }

        pub fn execArgs(db: *Self, sql: []const u8, args: anytype) Error!types.Result {
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const params = try value.argsToParams(args, arena_state.allocator());
            return db.runParams(sql, params, 0);
        }

        pub fn execScript(db: *Self, script: []const u8) Error!void {
            const State = enum { normal, single, double, backtick, line_comment, block_comment };
            var state: State = .normal;
            var start: usize = 0;
            var i: usize = 0;
            while (i < script.len) : (i += 1) {
                const ch = script[i];
                switch (state) {
                    .normal => {
                        if (ch == '\'' or ch == '"' or ch == '`') {
                            state = switch (ch) {
                                '\'' => .single,
                                '"' => .double,
                                else => .backtick,
                            };
                        } else if (ch == '-' and i + 1 < script.len and script[i + 1] == '-') {
                            state = .line_comment;
                            i += 1;
                        } else if (ch == '/' and i + 1 < script.len and script[i + 1] == '*') {
                            state = .block_comment;
                            i += 1;
                        } else if (ch == ';') {
                            const statement = std.mem.trim(u8, script[start..i], " \t\r\n");
                            if (statement.len > 0) try db.exec(statement);
                            start = i + 1;
                        }
                    },
                    .single, .double, .backtick => {
                        const delimiter: u8 = switch (state) {
                            .single => '\'',
                            .double => '"',
                            .backtick => '`',
                            else => unreachable,
                        };
                        if (ch == '\\') {
                            if (i + 1 < script.len) i += 1;
                        } else if (ch == delimiter) {
                            if (i + 1 < script.len and script[i + 1] == delimiter) {
                                i += 1;
                            } else {
                                state = .normal;
                            }
                        }
                    },
                    .line_comment => if (ch == '\n') {
                        state = .normal;
                    },
                    .block_comment => if (ch == '*' and i + 1 < script.len and script[i + 1] == '/') {
                        state = .normal;
                        i += 1;
                    },
                }
            }
            if (state == .single or state == .double or state == .backtick or state == .block_comment)
                return error.InvalidQuery;
            const statement = std.mem.trim(u8, script[start..], " \t\r\n;");
            if (statement.len > 0) try db.exec(statement);
        }

        pub fn runParams(db: *Self, sql: []const u8, params: []const types.Param, timeout_ms: u64) Error!types.Result {
            if (!db.plugin_registry.before(sql)) return error.HookAborted;
            const io = backendIo(db);
            const started = if (io) |active_io| std.Io.Clock.awake.now(active_io) else null;
            const result = db.backend.execParamsTimeout(sql, params, timeout_ms) catch |err| {
                const event = types.QueryEvent{ .sql = sql, .duration_ns = elapsedSince(io, started), .err = err };
                db.observer.emit(event);
                db.plugin_registry.after(event);
                return err;
            };
            const event = types.QueryEvent{
                .sql = sql,
                .duration_ns = elapsedSince(io, started),
                .affected_rows = result.affected,
                .returned_rows = result.rows.len,
            };
            db.observer.emit(event);
            db.plugin_registry.after(event);
            return result;
        }

        pub fn query(db: *Self, comptime T: type) *query_mod.Query(Self, dialect, T) {
            return query_mod.Query(Self, dialect, T).init(db);
        }

        pub fn association(db: *Self, parent: anytype, comptime field_name: []const u8) association_mod.Association(
            Self,
            dialect,
            @typeInfo(@TypeOf(parent)).pointer.child,
            field_name,
        ) {
            const M = @typeInfo(@TypeOf(parent)).pointer.child;
            return .{ .db = db, .parent = @as(*M, parent) };
        }

        pub fn runAfterFind(db: *Self, model: anytype) Error!void {
            const T = @TypeOf(model.*);
            try callHook(T, "afterFind", model, db);
        }
        pub fn autoMigrate(db: *Self, comptime T: type) Error!void {
            const table = comptime schema.tableOf(T);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();

            w.writeAll("CREATE TABLE IF NOT EXISTS ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
            w.writeAll(" (") catch return error.OutOfMemory;
            inline for (table.columns, 0..) |col, i| {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                writeIdent(w, col.name) catch return error.OutOfMemory;
                w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(ddlType(table, col)) catch return error.OutOfMemory;
                if (col.is_auto) {
                    w.writeByte(' ') catch return error.OutOfMemory;
                    w.writeAll(dialect.autoIncrementClause()) catch return error.OutOfMemory;
                } else {
                    if (!col.is_optional) w.writeAll(" NOT NULL") catch return error.OutOfMemory;
                    if (col.is_pk and table.pk_indexes.len == 1) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                }
            }
            if (table.pk_indexes.len > 1) {
                w.writeAll(", PRIMARY KEY (") catch return error.OutOfMemory;
                inline for (table.pk_indexes, 0..) |index, i| {
                    if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                    writeIdent(w, table.columns[index].name) catch return error.OutOfMemory;
                }
                w.writeByte(')') catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
            try db.exec(sql.slice());

            var existing = if (dialect == .sqlite) blk: {
                var pragma = SqlBuf.init(arena);
                pragma.writer().writeAll("PRAGMA table_info(") catch return error.OutOfMemory;
                writeIdent(pragma.writer(), table.name) catch return error.OutOfMemory;
                pragma.writer().writeByte(')') catch return error.OutOfMemory;
                break :blk try db.execRaw(pragma.slice());
            } else try db.execArgs(
                "SELECT column_name FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ?",
                .{table.name},
            );
            defer existing.deinit();
            inline for (table.columns) |column| {
                if (!columnExists(&existing, column.name)) {
                    if (column.is_auto) return error.InvalidModel;
                    var alter = SqlBuf.init(arena);
                    const aw = alter.writer();
                    aw.writeAll("ALTER TABLE ") catch return error.OutOfMemory;
                    writeIdent(aw, table.name) catch return error.OutOfMemory;
                    aw.writeAll(" ADD COLUMN ") catch return error.OutOfMemory;
                    writeIdent(aw, column.name) catch return error.OutOfMemory;
                    aw.writeByte(' ') catch return error.OutOfMemory;
                    aw.writeAll(ddlType(table, column)) catch return error.OutOfMemory;
                    if (!column.is_optional) {
                        aw.writeAll(" NOT NULL DEFAULT ") catch return error.OutOfMemory;
                        aw.writeAll(zeroDefault(column.kind)) catch return error.OutOfMemory;
                    }
                    try db.exec(alter.slice());
                }
            }
            inline for (table.unique) |column| try db.createIndexIfMissing(table.name, column, true, arena);
            inline for (table.indexes) |column| try db.createIndexIfMissing(table.name, column, false, arena);
        }

        pub fn autoMigrateAll(db: *Self, comptime models: anytype) Error!void {
            inline for (models) |T| try db.autoMigrate(T);
        }

        pub fn insert(db: *Self, model: anytype) Error!void {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            try callHook(T, "beforeSave", model, db);
            try callHook(T, "beforeCreate", model, db);
            try db.autoStamp(T, model, true);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();

            w.writeAll("INSERT INTO ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
            w.writeAll(" (") catch return error.OutOfMemory;
            var count: usize = 0;
            inline for (table.columns) |col| {
                const skip = col.is_auto and isNull(value.getColumn(model, col));
                if (!skip) {
                    if (count != 0) w.writeAll(", ") catch return error.OutOfMemory;
                    writeIdent(w, col.name) catch return error.OutOfMemory;
                    count += 1;
                }
            }
            if (count == 0) return error.InvalidModel;
            w.writeAll(") VALUES (") catch return error.OutOfMemory;
            count = 0;
            inline for (table.columns) |col| {
                const field_value = value.getColumn(model, col);
                const skip = col.is_auto and isNull(field_value);
                if (!skip) {
                    if (count != 0) w.writeAll(", ") catch return error.OutOfMemory;
                    try writeValue(w, field_value, arena);
                    count += 1;
                }
            }
            w.writeByte(')') catch return error.OutOfMemory;

            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            if (table.pk_index) |pk_index| {
                const pk = table.columns[pk_index];
                if (pk.is_auto and result.last_insert_id != 0 and isNull(value.getColumn(model, pk))) {
                    const V = value.columnFieldType(T, pk);
                    const Child = @typeInfo(V).optional.child;
                    const id = std.math.cast(Child, result.last_insert_id) orelse return error.TypeMismatch;
                    value.setColumn(model, pk, @as(V, id));
                }
            }
            try callHook(T, "afterCreate", model, db);
            try callHook(T, "afterSave", model, db);
        }

        pub fn insertBatch(db: *Self, models: anytype) Error!void {
            var tx = try db.begin();
            errdefer tx.rollback() catch {};
            for (models) |*model| try tx.insert(model);
            try tx.commit();
        }

        pub fn upsert(db: *Self, model: anytype, comptime conflict: OnConflict) Error!bool {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();
            w.writeAll("INSERT INTO ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
            w.writeAll(" (") catch return error.OutOfMemory;
            var count: usize = 0;
            inline for (table.columns) |column| {
                const skip = column.is_auto and isNull(value.getColumn(model, column));
                if (!skip) {
                    if (count != 0) w.writeAll(", ") catch return error.OutOfMemory;
                    writeIdent(w, column.name) catch return error.OutOfMemory;
                    count += 1;
                }
            }
            if (count == 0) return error.InvalidModel;
            w.writeAll(") VALUES (") catch return error.OutOfMemory;
            count = 0;
            inline for (table.columns) |column| {
                const field_value = value.getColumn(model, column);
                const skip = column.is_auto and isNull(field_value);
                if (!skip) {
                    if (count != 0) w.writeAll(", ") catch return error.OutOfMemory;
                    try writeValue(w, field_value, arena);
                    count += 1;
                }
            }
            w.writeByte(')') catch return error.OutOfMemory;
            switch (dialect) {
                .mysql => {
                    w.writeAll(" ON DUPLICATE KEY UPDATE ") catch return error.OutOfMemory;
                    if (conflict.update.len == 0) {
                        const pk = table.pk() orelse return error.InvalidModel;
                        writeIdent(w, pk.name) catch return error.OutOfMemory;
                        w.writeAll(" = ") catch return error.OutOfMemory;
                        writeIdent(w, pk.name) catch return error.OutOfMemory;
                    } else inline for (conflict.update, 0..) |name, i| {
                        if (comptime !table.hasColumn(name)) @compileError("zorm: unknown upsert column " ++ name);
                        if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                        writeIdent(w, name) catch return error.OutOfMemory;
                        w.writeAll(" = VALUES(") catch return error.OutOfMemory;
                        writeIdent(w, name) catch return error.OutOfMemory;
                        w.writeByte(')') catch return error.OutOfMemory;
                    }
                },
                .sqlite => {
                    w.writeAll(" ON CONFLICT") catch return error.OutOfMemory;
                    if (conflict.columns.len > 0) {
                        w.writeAll(" (") catch return error.OutOfMemory;
                        inline for (conflict.columns, 0..) |name, i| {
                            if (comptime !table.hasColumn(name)) @compileError("zorm: unknown conflict column " ++ name);
                            if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                            writeIdent(w, name) catch return error.OutOfMemory;
                        }
                        w.writeByte(')') catch return error.OutOfMemory;
                    }
                    if (conflict.update.len == 0) {
                        w.writeAll(" DO NOTHING") catch return error.OutOfMemory;
                    } else {
                        w.writeAll(" DO UPDATE SET ") catch return error.OutOfMemory;
                        inline for (conflict.update, 0..) |name, i| {
                            if (comptime !table.hasColumn(name)) @compileError("zorm: unknown upsert column " ++ name);
                            if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                            writeIdent(w, name) catch return error.OutOfMemory;
                            w.writeAll(" = excluded.") catch return error.OutOfMemory;
                            writeIdent(w, name) catch return error.OutOfMemory;
                        }
                    }
                },
                .postgresql => unreachable,
            }
            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            if (table.pk_index) |pk_index| {
                const pk = table.columns[pk_index];
                if (pk.is_auto and result.last_insert_id != 0 and isNull(value.getColumn(model, pk))) {
                    const V = value.columnFieldType(T, pk);
                    const Child = @typeInfo(V).optional.child;
                    const id = std.math.cast(Child, result.last_insert_id) orelse return error.TypeMismatch;
                    value.setColumn(model, pk, @as(V, id));
                }
            }
            return result.affected > 0;
        }

        pub fn upsertBatch(db: *Self, models: anytype, comptime conflict: OnConflict) Error!usize {
            var tx = try db.begin();
            errdefer tx.rollback() catch {};
            var changed: usize = 0;
            for (models) |*model| if (try tx.db.upsert(model, conflict)) {
                changed += 1;
            };
            try tx.commit();
            return changed;
        }

        pub fn find(db: *Self, comptime T: type, key: anytype, gpa: std.mem.Allocator) Error!?T {
            const table = comptime schema.tableOf(T);
            if (table.pk_indexes.len != 1) return error.InvalidModel;
            const pk = table.pk() orelse return error.InvalidModel;
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();
            try writeSelectPrefix(w, table);
            w.writeAll(" WHERE ") catch return error.OutOfMemory;
            writeIdent(w, pk.name) catch return error.OutOfMemory;
            w.writeAll(" = ") catch return error.OutOfMemory;
            try writeValue(w, key, arena);
            try writeScope(w, table);
            w.writeAll(" LIMIT 1") catch return error.OutOfMemory;

            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            if (result.rows.len == 0) return null;
            var out = try decodeRow(T, table, result.rows[0], gpa);
            errdefer value.freeValue(T, out, gpa);
            try db.runAfterFind(&out);
            return out;
        }

        pub fn all(db: *Self, comptime T: type, gpa: std.mem.Allocator) Error![]T {
            return db.selectWhere(T, null, gpa);
        }

        pub fn whereEq(
            db: *Self,
            comptime T: type,
            comptime column: []const u8,
            needle: anytype,
            gpa: std.mem.Allocator,
        ) Error![]T {
            const table = comptime schema.tableOf(T);
            if (comptime !table.hasColumn(column)) @compileError("zorm: unknown column " ++ column);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var predicate = SqlBuf.init(arena);
            writeIdent(predicate.writer(), column) catch return error.OutOfMemory;
            predicate.writer().writeAll(" = ") catch return error.OutOfMemory;
            try writeValue(predicate.writer(), needle, arena);
            return db.selectWhere(T, predicate.slice(), gpa);
        }

        fn selectWhere(
            db: *Self,
            comptime T: type,
            predicate: ?[]const u8,
            gpa: std.mem.Allocator,
        ) Error![]T {
            const table = comptime schema.tableOf(T);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            var sql = SqlBuf.init(arena_state.allocator());
            const w = sql.writer();
            try writeSelectPrefix(w, table);
            if (predicate) |p| {
                w.writeAll(" WHERE ") catch return error.OutOfMemory;
                w.writeAll(p) catch return error.OutOfMemory;
                try writeScope(w, table);
            } else if (table.deleted_at_index) |index| {
                w.writeAll(" WHERE ") catch return error.OutOfMemory;
                writeIdent(w, table.columns[index].name) catch return error.OutOfMemory;
                w.writeAll(" IS NULL") catch return error.OutOfMemory;
            }
            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            const out = gpa.alloc(T, result.rows.len) catch return error.OutOfMemory;
            var initialized: usize = 0;
            errdefer {
                for (out[0..initialized]) |item| value.freeValue(T, item, gpa);
                gpa.free(out);
            }
            for (result.rows, 0..) |row, i| {
                out[i] = try decodeRow(T, table, row, gpa);
                initialized += 1;
                try db.runAfterFind(&out[i]);
            }
            return out;
        }

        pub fn update(db: *Self, model: anytype) Error!void {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            if (table.pk_indexes.len == 0) return error.InvalidModel;
            try callHook(T, "beforeSave", model, db);
            try callHook(T, "beforeUpdate", model, db);
            try db.autoStamp(T, model, false);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            if (table.version_index) |index|
                _ = try nextVersion(value.getColumn(model, table.columns[index]));
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();
            w.writeAll("UPDATE ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
            w.writeAll(" SET ") catch return error.OutOfMemory;
            var count: usize = 0;
            inline for (table.columns, 0..) |col, index| {
                if (col.is_pk) continue;
                if (count != 0) w.writeAll(", ") catch return error.OutOfMemory;
                writeIdent(w, col.name) catch return error.OutOfMemory;
                if (table.version_index == index) {
                    w.writeAll(" = ") catch return error.OutOfMemory;
                    writeIdent(w, col.name) catch return error.OutOfMemory;
                    w.writeAll(" + 1") catch return error.OutOfMemory;
                } else {
                    w.writeAll(" = ") catch return error.OutOfMemory;
                    try writeValue(w, value.getColumn(model, col), arena);
                }
                count += 1;
            }
            if (count == 0) return error.InvalidModel;
            w.writeAll(" WHERE ") catch return error.OutOfMemory;
            try writePkPredicate(w, table, model, arena);
            try writeScope(w, table);
            if (table.version_index) |index| {
                w.writeAll(" AND ") catch return error.OutOfMemory;
                writeIdent(w, table.columns[index].name) catch return error.OutOfMemory;
                w.writeAll(" = ") catch return error.OutOfMemory;
                try writeValue(w, value.getColumn(model, table.columns[index]), arena);
            }
            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            if (table.version_index) |index| {
                if (result.affected == 0) return error.OptimisticLockConflict;
                const column = table.columns[index];
                value.setColumn(model, column, try nextVersion(value.getColumn(model, column)));
            }
            try callHook(T, "afterUpdate", model, db);
            try callHook(T, "afterSave", model, db);
        }

        pub fn save(db: *Self, model: anytype) Error!void {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            var complete_key = table.pk_indexes.len > 0;
            inline for (table.pk_indexes) |index| {
                if (isZeroValue(value.getColumn(model, table.columns[index]))) complete_key = false;
            }
            if (complete_key) return db.update(model);
            return db.insert(model);
        }

        pub fn updateWhere(db: *Self, comptime T: type, sets: anytype, sql: []const u8, args: anytype) Error!i64 {
            return db.query(T).where(sql, args).update(sets);
        }

        pub fn deleteWhere(db: *Self, comptime T: type, sql: []const u8, args: anytype) Error!i64 {
            return db.query(T).where(sql, args).delete();
        }

        pub fn deleteWhereHard(db: *Self, comptime T: type, sql: []const u8, args: anytype) Error!i64 {
            return db.query(T).unscoped().where(sql, args).delete();
        }

        pub fn delete(db: *Self, model: anytype) Error!void {
            _ = try db.deleteImpl(model, false);
        }

        pub fn deleteHard(db: *Self, model: anytype) Error!i64 {
            return db.deleteImpl(model, true);
        }

        fn deleteImpl(db: *Self, model: anytype, hard: bool) Error!i64 {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            if (table.pk_indexes.len == 0) return error.InvalidModel;
            try callHook(T, "beforeDelete", model, db);
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var sql = SqlBuf.init(arena);
            const w = sql.writer();
            if (!hard and table.deleted_at_index != null) {
                w.writeAll("UPDATE ") catch return error.OutOfMemory;
                writeIdent(w, table.name) catch return error.OutOfMemory;
                w.writeAll(" SET ") catch return error.OutOfMemory;
                writeIdent(w, table.columns[table.deleted_at_index.?].name) catch return error.OutOfMemory;
                w.writeAll(" = CURRENT_TIMESTAMP WHERE ") catch return error.OutOfMemory;
            } else {
                w.writeAll("DELETE FROM ") catch return error.OutOfMemory;
                writeIdent(w, table.name) catch return error.OutOfMemory;
                w.writeAll(" WHERE ") catch return error.OutOfMemory;
            }
            try writePkPredicate(w, table, model, arena);
            if (!hard) try writeScope(w, table);
            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            try callHook(T, "afterDelete", model, db);
            return result.affected;
        }

        pub fn restore(db: *Self, model: anytype) Error!i64 {
            const T = @TypeOf(model.*);
            const table = comptime schema.tableOf(T);
            const index = table.deleted_at_index orelse return error.InvalidModel;
            var arena_state = std.heap.ArenaAllocator.init(db.backend.gpa);
            defer arena_state.deinit();
            var sql = SqlBuf.init(arena_state.allocator());
            const w = sql.writer();
            w.writeAll("UPDATE ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
            w.writeAll(" SET ") catch return error.OutOfMemory;
            writeIdent(w, table.columns[index].name) catch return error.OutOfMemory;
            w.writeAll(" = NULL WHERE ") catch return error.OutOfMemory;
            try writePkPredicate(w, table, model, arena_state.allocator());
            var result = try db.execRaw(sql.slice());
            defer result.deinit();
            return result.affected;
        }

        pub fn begin(db: *Self) Error!Transaction {
            try db.backend.beginTransaction();
            return .{ .db = db };
        }

        /// Explicitly retries a complete transaction; ordinary writes are never replayed.
        pub fn transactionRetry(
            db: *Self,
            options: RetryOptions,
            context: anytype,
            comptime body: anytype,
        ) Error!void {
            const attempts = @max(@as(u8, 1), options.max_attempts);
            var attempt: u8 = 0;
            while (attempt < attempts) : (attempt += 1) {
                var tx = db.begin() catch |err| {
                    if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                    db.retryDelay(options, attempt);
                    continue;
                };
                body(context, &tx) catch |err| {
                    tx.rollback() catch {};
                    if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                    db.retryDelay(options, attempt);
                    continue;
                };
                tx.commit() catch |err| {
                    tx.rollback() catch {};
                    if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                    db.retryDelay(options, attempt);
                    continue;
                };
                return;
            }
            unreachable;
        }

        pub const Transaction = struct {
            db: *Self,
            finished: bool = false,

            pub fn commit(tx: *Transaction) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.backend.commit();
                tx.finished = true;
            }

            pub fn rollback(tx: *Transaction) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.backend.rollback();
                tx.finished = true;
            }

            pub fn insert(tx: *Transaction, model: anytype) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.insert(model);
            }

            pub fn upsert(tx: *Transaction, model: anytype, comptime conflict: OnConflict) Error!bool {
                if (tx.finished) return error.TransactionFinished;
                return tx.db.upsert(model, conflict);
            }

            pub fn save(tx: *Transaction, model: anytype) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.save(model);
            }

            pub fn update(tx: *Transaction, model: anytype) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.update(model);
            }

            pub fn delete(tx: *Transaction, model: anytype) Error!void {
                if (tx.finished) return error.TransactionFinished;
                try tx.db.delete(model);
            }

            pub fn deleteHard(tx: *Transaction, model: anytype) Error!i64 {
                if (tx.finished) return error.TransactionFinished;
                return tx.db.deleteHard(model);
            }

            pub fn restore(tx: *Transaction, model: anytype) Error!i64 {
                if (tx.finished) return error.TransactionFinished;
                return tx.db.restore(model);
            }

            pub fn find(tx: *Transaction, comptime T: type, key: anytype, gpa: std.mem.Allocator) Error!?T {
                if (tx.finished) return error.TransactionFinished;
                return tx.db.find(T, key, gpa);
            }

            pub fn execArgs(tx: *Transaction, sql: []const u8, args: anytype) Error!types.Result {
                if (tx.finished) return error.TransactionFinished;
                return tx.db.execArgs(sql, args);
            }
        };

        fn writeIdent(w: *std.Io.Writer, ident: []const u8) !void {
            const quote = dialect.identifierQuote();
            try w.writeByte(quote);
            for (ident) |ch| {
                try w.writeByte(ch);
                if (ch == quote) try w.writeByte(ch);
            }
            try w.writeByte(quote);
        }

        fn columnExists(result: *const types.Result, name: []const u8) bool {
            const index: usize = if (dialect == .sqlite) 1 else 0;
            for (result.rows) |row| {
                if (row.len > index and row[index] != null and std.mem.eql(u8, row[index].?, name)) return true;
            }
            return false;
        }

        fn createIndexIfMissing(
            db: *Self,
            table_name: []const u8,
            column: []const u8,
            unique: bool,
            arena: std.mem.Allocator,
        ) Error!void {
            var name_buf: std.Io.Writer.Allocating = .init(arena);
            name_buf.writer.print("{s}_{s}_{s}", .{ if (unique) "uq" else "idx", table_name, column }) catch return error.OutOfMemory;
            const name = name_buf.writer.buffered();
            if (dialect == .mysql) {
                var check = try db.execArgs(
                    "SELECT 1 FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? LIMIT 1",
                    .{ table_name, name },
                );
                defer check.deinit();
                if (check.rows.len > 0) return;
            }
            var sql = SqlBuf.init(arena);
            const w = sql.writer();
            w.writeAll("CREATE ") catch return error.OutOfMemory;
            if (unique) w.writeAll("UNIQUE ") catch return error.OutOfMemory;
            w.writeAll("INDEX ") catch return error.OutOfMemory;
            if (dialect == .sqlite) w.writeAll("IF NOT EXISTS ") catch return error.OutOfMemory;
            writeIdent(w, name) catch return error.OutOfMemory;
            w.writeAll(" ON ") catch return error.OutOfMemory;
            writeIdent(w, table_name) catch return error.OutOfMemory;
            w.writeAll(" (") catch return error.OutOfMemory;
            writeIdent(w, column) catch return error.OutOfMemory;
            w.writeByte(')') catch return error.OutOfMemory;
            try db.exec(sql.slice());
        }

        fn zeroDefault(kind: schema.FieldKind) []const u8 {
            return switch (kind) {
                .integer, .unsigned, .float => "0",
                .boolean => "FALSE",
                .time => "CURRENT_TIMESTAMP",
                .bytes => "X''",
                .jsonb, .int_array, .uint_array, .float_array, .bool_array, .text_array => "'{}'",
                .text, .enum_, .custom => "''",
            };
        }

        fn ddlType(comptime table: schema.Table, comptime col: schema.Column) []const u8 {
            return switch (dialect) {
                .postgresql => unreachable,
                .sqlite => switch (col.kind) {
                    .integer, .unsigned, .boolean => "INTEGER",
                    .float => "REAL",
                    .bytes => "BLOB",
                    else => "TEXT",
                },
                .mysql => switch (col.kind) {
                    .integer => "BIGINT",
                    .unsigned => "BIGINT UNSIGNED",
                    .float => "DOUBLE",
                    .boolean => "BOOLEAN",
                    .text, .enum_ => if (isIndexed(table, col.name)) "VARCHAR(255)" else "TEXT",
                    .time => "DATETIME(6)",
                    .jsonb, .int_array, .uint_array, .float_array, .bool_array, .text_array => "JSON",
                    .bytes => "LONGBLOB",
                    .custom => "TEXT",
                },
            };
        }

        fn isIndexed(comptime table: schema.Table, comptime name: []const u8) bool {
            inline for (table.unique) |column| if (std.mem.eql(u8, column, name)) return true;
            inline for (table.indexes) |column| if (std.mem.eql(u8, column, name)) return true;
            return false;
        }

        fn writeSelectPrefix(w: *std.Io.Writer, comptime table: schema.Table) Error!void {
            w.writeAll("SELECT ") catch return error.OutOfMemory;
            inline for (table.columns, 0..) |col, i| {
                if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
                writeIdent(w, col.name) catch return error.OutOfMemory;
            }
            w.writeAll(" FROM ") catch return error.OutOfMemory;
            writeIdent(w, table.name) catch return error.OutOfMemory;
        }

        fn writeScope(w: *std.Io.Writer, comptime table: schema.Table) Error!void {
            if (table.deleted_at_index) |index| {
                w.writeAll(" AND ") catch return error.OutOfMemory;
                writeIdent(w, table.columns[index].name) catch return error.OutOfMemory;
                w.writeAll(" IS NULL") catch return error.OutOfMemory;
            }
        }

        fn writePkPredicate(w: *std.Io.Writer, comptime table: schema.Table, model: anytype, arena: std.mem.Allocator) Error!void {
            inline for (table.pk_indexes, 0..) |index, i| {
                if (i != 0) w.writeAll(" AND ") catch return error.OutOfMemory;
                const col = table.columns[index];
                const field_value = value.getColumn(model, col);
                if (isNull(field_value)) return error.InvalidModel;
                writeIdent(w, col.name) catch return error.OutOfMemory;
                w.writeAll(" = ") catch return error.OutOfMemory;
                try writeValue(w, field_value, arena);
            }
        }

        fn writeValue(w: *std.Io.Writer, v: anytype, arena: std.mem.Allocator) Error!void {
            const T = @TypeOf(v);
            switch (@typeInfo(T)) {
                .null => w.writeAll("NULL") catch return error.OutOfMemory,
                .optional => {
                    if (v) |inner| return writeValue(w, inner, arena);
                    w.writeAll("NULL") catch return error.OutOfMemory;
                },
                .bool => w.writeByte(if (v) '1' else '0') catch return error.OutOfMemory,
                .int, .comptime_int => w.print("{d}", .{v}) catch return error.OutOfMemory,
                .float, .comptime_float => w.print("{d}", .{v}) catch return error.OutOfMemory,
                .@"enum" => try writeText(w, @tagName(v)),
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) return writeText(w, v);
                    return error.UnsupportedType;
                },
                .array => |array| {
                    if (array.child == u8) return writeText(w, &v);
                    return error.UnsupportedType;
                },
                .@"struct" => {
                    if (@hasDecl(T, "__zorm_time")) {
                        var buf: [value.Time.pg_text_len]u8 = undefined;
                        return writeText(w, v.toPgText(&buf));
                    }
                    if (@hasDecl(T, "__zorm_json")) return writeText(w, v.data);
                    if (@hasDecl(T, "__zorm_bytes")) return writeBlob(w, v.data);
                    if (@hasDecl(T, "zormEncode")) {
                        const param = v.zormEncode(arena) catch return error.TypeMismatch;
                        if (param.is_null) return w.writeAll("NULL") catch return error.OutOfMemory;
                        if (param.format != 0) return error.UnsupportedType;
                        return writeText(w, param.data);
                    }
                    return error.UnsupportedType;
                },
                else => return error.UnsupportedType,
            }
        }

        fn writeText(w: *std.Io.Writer, text: []const u8) Error!void {
            if (dialect == .sqlite) {
                w.writeAll("CAST(X'") catch return error.OutOfMemory;
                try writeHex(w, text);
                w.writeAll("' AS TEXT)") catch return error.OutOfMemory;
            } else {
                w.writeAll("CONVERT(X'") catch return error.OutOfMemory;
                try writeHex(w, text);
                w.writeAll("' USING utf8mb4)") catch return error.OutOfMemory;
            }
        }

        fn writeBlob(w: *std.Io.Writer, bytes: []const u8) Error!void {
            w.writeAll("X'") catch return error.OutOfMemory;
            try writeHex(w, bytes);
            w.writeByte('\'') catch return error.OutOfMemory;
        }

        fn callHook(comptime T: type, comptime name: []const u8, model: *T, db: *Self) Error!void {
            if (!@hasDecl(T, name)) return;
            const result = @call(.auto, @field(T, name), .{ model, db });
            switch (@typeInfo(@TypeOf(result))) {
                .void => {},
                .error_union => try result,
                else => @compileError("zorm: hook " ++ name ++ " must return void or an error union"),
            }
        }

        fn autoStamp(db: *Self, comptime T: type, model: *T, creating: bool) Error!void {
            const table = comptime schema.tableOf(T);
            if (table.created_at_index == null and table.updated_at_index == null) return;
            const io = backendIo(db) orelse return error.InvalidConfig;
            const now = value.Time.now(io);
            if (creating) {
                if (table.created_at_index) |index| {
                    const column = table.columns[index];
                    if (isZeroValue(value.getColumn(model, column))) try setTimeColumn(T, model, column, now);
                }
            }
            if (table.updated_at_index) |index|
                try setTimeColumn(T, model, table.columns[index], now);
        }

        fn backendIo(db: *Self) ?std.Io {
            if (comptime !@hasField(Backend, "io")) return null;
            const io = db.backend.io;
            return switch (@typeInfo(@TypeOf(io))) {
                .optional => io,
                else => io,
            };
        }

        fn elapsedSince(io: ?std.Io, started: ?std.Io.Timestamp) u128 {
            const active_io = io orelse return 0;
            const started_at = started orelse return 0;
            const ns = started_at.durationTo(std.Io.Clock.awake.now(active_io)).nanoseconds;
            return if (ns <= 0) 0 else @intCast(ns);
        }

        fn setTimeColumn(comptime T: type, model: *T, comptime column: schema.Column, now: value.Time) Error!void {
            const V = value.columnFieldType(T, column);

            switch (@typeInfo(V)) {
                .optional => |optional| {
                    if (optional.child == value.Time) {
                        value.setColumn(model, column, @as(V, now));
                    } else if (optional.child == i64) {
                        value.setColumn(model, column, @as(V, now.micros));
                    } else {
                        return error.InvalidModel;
                    }
                },
                .@"struct" => {
                    if (V != value.Time) return error.InvalidModel;
                    value.setColumn(model, column, now);
                },
                .int => {
                    if (V != i64) return error.InvalidModel;
                    value.setColumn(model, column, now.micros);
                },
                else => return error.InvalidModel,
            }
        }
        fn retryDelay(db: *Self, options: RetryOptions, failure_index: u8) void {
            if (options.base_delay_ms == 0) return;
            const io = backendIo(db) orelse return;
            const shift: u6 = @intCast(@min(failure_index, 63));
            const cap = @min(options.base_delay_ms *| (@as(u64, 1) << shift), options.max_delay_ms);
            var random: u64 = undefined;
            io.random(std.mem.asBytes(&random));
            const floor = cap / 2;
            io.sleep(.fromMilliseconds(@intCast(floor + random % (cap - floor + 1))), .awake) catch {};
        }

        fn retryableTransactionError(err: Error, options: RetryOptions) bool {
            return switch (err) {
                error.SerializationFailure, error.DeadlockDetected => true,
                error.ConnectionFailed,
                error.ConnectionClosed,
                error.NetworkReadTimeout,
                error.NetworkWriteTimeout,
                error.AcquireTimeout,
                => options.retry_connection_errors,
                else => false,
            };
        }

        fn nextVersion(v: anytype) Error!@TypeOf(v) {
            return switch (@typeInfo(@TypeOf(v))) {
                .int => std.math.add(@TypeOf(v), v, 1) catch return error.NumericValueOutOfRange,
                .optional => |optional| if (v) |inner|
                    @as(@TypeOf(v), std.math.add(optional.child, inner, 1) catch return error.NumericValueOutOfRange)
                else
                    @as(@TypeOf(v), 1),
                else => @compileError("zorm: version column must be an integer"),
            };
        }

        fn writeHex(w: *std.Io.Writer, bytes: []const u8) Error!void {
            for (bytes) |byte| w.print("{x:0>2}", .{byte}) catch return error.OutOfMemory;
        }

        fn decodeRow(comptime T: type, comptime table: schema.Table, row: []const ?[]const u8, gpa: std.mem.Allocator) Error!T {
            if (row.len != table.columns.len) return error.TypeMismatch;
            var out = std.mem.zeroInit(T, .{});
            errdefer value.freeValue(T, out, gpa);
            inline for (table.columns, 0..) |col, i| {
                const V = value.columnFieldType(T, col);
                value.setColumn(&out, col, value.decodeCell(V, row[i], 0, 0, gpa) catch |err| return err);
            }
            return out;
        }

        fn isZeroValue(v: anytype) bool {
            return switch (@typeInfo(@TypeOf(v))) {
                .optional => v == null,
                .int, .comptime_int => v == 0,
                .float, .comptime_float => v == 0,
                .bool => !v,
                .pointer => |pointer| pointer.size == .slice and v.len == 0,
                .array => |array| if (array.child == u8) std.mem.allEqual(u8, &v, 0) else false,
                else => false,
            };
        }

        fn isNull(v: anytype) bool {
            return @typeInfo(@TypeOf(v)) == .optional and v == null;
        }
    };
}
