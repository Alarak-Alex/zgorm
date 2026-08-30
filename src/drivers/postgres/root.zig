//! Pure-Zig PostgreSQL driver.

const std = @import("std");

pub const proto = @import("proto.zig");
pub const scram = @import("scram.zig");
pub const dsn = @import("dsn.zig");
const conn_mod = @import("conn.zig");

pub const Conn = conn_mod.Conn;
pub const Error = conn_mod.Error;
pub const PgError = conn_mod.PgError;
pub const Param = conn_mod.Param;
pub const Result = conn_mod.Result;
pub const Rows = conn_mod.Rows;
pub const Config = conn_mod.Config;
pub const SslMode = conn_mod.SslMode;
pub const TxnStatus = conn_mod.TxnStatus;

/// Parses a DSN into a `Config`. Slices of the returned config point either
/// into `text` or into memory allocated from `arena`.
pub fn parseDsn(arena: std.mem.Allocator, text: []const u8) Error!Config {
    return dsn.parse(arena, text);
}

test {
    std.testing.refAllDecls(@This());
}
