//! Pooled `Db` entry point: connection lifecycle, one-off CRUD delegates,
//! transactions, and observability configuration.
//!
//! Session execution and CRUD live in `session.zig`; the transaction wrapper
//! in `tx.zig`; association managers in `association.zig`. All remain
//! re-exported here for compatibility.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const pool_mod = @import("pool.zig");
const qb_mod = @import("qb.zig");
const session_mod = @import("session.zig");
const tx_mod = @import("tx.zig");
const assoc_mod = @import("association.zig");
const observability = @import("observability.zig");
const plugins_mod = @import("plugins.zig");

pub const logger_mod = session_mod.logger_mod;
pub const Error = pq.Error;
pub const Query = qb_mod.Query;
pub const Session = session_mod.Session;
pub const Tx = tx_mod.Tx;
pub const OnConflict = session_mod.OnConflict;
pub const Association = assoc_mod.Association;

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
        return connectDsnWithOptions(gpa, io, dsn, .{ .max_connections = max_connections });
    }

    pub fn connectDsnWithOptions(gpa: std.mem.Allocator, io: std.Io, dsn: []const u8, options: pool_mod.Options) Error!*Db {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        // Unescaped configuration strings are slices of the parser input.
        const owned_dsn = try arena.allocator().dupe(u8, dsn);
        const cfg = try pq.parseDsn(arena.allocator(), owned_dsn);
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
    pub fn association(d: *Db, parent: anytype, comptime field_name: []const u8) assoc_mod.Association(@typeInfo(@TypeOf(parent)).pointer.child, field_name) {
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
