const std = @import("std");
const builtin = @import("builtin");
const z = @import("zgorm");

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocations: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        _ = self.allocations.fetchAdd(1, .monotonic);
        _ = self.bytes.fetchAdd(len, .monotonic);
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) return false;
        if (new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ra) orelse return null;
        if (new_len > memory.len) _ = self.bytes.fetchAdd(new_len - memory.len, .monotonic);
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

const BenchPost = struct {
    id: ?i64 = null,
    user_id: i64 = 0,
    title: []const u8 = "",
    pub const zgorm = .{ .table = "zorm_bench_posts", .indexes = .{"user_id"} };
};

const BenchUser = struct {
    id: ?i64 = null,
    created_at: ?z.Time = null,
    updated_at: ?z.Time = null,
    deleted_at: ?z.Time = null,
    name: []const u8 = "",
    score: i64 = 0,
    posts: []BenchPost = &.{},
    pub const zgorm = .{
        .table = "zorm_bench_users",
        .has_many = .{ .posts = .{ .model = BenchPost, .foreign_key = "user_id" } },
    };
};

fn buildQueryOnly(gpa: std.mem.Allocator, i: usize) !void {
    var session: z.Session = undefined;
    session.gpa = gpa;
    const q = gpa.create(z.qb.Query(BenchUser)) catch return error.OutOfMemory;
    q.* = .{
        .sess = &session,
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    var dry = try q
        .whereEq("score", @as(i64, @intCast(i)))
        .where("name LIKE $1", .{"user%"})
        .order_by("id DESC")
        .limit(10)
        .dryRun(gpa);
    dry.deinit();
}

fn runQueryBuildCase(
    io: std.Io,
    gpa: std.mem.Allocator,
    counter: *CountingAllocator,
    warmup: usize,
    iterations: usize,
) !void {
    for (0..warmup) |i| try buildQueryOnly(gpa, i);
    const alloc_before = counter.allocations.load(.monotonic);
    const bytes_before = counter.bytes.load(.monotonic);
    const cpu_before = cpuMicros();
    const started = std.Io.Clock.awake.now(io);
    for (0..iterations) |i| try buildQueryOnly(gpa, i);
    const elapsed_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
    const allocs = counter.allocations.load(.monotonic) - alloc_before;
    const bytes = counter.bytes.load(.monotonic) - bytes_before;
    std.debug.print(
        "{{\"orm\":\"zorm\",\"case\":\"query-build\",\"iterations\":{d},\"ns_per_op\":{d:.3},\"allocations_per_op\":{d:.3},\"bytes_per_op\":{d:.3},\"cpu_us\":{d}}}\n",
        .{
            iterations,
            @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations)),
            @as(f64, @floatFromInt(allocs)) / @as(f64, @floatFromInt(iterations)),
            @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(iterations)),
            cpuMicros() - cpu_before,
        },
    );
}

const Context = struct {
    db: *z.Db,
    gpa: std.mem.Allocator,
};

fn drop(result: z.pq.Result) void {
    var r = result;
    r.deinit();
}

fn setup(ctx: *Context) !void {
    drop(try ctx.db.execRaw("DROP TABLE IF EXISTS zorm_bench_posts CASCADE; DROP TABLE IF EXISTS zorm_bench_users CASCADE"));
    try ctx.db.autoMigrateAll(.{ BenchUser, BenchPost });

    var users: [1_000]BenchUser = undefined;
    var names: [1_000][24]u8 = undefined;
    for (&users, &names, 0..) |*user, *name_buf, i| {
        const name = try std.fmt.bufPrint(name_buf, "user-{d}", .{i});
        user.* = .{ .name = name, .score = @intCast(i) };
    }
    try ctx.db.insertBatch(&users);

    var posts: [1_000]BenchPost = undefined;
    var titles: [1_000][24]u8 = undefined;
    for (&posts, &titles, 0..) |*post, *title_buf, i| {
        const title = try std.fmt.bufPrint(title_buf, "post-{d}", .{i});
        post.* = .{ .user_id = @intCast((i % 1_000) + 1), .title = title };
    }
    try ctx.db.insertBatch(&posts);
}

fn acquireOnly(ctx: *Context, _: usize) !void {
    const conn = try ctx.db.pool.acquire();
    ctx.db.pool.release(conn);
}

fn acquirePing(ctx: *Context, _: usize) !void {
    const conn = try ctx.db.pool.acquire();
    defer ctx.db.pool.release(conn);
    try conn.ping();
}

fn primaryKey(ctx: *Context, i: usize) !void {
    const value = (try ctx.db.find(BenchUser, @as(i64, @intCast((i % 1_000) + 1)))).?;
    z.free(BenchUser, value, ctx.gpa);
}

fn queryRows(comptime count: usize) *const fn (*Context, usize) anyerror!void {
    return struct {
        fn run(ctx: *Context, _: usize) !void {
            const rows = try z.query(BenchUser, ctx.db).limit(count).all(ctx.gpa);
            z.freeSlice(BenchUser, rows, ctx.gpa);
        }
    }.run;
}

fn insertOne(ctx: *Context, i: usize) !void {
    var buf: [32]u8 = undefined;
    var user = BenchUser{ .name = try std.fmt.bufPrint(&buf, "insert-{d}", .{i}) };
    try ctx.db.insert(&user);
}

fn updateOne(ctx: *Context, i: usize) !void {
    var result = try ctx.db.exec(
        "UPDATE zorm_bench_users SET score = score + 1 WHERE id = $1",
        .{@as(i64, @intCast((i % 1_000) + 1))},
    );
    result.deinit();
}

fn deleteOne(ctx: *Context, i: usize) !void {
    var buf: [32]u8 = undefined;
    var user = BenchUser{ .name = try std.fmt.bufPrint(&buf, "delete-{d}", .{i}) };
    try ctx.db.insert(&user);
    _ = try ctx.db.deleteHard(&user);
}

fn softDeleteOne(ctx: *Context, i: usize) !void {
    var buf: [32]u8 = undefined;
    var user = BenchUser{ .name = try std.fmt.bufPrint(&buf, "soft-{d}", .{i}) };
    try ctx.db.insert(&user);
    _ = try ctx.db.delete(&user);
}

fn batchInsert(ctx: *Context, iteration: usize) !void {
    var users: [100]BenchUser = undefined;
    var names: [100][32]u8 = undefined;
    for (&users, &names, 0..) |*user, *name_buf, i| {
        const name = try std.fmt.bufPrint(name_buf, "batch-{d}-{d}", .{ iteration, i });
        user.* = .{ .name = name };
    }
    try ctx.db.insertBatch(&users);
}

fn transaction(ctx: *Context, _: usize) !void {
    var tx = try ctx.db.begin();
    errdefer tx.rollback();
    var result = try tx.execRaw("SELECT 1");
    result.deinit();
    try tx.commit();
}

fn preload(ctx: *Context, _: usize) !void {
    const users = try z.query(BenchUser, ctx.db).preload("posts").limit(10).all(ctx.gpa);
    z.freeSlice(BenchUser, users, ctx.gpa);
}

fn cpuMicros() u128 {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;
    const usage = std.posix.getrusage(0);
    return @as(u128, @intCast(usage.utime.sec)) * std.time.us_per_s +
        @as(u128, @intCast(usage.utime.usec)) +
        @as(u128, @intCast(usage.stime.sec)) * std.time.us_per_s +
        @as(u128, @intCast(usage.stime.usec));
}

fn peakRssBytes() usize {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return 0;
    const rss: usize = @intCast(std.posix.getrusage(0).maxrss);
    return switch (builtin.os.tag) {
        .linux, .freebsd, .dragonfly, .netbsd, .openbsd => rss * 1024,
        else => rss,
    };
}

fn percentile(sorted: []const u64, numerator: usize, denominator: usize) u64 {
    if (sorted.len == 0) return 0;
    const index = @min((sorted.len * numerator + denominator - 1) / denominator - 1, sorted.len - 1);
    return sorted[index];
}

fn runCase(
    name: []const u8,
    ctx: *Context,
    counter: *CountingAllocator,
    warmup: usize,
    iterations: usize,
    operation: *const fn (*Context, usize) anyerror!void,
) !void {
    for (0..warmup) |i| try operation(ctx, i + 1_000_000);
    const latencies = try ctx.gpa.alloc(u64, iterations);
    defer ctx.gpa.free(latencies);
    const alloc_before = counter.allocations.load(.monotonic);
    const bytes_before = counter.bytes.load(.monotonic);
    const cpu_before = cpuMicros();
    const pool_before = ctx.db.poolStats();
    const started = std.Io.Clock.awake.now(ctx.db.io);
    for (latencies, 0..) |*latency, i| {
        const one = std.Io.Clock.awake.now(ctx.db.io);
        try operation(ctx, i);
        latency.* = @intCast(one.durationTo(std.Io.Clock.awake.now(ctx.db.io)).nanoseconds);
    }
    const elapsed_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(ctx.db.io)).nanoseconds);
    const cpu_us = cpuMicros() - cpu_before;
    const pool_after = ctx.db.poolStats();
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const allocs = counter.allocations.load(.monotonic) - alloc_before;
    const bytes = counter.bytes.load(.monotonic) - bytes_before;
    const ops_per_second = @as(f64, @floatFromInt(iterations)) * @as(f64, std.time.ns_per_s) /
        @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print(
        "{{\"orm\":\"zorm\",\"case\":\"{s}\",\"warmup\":{d},\"iterations\":{d},\"ops_per_second\":{d:.3},\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d},\"p999_ns\":{d},\"allocations_per_op\":{d:.3},\"bytes_per_op\":{d:.3},\"cpu_us\":{d},\"peak_rss_bytes\":{d},\"pool_wait_count\":{d},\"pool_wait_ns\":{d}}}\n",
        .{ name, warmup, iterations, ops_per_second, percentile(latencies, 50, 100), percentile(latencies, 95, 100), percentile(latencies, 99, 100), percentile(latencies, 999, 1000), @as(f64, @floatFromInt(allocs)) / @as(f64, @floatFromInt(iterations)), @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(iterations)), cpu_us, peakRssBytes(), pool_after.wait_count - pool_before.wait_count, pool_after.wait_duration_ns - pool_before.wait_duration_ns },
    );
}

const Worker = struct {
    ctx: *Context,
    worker: usize,
    operations: usize,
    latencies: []u64,
    failed: *std.atomic.Value(bool),

    fn run(w: Worker) std.Io.Cancelable!void {
        for (0..w.operations) |i| {
            const started = std.Io.Clock.awake.now(w.ctx.db.io);
            primaryKey(w.ctx, w.worker * w.operations + i) catch {
                w.failed.store(true, .release);
                return;
            };
            w.latencies[i] = @intCast(started.durationTo(std.Io.Clock.awake.now(w.ctx.db.io)).nanoseconds);
        }
    }
};

fn runConcurrency(ctx: *Context, counter: *CountingAllocator, concurrency: usize, operations: usize) !void {
    const latencies = try ctx.gpa.alloc(u64, concurrency * operations);
    defer ctx.gpa.free(latencies);
    var failed: std.atomic.Value(bool) = .init(false);
    const alloc_before = counter.allocations.load(.monotonic);
    const bytes_before = counter.bytes.load(.monotonic);
    const cpu_before = cpuMicros();
    const pool_before = ctx.db.poolStats();
    const started = std.Io.Clock.awake.now(ctx.db.io);
    var group: std.Io.Group = .init;
    for (0..concurrency) |i| try group.concurrent(ctx.db.io, Worker.run, .{Worker{
        .ctx = ctx,
        .worker = i,
        .operations = operations,
        .latencies = latencies[i * operations ..][0..operations],
        .failed = &failed,
    }});
    try group.await(ctx.db.io);
    if (failed.load(.acquire)) return error.QueryFailed;
    const elapsed_ns: u128 = @intCast(started.durationTo(std.Io.Clock.awake.now(ctx.db.io)).nanoseconds);
    const total = concurrency * operations;
    const pool_after = ctx.db.poolStats();
    const allocs = counter.allocations.load(.monotonic) - alloc_before;
    const bytes = counter.bytes.load(.monotonic) - bytes_before;
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    std.debug.print(
        "{{\"orm\":\"zorm\",\"case\":\"concurrency-{d}\",\"iterations\":{d},\"ops_per_second\":{d:.3},\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d},\"p999_ns\":{d},\"allocations_per_op\":{d:.3},\"bytes_per_op\":{d:.3},\"cpu_us\":{d},\"peak_rss_bytes\":{d},\"pool_wait_count\":{d},\"pool_wait_ns\":{d}}}\n",
        .{ concurrency, total, @as(f64, @floatFromInt(total)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(elapsed_ns)), percentile(latencies, 50, 100), percentile(latencies, 95, 100), percentile(latencies, 99, 100), percentile(latencies, 999, 1000), @as(f64, @floatFromInt(allocs)) / @as(f64, @floatFromInt(total)), @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(total)), cpuMicros() - cpu_before, peakRssBytes(), pool_after.wait_count - pool_before.wait_count, pool_after.wait_duration_ns - pool_before.wait_duration_ns },
    );
}

fn selected(init: std.process.Init, name: []const u8) bool {
    const filter = init.environ_map.get("ZORM_BENCH_CASE") orelse return true;
    return std.mem.eql(u8, filter, name);
}

pub fn main(init: std.process.Init) !void {
    var counter = CountingAllocator{ .backing = init.gpa };
    const gpa = counter.allocator();
    if (init.environ_map.get("ZORM_BENCH_CASE")) |filter| {
        if (std.mem.eql(u8, filter, "query-build")) {
            const iterations = if (init.environ_map.get("ZORM_BENCH_ITERS")) |value|
                try std.fmt.parseInt(usize, value, 10)
            else
                10_000;
            const warmup = if (init.environ_map.get("ZORM_BENCH_WARMUP")) |value|
                try std.fmt.parseInt(usize, value, 10)
            else
                1_000;
            try runQueryBuildCase(init.io, gpa, &counter, warmup, iterations);
            return;
        }
    }
    const dsn = init.environ_map.get("ZORM_DSN") orelse "postgres://zorm:zorm@127.0.0.1:5433/zorm?sslmode=disable";
    const iterations = if (init.environ_map.get("ZORM_BENCH_ITERS")) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        100;
    const warmup = if (init.environ_map.get("ZORM_BENCH_WARMUP")) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        20;
    const pool_size = if (init.environ_map.get("ZORM_BENCH_POOL")) |value|
        try std.fmt.parseInt(usize, value, 10)
    else
        32;
    const health_check_interval_ms = if (init.environ_map.get("ZORM_BENCH_HEALTH_CHECK_MS")) |value|
        try std.fmt.parseInt(u64, value, 10)
    else
        30_000;
    const db = try z.Db.connectDsnWithOptions(gpa, init.io, dsn, .{
        .max_connections = pool_size,
        .min_idle_connections = @min(pool_size, 4),
        .max_idle_connections = pool_size,
        .health_check_interval_ms = health_check_interval_ms,
        .cleanup_interval_ms = 1_000,
    });
    defer db.deinit();
    db.setLogger(z.Logger.discard);
    var ctx = Context{ .db = db, .gpa = gpa };
    try setup(&ctx);
    if (selected(init, "acquire")) try runCase("acquire", &ctx, &counter, warmup, iterations, acquireOnly);
    if (selected(init, "acquire-ping")) try runCase("acquire-ping", &ctx, &counter, warmup, iterations, acquirePing);

    if (selected(init, "primary-key")) try runCase("primary-key", &ctx, &counter, warmup, iterations, primaryKey);
    if (selected(init, "query-10")) try runCase("query-10", &ctx, &counter, warmup, iterations, queryRows(10));
    if (selected(init, "query-100")) try runCase("query-100", &ctx, &counter, warmup, iterations, queryRows(100));
    if (selected(init, "query-1000")) try runCase("query-1000", &ctx, &counter, warmup, iterations, queryRows(1_000));
    if (selected(init, "insert")) try runCase("insert", &ctx, &counter, warmup, iterations, insertOne);
    if (selected(init, "update")) try runCase("update", &ctx, &counter, warmup, iterations, updateOne);
    if (selected(init, "delete")) try runCase("delete", &ctx, &counter, warmup, iterations, deleteOne);
    if (selected(init, "soft-delete")) try runCase("soft-delete", &ctx, &counter, warmup, iterations, softDeleteOne);
    if (selected(init, "batch-insert-100")) try runCase("batch-insert-100", &ctx, &counter, @max(warmup / 10, 1), @max(iterations / 10, 1), batchInsert);
    if (selected(init, "transaction")) try runCase("transaction", &ctx, &counter, warmup, iterations, transaction);
    if (selected(init, "preload")) try runCase("preload", &ctx, &counter, warmup, iterations, preload);
    inline for (.{ 1, 16, 128, 512 }) |concurrency| {
        const name = comptime std.fmt.comptimePrint("concurrency-{d}", .{concurrency});
        if (selected(init, name)) {
            for (0..warmup) |i| try primaryKey(&ctx, i);
            try runConcurrency(&ctx, &counter, concurrency, iterations);
        }
    }
}
