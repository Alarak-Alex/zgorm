const std = @import("std");
const types = @import("types.zig");

pub const Options = struct {
    min_size: usize = 0,
    max_size: usize = 10,
    /// Idle connections are health-checked only after this interval. Zero
    /// disables the check (a dead connection surfaces on its first query).
    health_check_interval_ms: u64 = 30_000,
};

pub const Stats = struct {
    total: usize,
    idle: usize,
    in_use: usize,
};

pub fn Pool(
    comptime Backend: type,
    comptime Context: type,
    comptime createFn: fn (*Context) types.Error!Backend,
    comptime destroyFn: fn (Backend) void,
    comptime pingFn: fn (Backend) types.Error!void,
    comptime healthyFn: fn (Backend) bool,
) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        options: Options,
        context: Context,
        idle: std.ArrayList(IdleEntry) = .empty,
        total: usize = 0,
        closed: bool = false,
        mutex: std.Io.Mutex = .init,
        condition: std.Io.Condition = .init,

        const IdleEntry = struct {
            backend: Backend,
            idle_since: std.Io.Timestamp,
        };

        fn idleMilliseconds(pool: *const Self, entry: IdleEntry) u64 {
            const ns = entry.idle_since.durationTo(std.Io.Clock.awake.now(pool.io)).nanoseconds;
            return if (ns <= 0) 0 else @intCast(@divTrunc(ns, std.time.ns_per_ms));
        }

        pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options, context: Context) types.Error!*Self {
            if (options.max_size == 0 or options.min_size > options.max_size) return error.InvalidConfig;
            const pool = gpa.create(Self) catch return error.OutOfMemory;
            pool.* = .{ .gpa = gpa, .io = io, .options = options, .context = context };
            errdefer {
                for (pool.idle.items) |entry| destroyFn(entry.backend);
                pool.idle.deinit(gpa);
                gpa.destroy(pool);
            }
            while (pool.total < options.min_size) {
                const backend = try createFn(&pool.context);
                pool.idle.append(gpa, .{ .backend = backend, .idle_since = std.Io.Clock.awake.now(io) }) catch {
                    destroyFn(backend);
                    return error.OutOfMemory;
                };
                pool.total += 1;
            }
            return pool;
        }

        pub fn deinit(pool: *Self) void {
            pool.mutex.lockUncancelable(pool.io);
            pool.closed = true;
            // Idle connections are not in use: detach and account for them now.
            var idle = pool.idle;
            pool.idle = .empty;
            pool.total -= idle.items.len;
            pool.condition.broadcast(pool.io);
            // Wait for in-use and still-creating connections to be returned or
            // destroyed before freeing the pool, so no lease outlives it.
            while (pool.total != 0) {
                pool.condition.waitUncancelable(pool.io, &pool.mutex);
            }
            pool.mutex.unlock(pool.io);

            for (idle.items) |entry| destroyFn(entry.backend);
            idle.deinit(pool.gpa);
            const gpa = pool.gpa;
            gpa.destroy(pool);
        }

        pub fn acquire(pool: *Self) types.Error!Lease {
            while (true) {
                pool.mutex.lockUncancelable(pool.io);
                if (pool.closed) {
                    pool.mutex.unlock(pool.io);
                    return error.PoolClosed;
                }
                if (pool.idle.pop()) |entry| {
                    pool.mutex.unlock(pool.io);
                    // Reject broken connections immediately, regardless of how
                    // recently they were used.
                    if (!healthyFn(entry.backend)) {
                        destroyFn(entry.backend);
                        pool.removeConnection();
                        continue;
                    }
                    // Recently used connections are assumed live; pinging on
                    // every acquire would add a round trip to each query.
                    if (pool.options.health_check_interval_ms == 0 or
                        pool.idleMilliseconds(entry) >= pool.options.health_check_interval_ms)
                    {
                        pingFn(entry.backend) catch {
                            destroyFn(entry.backend);
                            pool.removeConnection();
                            continue;
                        };
                    }
                    return .{ .pool = pool, .backend = entry.backend };
                }
                if (pool.total < pool.options.max_size) {
                    pool.total += 1;
                    pool.mutex.unlock(pool.io);
                    const backend = createFn(&pool.context) catch |err| {
                        pool.removeConnection();
                        return err;
                    };
                    return .{ .pool = pool, .backend = backend };
                }
                pool.condition.waitUncancelable(pool.io, &pool.mutex);
                pool.mutex.unlock(pool.io);
            }
        }

        pub fn stats(pool: *Self) Stats {
            pool.mutex.lockUncancelable(pool.io);
            defer pool.mutex.unlock(pool.io);
            return .{
                .total = pool.total,
                .idle = pool.idle.items.len,
                .in_use = pool.total - pool.idle.items.len,
            };
        }

        fn release(pool: *Self, backend: Backend) void {
            // Resetting an open transaction can perform I/O.
            const reusable = healthyFn(backend);
            pool.mutex.lockUncancelable(pool.io);
            if (pool.closed or !reusable) {
                pool.total -= 1;
                pool.condition.signal(pool.io);
                pool.mutex.unlock(pool.io);
                // Destroy outside the lock: destroyFn does network I/O and must
                // not stall other acquire/release/stats callers.
                destroyFn(backend);
                return;
            }
            pool.idle.append(pool.gpa, .{ .backend = backend, .idle_since = std.Io.Clock.awake.now(pool.io) }) catch {
                pool.total -= 1;
                pool.condition.signal(pool.io);
                pool.mutex.unlock(pool.io);
                destroyFn(backend);
                return;
            };
            pool.condition.signal(pool.io);
            pool.mutex.unlock(pool.io);
        }

        fn removeConnection(pool: *Self) void {
            pool.mutex.lockUncancelable(pool.io);
            pool.total -= 1;
            pool.condition.signal(pool.io);
            pool.mutex.unlock(pool.io);
        }

        pub const Lease = struct {
            pool: *Self,
            backend: Backend,
            released: bool = false,

            pub fn deinit(lease: *Lease) void {
                if (lease.released) return;
                lease.released = true;
                lease.pool.release(lease.backend);
            }
        };
    };
}
