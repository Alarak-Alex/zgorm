//! MySQL/MariaDB driver facade.

const conn = @import("conn.zig");

pub const Error = conn.Error;
pub const SslMode = conn.SslMode;
pub const Config = conn.Config;
pub const PoolOptions = conn.PoolOptions;
pub const PoolStats = conn.PoolStats;
pub const Pool = conn.Pool;
pub const Result = conn.Result;
pub const Conn = conn.Conn;
pub const Orm = conn.Orm;
pub const Migrator = conn.Migrator;

pub const openPool = conn.openPool;
pub const orm = conn.orm;
pub const migrator = conn.migrator;
