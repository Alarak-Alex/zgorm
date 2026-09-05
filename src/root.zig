//! zgorm — a GORM-inspired ORM for Zig.
//!
//! Library root module. See README.md for a quick tour.

const std = @import("std");

pub const drivers = @import("drivers.zig");

/// Pure-Zig PostgreSQL driver (no libpq).
pub const pq = drivers.postgres;

pub const db = @import("orm/db.zig");
pub const logger = @import("orm/logger.zig");
pub const migrator = @import("orm/migrator.zig");
pub const pool = @import("orm/pool.zig");
pub const observability = @import("orm/observability.zig");
pub const plugins = @import("orm/plugins.zig");
pub const qb = @import("orm/qb.zig");
pub const router = @import("orm/router.zig");
pub const schema = @import("orm/schema.zig");
pub const value = @import("orm/value.zig");
pub const naming = @import("orm/naming.zig");
pub const time = @import("orm/time.zig");

pub const Db = db.Db;
pub const Session = db.Session;
pub const Tx = db.Tx;
pub const OnConflict = db.OnConflict;
pub const RetryOptions = db.RetryOptions;
pub const Migrator = migrator.Migrator;
pub const PoolOptions = pool.Options;
pub const PoolStats = pool.PoolStats;
pub const DryRun = qb.DryRun;
pub const ModelRows = qb.ModelRows;
pub const Migration = migrator.Migration;
pub const SchemaChange = migrator.SchemaChange;
pub const IndexOptions = migrator.IndexOptions;
pub const Router = router.Router;
pub const Plugin = plugins.Plugin;
pub const PluginMetrics = plugins.Metrics;
pub const TracePlugin = plugins.Trace;
pub const AuditPlugin = plugins.Audit;
pub const CacheInvalidationPlugin = plugins.CacheInvalidation;
pub const EncryptionPlugin = plugins.Encryption;
pub const TenantFilterPlugin = plugins.TenantFilter;
pub const PaginationPlugin = plugins.Pagination;
pub const Json = value.Json;
pub const Uuid = value.Uuid;
pub const Decimal = value.Decimal;
pub const Inet = value.Inet;
pub const Cidr = value.Cidr;
pub const Range = value.Range;
pub const Geometry = value.Geometry;
pub const TextScalar = value.TextScalar;
pub const Bytes = value.Bytes;
pub const Logger = logger.Logger;
pub const Observer = observability.Observer;
pub const QueryEvent = observability.QueryEvent;
pub const Metrics = observability.Metrics;
pub const SlowQueryLog = observability.SlowQueryLog;
pub const ErrorClass = observability.ErrorClass;
pub const LogLevel = logger.LogLevel;
pub const Time = time.Time;
pub const ModelConfig = schema.ModelConfig;
pub const AssociationConfig = schema.AssociationConfig;
pub const Association = schema.Association;
pub const associations = schema.associations;
pub const AssociationOptions = schema.AssociationOptions;
pub const belongsTo = schema.belongsTo;
pub const hasOne = schema.hasOne;
pub const hasMany = schema.hasMany;
pub const manyToMany = schema.manyToMany;
pub const belongsToWith = schema.belongsToWith;
pub const hasOneWith = schema.hasOneWith;
pub const hasManyWith = schema.hasManyWith;
pub const manyToManyWith = schema.manyToManyWith;
pub const Model = value.Model;

pub const Error = pq.Error;

/// Starts a query builder: `z.query(User, db).where(...)...`
pub fn query(comptime T: type, d: *Db) *db.Query(T) {
    return Db.query(T, d);
}

/// Frees string memory of a decoded value/slice (see `Db.find` / `Query.all`).
/// Details (SQLSTATE, message, constraint, ...) of the most recent server
/// error observed through `db`.
pub fn lastError(d: *Db) ?pq.PgError {
    return d.pool.last_error;
}

/// Concurrency-safe snapshot of the last server error, deep-copied into
/// `arena`.
pub fn lastErrorCopy(d: *Db, arena: std.mem.Allocator) ?pq.PgError {
    return d.pool.lastErrorCopy(arena);
}

pub fn free(comptime T: type, v: T, gpa: std.mem.Allocator) void {
    value.freeValue(T, v, gpa);
}

pub fn freeSlice(comptime T: type, slice: []T, gpa: std.mem.Allocator) void {
    value.freeSlice(T, slice, gpa);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("orm/value.zig");
    _ = @import("orm/schema.zig");
    _ = @import("orm/time.zig");
    _ = @import("orm/naming.zig");
    _ = @import("orm/qb.zig");
    _ = @import("orm/pool.zig");
    _ = @import("orm/observability.zig");
    _ = @import("orm/db.zig");
}
