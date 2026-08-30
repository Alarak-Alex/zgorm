const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const pool_mod = @import("pool.zig");

pub const ErrorClass = enum {
    none,
    timeout,
    canceled,
    constraint,
    transaction,
    connection,
    syntax,
    permission,
    data,
    database,
    client,
};

pub const QueryEvent = struct {
    sql: []const u8,
    fingerprint: u64,
    duration_ns: u128,
    pool_wait_ns: u128,
    affected_rows: i64,
    returned_rows: usize,
    sqlstate: []const u8 = "",
    error_class: ErrorClass = .none,
    prepared_hit_rate: f64,
    pool: pool_mod.PoolStats,
};

/// Dependency-free hooks for structured events and completed OpenTelemetry
/// spans. `on_span` receives database semantic fields through `QueryEvent`;
/// adapters can translate them into their OpenTelemetry SDK of choice.
pub const Observer = struct {
    context: ?*anyopaque = null,
    on_query: ?*const fn (?*anyopaque, QueryEvent) void = null,
    on_span: ?*const fn (?*anyopaque, QueryEvent) void = null,
    metrics: ?*Metrics = null,
    slow_queries: ?*SlowQueryLog = null,

    pub fn emit(o: Observer, event: QueryEvent) void {
        if (o.metrics) |metrics| metrics.observe(event);
        if (o.slow_queries) |slow| slow.observe(event);
        if (o.on_query) |callback| callback(o.context, event);
        if (o.on_span) |callback| callback(o.context, event);
    }
};

pub const Metrics = struct {
    queries: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    affected_rows: std.atomic.Value(u64) = .init(0),
    returned_rows: std.atomic.Value(u64) = .init(0),
    duration_ns: std.atomic.Value(u64) = .init(0),
    pool_wait_ns: std.atomic.Value(u64) = .init(0),

    pub fn observe(m: *Metrics, event: QueryEvent) void {
        _ = m.queries.fetchAdd(1, .monotonic);
        if (event.error_class != .none) _ = m.errors.fetchAdd(1, .monotonic);
        if (event.affected_rows > 0) _ = m.affected_rows.fetchAdd(@intCast(event.affected_rows), .monotonic);
        _ = m.returned_rows.fetchAdd(event.returned_rows, .monotonic);
        _ = m.duration_ns.fetchAdd(@intCast(@min(event.duration_ns, std.math.maxInt(u64))), .monotonic);
        _ = m.pool_wait_ns.fetchAdd(@intCast(@min(event.pool_wait_ns, std.math.maxInt(u64))), .monotonic);
    }

    /// Writes Prometheus text exposition, including live pool and prepared
    /// statement gauges from the supplied snapshot.
    pub fn writePrometheus(m: *const Metrics, writer: *std.Io.Writer, pool: pool_mod.PoolStats) !void {
        try writer.print(
            "# TYPE zorm_queries_total counter\nzorm_queries_total {d}\n" ++
                "# TYPE zorm_query_errors_total counter\nzorm_query_errors_total {d}\n" ++
                "# TYPE zorm_affected_rows_total counter\nzorm_affected_rows_total {d}\n" ++
                "# TYPE zorm_returned_rows_total counter\nzorm_returned_rows_total {d}\n" ++
                "# TYPE zorm_query_duration_seconds_total counter\nzorm_query_duration_seconds_total {d:.9}\n" ++
                "# TYPE zorm_pool_wait_seconds_total counter\nzorm_pool_wait_seconds_total {d:.9}\n" ++
                "# TYPE zorm_pool_connections gauge\nzorm_pool_connections{{state=\"open\"}} {d}\n" ++
                "zorm_pool_connections{{state=\"in_use\"}} {d}\n" ++
                "zorm_pool_connections{{state=\"idle\"}} {d}\n" ++
                "# TYPE zorm_pool_wait_total counter\nzorm_pool_wait_total {d}\n" ++
                "# TYPE zorm_prepared_statement_hits_total counter\nzorm_prepared_statement_hits_total {d}\n" ++
                "# TYPE zorm_prepared_statement_misses_total counter\nzorm_prepared_statement_misses_total {d}\n" ++
                "# TYPE zorm_prepared_statement_hit_ratio gauge\nzorm_prepared_statement_hit_ratio {d:.9}\n",
            .{
                m.queries.load(.monotonic),
                m.errors.load(.monotonic),
                m.affected_rows.load(.monotonic),
                m.returned_rows.load(.monotonic),
                @as(f64, @floatFromInt(m.duration_ns.load(.monotonic))) / std.time.ns_per_s,
                @as(f64, @floatFromInt(m.pool_wait_ns.load(.monotonic))) / std.time.ns_per_s,
                pool.open,
                pool.in_use,
                pool.idle,
                pool.wait_count,
                pool.prepared_hits,
                pool.prepared_misses,
                pool.preparedHitRate(),
            },
        );
    }
};

pub const SlowQueryLog = struct {
    pub const capacity = 64;
    pub const Entry = struct {
        fingerprint: u64,
        count: u64,
        total_duration_ns: u128,
        max_duration_ns: u128,
    };

    threshold_ns: u128,
    mutex: std.atomic.Mutex = .unlocked,
    entries: [capacity]Entry = undefined,
    len: usize = 0,

    pub fn init(threshold_ms: u64) SlowQueryLog {
        return .{ .threshold_ns = @as(u128, threshold_ms) * std.time.ns_per_ms };
    }

    fn lock(log: *SlowQueryLog) void {
        while (!log.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn observe(log: *SlowQueryLog, event: QueryEvent) void {
        if (event.duration_ns < log.threshold_ns) return;
        log.lock();
        defer log.mutex.unlock();
        for (log.entries[0..log.len]) |*entry| {
            if (entry.fingerprint != event.fingerprint) continue;
            entry.count +|= 1;
            entry.total_duration_ns +|= event.duration_ns;
            entry.max_duration_ns = @max(entry.max_duration_ns, event.duration_ns);
            return;
        }
        if (log.len < capacity) {
            log.entries[log.len] = .{
                .fingerprint = event.fingerprint,
                .count = 1,
                .total_duration_ns = event.duration_ns,
                .max_duration_ns = event.duration_ns,
            };
            log.len += 1;
            return;
        }
        var smallest: usize = 0;
        for (log.entries[1..], 1..) |entry, i| {
            if (entry.total_duration_ns < log.entries[smallest].total_duration_ns) smallest = i;
        }
        if (event.duration_ns > log.entries[smallest].total_duration_ns) {
            log.entries[smallest] = .{
                .fingerprint = event.fingerprint,
                .count = 1,
                .total_duration_ns = event.duration_ns,
                .max_duration_ns = event.duration_ns,
            };
        }
    }

    pub fn snapshot(log: *SlowQueryLog, out: *[capacity]Entry) []Entry {
        log.lock();
        defer log.mutex.unlock();
        @memcpy(out[0..log.len], log.entries[0..log.len]);
        return out[0..log.len];
    }
};

pub fn classify(err: ?pq.Error) ErrorClass {
    const value = err orelse return .none;
    return switch (value) {
        error.QueryTimeout, error.NetworkReadTimeout, error.NetworkWriteTimeout, error.AcquireTimeout, error.TransactionTimeout => .timeout,
        error.QueryCanceled => .canceled,
        error.UniqueViolation, error.ForeignKeyViolation, error.NotNullViolation, error.CheckViolation => .constraint,
        error.SerializationFailure, error.DeadlockDetected, error.OptimisticLockConflict => .transaction,
        error.ConnectionFailed, error.ConnectionClosed => .connection,
        error.SyntaxError, error.UndefinedTable, error.UndefinedColumn => .syntax,
        error.InsufficientPrivilege, error.AuthenticationFailed => .permission,
        error.NumericValueOutOfRange, error.InvalidTextRepresentation, error.NullValue, error.TypeMismatch => .data,
        error.QueryFailed => .database,
        else => .client,
    };
}

/// Allocation-free FNV-1a fingerprint. Whitespace, literal strings, and
/// numeric literals are normalized so equivalent query shapes aggregate.
pub fn fingerprint(sql: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    var i: usize = 0;
    var space = false;
    while (i < sql.len) {
        const byte = sql[i];
        if (std.ascii.isWhitespace(byte)) {
            space = true;
            i += 1;
            continue;
        }
        if (space) {
            hash = (hash ^ ' ') *% 1099511628211;
            space = false;
        }
        if (byte == '\'') {
            hash = (hash ^ '?') *% 1099511628211;
            i += 1;
            while (i < sql.len) : (i += 1) {
                if (sql[i] != '\'') continue;
                if (i + 1 < sql.len and sql[i + 1] == '\'') {
                    i += 1;
                    continue;
                }
                i += 1;
                break;
            }
            continue;
        }
        if (std.ascii.isDigit(byte)) {
            hash = (hash ^ '?') *% 1099511628211;
            i += 1;
            while (i < sql.len and (std.ascii.isDigit(sql[i]) or sql[i] == '.')) i += 1;
            continue;
        }
        hash = (hash ^ std.ascii.toLower(byte)) *% 1099511628211;
        i += 1;
    }
    return hash;
}

test "fingerprint normalizes literals and spacing" {
    try std.testing.expectEqual(fingerprint("SELECT * FROM users WHERE id = 1"), fingerprint("select  *  from users where id = 999"));
    try std.testing.expectEqual(fingerprint("name = 'alice'"), fingerprint("name = 'bob'"));
}
