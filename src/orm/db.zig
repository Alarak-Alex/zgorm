//! Session, transactions, CRUD, migrations and the pooled `Db` entry point.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const pool_mod = @import("pool.zig");
const qb_mod = @import("qb.zig");
const schema = @import("schema.zig");
const value = @import("value.zig");
const time_mod = @import("time.zig");
pub const logger_mod = @import("logger.zig");
const observability = @import("observability.zig");
const plugins_mod = @import("plugins.zig");

const Time = time_mod.Time;
pub const Error = pq.Error;
pub const Query = qb_mod.Query;

/// PostgreSQL ON CONFLICT policy. An empty `update` list means DO NOTHING;
/// otherwise each whitelisted column is assigned from `EXCLUDED`.
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

fn retryDelay(d: *Db, options: RetryOptions, failure_index: u8) void {
    if (options.base_delay_ms == 0) return;
    const shift: u6 = @intCast(@min(failure_index, 63));
    const exponential = options.base_delay_ms *| (@as(u64, 1) << shift);
    const cap = @min(exponential, options.max_delay_ms);
    var random: u64 = undefined;
    d.io.random(std.mem.asBytes(&random));
    const floor = cap / 2;
    const delay_ms = floor + random % (cap - floor + 1);
    d.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
}
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
    return struct {
        sess: Session,
        parent: *M,

        pub fn count(a: *@This()) Error!i64 {
            if (assoc.kind == .many_to_many) {
                var arena_state = std.heap.ArenaAllocator.init(a.sess.gpa);
                defer arena_state.deinit();
                const sql = std.fmt.allocPrint(arena_state.allocator(), "SELECT count(*) FROM {s} WHERE {s} = $1", .{
                    try qb_mod.quoteIdent(arena_state.allocator(), assoc.join_table),
                    try qb_mod.quoteIdent(arena_state.allocator(), assoc.join_foreign_key),
                }) catch return error.OutOfMemory;
                var res = try a.sess.exec(sql, .{value.getColumn(a.parent, associationColumn(M, assoc.primary_key))});
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
            var arena_state = std.heap.ArenaAllocator.init(a.sess.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const sql = std.fmt.allocPrint(arena, "INSERT INTO {s} ({s}, {s}) VALUES ($1, $2) ON CONFLICT DO NOTHING", .{
                try qb_mod.quoteIdent(arena, assoc.join_table),
                try qb_mod.quoteIdent(arena, assoc.join_foreign_key),
                try qb_mod.quoteIdent(arena, assoc.join_association_key),
            }) catch return error.OutOfMemory;
            var res = try a.sess.exec(sql, .{
                @field(a.parent, assoc.primary_key),
                @field(child, assoc.association_key),
            });
            res.deinit();
        }

        pub fn clear(a: *@This()) Error!void {
            var arena_state = std.heap.ArenaAllocator.init(a.sess.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            if (assoc.kind == .many_to_many) {
                const sql = std.fmt.allocPrint(arena, "DELETE FROM {s} WHERE {s} = $1", .{
                    try qb_mod.quoteIdent(arena, assoc.join_table),
                    try qb_mod.quoteIdent(arena, assoc.join_foreign_key),
                }) catch return error.OutOfMemory;
                var res = try a.sess.exec(sql, .{@field(a.parent, assoc.primary_key)});
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
            var arena_state = std.heap.ArenaAllocator.init(a.sess.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const sql = std.fmt.allocPrint(arena, "DELETE FROM {s} WHERE {s} = $1 AND {s} = $2", .{
                try qb_mod.quoteIdent(arena, assoc.join_table),
                try qb_mod.quoteIdent(arena, assoc.join_foreign_key),
                try qb_mod.quoteIdent(arena, assoc.join_association_key),
            }) catch return error.OutOfMemory;
            var res = try a.sess.exec(sql, .{
                @field(a.parent, assoc.primary_key),
                @field(child, assoc.association_key),
            });
            res.deinit();
        }

        pub fn replace(a: *@This(), children: []Child) Error!void {
            try a.clear();
            for (children) |*child| try a.append(child);
        }
    };
}

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
        .text, .enum_, .bytes, .custom => "''",
        .time => "now()",
        .jsonb => "'{}'::jsonb",
        .int_array, .uint_array, .float_array, .bool_array, .text_array => "'{}'",
    };
}

fn containsName(comptime names: []const []const u8, comptime needle: []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn FindPredicates(comptime T: type, comptime index: usize) type {
    const table = schema.tableOf(T);
    if (index == table.pk_indexes.len) return struct {
        pub const value = [0]u8{};
    };
    const column = table.columns[table.pk_indexes[index]];
    const separator = if (index == 0) "" else " AND ";
    return struct {
        pub const value = separator ++
            qb_mod.QuotedIdent(column.name).value ++
            " = $" ++
            std.fmt.comptimePrint("{d}", .{index + 1}) ++
            FindPredicates(T, index + 1).value;
    };
}

fn FindSoftDelete(comptime T: type, comptime unscoped: bool) type {
    const table = schema.tableOf(T);
    if (!table.softDeletable() or unscoped) return struct {
        pub const value = [0]u8{};
    };
    const column = table.columns[table.deleted_at_index.?];
    return struct {
        pub const value = " AND " ++ qb_mod.QuotedIdent(column.name).value ++ " IS NULL";
    };
}

fn FindSql(comptime T: type, comptime unscoped: bool) type {
    const table = schema.tableOf(T);
    return struct {
        pub const value = "SELECT * FROM " ++
            qb_mod.QuotedIdent(table.name).value ++
            " WHERE " ++
            FindPredicates(T, 0).value ++
            FindSoftDelete(T, unscoped).value ++
            " LIMIT 1";
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
    /// Overall transaction deadline; copied into nested savepoints.
    transaction_deadline: ?std.Io.Timestamp = null,
    observer: observability.Observer = .{},
    plugins: plugins_mod.Registry = .{},

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

    fn transactionTimeout(s: *Session, requested_ms: u64) Error!u64 {
        const deadline = s.transaction_deadline orelse return requested_ms;
        const remaining_ns = std.Io.Clock.awake.now(s.io).durationTo(deadline).nanoseconds;
        if (remaining_ns <= 0) return error.TransactionTimeout;
        const remaining_ms: u64 = @intCast(@max(1, @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        return if (requested_ms == 0) remaining_ms else @min(requested_ms, remaining_ms);
    }

    fn mapDeadlineError(s: *Session, err: Error) Error {
        if (err != error.QueryTimeout or s.transaction_deadline == null) return err;
        const remaining = std.Io.Clock.awake.now(s.io).durationTo(s.transaction_deadline.?).nanoseconds;
        return if (remaining <= 0) error.TransactionTimeout else err;
    }
    fn instrumentationEnabled(s: *const Session) bool {
        return s.logger.level != .silent or
            s.observer.on_query != null or
            s.observer.on_span != null or
            s.observer.metrics != null or
            s.observer.slow_queries != null or
            s.plugins.len != 0;
    }

    fn runExecFast(s: *Session, sql: []const u8, params: []const pq.Param, timeout_ms: u64) Error!pq.Result {
        const conn = try s.acquire();
        const effective = s.transactionTimeout(timeout_ms) catch |err| {
            s.releaseConn(conn);
            return err;
        };
        const res = conn.execParamsTimeout(sql, params, effective) catch |err| {
            s.captureError(conn);
            const mapped = s.mapDeadlineError(err);
            s.releaseConn(conn);
            return mapped;
        };
        s.releaseConn(conn);
        return res;
    }

    fn execRawFast(s: *Session, sql: []const u8, timeout_ms: u64) Error!pq.Result {
        const conn = try s.acquire();
        const effective = s.transactionTimeout(timeout_ms) catch |err| {
            s.releaseConn(conn);
            return err;
        };
        const res = conn.execSimpleTimeout(sql, effective) catch |err| {
            s.captureError(conn);
            const mapped = s.mapDeadlineError(err);
            s.releaseConn(conn);
            return mapped;
        };
        s.releaseConn(conn);
        return res;
    }

    pub fn runExec(s: *Session, sql: []const u8, params: []const pq.Param) Error!pq.Result {
        return s.runExecTimeout(sql, params, 0);
    }

    pub fn runExecTimeout(s: *Session, sql: []const u8, params: []const pq.Param, timeout_ms: u64) Error!pq.Result {
        if (!s.instrumentationEnabled()) return s.runExecFast(sql, params, timeout_ms);
        if (!s.plugins.runBeforeQuery(sql) or !s.plugins.runBeforeCrud(sql)) return error.HookAborted;
        const started = std.Io.Clock.awake.now(s.io);
        const conn = s.acquire() catch |err| {
            const wait_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(s.io)).nanoseconds);
            s.reportQuery(sql, params, started, wait_ns, 0, 0, err, "");
            return err;
        };
        const acquired = std.Io.Clock.awake.now(s.io);
        const wait_ns: u128 = @intCast(started.durationTo(acquired).nanoseconds);
        const effective = s.transactionTimeout(timeout_ms) catch |err| {
            s.releaseConn(conn);
            s.reportQuery(sql, params, started, wait_ns, 0, 0, err, "");
            return err;
        };
        const res = conn.execParamsTimeout(sql, params, effective) catch |e| {
            var state_buf: [5]u8 = undefined;
            const sqlstate = if (conn.lastError()) |server_error| blk: {
                const len = @min(state_buf.len, server_error.code.len);
                @memcpy(state_buf[0..len], server_error.code[0..len]);
                break :blk state_buf[0..len];
            } else "";
            s.captureError(conn);
            const mapped = s.mapDeadlineError(e);
            s.releaseConn(conn);
            s.reportQuery(sql, params, started, wait_ns, 0, 0, mapped, sqlstate);
            return mapped;
        };
        s.releaseConn(conn);
        s.reportQuery(sql, params, started, wait_ns, res.affected, res.rows.len, null, "");
        return res;
    }
    /// Executes a typed query and decodes rows into models. With logging,
    /// observers, plugins, or deadlines enabled it retains the fully
    /// instrumented result path; otherwise cells are decoded directly from
    /// the PostgreSQL cursor.
    pub fn runModels(
        s: *Session,
        comptime T: type,
        sql: []const u8,
        params: []const pq.Param,
        timeout_ms: u64,
        out_gpa: std.mem.Allocator,
    ) Error![]T {
        const table = comptime schema.tableOf(T);
        if (s.instrumentationEnabled() or timeout_ms != 0 or s.transaction_deadline != null) {
            var res = try s.runExecTimeout(sql, params, timeout_ms);
            defer res.deinit();
            const models = out_gpa.alloc(T, res.rows.len) catch return error.OutOfMemory;
            var decoded: usize = 0;
            var column_map: [table.columns.len]?usize = undefined;
            value.buildColumnMap(table, res.columns, &column_map);
            errdefer {
                for (models[0..decoded]) |model| value.freeValue(T, model, out_gpa);
                out_gpa.free(models);
            }
            for (res.rows, 0..) |row, i| {
                models[i] = try value.scanCellsMapped(T, table, res.columns, row, &column_map, out_gpa);
                decoded = i + 1;
            }
            for (models) |*model| try callHook(T, "afterFind", model, s);
            return models;
        }

        const conn = try s.acquire();
        const rows = conn.queryParamsBinary(sql, params) catch |err| {
            s.captureError(conn);
            s.releaseConn(conn);
            return err;
        };
        var cursor_open = true;
        defer if (cursor_open) {
            rows.deinit();
            s.releaseConn(conn);
        };

        var column_map: [table.columns.len]?usize = undefined;
        value.buildColumnMap(table, rows.columns, &column_map);
        var models: std.ArrayList(T) = .empty;
        errdefer {
            for (models.items) |model| value.freeValue(T, model, out_gpa);
            models.deinit(out_gpa);
        }
        while (rows.next() catch |err| {
            s.captureError(conn);
            return err;
        }) |row| {
            const model = try value.scanCellsMapped(T, table, rows.columns, row, &column_map, out_gpa);
            models.append(out_gpa, model) catch {
                value.freeValue(T, model, out_gpa);
                return error.OutOfMemory;
            };
        }
        rows.deinit();
        s.releaseConn(conn);
        cursor_open = false;

        for (models.items) |*model| try callHook(T, "afterFind", model, s);
        return models.toOwnedSlice(out_gpa) catch return error.OutOfMemory;
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

    /// Executes a parameterized query with a per-operation deadline.
    pub fn execTimeout(s: *Session, sql: []const u8, args: anytype, timeout_ms: u64) Error!pq.Result {
        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const params = try value.argsToParams(args, arena_state.allocator());
        return s.runExecTimeout(sql, params, timeout_ms);
    }

    /// Executes raw SQL without parameters (simple query protocol; several
    /// statements allowed).
    pub fn execRaw(s: *Session, sql: []const u8) Error!pq.Result {
        return s.execRawTimeout(sql, 0);
    }

    pub fn execRawTimeout(s: *Session, sql: []const u8, timeout_ms: u64) Error!pq.Result {
        if (!s.instrumentationEnabled()) return s.execRawFast(sql, timeout_ms);
        if (!s.plugins.runBeforeQuery(sql) or !s.plugins.runBeforeCrud(sql)) return error.HookAborted;
        const started = std.Io.Clock.awake.now(s.io);
        const conn = s.acquire() catch |err| {
            const wait_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(s.io)).nanoseconds);
            s.reportQuery(sql, &.{}, started, wait_ns, 0, 0, err, "");
            return err;
        };
        const acquired = std.Io.Clock.awake.now(s.io);
        const wait_ns: u128 = @intCast(started.durationTo(acquired).nanoseconds);
        const effective = s.transactionTimeout(timeout_ms) catch |err| {
            s.releaseConn(conn);
            s.reportQuery(sql, &.{}, started, wait_ns, 0, 0, err, "");
            return err;
        };
        const res = conn.execSimpleTimeout(sql, effective) catch |e| {
            var state_buf: [5]u8 = undefined;
            const sqlstate = if (conn.lastError()) |server_error| blk: {
                const len = @min(state_buf.len, server_error.code.len);
                @memcpy(state_buf[0..len], server_error.code[0..len]);
                break :blk state_buf[0..len];
            } else "";
            s.captureError(conn);
            const mapped = s.mapDeadlineError(e);
            s.releaseConn(conn);
            s.reportQuery(sql, &.{}, started, wait_ns, 0, 0, mapped, sqlstate);
            return mapped;
        };
        s.releaseConn(conn);
        s.reportQuery(sql, &.{}, started, wait_ns, res.affected, res.rows.len, null, "");
        return res;
    }

    /// Reports one query to the text logger, structured observer, span sink,
    /// metrics collector, and slow-query aggregator.
    fn reportQuery(
        s: *Session,
        sql: []const u8,
        params: []const pq.Param,
        started: std.Io.Timestamp,
        pool_wait_ns: u128,
        affected_rows: i64,
        returned_rows: usize,
        err: ?Error,
        sqlstate: []const u8,
    ) void {
        const elapsed_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(s.io)).nanoseconds);
        const level: logger_mod.LogLevel = if (err != null)
            .err
        else if (s.logger.slow_threshold_ms > 0 and
            elapsed_ns / std.time.ns_per_ms >= s.logger.slow_threshold_ms)
            .warn
        else
            .info;
        if (s.logger.enabled(level)) {
            var buf: [4096]u8 = undefined;
            const msg = logger_mod.formatQuery(&s.logger, &buf, sql, params, elapsed_ns, affected_rows, err);
            s.logger.log(level, msg);
        }
        const needs_observer = s.observer.on_query != null or
            s.observer.on_span != null or
            s.observer.metrics != null or
            s.observer.slow_queries != null or
            s.plugins.len != 0;
        if (!needs_observer) return;
        const pool = s.pool.stats();
        const event = observability.QueryEvent{
            .sql = sql,
            .fingerprint = observability.fingerprint(sql),
            .duration_ns = elapsed_ns,
            .pool_wait_ns = pool_wait_ns,
            .affected_rows = affected_rows,
            .returned_rows = returned_rows,
            .sqlstate = sqlstate,
            .error_class = observability.classify(err),
            .prepared_hit_rate = pool.preparedHitRate(),
            .pool = pool,
        };
        s.observer.emit(event);
        s.plugins.runAfterQuery(event);
        if (err == null) s.plugins.runAfterCrud(sql, affected_rows);
    }

    // ---------------------------------------------------------------- CRUD

    /// Inserts one model. Auto-increment primary keys are filled back in.
    /// `created_at` / `updated_at` columns are auto-stamped when empty.
    pub fn insert(s: *Session, m: anytype) Error!void {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zgorm: insert expects a mutable pointer to a model, e.g. db.insert(&user)");
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

        try s.saveAssociations(T, m);
        try callHook(T, "afterCreate", m, s);
        try callHook(T, "afterSave", m, s);
    }

    /// Inserts one model and decodes arbitrary RETURNING columns into `R`.
    /// Returned heap fields are owned by `s.gpa`.
    pub fn insertReturning(
        s: *Session,
        m: anytype,
        comptime R: type,
        comptime fields: []const []const u8,
    ) Error!R {
        if (fields.len == 0) @compileError("zgorm: insertReturning requires at least one field");
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zgorm: insertReturning expects a mutable model pointer");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        inline for (fields) |name| {
            if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown RETURNING column " ++ name);
        }

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
        const return_pk = comptime pk_col != null and pk_col.?.is_auto and !containsName(fields, pk_col.?.name);

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
        var np: usize = 0;
        inline for (table.columns) |col| {
            if (!(col.is_auto and isZeroValue(value.getColumn(m, col)))) {
                if (np > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                np += 1;
            }
        }
        w.writeAll(") RETURNING ") catch return error.OutOfMemory;
        inline for (fields, 0..) |name, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(try qb_mod.quoteIdent(arena, name)) catch return error.OutOfMemory;
        }
        if (return_pk) {
            w.print(", {s}", .{try qb_mod.quoteIdent(arena, pk_col.?.name)}) catch return error.OutOfMemory;
        }

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        if (res.rows.len != 1) return error.ProtocolViolation;
        if (comptime pk_col != null and pk_col.?.is_auto) {
            if (isZeroValue(value.getColumn(m, pk_col.?))) {
                const ci = res.colIndex(pk_col.?.name) orelse return error.ProtocolViolation;
                value.setColumn(m, pk_col.?, try value.decodeCell(
                    value.columnFieldType(T, pk_col.?),
                    res.rows[0][ci],
                    res.columns[ci].type_oid,
                    res.columns[ci].format,
                    s.gpa,
                ));
            }
        }
        const returned = try value.scanRow(R, comptime schema.tableOf(R), &res, res.rows[0], s.gpa);
        try callHook(T, "afterCreate", m, s);
        try callHook(T, "afterSave", m, s);
        return returned;
    }

    /// Inserts a mutable slice atomically and returns one projection per row.
    pub fn insertBatchReturning(
        s: *Session,
        models: anytype,
        comptime R: type,
        comptime fields: []const []const u8,
    ) Error![]R {
        const P = @typeInfo(@TypeOf(models));
        const Items: type = blk: {
            if (P == .pointer and P.pointer.size == .slice and !P.pointer.is_const) break :blk @TypeOf(models);
            if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.is_const)
                break :blk []@typeInfo(P.pointer.child).array.child;
            @compileError("zgorm: insertBatchReturning expects a mutable slice");
        };
        const list: Items = models;
        const out = s.gpa.alloc(R, list.len) catch return error.OutOfMemory;
        var initialized: usize = 0;
        errdefer {
            for (out[0..initialized]) |item| value.freeValue(R, item, s.gpa);
            s.gpa.free(out);
        }
        if (s.pinned != null) {
            for (list, 0..) |*model, i| {
                out[i] = try s.insertReturning(model, R, fields);
                initialized += 1;
            }
            return out;
        }
        var tx = try s.begin();
        errdefer tx.rollback();
        for (list, 0..) |*model, i| {
            out[i] = try tx.insertReturning(model, R, fields);
            initialized += 1;
        }
        try tx.commit();
        return out;
    }

    /// Inserts a model with a compile-time PostgreSQL ON CONFLICT policy.
    /// Returns false only when DO NOTHING skipped a conflicting row.
    pub fn upsert(s: *Session, m: anytype, comptime conflict: OnConflict) Error!bool {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zgorm: upsert expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        inline for (conflict.columns) |name| {
            if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown conflict column " ++ name);
        }
        inline for (conflict.update) |name| {
            if (comptime !table.hasColumn(name)) @compileError("zgorm: unknown upsert update column " ++ name);
        }
        if (conflict.update.len > 0 and conflict.columns.len == 0 and table.pk_indexes.len == 0)
            @compileError("zgorm: ON CONFLICT DO UPDATE requires conflict columns or a primary key");

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
        var np: usize = 0;
        inline for (table.columns) |col| {
            if (!(col.is_auto and isZeroValue(value.getColumn(m, col)))) {
                if (np > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("${d}", .{np + 1}) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                np += 1;
            }
        }
        w.writeAll(") ON CONFLICT") catch return error.OutOfMemory;
        if (conflict.columns.len > 0) {
            w.writeAll(" (") catch return error.OutOfMemory;
            inline for (conflict.columns, 0..) |name, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(try qb_mod.quoteIdent(arena, name)) catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
        }
        if (conflict.columns.len == 0 and conflict.update.len > 0) {
            w.writeAll(" (") catch return error.OutOfMemory;
            inline for (table.pk_indexes, 0..) |pk_index, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(try qb_mod.quoteIdent(arena, table.columns[pk_index].name)) catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
        }
        if (conflict.update.len == 0) {
            w.writeAll(" DO NOTHING") catch return error.OutOfMemory;
        } else {
            w.writeAll(" DO UPDATE SET ") catch return error.OutOfMemory;
            inline for (conflict.update, 0..) |name, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                const quoted = try qb_mod.quoteIdent(arena, name);
                w.print("{s} = EXCLUDED.{s}", .{ quoted, quoted }) catch return error.OutOfMemory;
            }
        }

        var returning = false;
        if (comptime (pk_col != null and pk_col.?.is_auto)) {
            if (isZeroValue(value.getColumn(m, pk_col.?))) {
                returning = true;
                w.print(" RETURNING {s}", .{try qb_mod.quoteIdent(arena, pk_col.?.name)}) catch return error.OutOfMemory;
            }
        }
        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        const affected = res.affected > 0;
        if (affected and returning and res.rows.len > 0) {
            const pkc = pk_col.?;
            value.setColumn(m, pkc, try value.decodeCell(
                value.columnFieldType(T, pkc),
                res.rows[0][0],
                res.columns[0].type_oid,
                res.columns[0].format,
                s.gpa,
            ));
        }
        if (affected) {
            try callHook(T, "afterCreate", m, s);
            try callHook(T, "afterSave", m, s);
        }
        return affected;
    }

    /// Applies the same upsert policy to a mutable slice atomically.
    pub fn upsertBatch(s: *Session, models: anytype, comptime conflict: OnConflict) Error!usize {
        const P = @typeInfo(@TypeOf(models));
        const Items: type = blk: {
            if (P == .pointer and P.pointer.size == .slice and !P.pointer.is_const) break :blk @TypeOf(models);
            if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.is_const)
                break :blk []@typeInfo(P.pointer.child).array.child;
            @compileError("zgorm: upsertBatch expects a mutable slice");
        };
        const list: Items = models;
        if (s.pinned != null) {
            var affected: usize = 0;
            for (list) |*model| affected += @intFromBool(try s.upsert(model, conflict));
            return affected;
        }
        var tx = try s.begin();
        errdefer tx.rollback();
        var affected: usize = 0;
        for (list) |*model| affected += @intFromBool(try tx.upsert(model, conflict));
        try tx.commit();
        return affected;
    }

    /// Inserts many models in chunked multi-row statements.
    pub fn insertBatch(s: *Session, models: anytype) Error!void {
        const P = @typeInfo(@TypeOf(models));
        const Items: type = blk: {
            if (P == .pointer and P.pointer.size == .slice) break :blk @TypeOf(models);
            if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array)
                break :blk []@typeInfo(P.pointer.child).array.child;
            @compileError("zgorm: insertBatch expects a slice, e.g. db.insertBatch(&users)");
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

    /// Updates a mutable model slice with optimistic-lock all-or-nothing
    /// semantics. Outside an existing transaction, any conflict rolls back
    /// every earlier update in the batch.
    pub fn updateBatch(s: *Session, models: anytype) Error!usize {
        const P = @typeInfo(@TypeOf(models));
        const Items: type = blk: {
            if (P == .pointer and P.pointer.size == .slice and !P.pointer.is_const) break :blk @TypeOf(models);
            if (P == .pointer and P.pointer.size == .one and @typeInfo(P.pointer.child) == .array and !P.pointer.is_const)
                break :blk []@typeInfo(P.pointer.child).array.child;
            @compileError("zgorm: updateBatch expects a mutable slice, e.g. db.updateBatch(&users)");
        };
        const list: Items = models;
        if (s.pinned != null) {
            for (list) |*model| _ = try s.update(model);
            return list.len;
        }
        var tx = try s.begin();
        errdefer tx.rollback();
        for (list) |*model| _ = try tx.update(model);
        try tx.commit();
        return list.len;
    }

    fn updateImpl(s: *Session, m: anytype, comptime unscoped: bool) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one or MP.pointer.is_const)
            @compileError("zgorm: update expects a mutable pointer to a model, e.g. db.update(&user)");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_indexes.len == 0)
            @compileError("zgorm: model has no primary key; declare one via `primary_key` or `primary_keys`");
        inline for (table.pk_indexes) |pk_index| {
            if (isZeroValue(value.getColumn(m, table.columns[pk_index]))) return error.NullValue;
        }
        if (comptime table.version()) |version_col| {
            try ensureVersionCanIncrement(T, m, version_col);
        }

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
        inline for (table.columns, 0..) |col, col_index| {
            if (!col.is_pk and (table.version_index == null or table.version_index.? != col_index)) {
                if (!first) w.writeAll(", ") catch return error.OutOfMemory;
                w.print("{s} = ${d}", .{ try qb_mod.quoteIdent(arena, col.name), np + 1 }) catch return error.OutOfMemory;
                params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
                first = false;
                np += 1;
            }
        }
        if (comptime table.version()) |version_col| {
            if (!first) w.writeAll(", ") catch return error.OutOfMemory;
            const name = try qb_mod.quoteIdent(arena, version_col.name);
            w.print("{s} = {s} + 1", .{ name, name }) catch return error.OutOfMemory;
        }
        w.writeAll(" WHERE ") catch return error.OutOfMemory;
        inline for (table.pk_indexes, 0..) |pk_index, key_index| {
            if (key_index > 0) w.writeAll(" AND ") catch return error.OutOfMemory;
            const pk_col = table.columns[pk_index];
            w.print("{s} = ${d}", .{ try qb_mod.quoteIdent(arena, pk_col.name), np + key_index + 1 }) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(value.getColumn(m, pk_col), arena)) catch return error.OutOfMemory;
        }
        if (comptime table.softDeletable() and !unscoped) {
            const del_col = table.columns[table.deleted_at_index.?];
            w.print(" AND {s} IS NULL", .{try qb_mod.quoteIdent(arena, del_col.name)}) catch return error.OutOfMemory;
        }
        if (comptime table.version()) |version_col| {
            w.print(" AND {s} = ${d}", .{ try qb_mod.quoteIdent(arena, version_col.name), np + table.pk_indexes.len + 1 }) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(value.getColumn(m, version_col), arena)) catch return error.OutOfMemory;
        }

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        const affected = res.affected;
        if (comptime table.version()) |version_col| {
            if (affected == 0) return error.OptimisticLockConflict;
            incrementVersion(T, m, version_col);
        }

        try s.saveAssociations(T, m);
        try callHook(T, "afterUpdate", m, s);
        try callHook(T, "afterSave", m, s);
        return affected;
    }

    /// Insert when the primary key is empty, update otherwise.
    pub fn save(s: *Session, m: anytype) Error!void {
        const T = @typeInfo(@TypeOf(m)).pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.pk_indexes.len == 0) {
            try s.insert(m);
            return;
        }
        inline for (table.pk_indexes) |pk_index| {
            if (isZeroValue(value.getColumn(m, table.columns[pk_index]))) {
                try s.insert(m);
                return;
            }
        }
        _ = try s.update(m);
    }

    /// Deletes the model by primary key. Returns affected rows.
    pub fn delete(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zgorm: delete expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        try validateModelPrimaryKey(T, m, table);

        try s.cascadeAssociations(T, m);
        try callHook(T, "beforeDelete", m, s);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        const w = b.w();
        const soft = comptime table.softDeletable();
        var params: std.ArrayList(pq.Param) = .empty;

        if (soft) {
            const del_col = table.columns[table.deleted_at_index.?];
            w.print("UPDATE {s} SET {s} = {s}", .{
                try qb_mod.quoteIdent(arena, table.name),
                try qb_mod.quoteIdent(arena, del_col.name),
                qb_mod.softDeleteStampSql(value.columnFieldType(T, del_col)),
            }) catch return error.OutOfMemory;
        } else {
            w.print("DELETE FROM {s}", .{
                try qb_mod.quoteIdent(arena, table.name),
            }) catch return error.OutOfMemory;
        }
        try appendModelPrimaryKeyWhere(T, m, table, w, arena, &params);

        var res = try s.runExec(b.slice(), params.items);
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
            @compileError("zgorm: deleteHard expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        try validateModelPrimaryKey(T, m, table);

        try s.cascadeAssociations(T, m);
        try callHook(T, "beforeDelete", m, s);

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var b = SqlBuf.init(arena);
        b.w().print("DELETE FROM {s}", .{
            try qb_mod.quoteIdent(arena, table.name),
        }) catch return error.OutOfMemory;
        var params: std.ArrayList(pq.Param) = .empty;
        try appendModelPrimaryKeyWhere(T, m, table, b.w(), arena, &params);

        var res = try s.runExec(b.slice(), params.items);
        defer res.deinit();
        const affected = res.affected;

        try callHook(T, "afterDelete", m, s);
        return affected;
    }

    /// Undoes a soft delete by primary key (sets `deleted_at` back to NULL).
    pub fn restore(s: *Session, m: anytype) Error!i64 {
        const MP = @typeInfo(@TypeOf(m));
        if (MP != .pointer or MP.pointer.size != .one)
            @compileError("zgorm: restore expects a pointer to a model");
        const T = MP.pointer.child;
        const table = comptime schema.tableOf(T);
        if (table.deleted_at_index == null) @compileError("zgorm: restore requires a deleted_at column");
        if (table.pk_index == null) @compileError("zgorm: model has no primary key");
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
            if (col_name == null) @compileError("zgorm: updateWhere set field '" ++ f.name ++ "' is not a column of " ++ @typeName(T));
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
    /// with `zgorm.free(T, value, gpa)` or decode into an arena of your own.
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
        if (table.pk_indexes.len == 0) @compileError("zgorm: model has no primary key");

        var arena_state = std.heap.ArenaAllocator.init(s.gpa);

        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const params = try value.argsToParams(pk, arena);
        if (params.len != table.pk_indexes.len) return error.InvalidQuery;

        const sql = FindSql(T, unscoped).value[0..];

        const models = try s.runModels(T, sql, params, 0, s.gpa);
        defer s.gpa.free(models);
        if (models.len == 0) return null;
        return models[0];
    }
    pub fn association(s: *Session, parent: anytype, comptime field_name: []const u8) Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
        const M = @typeInfo(@TypeOf(parent)).pointer.child;
        return .{ .sess = s.*, .parent = @as(*M, parent) };
    }

    // --------------------------------------------------------------- query

    /// Starts a GORM-style query builder for `T`. The builder (plus a heap
    /// copy of this session) is allocated on the heap and released by the
    /// terminal operation, so chains like `z.query(User, db).where(..).all()`
    /// need no manual cleanup.
    pub fn query(s: *Session, comptime T: type) *Query(T) {
        const gpa = s.gpa;
        const sess_copy = gpa.create(Session) catch @panic("zgorm: out of memory");
        sess_copy.* = s.*;
        const q = gpa.create(Query(T)) catch @panic("zgorm: out of memory");
        q.* = .{
            .sess = sess_copy,
            .owns_session = true,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        return q;
    }

    // -------------------------------------------------------- transactions

    /// Starts a transaction, pinning one pooled connection.
    pub fn begin(s: *Session) Error!Tx {
        return s.beginTimeout(0);
    }

    /// Starts a transaction with one overall client-side deadline. Each
    /// statement and commit observes the remaining time.
    pub fn beginTimeout(s: *Session, timeout_ms: u64) Error!Tx {
        if (s.pinned != null) return error.ProtocolViolation; // nested tx unsupported
        const conn = try s.pool.acquire();
        var res = conn.execSimple("BEGIN") catch |e| {
            s.captureError(conn);
            s.pool.release(conn);
            return e;
        };
        res.deinit();
        s.pinned = conn;
        s.transaction_deadline = if (timeout_ms == 0)
            null
        else
            std.Io.Clock.awake.now(s.io).addDuration(.fromMilliseconds(@intCast(timeout_ms)));
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
                    if (col.is_pk and table.pk_indexes.len == 1) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                }
            }
            if (table.pk_indexes.len > 1) {
                w.writeAll(", PRIMARY KEY (") catch return error.OutOfMemory;
                inline for (table.pk_indexes, 0..) |pk_index, i| {
                    if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                    w.writeAll(try qb_mod.quoteIdent(arena, table.columns[pk_index].name)) catch return error.OutOfMemory;
                }
                w.writeByte(')') catch return error.OutOfMemory;
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
                        if (col.is_pk and table.pk_indexes.len == 1 and !table_has_pk) {
                            w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                        }
                    }
                    var res = try s.execRaw(b.slice());
                    res.deinit();
                }
            }
            if (table.pk_indexes.len > 1 and !table_has_pk) {
                var b = SqlBuf.init(arena);
                const w = b.w();
                w.print("ALTER TABLE {s} ADD PRIMARY KEY (", .{
                    try qb_mod.quoteIdent(arena, table.name),
                }) catch return error.OutOfMemory;
                inline for (table.pk_indexes, 0..) |pk_index, i| {
                    if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                    w.writeAll(try qb_mod.quoteIdent(arena, table.columns[pk_index].name)) catch return error.OutOfMemory;
                }
                w.writeByte(')') catch return error.OutOfMemory;
                var res = try s.execRaw(b.slice());
                res.deinit();
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
    fn saveAssociations(s: *Session, comptime T: type, model: *T) Error!void {
        const table = comptime schema.tableOf(T);
        inline for (table.assocs) |assoc| {
            if (assoc.kind == .belongs_to) continue;
            var manager = s.association(model, assoc.field_name);
            switch (assoc.kind) {
                .has_one => {
                    if (@field(model, assoc.field_name)) |*child| try manager.append(child);
                },
                .has_many, .many_to_many => {
                    for (@field(model, assoc.field_name)) |*child| try manager.append(child);
                },
                .belongs_to => unreachable,
            }
        }
    }

    fn cascadeAssociations(s: *Session, comptime T: type, model: *T) Error!void {
        inline for (comptime schema.tableOf(T).assocs) |assoc| {
            if (assoc.cascade_delete) {
                var manager = s.association(model, assoc.field_name);
                try manager.clear();
            }
        }
    }

    fn validateModelPrimaryKey(comptime T: type, m: *T, comptime table: schema.Table) Error!void {
        if (table.pk_indexes.len == 0) @compileError("zgorm: model has no primary key");
        inline for (table.pk_indexes) |pk_index| {
            if (isZeroValue(value.getColumn(m, table.columns[pk_index]))) return error.NullValue;
        }
    }

    fn appendModelPrimaryKeyWhere(
        comptime T: type,
        m: *T,
        comptime table: schema.Table,
        w: *std.Io.Writer,
        arena: std.mem.Allocator,
        params: *std.ArrayList(pq.Param),
    ) Error!void {
        w.writeAll(" WHERE ") catch return error.OutOfMemory;
        inline for (table.pk_indexes, 0..) |pk_index, i| {
            if (i > 0) w.writeAll(" AND ") catch return error.OutOfMemory;
            const col = table.columns[pk_index];
            w.print("{s} = ${d}", .{ try qb_mod.quoteIdent(arena, col.name), params.items.len + 1 }) catch return error.OutOfMemory;
            params.append(arena, try value.toParam(value.getColumn(m, col), arena)) catch return error.OutOfMemory;
        }
    }

    fn ensureVersionCanIncrement(comptime T: type, m: *T, comptime col: schema.Column) Error!void {
        const F = value.columnFieldType(T, col);
        const current = value.getColumn(m, col);
        if (current == std.math.maxInt(F)) return error.NumericValueOutOfRange;
    }

    fn incrementVersion(comptime T: type, m: *T, comptime col: schema.Column) void {
        const current = value.getColumn(m, col);
        value.setColumn(m, col, current + 1);
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
        const name = std.fmt.bufPrint(&sp.sp_name_buf, "zgorm_sp_{d}", .{t.sess.savepoint_depth}) catch
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
        _ = t.sess.transactionTimeout(0) catch |err| {
            t.rollback();
            return err;
        };
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
            t.sess.transaction_deadline = null;
            t.sess.pinned = null;
            t.sess.pool.release(conn);
            t.finish();
            return e;
        };
        t.sess.transaction_deadline = null;
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
        t.sess.transaction_deadline = null;
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
    pub fn insertReturning(t: *Tx, m: anytype, comptime R: type, comptime fields: []const []const u8) Error!R {
        return t.sess.insertReturning(m, R, fields);
    }
    pub fn insertBatchReturning(t: *Tx, models: anytype, comptime R: type, comptime fields: []const []const u8) Error![]R {
        return t.sess.insertBatchReturning(models, R, fields);
    }
    pub fn upsert(t: *Tx, m: anytype, comptime conflict: OnConflict) Error!bool {
        return t.sess.upsert(m, conflict);
    }
    pub fn upsertBatch(t: *Tx, models: anytype, comptime conflict: OnConflict) Error!usize {
        return t.sess.upsertBatch(models, conflict);
    }
    pub fn update(t: *Tx, m: anytype) Error!i64 {
        return t.sess.update(m);
    }
    pub fn updateBatch(t: *Tx, models: anytype) Error!usize {
        return t.sess.updateBatch(models);
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
    pub fn association(t: *Tx, parent: anytype, comptime field_name: []const u8) Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
        return t.sess.association(parent, field_name);
    }
    pub fn query(t: *Tx, comptime T: type) *Query(T) {
        const gpa = t.sess.gpa;
        const q = gpa.create(Query(T)) catch @panic("zgorm: out of memory");
        q.* = .{
            .sess = t.sess,
            .owns_session = false,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
        return q;
    }
    pub fn execTimeout(t: *Tx, sql: []const u8, args: anytype, timeout_ms: u64) Error!pq.Result {
        return t.sess.execTimeout(sql, args, timeout_ms);
    }
    pub fn exec(t: *Tx, sql: []const u8, args: anytype) Error!pq.Result {
        return t.sess.exec(sql, args);
    }
    pub fn execRawTimeout(t: *Tx, sql: []const u8, timeout_ms: u64) Error!pq.Result {
        return t.sess.execRawTimeout(sql, timeout_ms);
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
    observer: observability.Observer = .{},
    plugins: plugins_mod.Registry = .{},

    pub fn connect(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, max_connections: usize) Error!*Db {
        return connectWithOptions(gpa, io, cfg, .{ .max_connections = max_connections });
    }

    pub fn connectWithOptions(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, options: pool_mod.Options) Error!*Db {
        const d = try gpa.create(Db);
        errdefer gpa.destroy(d);
        d.* = .{
            .pool = pool_mod.Pool.initWithOptions(gpa, io, cfg, options),
            .gpa = gpa,
            .io = io,
        };
        errdefer d.pool.deinit();
        const conn = try d.pool.acquire();
        d.pool.release(conn);
        try d.pool.start();
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

    pub fn connectDsnWithOptions(gpa: std.mem.Allocator, io: std.Io, dsn: []const u8, options: pool_mod.Options) Error!*Db {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const cfg = try pq.parseDsn(arena.allocator(), dsn);
        const d = try connectWithOptions(gpa, io, cfg, options);
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
        return .{
            .pool = &d.pool,
            .gpa = d.gpa,
            .io = d.io,
            .logger = d.logger,
            .observer = d.observer,
            .plugins = d.plugins,
        };
    }

    pub fn ping(d: *Db) Error!void {
        return d.pool.ping();
    }

    pub fn poolStats(d: *Db) pool_mod.PoolStats {
        return d.pool.stats();
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
    pub fn insertReturning(d: *Db, m: anytype, comptime R: type, comptime fields: []const []const u8) Error!R {
        var s = d.session();
        return s.insertReturning(m, R, fields);
    }
    pub fn insertBatchReturning(d: *Db, models: anytype, comptime R: type, comptime fields: []const []const u8) Error![]R {
        var s = d.session();
        return s.insertBatchReturning(models, R, fields);
    }
    pub fn upsert(d: *Db, m: anytype, comptime conflict: OnConflict) Error!bool {
        var s = d.session();
        return s.upsert(m, conflict);
    }
    pub fn upsertBatch(d: *Db, models: anytype, comptime conflict: OnConflict) Error!usize {
        var s = d.session();
        return s.upsertBatch(models, conflict);
    }
    pub fn update(d: *Db, m: anytype) Error!i64 {
        var s = d.session();
        return s.update(m);
    }
    pub fn updateBatch(d: *Db, models: anytype) Error!usize {
        var s = d.session();
        return s.updateBatch(models);
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
    pub fn beginTimeout(d: *Db, timeout_ms: u64) Error!Tx {
        const s = d.gpa.create(Session) catch return error.OutOfMemory;
        s.* = d.session();
        errdefer d.gpa.destroy(s);
        var tx = try s.beginTimeout(timeout_ms);
        tx.owns_session = true;
        return tx;
    }
    /// Explicitly retries a whole transaction. Ordinary CRUD and `begin`
    /// never replay writes; callers must opt in by invoking this helper.
    pub fn transactionRetry(
        d: *Db,
        options: RetryOptions,
        context: anytype,
        comptime body: anytype,
    ) Error!void {
        const attempts = @max(@as(u8, 1), options.max_attempts);
        var attempt: u8 = 0;
        while (attempt < attempts) : (attempt += 1) {
            var tx = d.begin() catch |err| {
                if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                retryDelay(d, options, attempt);
                continue;
            };
            body(context, &tx) catch |err| {
                tx.rollback();
                if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                retryDelay(d, options, attempt);
                continue;
            };
            tx.commit() catch |err| {
                if (attempt + 1 >= attempts or !retryableTransactionError(err, options)) return err;
                retryDelay(d, options, attempt);
                continue;
            };
            return;
        }
        unreachable;
    }
    pub fn association(d: *Db, parent: anytype, comptime field_name: []const u8) Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
        var s = d.session();
        return s.association(parent, field_name);
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
    pub fn setObserver(d: *Db, observer: observability.Observer) void {
        d.observer = observer;
    }
    pub fn addPlugin(d: *Db, plugin: plugins_mod.Plugin) Error!void {
        if (!d.plugins.add(plugin)) return error.InvalidQuery;
    }
    pub fn writePrometheus(d: *Db, metrics: *const observability.Metrics, writer: *std.Io.Writer) !void {
        try metrics.writePrometheus(writer, d.poolStats());
    }
    pub fn exec(d: *Db, sql: []const u8, args: anytype) Error!pq.Result {
        var s = d.session();
        return s.exec(sql, args);
    }
    pub fn execTimeout(d: *Db, sql: []const u8, args: anytype, timeout_ms: u64) Error!pq.Result {
        var s = d.session();
        return s.execTimeout(sql, args, timeout_ms);
    }
    pub fn execRaw(d: *Db, sql: []const u8) Error!pq.Result {
        var s = d.session();
        return s.execRaw(sql);
    }
    pub fn execRawTimeout(d: *Db, sql: []const u8, timeout_ms: u64) Error!pq.Result {
        var s = d.session();
        return s.execRawTimeout(sql, timeout_ms);
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
