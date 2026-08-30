//! Thread-safe PostgreSQL connection pool with bounded lifetime, idle cleanup,
//! prewarming, health checks, acquisition deadlines, and statistics.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");

pub const Error = pq.Error;

pub const Options = struct {
    max_connections: usize = 4,
    /// Bounds simultaneous PostgreSQL handshakes during burst growth.
    max_connecting: usize = 8,
    min_idle_connections: usize = 0,
    max_idle_connections: ?usize = null,
    max_connection_lifetime_ms: u64 = 0,
    idle_timeout_ms: u64 = 0,
    acquire_timeout_ms: u64 = 0,
    health_check_interval_ms: u64 = 30_000,
    cleanup_interval_ms: u64 = 1_000,
};

pub const PoolStats = struct {
    max_connections: usize,
    open: usize,
    in_use: usize,
    idle: usize,
    wait_count: u64,
    wait_duration_ns: u128,
    prepared_hits: u64,
    prepared_misses: u64,
    prepared_evictions: u64,

    pub fn preparedHitRate(s: PoolStats) f64 {
        const total = s.prepared_hits + s.prepared_misses;
        return if (total == 0) 0 else @as(f64, @floatFromInt(s.prepared_hits)) / @as(f64, @floatFromInt(total));
    }
};
const Waiter = struct {
    next: ?*Waiter = null,
    event: std.Io.Event = .unset,
    conn: ?*pq.Conn = null,
    retry: bool = false,
    closed: bool = false,
    started: std.Io.Timestamp = undefined,
    queued: bool = false,
};

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: pq.Config,
    options: Options,
    max_size: usize,

    mutex: std.Io.Mutex = .init,
    wait_head: ?*Waiter = null,
    wait_tail: ?*Waiter = null,
    free: std.ArrayList(*pq.Conn) = .empty,
    total: usize = 0,
    connecting: usize = 0,
    closed: bool = false,
    wait_count: u64 = 0,
    wait_duration_ns: u128 = 0,
    retired_prepared_hits: u64 = 0,
    retired_prepared_misses: u64 = 0,
    retired_prepared_evictions: u64 = 0,
    maintenance: std.Io.Group = .init,
    maintenance_started: bool = false,
    maintenance_stop: std.Io.Event = .unset,

    /// Details of the most recent server error. Guarded separately so query
    /// failures do not serialize ordinary pool operations.
    err_mutex: std.Io.Mutex = .init,
    err_buf: [1024]u8 = undefined,
    last_error: ?pq.PgError = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, max_size: usize) Pool {
        return initWithOptions(gpa, io, cfg, .{ .max_connections = max_size });
    }

    pub fn initWithOptions(gpa: std.mem.Allocator, io: std.Io, cfg: pq.Config, requested: Options) Pool {
        var options = requested;
        options.max_connections = @max(options.max_connections, 1);
        options.max_connecting = @min(@max(options.max_connecting, 1), options.max_connections);
        const max_idle = @min(options.max_idle_connections orelse options.max_connections, options.max_connections);
        options.max_idle_connections = max_idle;
        options.min_idle_connections = @min(options.min_idle_connections, max_idle);
        return .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .options = options,
            .max_size = options.max_connections,
        };
    }

    /// Starts background cleanup and creates the configured idle floor. Call
    /// only after the Pool has reached its stable address.
    pub fn start(p: *Pool) Error!void {
        try p.prewarm();
        if (p.options.cleanup_interval_ms > 0 and !p.maintenance_started) {
            p.maintenance_started = true;
            p.maintenance.async(p.io, maintain, .{p});
        }
    }

    fn maintain(p: *Pool) std.Io.Cancelable!void {
        while (true) {
            p.maintenance_stop.waitTimeout(p.io, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(p.options.cleanup_interval_ms)),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.Timeout => {
                    p.pruneExpired();
                    p.prewarm() catch {};
                    continue;
                },
                error.Canceled => return error.Canceled,
            };
            return;
        }
    }

    pub fn prewarm(p: *Pool) Error!void {
        while (true) {
            p.mutex.lockUncancelable(p.io);
            if (p.closed or p.free.items.len >= p.options.min_idle_connections or p.total >= p.max_size) {
                p.mutex.unlock(p.io);
                return;
            }
            p.total += 1;
            p.connecting += 1;
            p.mutex.unlock(p.io);

            const conn = pq.Conn.connect(p.gpa, p.io, p.cfg) catch |err| {
                p.mutex.lockUncancelable(p.io);
                p.total -= 1;
                p.connecting -= 1;
                p.wakeConnectorLocked();
                p.mutex.unlock(p.io);
                return err;
            };
            p.mutex.lockUncancelable(p.io);
            p.connecting -= 1;
            p.wakeConnectorLocked();
            p.mutex.unlock(p.io);
            p.release(conn);
        }
    }

    fn enqueueWaiterLocked(p: *Pool, waiter: *Waiter) void {
        waiter.queued = true;
        if (p.wait_tail) |tail| {
            tail.next = waiter;
        } else {
            p.wait_head = waiter;
        }
        p.wait_tail = waiter;
    }

    fn popWaiterLocked(p: *Pool) ?*Waiter {
        const waiter = p.wait_head orelse return null;
        p.wait_head = waiter.next;
        if (p.wait_head == null) p.wait_tail = null;
        waiter.next = null;
        waiter.queued = false;
        return waiter;
    }

    fn removeWaiterLocked(p: *Pool, target: *Waiter) bool {
        var previous: ?*Waiter = null;
        var current = p.wait_head;
        while (current) |waiter| {
            if (waiter == target) {
                if (previous) |prev| {
                    prev.next = waiter.next;
                } else {
                    p.wait_head = waiter.next;
                }
                if (p.wait_tail == waiter) p.wait_tail = previous;
                waiter.next = null;
                waiter.queued = false;
                return true;
            }
            previous = waiter;
            current = waiter.next;
        }
        return false;
    }

    /// Gives the oldest waiter first chance to fill newly available capacity.
    /// The event is set while holding the mutex so its stack node cannot time
    /// out and disappear before the wakeup is published.
    fn wakeRetryLocked(p: *Pool) void {
        const waiter = p.popWaiterLocked() orelse return;
        waiter.retry = true;
        waiter.event.set(p.io);
    }
    fn wakeConnectorLocked(p: *Pool) void {
        if (p.total < p.max_size and p.connecting < p.options.max_connecting) {
            p.wakeRetryLocked();
        }
    }

    fn elapsedNs(started: std.Io.Timestamp, io: std.Io) u128 {
        const ns = started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds;
        return if (ns <= 0) 0 else @intCast(ns);
    }

    fn recordWaitLocked(p: *Pool, started: std.Io.Timestamp) void {
        p.wait_duration_ns +|= elapsedNs(started, p.io);
    }

    fn recordWait(p: *Pool, started: std.Io.Timestamp) void {
        p.mutex.lockUncancelable(p.io);
        p.recordWaitLocked(started);
        p.mutex.unlock(p.io);
    }

    fn isExpired(p: *const Pool, c: *const pq.Conn) bool {
        return (p.options.max_connection_lifetime_ms > 0 and
            c.ageMilliseconds() >= p.options.max_connection_lifetime_ms) or
            (p.options.idle_timeout_ms > 0 and
                c.idleMilliseconds() >= p.options.idle_timeout_ms);
    }

    fn absorbPrepared(p: *Pool, c: *const pq.Conn) void {
        const prepared = c.preparedStats();
        p.retired_prepared_hits +|= prepared.hits;
        p.retired_prepared_misses +|= prepared.misses;
        p.retired_prepared_evictions +|= prepared.evictions;
    }

    fn retire(p: *Pool, c: *pq.Conn) void {
        p.mutex.lockUncancelable(p.io);
        p.total -= 1;
        p.absorbPrepared(c);
        p.wakeConnectorLocked();
        p.mutex.unlock(p.io);
        c.close();
    }

    fn pruneExpired(p: *Pool) void {
        while (true) {
            p.mutex.lockUncancelable(p.io);
            var expired: ?*pq.Conn = null;
            for (p.free.items, 0..) |c, i| {
                if (p.isExpired(c) or !c.healthy()) {
                    expired = p.free.orderedRemove(i);
                    p.total -= 1;
                    p.absorbPrepared(c);
                    p.wakeConnectorLocked();
                    break;
                }
            }
            p.mutex.unlock(p.io);
            const c = expired orelse return;
            c.close();
        }
    }

    /// Returns a live connection, observing the configured acquisition
    /// timeout. Idle connections are health-checked after the configured
    /// interval; expired or broken connections are replaced safely.
    pub fn acquire(p: *Pool) Error!*pq.Conn {
        const started = std.Io.Clock.awake.now(p.io);
        var waited = false;
        var priority = false;
        var waiter: Waiter = .{};
        while (true) {
            p.mutex.lockUncancelable(p.io);
            if (p.closed) {
                p.mutex.unlock(p.io);
                if (waited) p.recordWait(started);
                return error.ConnectionClosed;
            }

            // Once a queue exists, new callers join it instead of taking a
            // just-returned connection ahead of an older waiter.
            if (priority or p.wait_head == null) {
                if (p.free.items.len > 0) {
                    const c = p.free.pop().?;
                    if (p.isExpired(c) or !c.healthy()) {
                        p.total -= 1;
                        p.absorbPrepared(c);
                        p.wakeConnectorLocked();
                        p.mutex.unlock(p.io);
                        c.close();
                        priority = false;
                        continue;
                    }
                    p.mutex.unlock(p.io);
                    if (p.options.health_check_interval_ms > 0 and
                        c.idleMilliseconds() >= p.options.health_check_interval_ms)
                    {
                        c.ping() catch {
                            p.retire(c);
                            priority = false;
                            continue;
                        };
                    }
                    c.touch();
                    if (waited) p.recordWait(started);
                    return c;
                }
                if (p.total < p.max_size and p.connecting < p.options.max_connecting) {
                    p.total += 1;
                    p.connecting += 1;
                    p.mutex.unlock(p.io);
                    const c = pq.Conn.connect(p.gpa, p.io, p.cfg) catch |err| {
                        p.mutex.lockUncancelable(p.io);
                        p.total -= 1;
                        p.connecting -= 1;
                        p.wakeConnectorLocked();
                        if (waited) p.recordWaitLocked(started);
                        p.mutex.unlock(p.io);
                        return err;
                    };
                    p.mutex.lockUncancelable(p.io);
                    p.connecting -= 1;
                    p.wakeConnectorLocked();
                    if (waited) p.recordWaitLocked(started);
                    p.mutex.unlock(p.io);
                    return c;
                }
            }

            if (!waited) {
                waited = true;
                p.wait_count +|= 1;
            }
            priority = false;
            waiter = .{ .started = started };
            p.enqueueWaiterLocked(&waiter);
            p.mutex.unlock(p.io);

            const timeout_ms = p.options.acquire_timeout_ms;
            if (timeout_ms == 0) {
                waiter.event.waitUncancelable(p.io);
            } else {
                while (!waiter.event.isSet()) {
                    const elapsed_ms = elapsedNs(started, p.io) / std.time.ns_per_ms;
                    if (elapsed_ms >= timeout_ms) {
                        p.mutex.lockUncancelable(p.io);
                        if (waiter.queued) {
                            _ = p.removeWaiterLocked(&waiter);
                            p.recordWaitLocked(started);
                            p.mutex.unlock(p.io);
                            return error.AcquireTimeout;
                        }
                        p.mutex.unlock(p.io);
                        break;
                    }
                    const remaining: u64 = @intCast(timeout_ms - elapsed_ms);
                    waiter.event.waitTimeout(p.io, .{ .duration = .{
                        .raw = .fromMilliseconds(@intCast(remaining)),
                        .clock = .awake,
                    } }) catch |err| switch (err) {
                        error.Timeout => continue,
                        error.Canceled => {
                            p.mutex.lockUncancelable(p.io);
                            const removed = if (waiter.queued) p.removeWaiterLocked(&waiter) else false;
                            if (removed) p.recordWaitLocked(started);
                            p.mutex.unlock(p.io);
                            if (removed) return error.AcquireTimeout;
                            break;
                        },
                    };
                }
            }

            if (waiter.conn) |c| return c;
            if (waiter.closed) return error.ConnectionClosed;
            if (waiter.retry) {
                priority = true;
                continue;
            }
            unreachable;
        }
    }

    /// Returns a connection to the pool. Broken and expired connections are
    /// closed; excess idle connections are capped.
    pub fn release(p: *Pool, c: *pq.Conn) void {
        c.touch();
        p.mutex.lockUncancelable(p.io);
        const max_idle = p.options.max_idle_connections.?;
        if (!p.closed and c.healthy() and
            (p.options.max_connection_lifetime_ms == 0 or
                c.ageMilliseconds() < p.options.max_connection_lifetime_ms))
        {
            if (p.popWaiterLocked()) |waiter| {
                p.recordWaitLocked(waiter.started);
                waiter.conn = c;
                waiter.event.set(p.io);
                p.mutex.unlock(p.io);
                return;
            }
            if (p.free.items.len < max_idle) {
                p.free.append(p.gpa, c) catch {
                    p.total -= 1;
                    p.absorbPrepared(c);
                    p.wakeConnectorLocked();
                    p.mutex.unlock(p.io);
                    c.close();
                    return;
                };
                p.mutex.unlock(p.io);
                return;
            }
        }
        p.total -= 1;
        p.absorbPrepared(c);
        p.wakeConnectorLocked();
        p.mutex.unlock(p.io);
        c.close();
    }

    pub fn ping(p: *Pool) Error!void {
        const c = try p.acquire();
        defer p.release(c);
        try c.ping();
    }

    pub fn stats(p: *Pool) PoolStats {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        var hits = p.retired_prepared_hits;
        var misses = p.retired_prepared_misses;
        var evictions = p.retired_prepared_evictions;
        for (p.free.items) |c| {
            const prepared = c.preparedStats();
            hits +|= prepared.hits;
            misses +|= prepared.misses;
            evictions +|= prepared.evictions;
        }
        return .{
            .max_connections = p.max_size,
            .open = p.total,
            .in_use = p.total - p.free.items.len,
            .idle = p.free.items.len,
            .wait_count = p.wait_count,
            .wait_duration_ns = p.wait_duration_ns,
            .prepared_hits = hits,
            .prepared_misses = misses,
            .prepared_evictions = evictions,
        };
    }

    /// Copies the connection's server error into pool-owned storage.
    pub fn captureError(p: *Pool, c: *pq.Conn) void {
        const src = c.last_error orelse return;
        p.err_mutex.lockUncancelable(p.io);
        defer p.err_mutex.unlock(p.io);
        var fbs: std.Io.Writer = .fixed(&p.err_buf);
        var e: pq.PgError = .{};
        e.severity = store(&fbs, src.severity);
        e.code = store(&fbs, src.code);
        e.message = store(&fbs, src.message);
        e.detail = store(&fbs, src.detail);
        e.hint = store(&fbs, src.hint);
        e.position = store(&fbs, src.position);
        e.schema = store(&fbs, src.schema);
        e.table = store(&fbs, src.table);
        e.column = store(&fbs, src.column);
        e.constraint = store(&fbs, src.constraint);
        p.last_error = e;
    }

    pub fn lastErrorCopy(p: *Pool, arena: std.mem.Allocator) ?pq.PgError {
        p.err_mutex.lockUncancelable(p.io);
        defer p.err_mutex.unlock(p.io);
        const src = p.last_error orelse return null;
        var e: pq.PgError = .{};
        e.severity = arena.dupe(u8, src.severity) catch return null;
        e.code = arena.dupe(u8, src.code) catch return null;
        e.message = arena.dupe(u8, src.message) catch return null;
        e.detail = arena.dupe(u8, src.detail) catch return null;
        e.hint = arena.dupe(u8, src.hint) catch return null;
        e.position = arena.dupe(u8, src.position) catch return null;
        e.schema = arena.dupe(u8, src.schema) catch return null;
        e.table = arena.dupe(u8, src.table) catch return null;
        e.column = arena.dupe(u8, src.column) catch return null;
        e.constraint = arena.dupe(u8, src.constraint) catch return null;
        return e;
    }

    fn store(fbs: *std.Io.Writer, src: []const u8) []const u8 {
        if (src.len == 0) return "";
        const offset = fbs.end;
        fbs.writeAll(src) catch return "";
        return fbs.buffered()[offset..];
    }

    pub fn deinit(p: *Pool) void {
        if (p.maintenance_started) {
            p.maintenance_stop.set(p.io);
            p.maintenance.cancel(p.io);
        }
        p.mutex.lockUncancelable(p.io);
        p.closed = true;
        while (p.popWaiterLocked()) |waiter| {
            p.recordWaitLocked(waiter.started);
            waiter.closed = true;
            waiter.event.set(p.io);
        }
        while (p.free.pop()) |c| {
            p.total -= 1;
            p.absorbPrepared(c);
            c.close();
        }
        p.mutex.unlock(p.io);
        p.free.deinit(p.gpa);
    }
};

test "pool options normalize idle bounds" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const p = Pool.initWithOptions(std.testing.allocator, threaded.io(), .{}, .{
        .max_connections = 2,
        .min_idle_connections = 9,
        .max_idle_connections = 7,
        .max_connecting = 9,
    });
    try std.testing.expectEqual(@as(usize, 2), p.options.min_idle_connections);
    try std.testing.expectEqual(@as(usize, 2), p.options.max_idle_connections.?);
    try std.testing.expectEqual(@as(usize, 2), p.options.max_connecting);
}

test "pool acquire failure releases reserved slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var p = Pool.init(std.testing.allocator, threaded.io(), .{
        .user = "x",
        .host = "127.0.0.1",
        .port = 1,
    }, 2);
    defer p.deinit();
    try std.testing.expectError(error.ConnectionFailed, p.acquire());
    try std.testing.expectEqual(@as(usize, 0), p.stats().open);
    try std.testing.expectEqual(@as(usize, 0), p.connecting);
}
