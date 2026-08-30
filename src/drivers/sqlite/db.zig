//! Small SQLite driver used when an embedded database is preferable to a pool.

const std = @import("std");
const types = @import("../shared/types.zig");
const pool_mod = @import("../shared/pool.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Error = types.Error;

pub const Param = types.Param;

pub const OpenOptions = struct {
    read_only: bool = false,
    create: bool = true,
    busy_timeout_ms: u32 = 5_000,
    foreign_keys: bool = true,
    wal: bool = false,
};

pub const PoolOptions = pool_mod.Options;
pub const PoolStats = pool_mod.Stats;

const PoolContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    filename: []const u8,
    options: OpenOptions,
};

fn poolCreate(context: *PoolContext) Error!*Db {
    return Db.openWithIo(context.gpa, context.io, context.filename, context.options);
}

fn poolDestroy(db: *Db) void {
    db.deinit();
}

fn poolPing(db: *Db) Error!void {
    var result = try db.exec("SELECT 1");
    result.deinit();
}

pub const Pool = pool_mod.Pool(*Db, PoolContext, poolCreate, poolDestroy, poolPing);

pub fn openPool(gpa: std.mem.Allocator, io: std.Io, filename: []const u8, options: OpenOptions, pool_options: PoolOptions) Error!*Pool {
    return Pool.init(gpa, io, pool_options, .{ .gpa = gpa, .io = io, .filename = filename, .options = options });
}
pub const Result = types.Result;

pub const Db = struct {
    gpa: std.mem.Allocator,
    handle: *c.sqlite3,
    last_error: ?types.ServerError = null,
    io: ?std.Io = null,
    error_code_buf: [16]u8 = undefined,
    deadline: ?std.Io.Timestamp = null,

    pub fn open(gpa: std.mem.Allocator, filename: []const u8) Error!*Db {
        return openWithOptions(gpa, filename, .{});
    }

    pub fn openWithOptions(gpa: std.mem.Allocator, filename: []const u8, options: OpenOptions) Error!*Db {
        const name = gpa.dupeZ(u8, filename) catch return error.OutOfMemory;
        defer gpa.free(name);
        var handle: ?*c.sqlite3 = null;
        const flags = if (options.read_only)
            c.SQLITE_OPEN_READONLY
        else
            c.SQLITE_OPEN_READWRITE | (if (options.create) c.SQLITE_OPEN_CREATE else 0);
        if (c.sqlite3_open_v2(name.ptr, &handle, flags | c.SQLITE_OPEN_URI, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.OpenFailed;
        }
        const db = gpa.create(Db) catch {
            _ = c.sqlite3_close(handle.?);
            return error.OutOfMemory;
        };
        db.* = .{ .gpa = gpa, .handle = handle.? };
        errdefer db.deinit();
        _ = c.sqlite3_extended_result_codes(db.handle, 1);
        if (options.busy_timeout_ms > std.math.maxInt(c_int)) return error.InvalidQuery;
        if (c.sqlite3_busy_timeout(db.handle, @intCast(options.busy_timeout_ms)) != c.SQLITE_OK)
            return db.databaseError();
        if (options.foreign_keys) try db.execControl("PRAGMA foreign_keys=ON");
        if (options.wal and !options.read_only) try db.execControl("PRAGMA journal_mode=WAL");
        return db;
    }

    pub fn openWithIo(gpa: std.mem.Allocator, io: std.Io, filename: []const u8, options: OpenOptions) Error!*Db {
        const db = try openWithOptions(gpa, filename, options);
        db.io = io;
        return db;
    }

    pub fn deinit(db: *Db) void {
        _ = c.sqlite3_close(db.handle);
        const gpa = db.gpa;
        gpa.destroy(db);
    }

    pub fn exec(db: *Db, sql: []const u8) Error!Result {
        return db.execParams(sql, &.{});
    }

    pub fn execParams(db: *Db, sql: []const u8, params: []const Param) Error!Result {
        const text = db.gpa.dupeZ(u8, sql) catch return error.OutOfMemory;
        defer db.gpa.free(text);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, text.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK)
            return db.databaseError();
        defer _ = c.sqlite3_finalize(stmt.?);

        if (c.sqlite3_bind_parameter_count(stmt.?) != params.len) return error.InvalidQuery;
        for (params, 1..) |param, index| {
            if (bindParam(stmt.?, @intCast(index), param) != c.SQLITE_OK)
                return db.databaseError();
        }

        const arena_state = db.gpa.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_state.* = std.heap.ArenaAllocator.init(db.gpa);
        errdefer {
            arena_state.deinit();
            db.gpa.destroy(arena_state);
        }
        const arena = arena_state.allocator();
        var columns: std.ArrayList(Result.Column) = .empty;
        const column_count: usize = @intCast(c.sqlite3_column_count(stmt.?));
        for (0..column_count) |i| {
            const name = std.mem.span(c.sqlite3_column_name(stmt.?, @intCast(i)));
            columns.append(arena, .{
                .name = arena.dupe(u8, name) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }

        var rows: std.ArrayList(Result.Row) = .empty;
        while (true) switch (c.sqlite3_step(stmt.?)) {
            c.SQLITE_ROW => {
                const row = arena.alloc(?[]const u8, column_count) catch return error.OutOfMemory;
                @memset(row, null);
                for (row, 0..) |*cell, i| {
                    if (c.sqlite3_column_type(stmt.?, @intCast(i)) == c.SQLITE_NULL) continue;
                    const ptr = c.sqlite3_column_blob(stmt.?, @intCast(i)) orelse {
                        cell.* = "";
                        continue;
                    };
                    const len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, @intCast(i)));
                    const bytes: [*]const u8 = @ptrCast(ptr);
                    cell.* = arena.dupe(u8, bytes[0..len]) catch return error.OutOfMemory;
                }
                rows.append(arena, row) catch return error.OutOfMemory;
            },
            c.SQLITE_DONE => break,
            else => return db.databaseError(),
        };

        const row_count = rows.items.len;
        return .{
            .arena = arena_state,
            .columns = columns.toOwnedSlice(arena) catch return error.OutOfMemory,
            .rows = rows.toOwnedSlice(arena) catch return error.OutOfMemory,
            .affected = if (column_count == 0) c.sqlite3_changes64(db.handle) else @intCast(row_count),
            .last_insert_id = @intCast(c.sqlite3_last_insert_rowid(db.handle)),
        };
    }

    pub fn execParamsTimeout(db: *Db, sql: []const u8, params: []const Param, timeout_ms: u64) Error!Result {
        if (timeout_ms == 0) return db.execParams(sql, params);
        const io = db.io orelse return error.InvalidConfig;
        db.deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(@intCast(timeout_ms)));
        c.sqlite3_progress_handler(db.handle, 1_000, progressCallback, db);
        defer {
            c.sqlite3_progress_handler(db.handle, 0, null, null);
            db.deadline = null;
        }
        return db.execParams(sql, params);
    }

    pub fn lastError(db: *const Db) ?types.ServerError {
        return db.last_error;
    }

    pub fn interrupt(db: *Db) void {
        c.sqlite3_interrupt(db.handle);
    }

    fn progressCallback(raw: ?*anyopaque) callconv(.c) c_int {
        const db: *Db = @ptrCast(@alignCast(raw orelse return 1));
        const deadline = db.deadline orelse return 0;
        const io = db.io orelse return 1;
        return if (std.Io.Clock.awake.now(io).durationTo(deadline).nanoseconds <= 0) 1 else 0;
    }

    fn databaseError(db: *Db) Error {
        const code = c.sqlite3_extended_errcode(db.handle);
        const code_text = std.fmt.bufPrint(&db.error_code_buf, "{d}", .{code}) catch "";
        db.last_error = .{
            .severity = "ERROR",
            .code = code_text,
            .message = std.mem.span(c.sqlite3_errmsg(db.handle)),
        };
        return switch (code & 0xff) {
            c.SQLITE_INTERRUPT => if (db.deadline != null) error.QueryTimeout else error.QueryCanceled,
            c.SQLITE_CONSTRAINT => switch (code) {
                c.SQLITE_CONSTRAINT_UNIQUE, c.SQLITE_CONSTRAINT_PRIMARYKEY => error.UniqueViolation,
                c.SQLITE_CONSTRAINT_FOREIGNKEY => error.ForeignKeyViolation,
                c.SQLITE_CONSTRAINT_NOTNULL => error.NotNullViolation,
                c.SQLITE_CONSTRAINT_CHECK => error.CheckViolation,
                else => error.QueryFailed,
            },
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SerializationFailure,
            c.SQLITE_RANGE => error.NumericValueOutOfRange,
            c.SQLITE_MISMATCH => error.TypeMismatch,
            else => error.QueryFailed,
        };
    }

    pub fn beginTransaction(db: *Db) Error!void {
        try db.execControl("BEGIN");
    }

    pub fn commit(db: *Db) Error!void {
        try db.execControl("COMMIT");
    }

    pub fn rollback(db: *Db) Error!void {
        try db.execControl("ROLLBACK");
    }

    fn execControl(db: *Db, sql: []const u8) Error!void {
        var result = try db.exec(sql);
        result.deinit();
    }
};

fn bindParam(stmt: *c.sqlite3_stmt, index: c_int, param: Param) c_int {
    if (param.is_null or param.kind == .null_) return c.sqlite3_bind_null(stmt, index);
    return switch (param.kind) {
        .null_ => unreachable,
        .boolean => c.sqlite3_bind_int(stmt, index, if (param.data.len > 0 and param.data[0] != 0) 1 else 0),
        .signed => if (param.format == 1 and param.data.len == 8)
            c.sqlite3_bind_int64(stmt, index, @bitCast(std.mem.readInt(u64, param.data[0..8], .big)))
        else
            c.sqlite3_bind_text(stmt, index, param.data.ptr, @intCast(param.data.len), null),
        .unsigned => if (param.format == 1 and param.data.len == 8 and std.mem.readInt(u64, param.data[0..8], .big) <= std.math.maxInt(i64))
            c.sqlite3_bind_int64(stmt, index, @intCast(std.mem.readInt(u64, param.data[0..8], .big)))
        else
            c.sqlite3_bind_text(stmt, index, param.data.ptr, @intCast(param.data.len), null),
        .float => if (param.format == 1 and param.data.len == 8)
            c.sqlite3_bind_double(stmt, index, @bitCast(std.mem.readInt(u64, param.data[0..8], .big)))
        else
            c.sqlite3_bind_text(stmt, index, param.data.ptr, @intCast(param.data.len), null),
        .bytes => c.sqlite3_bind_blob(stmt, index, param.data.ptr, @intCast(param.data.len), null),
        .text, .json, .time => blk: {
            const text = if (param.canonical.len > 0) param.canonical else param.data;
            break :blk c.sqlite3_bind_text(stmt, index, text.ptr, @intCast(text.len), null);
        },
    };
}

pub const Orm = @import("../shared/orm.zig").Orm(Db, .sqlite);

pub fn orm(db: *Db) Orm {
    return .init(db);
}

pub const Migrator = @import("../shared/migrator.zig").Migrator(Orm);

pub fn migrator(db: *Orm) Migrator {
    return .init(db);
}

test "SQLite in-memory CRUD" {
    const gpa = std.testing.allocator;
    const db = try Db.open(gpa, ":memory:");
    defer db.deinit();
    var create = try db.exec("CREATE TABLE users (id integer primary key, name text)");
    create.deinit();
    var insert = try db.exec("INSERT INTO users (name) VALUES ('Ada')");
    defer insert.deinit();
    try std.testing.expectEqual(@as(i64, 1), insert.affected);
    var result = try db.exec("SELECT id, name FROM users");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("Ada", result.rows[0][1].?);
}
