//! Session, transactions, CRUD, migrations and the pooled `Db` entry point.

const std = @import("std");
const pq = @import("../pq.zig");
const pool_mod = @import("pool.zig");
const qb_mod = @import("qb.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const time_mod = @import("time.zig");
pub const logger_mod = @import("logger.zig");

const Time = time_mod.Time;
pub const Error = pq.Error;
pub const Query = qb_mod.Query;

/// PostgreSQL's hard limit on bind parameters; batch inserts are chunked to
/// respect it.
const max_params = 65535;

/// SQL text builder over an arena. All SQL assembled here is released with
/// the arena that owns it.
const SqlBuf = struct {
    aw: std.Io.Writer.Allocating,

    fn init(arena: std.mem.Allocator) SqlBuf {
        return .{ .aw = std.Io.Writer.Allocating.init(arena) };
    }

    fn w(b: *SqlBuf) *std.Io.Writer {
        return &b.aw.writer;
    }

    fn slice(b: *SqlBuf) []const u8 {
        return b.aw.writer.buffered();
    }
};

/// Type-appropriate zero value used as DEFAULT when adding NOT NULL columns
/// to existing tables (PostgreSQL requires a default for existing rows).
fn zeroDefault(kind: schema.FieldKind) []const u8 {
    return switch (kind) {
        .integer, .unsigned, .float => "0",
        .boolean => "false",
        .text, .enum_, .bytes => "''",
        .time => "now()",
        .jsonb => "'{}'::jsonb",
        .int_array, .uint_array, .float_array, .bool_array, .text_array => "'{}'",
    };
}

/// One unit of work against the database. Db hands out sessions; a session
/// inside a transaction pins a single connection.
pub const Session = struct {
    pool: *pool_mod.Pool,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Non-null while inside a transaction.
    pinned: ?*pq.Conn = null,
    savepoint_depth: usize = 0,
    logger: logger_mod.Logger = logger_mod.Logger.default,

    pub fn acquire(s: *Session) Error!*pq.Conn {
        return s.pinned orelse s.pool.acquire();
    }

    /// Invokes an optional model hook (`pub fn <name>(self: *T, s: *Session)
    /// z.Error!void`) when the model declares one.
    pub fn callHook(comptime T: type, comptime name: []const u8, m: *T, s: *Session) Error!void {
        if (@hasDecl(T, name)) {
            return @field(T, name)(m, s);
        }
    }

    pub fn releaseConn(s: *Session, c: *pq.Conn) void {
        if (s.pinned == null) s.pool.release(c);
    }

    fn runExec(s: *Session, sql: []const u8, params: []const pq.Param) Error!pq.Result {
        const started = std.Io.Clock.awake.now(s.io);
        const conn = try s.acquire();
        const res = conn.execParams(sql, params) catch |e| {
            s.captureError(conn);
            s.releaseConn(conn);
            s.logQuery(sql, params, started, 0, e);
            return e;
        };
        s.releaseConn(conn);
        s.logQuery(sql, params, started, res.affected, null);
        return res;
    }

    /// Copies the connection's server error into pool-owned storage.
    pub fn captureError(s: *Session, c: *pq.Conn) void {
        s.pool.captureError(c);
    }

    // ------------------------------------------------------------ raw exec

    /// Executes parameterized SQL. Returns a `pq.Result` the caller owns
    /// (`res.deinit()`).
    pub fn exec(s: *Session, sql: []const u8, args: anytype) Error!pq.Result {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const params = try value.argsToParams(args, arena_state.allocator());
        return s.runExec(sql, params);
    }

    /// Executes raw SQL without parameters (simple query protocol; several
    /// statements allowed).
    pub fn execRaw(s: *Session, sql: []const u8) Error!pq.Result {
        const started = std.Io.Clock.awake.now(s.io);
        const conn = try s.acquire();
        const res = conn.execSimple(sql) catch |e| {
            s.captureError(conn);
            s.releaseConn(conn);
            s.logQuery(sql, &.{}, started, 0, e);
            return e;
        };
        s.releaseConn(conn);
        s.logQuery(sql, &.{}, started, res.affected, null);
        return res;
    }

    /// Times and reports one query through the session's logger.
    fn logQuery(
        s: *Session,
        sql: []const u8,
        params: []const pq.Param,
        started: std.Io.Timestamp,
        rows: i64,
        err: ?anyerror,
    ) void {
        const elapsed_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(s.io)).nanoseconds);
        var buf: [4096]u8 = undefined;
        const msg = logger_mod.formatQuery(&s.logger, &buf, sql, params, elapsed_ns, rows, err);
        const level: logger_mod.LogLevel = if (err != null)
            .err
        else if (s.logger.slow_threshold_ms > 0 and
            elapsed_ns / std.time.ns_per_ms >= s.logger.slow_threshold_ms)
            .warn
        else
            .info;
        s.logger.log(level, msg);
    }

    // ---------------------------------------------------------------- CRUD

    /// Inserts one model. Auto-increment primary keys are filled back in.
    /// `created_at` / `updated_at` columns are auto-stamped when empty.
    pub fn insert(s: *Session, m: anytype) Error!void {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zorm: insert expects a mutable pointer to a model, e.g. db.insert(&user)");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);

        try callHook(T, "beforeSave", m, s);
        try callHook(T, "beforeCreate", m, s);
        try s.autoStamp(T, m, true);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var params: std.ArrayList(pq.Param) = .empty;

        var b = SqlBuf.init(arena);
        const w = b.w();

        const pk_col = comptime table.pk();

        w.print("INSERT INTO {s} (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        var first = true;
        inline for (table.columns) |col| {
            if (!(col.is_auto and isZeroValue(value.getColumn(m, col)))) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(try qb_mod.quoteIdent(arena, col.name)) catch return error.OutOfMemory;
                first = false;
            }
        }
        w.writeAll(") VALUES (") catch return error.OutOfMemory;
        var nparams: usize = 0;
        inline for (table.columns) |col| {
            if (!(col.is_auto and isZeroValue(value.getColumn(m, col)))) {
                if (nparams > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{nparams + 1}) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                nparams += 1;
            }
        }
        w.writeAll(")") catch return error.OutOfMemory;

        var returning = false;
        if (comptime (pk_col != null and pk_col.?.is_auto)) {
            if (isZeroValue(value.getColumn(m, pk_col.?))) {
                returning = true;
                const pkc = pk_col.?;
                w.print(" RETURNING {s}", .{try qb_mod.quoteIdent(arena, pkc.name)}) catch return error.OutOfMemory;
            }
        }

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();

        if (returning and res.rows.len > 0 and table.pk_index != null) {
            const pkc = table.columns[table.pk_index.?];
            const FType = value.columnFieldType(T, pkc);
            value.setColumn(m, pkc, try value.decodeCell(
                FType,
                res.rows[0][0],
                res.columns[0].type_oid,
                res.columns[0].format,
                s.gpa,
            ));
        }

        try callHook(T, "afterCreate", m, s);
        try callHook(T, "afterSave", m, s);
    }

    /// Inserts many models in chunked multi-row statements.
    pub fn insertBatch(s: *Session, models: anytype) Error!void {
        const P = @typeInfo(@TypeOf(models));
        const Items: type = blk: {
            if (P == .pointer and P.pointer.size == .slice) break :blk @TypeOf(models);
            if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array)
                break :blk []@typeInfo(P.pointer.child).array.child;
            @compileError("zorm: insertBatch expects a slice, e.g. db.insertBatch(&users)");
        };
        const list: Items = models;
        const T = @typeInfo(Items).pointer.child;
        const table = comptime schema.tableOf(T);
        if (models.len == 0) return;

        var return_auto_pk = false;
        if (comptime table.pk()) |pkc| {
            if (comptime pkc.is_auto) {
                return_auto_pk = true;
                for (list) |*m| {
                    if (!isZeroValue(value.getColumn(m, pkc))) {
                        return_auto_pk = false;
                        break;
                    }
                }
                if (!return_auto_pk) {
                    for (list) |*m| {
                        if (isZeroValue(value.getColumn(m, pkc)))
                            return error.NullValue; // mixed manual/auto pk batch
                    }
                }
            }
        }

        const denom: usize = @max(table.columns.len, 1);
        const chunk_rows: usize = @max(@as(usize, 1), max_params / denom);
        var i: usize = 0;
        while (i < list.len) {
            const end = @min(i + chunk_rows, list.len);
            try s.insertChunk(T, list[i..end], return_auto_pk);
            i = end;
        }
    }

    fn insertChunk(s: *Session, comptime T: type, models: []T, returning: bool) Error!void {
        const table = comptime schema.tableOf(T);
        for (models) |*m| {
            try callHook(T, "beforeSave", m, s);
            try callHook(T, "beforeCreate", m, s);
            try s.autoStamp(T, m, true);
        }

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var params: std.ArrayList(pq.Param) = .empty;

        var b = SqlBuf.init(arena);
        const w = b.w();

        w.print("INSERT INTO {s} (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        var first_col = true;
        inline for (table.columns) |col| {
            if (!(returning and col.is_pk)) {
                if (!first_col) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(try qb_mod.quoteIdent(arena, col.name)) catch return error.OutOfMemory;
                first_col = false;
            }
        }
        w.writeAll(") VALUES ") catch return error.OutOfMemory;

        var np: usize = 0;
        for (models, 0..) |*m, r| {
            if (r > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeByte('(') catch return error.OutOfMemory;
            var first = true;
            inline for (table.columns) |col| {
                if (!(returning and col.is_pk)) {
                    if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                    w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
                    params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                    np += 1;
                    first = false;
                }
            }
            w.writeByte(')') catch return error.OutOfMemory;
        }

        if (returning) {
            const pkc = table.pk().?;
            w.print(" RETURNING {s}", .{try qb_mod.quoteIdent(arena, pkc.name)}) catch return error.OutOfMemory;
        }

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        if (returning and (res.rows.len != models.len or res.columns.len == 0))
            return error.ProtocolViolation;

        if (returning) {
            const pkc = comptime table.pk().?;
            const FType = value.columnFieldType(T, pkc);
            for (models, 0..) |*m, r| {
                if (res.rows[r].len == 0) return error.ProtocolViolation;
                value.setColumn(m, pkc, try value.decodeCell(
                    FType,
                    res.rows[r][0],
                    res.columns[0].type_oid,
                    res.columns[0].format,
                    s.gpa,
                ));
            }
        }

        for (models) |*m| {
            try callHook(T, "afterCreate", m, s);
            try callHook(T, "afterSave", m, s);
        }
    }

    /// Updates every column of the model (except the primary key) by primary
    /// key. `updated_at` is refreshed. Soft-deleted rows are not updated.
    /// Returns affected rows (0 or 1).
    pub fn update(s: *Session, m: anytype) Error!i64 {
        return s.updateImpl(m, false);
    }

    /// Like `update`, but also updates soft-deleted rows.
    pub fn updateUnscoped(s: *Session, m: anytype) Error!i64 {
        return s.updateImpl(m, true);
    }

    fn updateImpl(s: *Session, m: anytype, comptime unscoped: bool) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zorm: update expects a mutable pointer to a model, e.g. db.update(&user)");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key; declare one via `pub const zorm = .{ .primary_key = ... }`");
        const pkc = table.columns[table.pk_index.?];
        if (isZeroValue(value.getColumn(m, pkc))) return error.NullValue;

        try callHook(T, "beforeSave", m, s);
        try callHook(T, "beforeUpdate", m, s);
        try s.autoStamp(T, m, false);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var params: std.ArrayList(pq.Param) = .empty;

        var b = SqlBuf.init(arena);
        const w = b.w();

        w.print("UPDATE {s} SET ", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        var first = true;
        comptime var np: usize = 0;
        inline for (table.columns) |col| {
            if (!col.is_pk) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("{s} = ${d}", .{ try qb_mod.quoteIdent(arena, col.name), np + 1 }) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                first = false;
                np += 1;
            }
        }
        w.print(" WHERE {s} = ${d}", .{ try qb_mod.quoteIdent(arena, pkc.name), np + 1 }) catch return error.OutOfMemory;
        if (comptime table.softDeletable() and !unscoped) {
            const del_col = table.columns[table.deleted_at_index.?];
            w.print(" AND {s} IS NULL", .{try qb_mod.quoteIdent(arena, del_col.name)}) catch return error.OutOfMemory;
        }
        params.append(arena, try value.toParam(value.getColumn(m, pkc), arena)) catch return error.OutOfMemory;

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        const affected = res.affected;

        try callHook(T, "afterUpdate", m, s);
        try callHook(T, "afterSave", m, s);
        return affected;
    }

    /// Insert when the primary key is empty, update otherwise.
    pub fn save(s: *Session, m: anytype) Error!void {
        const T = @typeInfo(@TypeOf(m)).pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) {
            try s.insert(m);
            return;
        }
        const pkc = table.columns[table.pk_index.?];
        if (isZeroValue(value.getColumn(m, pkc))) {
            try s.insert(m);
        } else {
            _ = try s.update(m);
        }
    }

    /// Deletes the model by primary key. Returns affected rows.
    pub fn delete(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zorm: delete expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key");
        const pkc = table.columns[table.pk_index.?];
        if (isZeroValue(value.getColumn(m, pkc))) return error.NullValue;

        try callHook(T, "beforeDelete", m, s);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        const w = b.w();
        const soft = comptime table.softDeletable();
        const params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(value.getColumn(m, pkc), arena);

        if (soft) {
            // Soft delete: stamp deleted_at instead of removing the row.
            const del_col = table.columns[table.deleted_at_index.?];
            w.print("UPDATE {s} SET {s} = {s} WHERE {s} = $1", .{
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, del_col.name),
                qb_mod.softDeleteStampSql(value.columnFieldType(T, del_col)),
                try qb_mod.quoteIdent(arena, pkc.name),
            }) catch return error.OutOfMemory;
        } else {
            w.print("DELETE FROM {s} WHERE {s} = $1", .{
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, pkc.name),
            }) catch return error.OutOfMemory;
        }

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        const affected = res.affected;

        if (soft) {
            // Reflect the stamp in the in-memory model (GORM behaviour).
            const del_col = table.columns[table.deleted_at_index.?];
            const FType = value.columnFieldType(T, del_col);
            const now = Time.now(s.io);
            switch (FType) {
                Time, ?Time => value.setColumn(m, del_col, now),
                i64, ?i64 => value.setColumn(m, del_col, now.micros),
                else => {},
            }
        }

        try callHook(T, "afterDelete", m, s);
        return affected;
    }

    /// Hard-deletes the model row even when the model has a `deleted_at`
    /// column. Returns affected rows.
    pub fn deleteHard(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zorm: deleteHard expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key");
        const pkc = table.columns[table.pk_index.?];
        if (isZeroValue(value.getColumn(m, pkc))) return error.NullValue;

        try callHook(T, "beforeDelete", m, s);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("DELETE FROM {s} WHERE {s} = $1", .{
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, pkc.name),
        }) catch return error.OutOfMemory;
        const params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(value.getColumn(m, pkc), arena);

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        const affected = res.affected;

        try callHook(T, "afterDelete", m, s);
        return affected;
    }

    /// Undoes a soft delete by primary key (sets `deleted_at` back to NULL).
    pub fn restore(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zorm: restore expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.deleted_at_index == null) @compileError("zorm: restore requires a deleted_at column");
        if (table.pk_index == null) @compileError("zorm: model has no primary key");
        const pkc = table.columns[table.pk_index.?];
        const del_col = table.columns[table.deleted_at_index.?];
        if (isZeroValue(value.getColumn(m, pkc))) return error.NullValue;

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("UPDATE {s} SET {s} = NULL WHERE {s} = $1", .{
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, del_col.name),
            try qb_mod.quoteIdent(arena, pkc.name),
        }) catch return error.OutOfMemory;
        const params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(value.getColumn(m, pkc), arena);

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        const affected = res.affected;
        if (affected > 0) value.setColumn(m, del_col, null);
        return affected;
    }

    /// Soft-deletes matching rows when the model has `deleted_at`, otherwise
    /// performs a real DELETE. Returns affected rows.
    pub fn deleteWhere(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return s.deleteWhereImpl(T, frag, args, false);
    }

    /// Hard variant of `deleteWhere`: always performs a real DELETE.
    pub fn deleteWhereHard(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return s.deleteWhereImpl(T, frag, args, true);
    }

    fn deleteWhereImpl(s: *Session, comptime T: type, frag: []const u8, args: anytype, comptime force_hard: bool) Error!i64 {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const table = comptime schema.tableOf(T);
        const soft = comptime table.softDeletable() and !force_hard;

        var b = SqlBuf.init(arena);
        const w = b.w();
        const params_list = try value.argsToParams(args, arena);

        if (soft) {
            const del_col = table.columns[table.deleted_at_index.?];
            w.print("UPDATE {s} SET {s} = {s} WHERE (", .{
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, del_col.name),
                qb_mod.softDeleteStampSql(value.columnFieldType(T, del_col)),
            }) catch return error.OutOfMemory;
            qb_mod.writeRenumbered(w, frag, 0) catch return error.OutOfMemory;
            w.print(") AND {s} IS NULL", .{try qb_mod.quoteIdent(arena, del_col.name)}) catch return error.OutOfMemory;
        } else {
            w.print("DELETE FROM {s} WHERE (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
            qb_mod.writeRenumbered(w, frag, 0) catch return error.OutOfMemory;
            w.writeByte(')') catch return error.OutOfMemory;
        }

        var res = try s.runExec(b.slice(), params_list);
        defer res.deinit();
        return res.affected;
    }

    /// Updates the given fields of matching rows. `sets` is a struct whose
    /// fields reference model columns, e.g. `.{ .active = false }`.
    /// Returns affected rows.
    pub fn updateWhere(s: *Session, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        const table = comptime schema.tableOf(T);
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        const w = b.w();
        var params: std.ArrayList(pq.Param) = .empty;

        const SetsInfo = @typeInfo(@TypeOf(sets)).@"struct";
        if (SetsInfo.fields.len == 0) return error.TypeMismatch;

        w.print("UPDATE {s} SET ", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        inline for (SetsInfo.fields, 0..) |f, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            comptime var col_name: ?[]const u8 = null;
            inline for (table.columns) |col| {
                if (comptime std.mem.eql(u8, col.field_name, f.name)) col_name = col.name;
            }
            if (col_name == null) @compileError("zorm: updateWhere set field '" ++ f.name ++ "' is not a column of " ++ @typeName(T));
            w.print("{s} = ${d}", .{ try qb_mod.quoteIdent(arena, col_name.?), i + 1 }) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(@field(sets, f.name), arena)) catch return error.OutOfMemory;
        }
        w.writeAll(" WHERE (") catch return error.OutOfMemory;
        qb_mod.writeRenumbered(w, frag, SetsInfo.fields.len) catch return error.OutOfMemory;
        w.writeByte(')') catch return error.OutOfMemory;
        if (comptime table.softDeletable()) {
            const del_col = table.columns[table.deleted_at_index.?];
            w.print(" AND {s} IS NULL", .{try qb_mod.quoteIdent(arena, del_col.name)}) catch return error.OutOfMemory;
        }

        const cond_params = try value.argsToParams(args, arena);
        params.appendSlice(arena, cond_params) catch return error.OutOfMemory;

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        return res.affected;
    }

    /// Fetches one model by primary key, or null.
    /// Returned strings are allocated with the session's gpa; release them
    /// with `zorm.free(T, value, gpa)` or decode into an arena of your own.
    /// Fetches one model by primary key, excluding soft-deleted rows
    /// (models with a `deleted_at` column). Use `findUnscoped` to include them.
    pub fn find(s: *Session, comptime T: type, pk: anytype) Error!?T {
        return s.findImpl(T, pk, false);
    }

    /// Like `find`, but also matches soft-deleted rows.
    pub fn findUnscoped(s: *Session, comptime T: type, pk: anytype) Error!?T {
        return s.findImpl(T, pk, true);
    }

    fn findImpl(s: *Session, comptime T: type, pk: anytype, comptime unscoped: bool) Error!?T {
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key");
        const pkc = table.columns[table.pk_index.?];

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("SELECT * FROM {s} WHERE {s} = $1", .{
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, pkc.name),
        }) catch return error.OutOfMemory;
        if (comptime table.softDeletable() and !unscoped) {
            const del_col = table.columns[table.deleted_at_index.?];
            b.w().print(" AND {s} IS NULL", .{try qb_mod.quoteIdent(arena, del_col.name)}) catch return error.OutOfMemory;
        }
        b.w().writeAll(" LIMIT 1") catch return error.OutOfMemory;
        const params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(pk, arena);

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        if (res.rows.len == 0) return null;
        var out = try value.scanRow(T, table, &res, res.rows[0], s.gpa);
        try callHook(T, "afterFind", &out, s);
        return out;
    }

    // --------------------------------------------------------------- query

    /// Starts a GORM-style query builder for `T`. The builder (plus a heap
    /// copy of this session) is allocated on the heap and released by the
    /// terminal operation, so chains like `z.query(User, db).where(..).all()`
    /// need no manual cleanup.
    pub fn query(s: *Session, comptime T: type) *Query(T) {
        const gpa = s.gpa;
        const sess_copy = gpa.create(Session) catch @panic("zorm: out of memory");
        sess_copy.* = s.*;
        const arena = gpa.create(std.heap.ArenaAllocator) catch @panic("zorm: out of memory");
        arena.* = std.heap.ArenaAllocator.init(gpa);
        const q = gpa.create(Query(T)) catch @panic("zorm: out of memory");
        q.* = .{ .sess = sess_copy, .owns_session = true, .arena = arena };
        return q;
    }

    // -------------------------------------------------------- transactions

    /// Starts a transaction, pinning one pooled connection.
    pub fn begin(s: *Session) Error!Tx {
        if (s.pinned != null) return error.ProtocolViolation; // nested tx unsupported
        const conn = try s.pool.acquire();
        var res = conn.execSimple("BEGIN") catch |e| {
            s.captureError(conn);
            s.pool.release(conn);
            return e;
        };
        res.deinit();
        s.pinned = conn;
        return .{ .sess = s };
    }

    // -------------------------------------------------------------- migrate

    /// Creates the table for `T` if missing, and adds any missing columns.
    pub fn autoMigrate(s: *Session, comptime T: type) Error!void {
        const table = comptime schema.tableOf(T);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var existing: std.ArrayList([]const u8) = .empty;
        {
            var res = try s.exec(
                "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
                .{table.name},
            );
            defer res.deinit();
            for (res.rows) |row| {
                if (row[0]) |name| {
                    existing.append(arena, arena.dupe(u8, name) catch return error.OutOfMemory) catch return error.OutOfMemory;
                }
            }
        }

        if (existing.items.len == 0) {
            var b = SqlBuf.init(arena);
            const w = b.w();
            w.print("CREATE TABLE IF NOT EXISTS {s} (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
            inline for (table.columns, 0..) |col, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                if (col.is_auto) {
                    const serial: []const u8 = if (std.mem.eql(u8, col.ddl_type, "integer"))
                        "serial"
                    else if (std.mem.eql(u8, col.ddl_type, "bigint"))
                        "bigserial"
                    else
                        col.ddl_type;
                    w.print("{s} {s} PRIMARY KEY", .{ try qb_mod.quoteIdent(arena, col.name), serial }) catch return error.OutOfMemory;
                } else {
                    w.print("{s} {s}", .{ try qb_mod.quoteIdent(arena, col.name), col.ddl_type }) catch return error.OutOfMemory;
                    if (!col.is_optional) w.writeAll(" NOT NULL") catch return error.OutOfMemory;
                    if (col.is_pk) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                }
            }
            w.writeAll(")") catch return error.OutOfMemory;
            var res = try s.execRaw(b.slice());
            res.deinit();
        } else {
            // Does the table already have a primary key? Auto-increment
            // columns can only carry PRIMARY KEY when none exists.
            var table_has_pk = false;
            {
                var res = try s.exec(
                    \\SELECT 1 FROM information_schema.table_constraints
                    \\WHERE table_schema = current_schema() AND table_name = $1
                    \\  AND constraint_type = 'PRIMARY KEY' LIMIT 1
                ,
                    .{table.name},
                );
                defer res.deinit();
                table_has_pk = res.rows.len > 0;
            }

            inline for (table.columns) |col| {
                var found = false;
                for (existing.items) |name| {
                    if (std.mem.eql(u8, name, col.name)) found = true;
                }
                if (!found) {
                    var b = SqlBuf.init(arena);
                    const w = b.w();
                    w.print("ALTER TABLE {s} ADD COLUMN IF NOT EXISTS {s} ", .{
                        try qb_mod.quoteIdent(arena, table.name),
                        try qb_mod.quoteIdent(arena, col.name),
                    }) catch return error.OutOfMemory;
                    if (col.is_auto) {
                        // Serial implies NOT NULL + sequence default.
                        const serial: []const u8 = if (std.mem.eql(u8, col.ddl_type, "integer"))
                            "serial"
                        else if (std.mem.eql(u8, col.ddl_type, "bigint"))
                            "bigserial"
                        else
                            col.ddl_type;
                        w.writeAll(serial) catch return error.OutOfMemory;
                        if (!table_has_pk) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                    } else {
                        w.writeAll(col.ddl_type) catch return error.OutOfMemory;
                        if (!col.is_optional) {
                            w.print(" NOT NULL DEFAULT {s}", .{zeroDefault(col.kind)}) catch return error.OutOfMemory;
                        }
                        if (col.is_pk and !table_has_pk) {
                            w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                        }
                    }
                    var res = try s.execRaw(b.slice());
                    res.deinit();
                }
            }
        }

        // Single-column indexes.
        inline for (table.unique) |col_name| {
            const idx = std.fmt.allocPrint(arena, "uq_{s}_{s}", .{ table.name, col_name }) catch return error.OutOfMemory;
            var b = SqlBuf.init(arena);
            b.w().print("CREATE UNIQUE INDEX IF NOT EXISTS {s} ON {s} ({s})", .{
                try qb_mod.quoteIdent(arena, idx),
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, col_name),
            }) catch return error.OutOfMemory;
            var res = try s.execRaw(b.slice());
            res.deinit();
        }
        inline for (table.indexes) |col_name| {
            const idx = std.fmt.allocPrint(arena, "idx_{s}_{s}", .{ table.name, col_name }) catch return error.OutOfMemory;
            var b = SqlBuf.init(arena);
            b.w().print("CREATE INDEX IF NOT EXISTS {s} ON {s} ({s})", .{
                try qb_mod.quoteIdent(arena, idx),
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, col_name),
            }) catch return error.OutOfMemory;
            var res = try s.execRaw(b.slice());
            res.deinit();
        }
    }

    /// Runs autoMigrate for every model in the tuple.
    pub fn autoMigrateAll(s: *Session, comptime models: anytype) Error!void {
        inline for (models) |T| try s.autoMigrate(T);
    }

    // ------------------------------------------------------------- helpers

    fn autoStamp(s: *Session, comptime T: type, m: anytype, comptime is_insert: bool) Error!void {
        const table = comptime schema.tableOf(T);
        if (table.created_at_index == null and table.updated_at_index == null) return;

        const now = Time.now(s.io);
        inline for (table.columns, 0..) |col, i| {
            const is_created = table.created_at_index != null and table.created_at_index.? == i;
            const is_updated = table.updated_at_index != null and table.updated_at_index.? == i;
            if ((is_created and is_insert) or is_updated) {
                const FType = value.columnFieldType(T, col);
                switch (FType) {
                    Time => {
                        if (value.getColumn(m, col).micros == 0) value.setColumn(m, col, now);
                    },
                    ?Time => {
                        if (value.getColumn(m, col) == null) value.setColumn(m, col, now);
                    },
                    i64 => {
                        if (value.getColumn(m, col) == 0) value.setColumn(m, col, now.micros);
                    },
                    ?i64 => {
                        if (value.getColumn(m, col) == null) value.setColumn(m, col, now.micros);
                    },
                    else => {},
                }
            }
        }
    }

    fn isZeroValue(v: anytype) bool {
        return switch (@typeInfo(@TypeOf(v))) {
            .optional => v == null,
            .int => v == 0,
            .pointer => v.len == 0,
            else => false,
        };
    }
};

/// A pinned-connection transaction. A Tx created with `begin()` on another
/// Tx represents a SAVEPOINT: `commit()` releases it, `rollback()` rolls back
/// to it (and releases).
pub const Tx = struct {
    sess: *Session,
    /// True when the Tx owns its (heap) session — `Db.begin`.
    owns_session: bool = false,
    /// True when this Tx is a savepoint inside an outer transaction.
    is_savepoint: bool = false,
    sp_name_buf: [24]u8 = undefined,
    sp_name_len: usize = 0,
    finished: bool = false,

    fn spName(t: *const Tx) []const u8 {
        return t.sp_name_buf[0..t.sp_name_len];
    }

    /// Starts a nested transaction (SAVEPOINT) inside this transaction.
    pub fn begin(t: *Tx) Error!Tx {
        if (t.sess.pinned == null) return error.ProtocolViolation;
        t.sess.savepoint_depth += 1;
        errdefer t.sess.savepoint_depth -= 1;

        var sp = Tx{ .sess = t.sess, .is_savepoint = true };
        const name = std.fmt.bufPrint(&sp.sp_name_buf, "zorm_sp_{d}", .{t.sess.savepoint_depth}) catch
            unreachable;
        sp.sp_name_len = name.len;

        const sql = std.fmt.allocPrint(t.sess.gpa, "SAVEPOINT {s}", .{sp.spName()}) catch
            return error.OutOfMemory;
        defer t.sess.gpa.free(sql);
        var res = try t.sess.execRaw(sql);
        res.deinit();
        return sp;
    }

    fn releaseSavepoint(t: *Tx, comptime action: []const u8) Error!void {
        const sql = std.fmt.allocPrint(t.sess.gpa, "{s} SAVEPOINT {s}", .{ action, t.spName() }) catch
            return error.OutOfMemory;
        defer t.sess.gpa.free(sql);
        var res = try t.sess.execRaw(sql);
        res.deinit();
    }

    fn finish(t: *Tx) void {
        if (t.owns_session) t.sess.gpa.destroy(t.sess);
    }

    pub fn commit(t: *Tx) Error!void {
        if (t.finished) return error.ConnectionClosed;
        t.finished = true;
        if (t.is_savepoint) {
            t.releaseSavepoint("RELEASE") catch |e| {
                t.sess.savepoint_depth -= 1;
                t.finish();
                return e;
            };
            t.sess.savepoint_depth -= 1;
            t.finish();
            return;
        }
        const conn = t.sess.pinned.?;
        var res = conn.execSimple("COMMIT") catch |e| {
            t.sess.captureError(conn);
            t.sess.pinned = null;
            t.sess.pool.release(conn);
            t.finish();
            return e;
        };
        res.deinit();
        t.sess.pinned = null;
        t.sess.pool.release(conn);
        t.finish();
    }

    /// Rolls back. Safe to call from `defer`; safe on an already-finished tx.
    pub fn rollback(t: *Tx) void {
        if (t.finished) return;
        t.finished = true;
        if (t.is_savepoint) {
            // Roll back to the savepoint, then release it so the name can be
            // reused later in the same transaction.
            t.releaseSavepoint("ROLLBACK TO") catch {
                t.sess.savepoint_depth -= 1;
                t.finish();
                return;
            };
            t.releaseSavepoint("RELEASE") catch {};
            t.sess.savepoint_depth -= 1;
            t.finish();
            return;
        }
        const conn = t.sess.pinned.?;
        var res = conn.execSimple("ROLLBACK") catch {
            t.sess.pinned = null;
            t.sess.pool.release(conn);
            t.finish();
            return;
        };
        res.deinit();
        t.sess.pinned = null;
        t.sess.pool.release(conn);
        t.finish();
    }

    // All Session operations are available on the transaction.
    pub fn insert(t: *Tx, m: anytype) Error!void {
        return t.sess.insert(m);
    }
    pub fn insertBatch(t: *Tx, models: anytype) Error!void {
        return t.sess.insertBatch(models);
    }
    pub fn update(t: *Tx, m: anytype) Error!i64 {
        return t.sess.update(m);
    }
    pub fn save(t: *Tx, m: anytype) Error!void {
        return t.sess.save(m);
    }
    pub fn delete(t: *Tx, m: anytype) Error!i64 {
        return t.sess.delete(m);
    }
    pub fn deleteWhere(t: *Tx, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.deleteWhere(T, frag, args);
    }
    pub fn deleteHard(t: *Tx, m: anytype) Error!i64 {
        return t.sess.deleteHard(m);
    }
    pub fn deleteWhereHard(t: *Tx, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.deleteWhereHard(T, frag, args);
    }
    pub fn restore(t: *Tx, m: anytype) Error!i64 {
        return t.sess.restore(m);
    }
    pub fn updateWhere(t: *Tx, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.updateWhere(T, sets, frag, args);
    }
    pub fn find(t: *Tx, comptime T: type, pk: anytype) Error!?T {
        return t.sess.find(T, pk);
    }
    pub fn findUnscoped(t: *Tx, comptime T: type, pk: anytype) Error!?T {
        return t.sess.findUnscoped(T, pk);
    }
    pub fn updateUnscoped(t: *Tx, m: anytype) Error!i64 {
        return t.sess.updateUnscoped(m);
    }
    pub fn query(t: *Tx, comptime T: type) *Query(T) {
        const gpa = t.sess.gpa;
        const arena = gpa.create(std.heap.ArenaAllocator) catch @panic("zorm: out of memory");
        arena.* = std.heap.ArenaAllocator.init(gpa);
        const q = gpa.create(Query(T)) catch @panic("zorm: out of memory");
        q.* = .{ .sess = t.sess, .owns_session = false, .arena = arena };
        return q;
    }
    pub fn exec(t: *Tx, sql: []const u8, args: anytype) Error!pq.Result {
        return t.sess.exec(sql, args);
    }
    pub fn execRaw(t: *Tx, sql: []const u8) Error!pq.Result {
        return t.sess.execRaw(sql);
    }
};

/// Pooled database handle. Sessions are cheap value structs derived from it.
pub const Db = struct {
    pool: pool_mod.Pool,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Logger used for every query issued through this handle.
    /// Replace with `setLogger`; defaults to the stderr logger at warn level.
    logger: logger_mod.Logger = logger_mod.Logger.default,
    /// Owns the parsed Config strings for DSN-based connections so they live
    /// as long as the pool (the pool only copies the slices).
    cfg_arena: ?*std.heap.ArenaAllocator = null,

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, max_connections: usize) Error!*Db {
        const d = try gpa.create(Db);
        errdefer gpa.destroy(d);
        d.* = .{
            .pool = pool_mod.Pool.init(gpa, io, cfg, max_connections),
            .gpa = gpa,
            .io = io,
        };
        // Fail fast on bad credentials/config.
        const conn = try d.pool.acquire();
        d.pool.release(conn);
        return d;
    }

    /// Parses `dsn` (URL or keyword form) and connects. The parsed strings
    /// are owned by the returned Db and live until `deinit` — the caller's
    /// DSN buffer may be freed immediately after this call.
    pub fn connectDsn(gpa: std.mem.Allocator, io: std.Io, dsn: []const u8, max_connections: usize) Error!*Db {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const cfg = try pq.parseDsn(arena.allocator(), dsn);
        const d = try connect(gpa, io, cfg, max_connections);
        // connect succeeded: hand the arena over to the Db.
        d.cfg_arena = arena;
        return d;
    }

    pub fn deinit(d: *Db) void {
        d.pool.deinit();
        if (d.cfg_arena) |a| {
            const gpa = d.gpa;
            a.deinit();
            gpa.destroy(a);
        }
        d.gpa.destroy(d);
    }

    pub fn session(d: *Db) Session {
        return .{ .pool = &d.pool, .gpa = d.gpa, .io = d.io, .logger = d.logger };
    }

    // Convenience delegates for one-off operations.
    pub fn insert(d: *Db, m: anytype) Error!void {
        var s = d.session();
        return s.insert(m);
    }
    pub fn insertBatch(d: *Db, models: anytype) Error!void {
        var s = d.session();
        return s.insertBatch(models);
    }
    pub fn update(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.update(m);
    }
    pub fn save(d: *Db, m: anytype) Error!void {
        var s = d.session();
        return s.save(m);
    }
    pub fn delete(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.delete(m);
    }
    pub fn deleteWhere(d: *Db, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        var s = d.session();
        return s.deleteWhere(T, frag, args);
    }
    pub fn deleteHard(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.deleteHard(m);
    }
    pub fn deleteWhereHard(d: *Db, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        var s = d.session();
        return s.deleteWhereHard(T, frag, args);
    }
    pub fn restore(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.restore(m);
    }
    pub fn updateWhere(d: *Db, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        var s = d.session();
        return s.updateWhere(T, sets, frag, args);
    }
    pub fn find(d: *Db, comptime T: type, pk: anytype) Error!?T {
        var s = d.session();
        return s.find(T, pk);
    }
    pub fn findUnscoped(d: *Db, comptime T: type, pk: anytype) Error!?T {
        var s = d.session();
        return s.findUnscoped(T, pk);
    }
    pub fn updateUnscoped(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.updateUnscoped(m);
    }
    pub fn begin(d: *Db) Error!Tx {
        const s = d.gpa.create(Session) catch return error.OutOfMemory;
        s.* = d.session();
        errdefer d.gpa.destroy(s);
        var tx = try s.begin();
        tx.owns_session = true;
        return tx;
    }
    pub fn query(comptime T: type, d: *Db) *Query(T) {
        var s = d.session();
        return s.query(T);
    }

    /// Details (SQLSTATE, message, constraint, ...) of the most recent
    /// server error observed through this handle. The returned slices point
    /// into the pool's diagnostic buffer and are valid until the next
    /// captured error on any session of this Db.
    pub fn lastError(d: *Db) ?pq.PgError {
        return d.pool.last_error;
    }

    /// Concurrency-safe variant of `lastError`: returns a snapshot whose
    /// strings are deep-copied into `arena`.
    pub fn lastErrorCopy(d: *Db, arena: std.mem.Allocator) ?pq.PgError {
        return d.pool.lastErrorCopy(arena);
    }

    /// Replaces the logger used for every query issued through this handle.
    /// Pass `z.Logger.discard` to silence, or a custom `Logger` with your own
    /// sink. Defaults to the stderr logger at warn level.
    pub fn setLogger(d: *Db, logger: logger_mod.Logger) void {
        d.logger = logger;
    }
    pub fn exec(d: *Db, sql: []const u8, args: anytype) Error!pq.Result {
        var s = d.session();
        return s.exec(sql, args);
    }
    pub fn execRaw(d: *Db, sql: []const u8) Error!pq.Result {
        var s = d.session();
        return s.execRaw(sql);
    }
    pub fn autoMigrate(d: *Db, comptime T: type) Error!void {
        var s = d.session();
        return s.autoMigrate(T);
    }
    pub fn autoMigrateAll(d: *Db, comptime models: anytype) Error!void {
        var s = d.session();
        return s.autoMigrateAll(models);
    }
};
