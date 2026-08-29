//! Session, transactions, CRUD, migrations and the pooled `Db` entry point.

const std = @import("std");
const pq = @import("../pq.zig");
const pool_mod = @import("pool.zig");
const qb_mod = @import("qb.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const time_mod = @import("time.zig");

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

/// One unit of work against the database. Db hands out sessions; a session
/// inside a transaction pins a single connection.
pub const Session = struct {
    pool: *pool_mod.Pool,
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Non-null while inside a transaction.
    pinned: ?*pq.Conn = null,
    logger: ?*const fn (sql: []const u8, params: []const pq.Param) void = null,

    pub fn acquire(s: *Session) Error!*pq.Conn {
        return s.pinned orelse s.pool.acquire();
    }

    pub fn releaseConn(s: *Session, c: *pq.Conn) void {
        if (s.pinned == null) s.pool.release(c);
    }

    fn runExec(s: *Session, sql: []const u8, params: []const pq.Param) Error!pq.Result {
        if (s.logger) |log| log(sql, params);
        const conn = try s.acquire();
        const res = conn.execParams(sql, params) catch |e| {
            s.captureError(conn);
            s.releaseConn(conn);
            return e;
        };
        s.releaseConn(conn);
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
        if (s.logger) |log| log(sql, &.{});
        const conn = try s.acquire();
        const res = conn.execSimple(sql) catch |e| {
            s.captureError(conn);
            s.releaseConn(conn);
            return e;
        };
        s.releaseConn(conn);
        return res;
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
            if (!(col.is_auto and isZeroPk(T, m, col.field_name))) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(try qb_mod.quoteIdent(arena, col.name)) catch return error.OutOfMemory;
                first = false;
            }
        }
        w.writeAll(") VALUES (") catch return error.OutOfMemory;
        var nparams: usize = 0;
        inline for (table.columns) |col| {
            if (!(col.is_auto and isZeroPk(T, m, col.field_name))) {
                if (nparams > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{nparams + 1}) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(getField(T, m, col.field_name), arena)) catch return error.OutOfMemory;
                nparams += 1;
            }
        }
        w.writeAll(")") catch return error.OutOfMemory;

        var returning = false;
        if (comptime (pk_col != null and pk_col.?.is_auto)) {
            if (isZeroPk(T, m, pk_col.?.field_name)) {
                returning = true;
                const pkc = pk_col.?;
                w.print(" RETURNING {s}", .{try qb_mod.quoteIdent(arena, pkc.name)}) catch return error.OutOfMemory;
            }
        }

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();

        if (returning and res.rows.len > 0 and table.pk_index != null) {
            const pkc = table.columns[table.pk_index.?];
            const FType = FieldOf(T, pkc.field_name);
            @field(m, pkc.field_name) = try value.decodeCell(
                FType,
                res.rows[0][0],
                res.columns[0].type_oid,
                s.gpa,
            );
        }
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

        var all_auto: bool = true;
        if (comptime table.pk()) |pkc| {
            for (list) |*m| {
                if (!isZeroPk(T, m, pkc.field_name)) {
                    all_auto = false;
                    break;
                }
            }
            if (!all_auto) {
                for (list) |*m| {
                    if (isZeroPk(T, m, pkc.field_name))
                        return error.NullValue; // mixed manual/auto pk batch
                }
            }
        }

        const denom: usize = @max(table.columns.len, 1);
        const chunk_rows: usize = @max(@as(usize, 1), max_params / denom);
        var i: usize = 0;
        while (i < list.len) {
            const end = @min(i + chunk_rows, list.len);
            try s.insertChunk(T, list[i..end], all_auto and table.pk() != null);
            i = end;
        }
    }

    fn insertChunk(s: *Session, comptime T: type, models: []T, returning: bool) Error!void {
        const table = comptime schema.tableOf(T);
        for (models) |*m| try s.autoStamp(T, m, true);

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
                    params.append(arena, try value.toParam(getField(T, m, col.field_name), arena)) catch return error.OutOfMemory;
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

        if (returning) {
            const pkc = comptime table.pk().?;
            const FType = FieldOf(T, pkc.field_name);
            for (models, 0..) |*m, r| {
                @field(m, pkc.field_name) = try value.decodeCell(
                    FType,
                    res.rows[r][0],
                    res.columns[0].type_oid,
                    s.gpa,
                );
            }
        }
    }

    /// Updates every column of the model (except the primary key) by primary
    /// key. `updated_at` is refreshed. Returns affected rows (0 or 1).
    pub fn update(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zorm: update expects a mutable pointer to a model, e.g. db.update(&user)");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key; declare one via `pub const zorm = .{ .primary_key = ... }`");
        const pkc = table.columns[table.pk_index.?];
        if (isZeroPk(T, m, pkc.field_name)) return error.NullValue;

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
                params.append(arena, try value.toParam(getField(T, m, col.field_name), arena)) catch return error.OutOfMemory;
                first = false;
                np += 1;
            }
        }
        w.print(" WHERE {s} = ${d}", .{ try qb_mod.quoteIdent(arena, pkc.name), np + 1 }) catch return error.OutOfMemory;
        params.append(arena, try value.toParam(getField(T, m, pkc.field_name), arena)) catch return error.OutOfMemory;

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        return res.affected;
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
        if (isZeroPk(T, m, pkc.field_name)) {
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
        if (isZeroPk(T, m, pkc.field_name)) return error.NullValue;

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("DELETE FROM {s} WHERE {s} = $1", .{
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, pkc.name),
        }) catch return error.OutOfMemory;
        var params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(getField(T, m, pkc.field_name), arena);

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        return res.affected;
    }

    /// `DELETE FROM table WHERE (frag)`, returns affected rows.
    pub fn deleteWhere(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const table = comptime schema.tableOf(T);

        var b = SqlBuf.init(arena);
        const w = b.w();
        w.print("DELETE FROM {s} WHERE (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        qb_mod.writeRenumbered(w, frag, 0) catch return error.OutOfMemory;
        w.writeByte(')') catch return error.OutOfMemory;

        const params = try value.argsToParams(args, arena);
        var res = try s.runExec(b.slice(), params);
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

        const cond_params = try value.argsToParams(args, arena);
        params.appendSlice(arena, cond_params) catch return error.OutOfMemory;

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        return res.affected;
    }

    /// Fetches one model by primary key, or null.
    /// Returned strings are allocated with the session's gpa; release them
    /// with `zorm.free(T, value, gpa)` or decode into an arena of your own.
    pub fn find(s: *Session, comptime T: type, pk: anytype) Error!?T {
        const table = comptime schema.tableOf(T);
        if (table.pk_index == null) @compileError("zorm: model has no primary key");
        const pkc = table.columns[table.pk_index.?];

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("SELECT * FROM {s} WHERE {s} = $1 LIMIT 1", .{
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, pkc.name),
        }) catch return error.OutOfMemory;
        const params = try arena.alloc(pq.Param, 1);
        params[0] = try value.toParam(pk, arena);

        var res = try s.runExec(b.slice(), params);
        defer res.deinit();
        if (res.rows.len == 0) return null;
        return try value.scanRow(T, table, &res, res.rows[0], s.gpa);
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
            inline for (table.columns) |col| {
                var found = false;
                for (existing.items) |name| {
                    if (std.mem.eql(u8, name, col.name)) found = true;
                }
                if (!found) {
                    var b = SqlBuf.init(arena);
                    b.w().print("ALTER TABLE {s} ADD COLUMN IF NOT EXISTS {s} {s}", .{
                        try qb_mod.quoteIdent(arena, table.name),
                        try qb_mod.quoteIdent(arena, col.name),
                        col.ddl_type,
                    }) catch return error.OutOfMemory;
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
                const FType = FieldOf(T, col.field_name);
                switch (FType) {
                    Time => {
                        if (@field(m, col.field_name).micros == 0) @field(m, col.field_name) = now;
                    },
                    ?Time => {
                        if (@field(m, col.field_name) == null) @field(m, col.field_name) = now;
                    },
                    i64 => {
                        if (@field(m, col.field_name) == 0) @field(m, col.field_name) = now.micros;
                    },
                    ?i64 => {
                        if (@field(m, col.field_name) == null) @field(m, col.field_name) = now.micros;
                    },
                    else => {},
                }
            }
        }
    }

    fn getField(comptime T: type, m: anytype, comptime name: []const u8) FieldOf(T, name) {
        return @field(m, name);
    }

    fn FieldOf(comptime T: type, comptime name: []const u8) type {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, name)) return f.type;
        }
        @compileError("zorm: model " ++ @typeName(T) ++ " has no field " ++ name);
    }

    fn isZeroPk(comptime T: type, m: anytype, comptime name: []const u8) bool {
        _ = T;
        const v = @field(m, name);
        return switch (@typeInfo(@TypeOf(v))) {
            .optional => v == null,
            .int => v == 0,
            .pointer => v.len == 0,
            else => false,
        };
    }
};

/// A pinned-connection transaction.
pub const Tx = struct {
    sess: *Session,
    /// True when the Tx owns its (heap) session — `Db.begin`.
    owns_session: bool = false,
    finished: bool = false,

    fn finish(t: *Tx) void {
        if (t.owns_session) t.sess.gpa.destroy(t.sess);
    }

    pub fn commit(t: *Tx) Error!void {
        if (t.finished) return error.ConnectionClosed;
        t.finished = true;
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
    pub fn updateWhere(t: *Tx, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        return t.sess.updateWhere(T, sets, frag, args);
    }
    pub fn find(t: *Tx, comptime T: type, pk: anytype) Error!?T {
        return t.sess.find(T, pk);
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
    /// Optional SQL logger (debug aid).
    logger: ?*const fn (sql: []const u8, params: []const pq.Param) void = null,

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

    /// Parses `dsn` (URL or keyword form) and connects.
    pub fn connectDsn(gpa: std.mem.Allocator, io: std.Io, dsn: []const u8, max_connections: usize) Error!*Db {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const cfg = try pq.parseDsn(arena_state.allocator(), dsn);
        return connect(gpa, io, cfg, max_connections);
    }

    pub fn deinit(d: *Db) void {
        d.pool.deinit();
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
    pub fn updateWhere(d: *Db, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        var s = d.session();
        return s.updateWhere(T, sets, frag, args);
    }
    pub fn find(d: *Db, comptime T: type, pk: anytype) Error!?T {
        var s = d.session();
        return s.find(T, pk);
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
    /// server error observed through this handle.
    pub fn lastError(d: *Db) ?pq.PgError {
        return d.pool.last_error;
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
