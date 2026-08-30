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
