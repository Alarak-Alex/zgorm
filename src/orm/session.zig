//! One unit of work against the database: connection acquisition, raw and
//! typed execution, CRUD, streaming decode, hooks, and observability.
//! `Db` hands out sessions; a session inside a transaction pins one connection.
//!
//! Comptime CRUD SQL templates live in `session/crud_sql.zig`; the Tx wrapper
//! in `tx.zig`; association managers in `association.zig`.

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
const crud_sql = @import("session/crud_sql.zig");
const crud = @import("session/crud.zig");
const crud_helpers = @import("session/crud_helpers.zig");
const migrate = @import("session/migrate.zig");
const assoc_mod = @import("association.zig");
const tx_mod = @import("tx.zig");

const Time = time_mod.Time;
pub const Error = pq.Error;
pub const Query = qb_mod.Query;
pub const OnConflict = crud_sql.OnConflict;

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

    pub fn transactionTimeout(s: *Session, requested_ms: u64) Error!u64 {
        const deadline = s.transaction_deadline orelse return requested_ms;
        const remaining_ns = std.Io.Clock.awake.now(s.io).durationTo(deadline).nanoseconds;
        if (remaining_ns <= 0) return error.TransactionTimeout;
        const remaining_ms: u64 = @intCast(@max(1, @divFloor(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        return if (requested_ms == 0) remaining_ms else @min(requested_ms, remaining_ms);
    }

    pub fn mapDeadlineError(s: *Session, err: Error) Error {
        if (err != error.QueryTimeout or s.transaction_deadline == null) return err;
        const remaining = std.Io.Clock.awake.now(s.io).durationTo(s.transaction_deadline.?).nanoseconds;
        return if (remaining <= 0) error.TransactionTimeout else err;
    }
    pub fn instrumentationEnabled(s: *const Session) bool {
        return s.logger.level != .silent or s.needsObserverOrPlugins();
    }

    /// Observers and plugins need pre-query hooks and a full result event;
    /// the text logger alone can be served after a streaming decode.
    pub fn needsObserverOrPlugins(s: *const Session) bool {
        return s.observer.on_query != null or
            s.observer.on_span != null or
            s.observer.metrics != null or
            s.observer.slow_queries != null or
            s.plugins.len != 0;
    }

    pub fn runExecFast(s: *Session, sql: []const u8, params: []const pq.Param, timeout_ms: u64) Error!pq.Result {
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

    pub fn execRawFast(s: *Session, sql: []const u8, timeout_ms: u64) Error!pq.Result {
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
        if (!s.needsObserverOrPlugins()) {
            // Logger only: no pre-query hooks or pool-wait accounting needed.
            const started = std.Io.Clock.awake.now(s.io);
            const res = s.runExecFast(sql, params, timeout_ms) catch |err| {
                s.reportQuery(sql, params, started, 0, 0, 0, err, "");
                return err;
            };
            s.reportQuery(sql, params, started, 0, res.affected, res.rows.len, null, "");
            return res;
        }
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
    /// Decodes directly from a cursor unless observers, plugins, a per-call
    /// timeout or a transaction deadline require the buffered result path.
    /// Both paths observe the connection's query timeout.
    pub fn runModels(
        s: *Session,
        comptime T: type,
        sql: []const u8,
        params: []const pq.Param,
        timeout_ms: u64,
        out_gpa: std.mem.Allocator,
    ) Error![]T {
        const table = comptime schema.tableOf(T);
        if (s.needsObserverOrPlugins() or timeout_ms != 0 or s.transaction_deadline != null) {
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

        // Streaming path: decode cells directly from the cursor without
        // materializing the whole result. The text logger (if enabled) is
        // served afterwards from the elapsed time and outcome.
        const started = std.Io.Clock.awake.now(s.io);
        const models = s.runModelsStream(T, table, sql, params, out_gpa) catch |err| {
            if (s.logger.level != .silent) s.reportQuery(sql, params, started, 0, 0, 0, err, "");
            return err;
        };
        if (s.logger.level != .silent) s.reportQuery(sql, params, started, 0, @intCast(models.len), models.len, null, "");
        return models;
    }

    pub fn runModelsStream(
        s: *Session,
        comptime T: type,
        comptime table: schema.Table,
        sql: []const u8,
        params: []const pq.Param,
        out_gpa: std.mem.Allocator,
    ) Error![]T {
        const conn = try s.acquire();
        const rows = (if (conn.cfg.binary_results)
            conn.queryParamsBinary(sql, params)
        else
            conn.queryParamsStream(sql, params)) catch |err| {
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
    pub fn reportQuery(
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
        // Metrics never reads the fingerprint; the slow log only needs it for
        // queries above its threshold. Skip the hash otherwise.
        const needs_fingerprint = s.observer.on_query != null or
            s.observer.on_span != null or
            (s.observer.slow_queries != null and elapsed_ns >= s.observer.slow_queries.?.threshold_ns);
        const event = observability.QueryEvent{
            .sql = sql,
            .fingerprint = if (needs_fingerprint) observability.fingerprint(sql) else 0,
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
    // Typed CRUD lives in session/crud.zig; these delegates keep the
    // Session API unchanged.

    pub fn insert(s: *Session, m: anytype) Error!void {
        return crud.insert(s, m);
    }
    pub fn insertReturning(s: *Session, m: anytype, comptime R: type, comptime fields: []const []const u8) Error!R {
        return crud.insertReturning(s, m, R, fields);
    }
    pub fn insertBatchReturning(s: *Session, models: anytype, comptime R: type, comptime fields: []const []const u8) Error![]R {
        return crud.insertBatchReturning(s, models, R, fields);
    }
    pub fn upsert(s: *Session, m: anytype, comptime conflict: OnConflict) Error!bool {
        return crud.upsert(s, m, conflict);
    }
    pub fn upsertBatch(s: *Session, models: anytype, comptime conflict: OnConflict) Error!usize {
        return crud.upsertBatch(s, models, conflict);
    }
    pub fn insertBatch(s: *Session, models: anytype) Error!void {
        return crud.insertBatch(s, models);
    }
    pub fn update(s: *Session, m: anytype) Error!i64 {
        return crud.update(s, m);
    }
    pub fn updateUnscoped(s: *Session, m: anytype) Error!i64 {
        return crud.updateUnscoped(s, m);
    }
    pub fn updateBatch(s: *Session, models: anytype) Error!usize {
        return crud.updateBatch(s, models);
    }
    pub fn save(s: *Session, m: anytype) Error!void {
        return crud.save(s, m);
    }
    pub fn delete(s: *Session, m: anytype) Error!i64 {
        return crud.delete(s, m);
    }
    pub fn deleteHard(s: *Session, m: anytype) Error!i64 {
        return crud.deleteHard(s, m);
    }
    pub fn restore(s: *Session, m: anytype) Error!i64 {
        return crud.restore(s, m);
    }
    pub fn deleteWhere(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return crud.deleteWhere(s, T, frag, args);
    }
    pub fn deleteWhereHard(s: *Session, comptime T: type, frag: []const u8, args: anytype) Error!i64 {
        return crud.deleteWhereHard(s, T, frag, args);
    }
    pub fn updateWhere(s: *Session, comptime T: type, sets: anytype, frag: []const u8, args: anytype) Error!i64 {
        return crud.updateWhere(s, T, sets, frag, args);
    }
    pub fn find(s: *Session, comptime T: type, pk: anytype) Error!?T {
        return crud.find(s, T, pk);
    }
    pub fn findUnscoped(s: *Session, comptime T: type, pk: anytype) Error!?T {
        return crud.findUnscoped(s, T, pk);
    }
    pub fn association(s: *Session, parent: anytype, comptime field_name: []const u8) assoc_mod.Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
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
    pub fn begin(s: *Session) Error!tx_mod.Tx {
        return s.beginTimeout(0);
    }

    /// Starts a transaction with one overall client-side deadline. Each
    /// statement and commit observes the remaining time.
    pub fn beginTimeout(s: *Session, timeout_ms: u64) Error!tx_mod.Tx {
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

    pub fn autoMigrate(s: *Session, comptime T: type) Error!void {
        return migrate.autoMigrate(s, T);
    }
    pub fn autoMigrateAll(s: *Session, comptime models: anytype) Error!void {
        inline for (models) |T| try s.autoMigrate(T);
    }

    // ------------------------------------------------------------- helpers

    pub fn autoStamp(s: *Session, comptime T: type, m: anytype, comptime is_insert: bool) Error!void {
        return crud_helpers.autoStamp(s, T, m, is_insert);
    }
    pub fn isZeroValue(v: anytype) bool {
        return crud_helpers.isZeroValue(v);
    }
};
