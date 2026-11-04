//! Hand-written subset of the SQLite C ABI.
//!
//! Zig 0.17 removed `@cImport`, and a translate-c step would require sqlite3.h
//! on every consumer's machine. The driver uses a small, stable slice of the
//! C API, so it is declared here and resolved by linking `libsqlite3`.
//! Types mirror the 64-bit Unix/macOS ABI in sqlite3.h.

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_LOCKED: c_int = 6;
pub const SQLITE_INTERRUPT: c_int = 9;
pub const SQLITE_CONSTRAINT: c_int = 19;
pub const SQLITE_MISMATCH: c_int = 20;
pub const SQLITE_RANGE: c_int = 25;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_CONSTRAINT_CHECK: c_int = SQLITE_CONSTRAINT | (1 << 8);
pub const SQLITE_CONSTRAINT_FOREIGNKEY: c_int = SQLITE_CONSTRAINT | (3 << 8);
pub const SQLITE_CONSTRAINT_NOTNULL: c_int = SQLITE_CONSTRAINT | (5 << 8);
pub const SQLITE_CONSTRAINT_PRIMARYKEY: c_int = SQLITE_CONSTRAINT | (6 << 8);
pub const SQLITE_CONSTRAINT_UNIQUE: c_int = SQLITE_CONSTRAINT | (8 << 8);

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_URI: c_int = 0x00000040;

pub const SQLITE_NULL: c_int = 5;

pub extern fn sqlite3_open_v2(
    filename: [*c]const u8,
    db: *?*sqlite3,
    flags: c_int,
    vfs: [*c]const u8,
) c_int;
pub extern fn sqlite3_close(db: *sqlite3) c_int;
pub extern fn sqlite3_errmsg(db: *sqlite3) [*c]const u8;
pub extern fn sqlite3_extended_errcode(db: *sqlite3) c_int;
pub extern fn sqlite3_extended_result_codes(db: *sqlite3, onoff: c_int) c_int;
pub extern fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
pub extern fn sqlite3_changes64(db: *sqlite3) i64;
pub extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;
pub extern fn sqlite3_interrupt(db: *sqlite3) void;
pub extern fn sqlite3_progress_handler(
    db: *sqlite3,
    n: c_int,
    callback: ?*const fn (?*anyopaque) callconv(.c) c_int,
    arg: ?*anyopaque,
) void;

pub extern fn sqlite3_prepare_v2(
    db: *sqlite3,
    sql: [*c]const u8,
    n_byte: c_int,
    stmt: *?*sqlite3_stmt,
    tail: ?*[*c]const u8,
) c_int;
pub extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;

pub extern fn sqlite3_bind_parameter_count(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_bind_int(stmt: *sqlite3_stmt, index: c_int, value: c_int) c_int;
pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, index: c_int, value: f64) c_int;
pub extern fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    index: c_int,
    text: [*c]const u8,
    len: c_int,
    destructor: Destructor,
) c_int;
pub extern fn sqlite3_bind_blob(
    stmt: *sqlite3_stmt,
    index: c_int,
    blob: ?*const anyopaque,
    len: c_int,
    destructor: Destructor,
) c_int;

pub extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_column_name(stmt: *sqlite3_stmt, index: c_int) [*c]const u8;
pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_column_blob(stmt: *sqlite3_stmt, index: c_int) ?*const anyopaque;
pub extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, index: c_int) c_int;
