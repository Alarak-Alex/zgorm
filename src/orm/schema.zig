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
    /// 1-D PostgreSQL arrays, decoded from the array-literal text format.
    int_array,
    uint_array,
    float_array,
    bool_array,
    text_array,
    /// `zorm.Json` wrapper <-> `jsonb` column.
    jsonb,
    /// `zorm.Bytes` wrapper <-> `bytea` column.
    bytes,
};

pub const Column = struct {
    name: []const u8, // SQL column identifier
    field_name: []const u8, // Zig struct field name (leaf; within `embed` when set)
    kind: FieldKind,
    /// Non-null when the column comes from an embedded model field
    /// (e.g. `base: zorm.Model`); holds the embedding field's name.
    embed: ?[]const u8 = null,
    /// DDL type, e.g. "bigint", "text".
    ddl_type: []const u8,
    is_optional: bool = false,
    is_pk: bool = false,
    /// True when the column is a serial/bigserial primary key (filled by the
    /// server on insert when the struct value is null).
    is_auto: bool = false,
};

/// One declared association (`belongs_to` or `has_many`).
pub const Assoc = struct {
    pub const Kind = enum { has_many, belongs_to };

    field_name: []const u8, // Zig field on this model
    model: type, // the associated model
    /// Column holding the foreign key:
    ///   has_many   -> column on the *associated* model pointing at this pk
    ///   belongs_to -> column on *this* model pointing at the associated pk
    foreign_key: []const u8,
    /// Field of the associated model used as the key (default `id`).
    primary_key: []const u8 = "id",
    kind: Kind,
};

pub const Table = struct {
    model: type,
    name: []const u8,
    columns: []const Column,
    /// Declared associations, excluded from `columns`.
    assocs: []const Assoc = &.{},
    pk_index: ?usize = null,
    created_at_index: ?usize = null,
    updated_at_index: ?usize = null,
    /// Index of the `deleted_at` column when the model declares one —
    /// enables soft-delete semantics (filter + stamped deletes).
    deleted_at_index: ?usize = null,
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

    /// True when the model declares a `deleted_at` column (soft delete).
    pub fn softDeletable(t: *const Table) bool {
        return t.deleted_at_index != null;
    }

    pub fn assoc(t: *const Table, comptime field_name: []const u8) ?Assoc {
        inline for (t.assocs) |a| {
            if (comptime std.mem.eql(u8, a.field_name, field_name)) return a;
        }
        return null;
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
        .int_array => "bigint[]",
        .uint_array => "bigint[]",
        .float_array => "double precision[]",
        .bool_array => "boolean[]",
        .text_array => "text[]",
        .jsonb => "jsonb",
        .bytes => "bytea",
    };
}

fn kindOf(comptime T: type) FieldKind {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed) FieldKind.integer else FieldKind.unsigned,
        .float => FieldKind.float,
        .bool => FieldKind.boolean,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) break :blk FieldKind.text;
                // Nested slices give multi-dimensional arrays; the DDL type
                // follows the innermost scalar kind. Optional elements are
                // unwrapped (NULL-able elements).
                const ChildElem = if (@typeInfo(ptr.child) == .optional)
                    @typeInfo(ptr.child).optional.child
                else
                    ptr.child;
                const inner = comptime kindOf(ChildElem);
                break :blk switch (inner) {
                    .integer, .int_array => FieldKind.int_array,
                    .unsigned, .uint_array => FieldKind.uint_array,
                    .float, .float_array => FieldKind.float_array,
                    .boolean, .bool_array => FieldKind.bool_array,
                    .text, .text_array => FieldKind.text_array,
                    else => @compileError("zorm: unsupported array element type " ++ @typeName(ptr.child)),
                };
            }
            @compileError("zorm: unsupported field type " ++ @typeName(T) ++
                " (only []const u8 / []u8 slices are supported for strings)");
        },
        .@"enum" => FieldKind.enum_,
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) break :blk FieldKind.time;
            if (@hasDecl(T, "__zorm_json")) break :blk FieldKind.jsonb;
            if (@hasDecl(T, "__zorm_bytes")) break :blk FieldKind.bytes;
            @compileError("zorm: unsupported struct field type " ++ @typeName(T) ++
                " (zorm.Time / zorm.Json / zorm.Bytes are the supported struct column types)");
        },
        else => @compileError("zorm: unsupported field type " ++ @typeName(T) ++
            " (supported: integers, floats, bool, []const u8, arrays, zorm.Time/Json/Bytes, enums, and optionals of those)"),
    };
}

/// True when the model (or any of its embedded models) has a field named
/// `id` — the default primary-key convention.
fn hasIdLeaf(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "id")) return true;
        const FT = f.type;
        if (comptime (@typeInfo(FT) == .@"struct" and @hasDecl(FT, "__zorm_embedded"))) {
            if (comptime @hasField(FT, "id")) return true;
        }
    }
    return false;
}

/// Builds one column from a model field (or a field of an embedded model,
/// when `embed` is non-null).
fn makeColumn(
    comptime embed: ?[]const u8,
    comptime field: std.builtin.Type.StructField,
    comptime fname: []const u8,
    comptime opts: anytype,
    comptime pk_field: ?[]const u8,
) Column {
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

    return .{
        .name = col_name,
        .field_name = fname,
        .kind = kind,
        .ddl_type = comptime ddlType(kind, Inner),
        .is_optional = is_optional,
        .is_pk = is_pk,
        .is_auto = is_auto,
        .embed = embed,
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
    else if (hasIdLeaf(T)) "id" else null;

    comptime var columns: []const Column = &.{};
    comptime var assocs: []const Assoc = &.{};
    comptime var pk_index: ?usize = null;
    comptime var created_at_index: ?usize = null;
    comptime var updated_at_index: ?usize = null;
    comptime var deleted_at_index: ?usize = null;
    // Column list index (struct fields can be skipped via `.ignore`).
    comptime var col_i: usize = 0;

    inline for (info.fields) |field| {
        const fname = field.name;

        // Embedded models (e.g. `base: zorm.Model`) flatten into columns.
        const FT_raw = field.type;
        if (@typeInfo(FT_raw) == .@"struct" and @hasDecl(FT_raw, "__zorm_embedded")) {
            inline for (@typeInfo(FT_raw).@"struct".fields) |sub| {
                const col = comptime makeColumn(fname, sub, sub.name, opts, pk_field);
                columns = columns ++ &[_]Column{col};
                if (col.is_pk) pk_index = col_i;
                if (comptime std.mem.eql(u8, col.name, "created_at")) created_at_index = col_i;
                if (comptime std.mem.eql(u8, col.name, "updated_at")) updated_at_index = col_i;
                if (comptime std.mem.eql(u8, col.name, "deleted_at")) deleted_at_index = col_i;
                col_i += 1;
            }
            continue;
        }

        // Association fields are handled by preload, not as columns.
        comptime var is_assoc = false;
        if (@hasField(@TypeOf(opts), "belongs_to")) {
            inline for (@typeInfo(@TypeOf(opts.belongs_to)).@"struct".fields) |af| {
                if (comptime std.mem.eql(u8, af.name, fname)) {
                    const cfg = @field(opts.belongs_to, af.name);
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = cfg.foreign_key,
                        .primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else "id",
                        .kind = .belongs_to,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (!is_assoc and @hasField(@TypeOf(opts), "has_many")) {
            inline for (@typeInfo(@TypeOf(opts.has_many)).@"struct".fields) |af| {
                if (comptime std.mem.eql(u8, af.name, fname)) {
                    const cfg = @field(opts.has_many, af.name);
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = cfg.foreign_key,
                        .primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else "id",
                        .kind = .has_many,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (is_assoc) continue;

        // Skip fields listed in `.ignore`.
        if (@hasField(@TypeOf(opts), "ignore")) {
            comptime var ignored = false;
            inline for (opts.ignore) |ig| {
                if (comptime std.mem.eql(u8, ig, fname)) ignored = true;
            }
            if (ignored) continue;
        }

        const col = comptime makeColumn(null, field, fname, opts, pk_field);
        columns = columns ++ &[_]Column{col};

        if (col.is_pk) pk_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "created_at")) created_at_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "updated_at")) updated_at_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "deleted_at")) deleted_at_index = col_i;
        col_i += 1;
    }

    // Detect duplicate column names (e.g. two embedded models colliding).
    inline for (columns, 0..) |a, i| {
        inline for (columns, 0..) |b, j| {
            if (j > i and comptime std.mem.eql(u8, a.name, b.name)) {
                @compileError("zorm: model " ++ @typeName(T) ++ " has duplicate column name '" ++ a.name ++ "'");
            }
        }
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
        .assocs = assocs,
        .pk_index = pk_index,
        .created_at_index = created_at_index,
        .updated_at_index = updated_at_index,
        .deleted_at_index = deleted_at_index,
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

const PostModel = struct {
    id: ?i64 = null,
    author_id: ?i64 = null,
    title: []const u8 = "",
};

const Author = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    posts: []PostModel = &.{},

    pub const zorm = .{
        .has_many = .{ .posts = .{ .model = PostModel, .foreign_key = "author_id" } },
    };
};

const Post2 = struct {
    id: ?i64 = null,
    author_id: ?i64 = null,
    title: []const u8 = "",
    author: ?Author = null,
    tags: []const []const u8 = &.{},
    meta: ?Json = null,

    pub const Json = struct {
        data: []const u8,
        pub const __zorm_json = true;
    };

    pub const zorm = .{
        .table = "posts",
        .belongs_to = .{ .author = .{ .model = Author, .foreign_key = "author_id" } },
    };
};

test "associations are excluded from columns and registered" {
    const at = comptime tableOf(Author);
    try testing.expectEqual(@as(usize, 2), at.columns.len); // id, name only
    try testing.expectEqual(@as(usize, 1), at.assocs.len);
    try testing.expectEqual(Assoc.Kind.has_many, at.assocs[0].kind);
    try testing.expectEqualStrings("posts", at.assocs[0].field_name);
    try testing.expectEqualStrings("author_id", at.assocs[0].foreign_key);
    try testing.expect(at.assoc("posts") != null);
    try testing.expect(at.assoc("name") == null);

    const pt = comptime tableOf(Post2);
    // id, author_id, title, tags (text[]), meta (jsonb)
    try testing.expectEqual(@as(usize, 5), pt.columns.len);
    try testing.expectEqualStrings("author", pt.assocs[0].field_name);
    try testing.expectEqual(Assoc.Kind.belongs_to, pt.assocs[0].kind);
    try testing.expectEqual(Author, pt.assocs[0].model);
    try testing.expectEqualStrings("text[]", pt.columns[3].ddl_type);
    try testing.expectEqualStrings("jsonb", pt.columns[4].ddl_type);
}

test "array and jsonb column kinds" {
    const pt = comptime tableOf(Post2);
    try testing.expectEqualStrings("text[]", pt.columns[3].ddl_type);
    const WithArrays = struct {
        id: ?i64 = null,
        scores: []const i64 = &.{},
        weights: ?[]const f64 = null,
        flags: []const bool = &.{},
    };
    const wt = comptime tableOf(WithArrays);
    try testing.expectEqual(@as(usize, 4), wt.columns.len);
    try testing.expectEqualStrings("bigint[]", wt.columns[1].ddl_type);
    try testing.expectEqualStrings("double precision[]", wt.columns[2].ddl_type);
    try testing.expectEqualStrings("boolean[]", wt.columns[3].ddl_type);
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

const EmbModel = struct {
    id: ?i64 = null,
    created_at: ?time_mod.Time = null,
    updated_at: ?time_mod.Time = null,

    pub const __zorm_embedded = true;
};

const EmbPost = struct {
    base: EmbModel,
    title: []const u8 = "",

    pub const zorm = .{ .table = "embedded_posts" };
};

test "embedded model fields flatten into columns" {
    const t = comptime tableOf(EmbPost);
    try testing.expectEqual(@as(usize, 4), t.columns.len); // id, created_at, updated_at, title
    try testing.expectEqualStrings("id", t.columns[0].name);
    try testing.expectEqualStrings("base", t.columns[0].embed.?);
    try testing.expect(t.columns[0].is_auto);
    try testing.expectEqualStrings("created_at", t.columns[1].name);
    try testing.expectEqualStrings("updated_at", t.columns[2].name);
    try testing.expectEqualStrings("title", t.columns[3].name);
    try testing.expect(t.columns[3].embed == null);
}
