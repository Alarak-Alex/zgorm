//! Driver-neutral errors, parameters, results, and server diagnostics.

const std = @import("std");

pub const Error = error{
    ConnectionFailed,
    ConnectionClosed,
    AuthenticationFailed,
    TlsUnsupported,
    ProtocolViolation,
    OpenFailed,
    InvalidDsn,
    InvalidConfig,
    PoolClosed,
    InvalidQuery,
    InvalidModel,
    InvalidColumn,
    UnsupportedType,
    MigrationChecksumMismatch,
    DirtyMigration,
    NullValue,
    TypeMismatch,
    QueryFailed,
    HookAborted,
    OutOfMemory,
    AcquireTimeout,
    QueryTimeout,
    QueryCanceled,
    NetworkReadTimeout,
    NetworkWriteTimeout,
    WriteFailed,
    TransactionTimeout,
    TransactionFinished,
    OptimisticLockConflict,
    UniqueViolation,
    ForeignKeyViolation,
    NotNullViolation,
    CheckViolation,
    SerializationFailure,
    DeadlockDetected,
    UndefinedTable,
    UndefinedColumn,
    SyntaxError,
    InsufficientPrivilege,
    NumericValueOutOfRange,
    InvalidTextRepresentation,
};
pub const SslMode = enum {
    disable,
    require,
    verify_ca,
    verify_full,
};

pub const ServerError = struct {
    severity: []const u8 = "",
    code: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    hint: []const u8 = "",
    position: []const u8 = "",
    schema: []const u8 = "",
    table: []const u8 = "",
    column: []const u8 = "",
    constraint: []const u8 = "",
};

pub const QueryEvent = struct {
    sql: []const u8,
    duration_ns: u128,
    affected_rows: i64 = 0,
    returned_rows: usize = 0,
    err: ?Error = null,
};

pub const Observer = struct {
    context: ?*anyopaque = null,
    on_query: ?*const fn (?*anyopaque, QueryEvent) void = null,

    pub fn emit(observer: Observer, event: QueryEvent) void {
        if (observer.on_query) |callback| callback(observer.context, event);
    }
};

/// Driver-neutral encoded parameter. PostgreSQL uses `oid` as a type OID;
/// MySQL and SQLite infer the concrete type from `kind`.
pub const Param = struct {
    pub const Kind = enum { null_, boolean, signed, unsigned, float, text, bytes, time, json };

    oid: u32 = 0,
    format: u16 = 0,
    kind: Kind = .text,
    is_null: bool = false,
    data: []const u8 = "",

    canonical: []const u8 = "",
    pub fn nullParam(oid: u32) Param {
        return .{ .oid = oid, .format = 1, .kind = .null_, .is_null = true };
    }
};

/// Writes lowercase hex encoding of `bytes` using a lookup table and bulk
/// writes, avoiding per-byte formatting overhead on text/bytes hot paths.
pub fn writeHex(w: *std.Io.Writer, bytes: []const u8) error{OutOfMemory}!void {
    const digits = "0123456789abcdef";
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < bytes.len) {
        const n: usize = @min(bytes.len - i, buf.len / 2);
        for (bytes[i..][0..n], 0..) |b, j| {
            buf[j * 2] = digits[b >> 4];
            buf[j * 2 + 1] = digits[b & 0xF];
        }
        w.writeAll(buf[0 .. n * 2]) catch return error.OutOfMemory;
        i += n;
    }
}

test "writeHex matches per-byte formatting" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeHex(&aw.writer, "\x00\x0f\xde\xad\xff");
    try std.testing.expectEqualStrings("000fdeadff", aw.writer.buffered());
}

test "writeHex large input" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const big = try std.testing.allocator.alloc(u8, 17 * 1024 * 1024);
    defer std.testing.allocator.free(big);
    @memset(big, 0xab);
    try writeHex(&aw.writer, big);
    try std.testing.expectEqual(big.len * 2, aw.writer.buffered().len);
}

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    columns: []Column = &.{},
    rows: []Row = &.{},
    cmd_tag: []const u8 = "",
    affected: i64 = 0,
    last_insert_id: u64 = 0,

    pub const Column = struct {
        name: []const u8,
        type_oid: u32 = 0,
        format: u16 = 0,
    };

    pub const Row = []const ?[]const u8;

    pub fn deinit(r: *Result) void {
        const child = r.arena.child_allocator;
        r.arena.deinit();
        child.destroy(r.arena);
    }

    pub fn colIndex(r: *const Result, name: []const u8) ?usize {
        for (r.columns, 0..) |column, i| {
            if (std.mem.eql(u8, column.name, name)) return i;
        }
        return null;
    }
};
