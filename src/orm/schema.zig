//! Comptime model reflection: turns a plain Zig struct into table metadata.
//!
//! A model is any struct whose fields use the supported column types:
//!   integers, floats, bool, `[]const u8` / `[]u8` (text), `zorm.Time`,
//!   enums (stored as their tag name), and optionals of any of those.
//!
//! Optional conventions (all overridable via a `pub const zorm` declaration):
//!   - table name: snake_case of the struct name
//!   - primary key: the field named `id`
//!   - column name: snake_case of the field name
//!   - `created_at` / `updated_at`: auto-filled timestamps
//!
//! ```zig
//! pub const User = struct {
//!     id: ?i64 = null,
//!     email: []const u8 = "",
//!     isActive: bool = true,
//!
//!     pub const zorm = .{
//!         .table = "users",
//!         .unique = .{"email"},
//!         // .primary_key = "email", .ignore = .{.cache}, .columns = .{.isActive = "active"},
//!     };
//! };
//! ```

const std = @import("std");
const naming = @import("naming.zig");
const time_mod = @import("time.zig");

pub const Time = time_mod.Time;

pub const FieldKind = enum {
    integer,
    unsigned,
    float,
    boolean,
    text,
    time,
    enum_,
};

pub const Column = struct {
    name: []const u8, // SQL column identifier
    field_name: []const u8, // Zig struct field name
    kind: FieldKind,
    /// DDL type, e.g. "bigint", "text".
    ddl_type: []const u8,
    is_optional: bool = false,
    is_pk: bool = false,
    /// True when the column is a serial/bigserial primary key (filled by the
    /// server on insert when the struct value is null).
    is_auto: bool = false,
};

pub const Table = struct {
    model: type,
    name: []const u8,
    columns: []const Column,
    pk_index: ?usize = null,
    created_at_index: ?usize = null,
    updated_at_index: ?usize = null,
    /// Columns with a UNIQUE single-column index.
    unique: []const []const u8 = &.{},
    /// Columns with a plain single-column index.
    indexes: []const []const u8 = &.{},

    pub fn pk(t: *const Table) ?Column {
        const i = t.pk_index orelse return null;
        return t.columns[i];
    }

    pub fn hasColumn(t: *const Table, name: []const u8) bool {
        for (t.columns) |c| {
            if (std.mem.eql(u8, c.name, name)) return true;
        }
        return false;
    }
};

fn ddlType(comptime kind: FieldKind, comptime T: type) []const u8 {
    return switch (kind) {
        .integer => switch (@bitSizeOf(T)) {
            8 => "smallint",
            16 => "smallint",
            32 => "integer",
            else => "bigint",
        },
        .unsigned => switch (@bitSizeOf(T)) {
            8 => "smallint",
            16 => "integer",
            32 => "bigint",
            else => "bigint",
        },
        .float => if (@bitSizeOf(T) <= 32) "real" else "double precision",
        .boolean => "boolean",
        .text => "text",
        .time => "timestamptz",
        .enum_ => "text",
    };
}

fn kindOf(comptime T: type) FieldKind {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) FieldKind.integer else FieldKind.unsigned,
        .float => FieldKind.float,
        .bool => FieldKind.boolean,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) break :blk FieldKind.text;
            @compileError("zorm: unsupported field type " ++ @typeName(T) ++
                " (only []const u8 / []u8 slices are supported for strings)");
        },
        .@"enum" => FieldKind.enum_,
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) break :blk FieldKind.time;
            @compileError("zorm: unsupported struct field type " ++ @typeName(T) ++
                " (zorm.Time is the only supported struct column type)");
        },
        else => @compileError("zorm: unsupported field type " ++ @typeName(T) ++
            " (supported: integers, floats, bool, []const u8, zorm.Time, enums, and optionals of those)"),
    };
}

/// Evaluates the table metadata for model `T` at comptime.
pub fn tableOf(comptime T: type) Table {
    @setEvalBranchQuota(20000);
    const info = @typeInfo(T).@"struct";

    // Model-level options from `pub const zorm`, if present.
    const has_opts = @hasDecl(T, "zorm");
    const opts = if (has_opts) T.zorm else .{};

    const table_name: []const u8 = if (@hasField(@TypeOf(opts), "table"))
        opts.table
    else blk: {
        const tn: []const u8 = @typeName(T);
        const dot = std.mem.lastIndexOfScalar(u8, tn, '.') orelse 0;
        break :blk naming.toSnakeCase(tn[dot + 1 ..]);
    };

    const pk_field: ?[]const u8 = if (@hasField(@TypeOf(opts), "primary_key"))
        opts.primary_key
    else if (@hasField(T, "id")) "id" else null;

    comptime var columns: []const Column = &.{};
    comptime var pk_index: ?usize = null;
    comptime var created_at_index: ?usize = null;
    comptime var updated_at_index: ?usize = null;
    // Column list index (struct fields can be skipped via `.ignore`).
    comptime var col_i: usize = 0;

    inline for (info.fields) |field| {
        const fname = field.name;

        // Skip fields listed in `.ignore`.
        if (@hasField(@TypeOf(opts), "ignore")) {
            comptime var ignored = false;
            inline for (opts.ignore) |ig| {
                if (comptime std.mem.eql(u8, ig, fname)) ignored = true;
            }
            if (ignored) continue;
        }

        const FT = field.type;
        const is_optional = @typeInfo(FT) == .optional;
        const Inner = if (is_optional) @typeInfo(FT).optional.child else FT;

        var col_name: []const u8 = naming.toSnakeCase(fname);
        if (@hasField(@TypeOf(opts), "columns")) {
            const cols_opts = opts.columns;
            if (@hasField(@TypeOf(cols_opts), fname)) {
                col_name = @field(cols_opts, fname);
            }
        }

        const kind = comptime kindOf(Inner);
        const is_pk = blk: {
            if (pk_field) |p| break :blk std.mem.eql(u8, p, fname);
            break :blk false;
        };
        // Auto-increment: integer primary key stored as an optional (null ->
        // let the sequence fill it).
        const is_auto = is_pk and is_optional and (kind == .integer or kind == .unsigned);

        const col = Column{
            .name = col_name,
            .field_name = fname,
            .kind = kind,
            .ddl_type = comptime ddlType(kind, Inner),
            .is_optional = is_optional,
            .is_pk = is_pk,
            .is_auto = is_auto,
        };
        columns = columns ++ &[_]Column{col};

        if (is_pk) pk_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "created_at")) created_at_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "updated_at")) updated_at_index = col_i;
        col_i += 1;
    }

    comptime var unique: []const []const u8 = &.{};
    if (@hasField(@TypeOf(opts), "unique")) {
        inline for (opts.unique) |u| unique = unique ++ &[_][]const u8{u};
    }
    comptime var indexes: []const []const u8 = &.{};
    if (@hasField(@TypeOf(opts), "indexes")) {
        inline for (opts.indexes) |ix| indexes = indexes ++ &[_][]const u8{ix};
    }

    return .{
        .model = T,
        .name = table_name,
        .columns = columns,
        .pk_index = pk_index,
        .created_at_index = created_at_index,
        .updated_at_index = updated_at_index,
        .unique = unique,
        .indexes = indexes,
    };
}

const testing = std.testing;

const Simple = struct {
    id: ?i64 = null,
    userName: []const u8 = "",
    age: i32 = 0,
    balance: f64 = 0,
    isActive: bool = true,
};

const Custom = struct {
    uid: ?i64 = null,
    email: []const u8 = "",
    metadata: ?[]const u8 = null,
    lastSeen: ?Time = null,

    pub const zorm = .{
        .table = "custom_users",
        .primary_key = "uid",
        .unique = .{"email"},
        .indexes = .{"lastSeen"},
    };
};

test "table reflection with conventions" {
    const t = comptime tableOf(Simple);
    try testing.expectEqualStrings("simple", t.name);
    try testing.expectEqual(@as(usize, 5), t.columns.len);
    try testing.expect(t.pk_index != null);
    try testing.expect(t.columns[t.pk_index.?].is_auto);
    try testing.expectEqualStrings("user_name", t.columns[1].name);
    try testing.expectEqual(FieldKind.text, t.columns[1].kind);
    try testing.expectEqualStrings("text", t.columns[1].ddl_type);
    try testing.expectEqualStrings("integer", t.columns[2].ddl_type);
    try testing.expectEqualStrings("double precision", t.columns[3].ddl_type);
    try testing.expectEqualStrings("boolean", t.columns[4].ddl_type);
    try testing.expect(t.created_at_index == null);
}

test "table reflection with options" {
    const t = comptime tableOf(Custom);
    try testing.expectEqualStrings("custom_users", t.name);
    try testing.expectEqual(@as(usize, 4), t.columns.len);
    try testing.expectEqualStrings("uid", t.columns[t.pk_index.?].field_name);
    try testing.expect(t.columns[t.pk_index.?].is_auto);
    try testing.expect(t.columns[2].is_optional);
    try testing.expectEqualStrings("timestamptz", t.columns[3].ddl_type);
    try testing.expectEqual(@as(usize, 1), t.unique.len);
    try testing.expectEqualStrings("email", t.unique[0]);
    try testing.expectEqualStrings("last_seen", t.columns[3].name);
}
