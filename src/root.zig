//! zorm — a GORM-inspired ORM for Zig, PostgreSQL first.
//!
//! Library root module. See README.md for a quick tour.

const std = @import("std");

/// Pure-Zig PostgreSQL driver (no libpq).
pub const pq = @import("pq.zig");

pub const db = @import("orm/db.zig");
pub const logger = @import("orm/logger.zig");
pub const migrator = @import("orm/migrator.zig");
pub const pool = @import("orm/pool.zig");
pub const qb = @import("orm/qb.zig");
pub const schema = @import("orm/schema.zig");
pub const value = @import("orm/value.zig");
pub const naming = @import("orm/naming.zig");
pub const time = @import("orm/time.zig");

pub const Db = db.Db;
pub const Session = db.Session;
pub const Tx = db.Tx;
pub const Migrator = migrator.Migrator;
pub const Migration = migrator.Migration;
pub const Json = value.Json;
pub const Bytes = value.Bytes;
pub const Logger = logger.Logger;
pub const LogLevel = logger.LogLevel;
pub const Time = time.Time;
pub const Model = value.Model;

pub const Error = pq.Error;

/// Starts a query builder: `z.query(db, User).where(...)...`
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
    _ = @import("orm/db.zig");
}
