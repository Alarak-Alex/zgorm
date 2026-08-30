//! Driver-neutral primary, replica, tenant, and shard routing.

const std = @import("std");
const types = @import("types.zig");

pub fn Router(comptime Orm: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io: std.Io,
        primary: *Orm,
        active_primary: *Orm,
        replicas: []const *Orm,
        shards: []const *Orm = &.{},
        tenants: std.StringHashMap(*Orm),
        next_replica: usize = 0,
        mutex: std.Io.Mutex = .init,

        pub fn init(gpa: std.mem.Allocator, io: std.Io, primary: *Orm, replicas: []const *Orm) Self {
            return .{
                .gpa = gpa,
                .io = io,
                .primary = primary,
                .active_primary = primary,
                .replicas = replicas,
                .tenants = .init(gpa),
            };
        }

        pub fn deinit(router: *Self) void {
            var iterator = router.tenants.keyIterator();
            while (iterator.next()) |key| router.gpa.free(key.*);
            router.tenants.deinit();
        }

        pub fn reader(router: *Self) types.Error!*Orm {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            for (0..router.replicas.len) |_| {
                const candidate = router.replicas[router.next_replica % router.replicas.len];
                router.next_replica +%= 1;
                if (healthy(candidate)) return candidate;
            }
            if (!healthy(router.active_primary)) return error.ConnectionFailed;
            return router.active_primary;
        }

        pub fn writer(router: *Self) types.Error!*Orm {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            if (healthy(router.active_primary)) return router.active_primary;
            for (router.replicas) |candidate| {
                if (!healthy(candidate)) continue;
                router.active_primary = candidate;
                return candidate;
            }
            return error.ConnectionFailed;
        }

        pub fn resetPrimary(router: *Self) void {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            router.active_primary = router.primary;
        }

        pub fn setTenant(router: *Self, tenant_id: []const u8, db: *Orm) types.Error!void {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            if (router.tenants.getKey(tenant_id)) |key| {
                router.tenants.put(key, db) catch return error.OutOfMemory;
                return;
            }
            const key = router.gpa.dupe(u8, tenant_id) catch return error.OutOfMemory;
            errdefer router.gpa.free(key);
            router.tenants.put(key, db) catch return error.OutOfMemory;
        }

        pub fn tenant(router: *Self, tenant_id: []const u8) types.Error!*Orm {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            return router.tenants.get(tenant_id) orelse error.InvalidQuery;
        }

        pub fn setShards(router: *Self, shards: []const *Orm) void {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            router.shards = shards;
        }

        pub fn shard(router: *Self, key: []const u8) types.Error!*Orm {
            router.mutex.lockUncancelable(router.io);
            defer router.mutex.unlock(router.io);
            if (router.shards.len == 0) return error.InvalidQuery;
            return router.shards[std.hash.Wyhash.hash(0, key) % router.shards.len];
        }

        pub fn execRead(router: *Self, sql: []const u8, args: anytype) types.Error!types.Result {
            return (try router.reader()).execArgs(sql, args);
        }

        pub fn execWrite(router: *Self, sql: []const u8, args: anytype) types.Error!types.Result {
            return (try router.writer()).execArgs(sql, args);
        }

        fn healthy(db: *Orm) bool {
            var result = db.execRaw("SELECT 1") catch return false;
            result.deinit();
            return true;
        }
    };
}
