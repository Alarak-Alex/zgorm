//! Primary/replica, tenant, and shard routing over existing Db handles.

const std = @import("std");
const db_mod = @import("db.zig");
const pq = @import("../drivers/postgres/root.zig");

pub const Error = pq.Error;

/// Router does not own any Db. Callers keep every configured handle alive.
pub const Router = struct {
    gpa: std.mem.Allocator,
    primary: *db_mod.Db,
    active_primary: *db_mod.Db,
    replicas: []const *db_mod.Db,
    shards: []const *db_mod.Db = &.{},
    tenants: std.StringHashMap(*db_mod.Db),
    next_replica: usize = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, primary: *db_mod.Db, replicas: []const *db_mod.Db) Router {
        return .{
            .gpa = gpa,
            .primary = primary,
            .active_primary = primary,
            .replicas = replicas,
            .tenants = std.StringHashMap(*db_mod.Db).init(gpa),
        };
    }

    fn lock(r: *Router) void {
        r.mutex.lockUncancelable(r.primary.io);
    }

    fn unlock(r: *Router) void {
        r.mutex.unlock(r.primary.io);
    }
    pub fn deinit(r: *Router) void {
        var it = r.tenants.keyIterator();
        while (it.next()) |key| r.gpa.free(key.*);
        r.tenants.deinit();
    }

    /// Returns a healthy replica in round-robin order, or the active primary.
    pub fn reader(r: *Router) Error!*db_mod.Db {
        r.lock();
        defer r.unlock();
        for (0..r.replicas.len) |_| {
            const candidate = r.replicas[r.next_replica % r.replicas.len];
            r.next_replica +%= 1;
            candidate.ping() catch continue;
            return candidate;
        }
        try r.active_primary.ping();
        return r.active_primary;
    }

    /// Returns the primary, promoting the first healthy replica when it fails.
    pub fn writer(r: *Router) Error!*db_mod.Db {
        r.lock();
        defer r.unlock();
        r.active_primary.ping() catch {
            for (r.replicas) |candidate| {
                candidate.ping() catch continue;
                r.active_primary = candidate;
                return candidate;
            }
            return error.ConnectionFailed;
        };
        return r.active_primary;
    }

    pub fn resetPrimary(r: *Router) void {
        r.lock();
        defer r.unlock();
        r.active_primary = r.primary;
    }

    pub fn setTenant(r: *Router, tenant_id: []const u8, db: *db_mod.Db) Error!void {
        r.lock();
        defer r.unlock();
        if (r.tenants.getKey(tenant_id)) |old| {
            try r.tenants.put(old, db);
            return;
        }
        const key = r.gpa.dupe(u8, tenant_id) catch return error.OutOfMemory;
        errdefer r.gpa.free(key);
        try r.tenants.put(key, db);
    }

    pub fn tenant(r: *Router, tenant_id: []const u8) Error!*db_mod.Db {
        r.lock();
        defer r.unlock();
        return r.tenants.get(tenant_id) orelse error.InvalidQuery;
    }

    pub fn setShards(r: *Router, shards: []const *db_mod.Db) void {
        r.lock();
        defer r.unlock();
        r.shards = shards;
    }

    /// Stable rendezvous-free routing; changing shard count remaps keys.
    pub fn shard(r: *Router, key: []const u8) Error!*db_mod.Db {
        r.lock();
        defer r.unlock();
        if (r.shards.len == 0) return error.InvalidQuery;
        return r.shards[std.hash.Wyhash.hash(0, key) % r.shards.len];
    }

    pub fn execRead(r: *Router, sql: []const u8, args: anytype) Error!pq.Result {
        return (try r.reader()).exec(sql, args);
    }

    pub fn execWrite(r: *Router, sql: []const u8, args: anytype) Error!pq.Result {
        return (try r.writer()).exec(sql, args);
    }

    pub fn find(r: *Router, comptime T: type, pk: anytype) Error!?T {
        return (try r.reader()).find(T, pk);
    }
};
