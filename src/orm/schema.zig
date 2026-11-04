//! Comptime model reflection: turns a plain Zig struct into table metadata.
//!
//! A model is any struct whose fields use the supported column types:
//!   integers, floats, bool, `[]const u8` / `[]u8` (text), `zgorm.Time`,
//!   enums (stored as their tag name), and optionals of any of those.
//!
//! Optional conventions (all overridable via a `pub const zgorm` declaration):
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
//!     pub const zgorm = .{
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

/// Typed model options for editor completion.
pub const ModelConfig = struct {
    table: []const u8 = "",
    unique: []const []const u8 = &.{},
    indexes: []const []const u8 = &.{},
    associations: []const associations = &.{},
};

pub const FieldKind = enum {
    integer,
    unsigned,
    float,
    boolean,
    text,
    time,
    enum_,
    int_array,
    uint_array,
    float_array,
    bool_array,
    text_array,
    jsonb,
    bytes,
    custom,
};

const InferredAssoc = struct {
    model: type,
    kind: Assoc.Kind,
};

fn inferredAssoc(comptime T: type) ?InferredAssoc {
    return switch (@typeInfo(T)) {
        .optional => |o| switch (@typeInfo(o.child)) {
            .@"struct" => if (@hasDecl(o.child, "__zgorm_time") or
                @hasDecl(o.child, "__zgorm_json") or @hasDecl(o.child, "__zgorm_bytes"))
                null
            else
                .{ .model = o.child, .kind = .belongs_to },
            else => null,
        },
        .pointer => |p| if (p.size == .slice and @typeInfo(p.child) == .@"struct")
            .{ .model = p.child, .kind = .has_many }
        else
            null,
        else => null,
    };
}

fn modelForeignKey(comptime owner: type, comptime related: type, comptime kind: Assoc.Kind) []const u8 {
    const model = if (kind == .belongs_to) related else owner;
    const model_name = @typeName(model);
    const dot = std.mem.lastIndexOfScalar(u8, model_name, '.') orelse 0;
    return naming.toSnakeCase(model_name[dot + 1 ..]) ++ "_id";
}

pub const Column = struct {
    name: []const u8, // SQL column identifier
    field_name: []const u8, // Zig struct field name (leaf; within `embed` when set)
    kind: FieldKind,
    /// Non-null when the column comes from an embedded model field
    /// (e.g. `base: zgorm.Model`); holds the embedding field's name.
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
    pub const Kind = enum { belongs_to, has_one, has_many, many_to_many };

    field_name: []const u8, // Zig field on this model
    model: type, // the associated model
    ///   has_many   -> column on the *associated* model pointing at this pk
    ///   belongs_to -> column on *this* model pointing at the associated pk
    foreign_key: []const u8,
    /// Field of the associated model used as the key (default `id`).
    primary_key: []const u8 = "id",
    foreign_keys: []const []const u8 = &.{},
    primary_keys: []const []const u8 = &.{},
    join_table: []const u8 = "",
    join_foreign_key: []const u8 = "",
    join_association_key: []const u8 = "",
    association_key: []const u8 = "id",
    polymorphic_type: []const u8 = "",
    polymorphic_value: []const u8 = "",
    cascade_delete: bool = false,
    kind: Kind,
};
/// Typed association entry used by `ModelConfig`.
pub const AssociationConfig = struct {
    field: []const u8 = "",
    model: type,
    kind: Assoc.Kind,
    foreign_key: []const u8 = "",
    primary_key: []const u8 = "id",
    foreign_keys: []const []const u8 = &.{},
    primary_keys: []const []const u8 = &.{},
    join_table: []const u8 = "",
    join_foreign_key: []const u8 = "",
    join_association_key: []const u8 = "",
    association_key: []const u8 = "id",
    polymorphic_type: []const u8 = "",
    polymorphic_value: []const u8 = "",
    cascade_delete: bool = false,
};

/// Explicitly named association type for fully typed array literals.
pub const Association = AssociationConfig;

/// Short name for one typed association entry.
pub const associations = AssociationConfig;

/// Shared options template for typed association constructors.
pub const AssociationOptions = struct {
    foreign_key: []const u8 = "",
    primary_key: []const u8 = "id",
    foreign_keys: []const []const u8 = &.{},
    primary_keys: []const []const u8 = &.{},
    join_table: []const u8 = "",
    join_foreign_key: []const u8 = "",
    join_association_key: []const u8 = "",
    association_key: []const u8 = "id",
    polymorphic_type: []const u8 = "",
    polymorphic_value: []const u8 = "",
    cascade_delete: bool = false,
};

fn associationConfig(
    comptime field: []const u8,
    comptime M: type,
    comptime kind: Assoc.Kind,
    options: AssociationOptions,
) AssociationConfig {
    return .{
        .field = field,
        .model = M,
        .kind = kind,
        .foreign_key = options.foreign_key,
        .primary_key = options.primary_key,
        .foreign_keys = options.foreign_keys,
        .primary_keys = options.primary_keys,
        .join_table = options.join_table,
        .join_foreign_key = options.join_foreign_key,
        .join_association_key = options.join_association_key,
        .association_key = options.association_key,
        .polymorphic_type = options.polymorphic_type,
        .polymorphic_value = options.polymorphic_value,
        .cascade_delete = options.cascade_delete,
    };
}

pub fn belongsTo(comptime M: type) AssociationConfig {
    return associationConfig("", M, .belongs_to, .{});
}

pub fn belongsToWith(comptime M: type, options: AssociationOptions) AssociationConfig {
    return associationConfig("", M, .belongs_to, options);
}

pub fn hasOne(comptime M: type) AssociationConfig {
    return associationConfig("", M, .has_one, .{});
}

pub fn hasOneWith(comptime M: type, options: AssociationOptions) AssociationConfig {
    return associationConfig("", M, .has_one, options);
}

pub fn hasMany(comptime M: type) AssociationConfig {
    return associationConfig("", M, .has_many, .{});
}

pub fn hasManyWith(comptime M: type, options: AssociationOptions) AssociationConfig {
    return associationConfig("", M, .has_many, options);
}

pub fn manyToMany(comptime M: type) AssociationConfig {
    return associationConfig("", M, .many_to_many, .{});
}

pub fn manyToManyWith(comptime M: type, options: AssociationOptions) AssociationConfig {
    return associationConfig("", M, .many_to_many, options);
}

pub const Table = struct {
    model: type,
    name: []const u8,
    columns: []const Column,
    /// Declared associations, excluded from `columns`.
    assocs: []const Assoc = &.{},
    pk_index: ?usize = null,
    /// All primary-key column indexes; length > 1 denotes a composite key.
    pk_indexes: []const usize = &.{},
    created_at_index: ?usize = null,
    updated_at_index: ?usize = null,
    /// Integer field used for optimistic locking.
    version_index: ?usize = null,
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

    pub fn version(t: *const Table) ?Column {
        const i = t.version_index orelse return null;
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
        .custom => T.zgormDdl,
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
                    else => @compileError("zgorm: unsupported array element type " ++ @typeName(ptr.child)),
                };
            }
            @compileError("zgorm: unsupported field type " ++ @typeName(T) ++
                " (only []const u8 / []u8 slices are supported for strings)");
        },
        .@"enum" => if (@hasDecl(T, "zgormEncode") and @hasDecl(T, "zgormDecode") and @hasDecl(T, "zgormDdl")) FieldKind.custom else FieldKind.enum_,
        .@"struct" => blk: {
            if (@hasDecl(T, "__zgorm_time")) break :blk FieldKind.time;
            if (@hasDecl(T, "__zgorm_json")) break :blk FieldKind.jsonb;
            if (@hasDecl(T, "__zgorm_bytes")) break :blk FieldKind.bytes;
            if (@hasDecl(T, "zgormEncode") and @hasDecl(T, "zgormDecode") and @hasDecl(T, "zgormDdl"))
                break :blk FieldKind.custom;
            @compileError("zgorm: unsupported struct field type " ++ @typeName(T) ++
                " (zgorm.Time / zgorm.Json / zgorm.Bytes are the supported struct column types)");
        },
        else => @compileError("zgorm: unsupported field type " ++ @typeName(T) ++
            " (supported: integers, floats, bool, []const u8, arrays, zgorm.Time/Json/Bytes, enums, and optionals of those)"),
    };
}

/// True when the model (or any of its embedded models) has a field named
/// `id` — the default primary-key convention.
fn hasIdLeaf(comptime T: type) bool {
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |fname, FT| {
        if (comptime std.mem.eql(u8, fname, "id")) return true;
        if (comptime (@typeInfo(FT) == .@"struct" and @hasDecl(FT, "__zgorm_embedded"))) {
            if (comptime @hasField(FT, "id")) return true;
        }
    }
    return false;
}

/// Builds one column from a model field (or a field of an embedded model,
/// when `embed` is non-null).
fn makeColumn(
    comptime embed: ?[]const u8,
    comptime field_type: type,
    comptime fname: []const u8,
    comptime opts: anytype,
    comptime pk_field: ?[]const u8,
) Column {
    const FT = field_type;
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
        if (@hasField(@TypeOf(opts), "primary_keys")) {
            inline for (opts.primary_keys) |name| {
                if (std.mem.eql(u8, name, fname)) break :blk true;
            }
            break :blk false;
        }
        if (pk_field) |name| break :blk std.mem.eql(u8, name, fname);
        break :blk false;
    };
    // Auto-increment: integer primary key stored as an optional (null ->
    // let the sequence fill it).
    const is_auto = is_pk and !@hasField(@TypeOf(opts), "primary_keys") and is_optional and (kind == .integer or kind == .unsigned);

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

    // Model-level options from `pub const zgorm`, if present.
    const has_opts = @hasDecl(T, "zgorm");
    const opts = if (has_opts) T.zgorm else .{};

    const table_name: []const u8 = if (@hasField(@TypeOf(opts), "table") and opts.table.len > 0)
        opts.table
    else blk: {
        const tn: []const u8 = @typeName(T);
        const dot = std.mem.lastIndexOfScalar(u8, tn, '.') orelse 0;
        break :blk naming.toSnakeCase(tn[dot + 1 ..]);
    };

    const pk_field: ?[]const u8 = if (@hasField(@TypeOf(opts), "primary_key"))
        opts.primary_key
    else if (hasIdLeaf(T)) "id" else null;

    const version_field: ?[]const u8 = if (@hasField(@TypeOf(opts), "version"))
        opts.version
    else if (@hasField(T, "version"))
        "version"
    else
        null;

    comptime var columns: []const Column = &.{};
    comptime var assocs: []const Assoc = &.{};
    comptime var pk_indexes: []const usize = &.{};
    comptime var created_at_index: ?usize = null;
    comptime var updated_at_index: ?usize = null;
    comptime var deleted_at_index: ?usize = null;
    comptime var version_index: ?usize = null;
    // Column list index (struct fields can be skipped via `.ignore`).
    comptime var col_i: usize = 0;

    inline for (info.field_names, info.field_types) |fname, FT_raw| {

        // Embedded models (e.g. `base: zgorm.Model`) flatten into columns.
        if (@typeInfo(FT_raw) == .@"struct" and @hasDecl(FT_raw, "__zgorm_embedded")) {
            inline for (@typeInfo(FT_raw).@"struct".field_names, @typeInfo(FT_raw).@"struct".field_types) |sub_name, sub_type| {
                const col = comptime makeColumn(fname, sub_type, sub_name, opts, pk_field);
                columns = columns ++ &[_]Column{col};
                if (col.is_pk) pk_indexes = pk_indexes ++ &[_]usize{col_i};
                if (comptime std.mem.eql(u8, col.name, "created_at")) created_at_index = col_i;
                if (comptime std.mem.eql(u8, col.name, "updated_at")) updated_at_index = col_i;
                if (comptime std.mem.eql(u8, col.name, "deleted_at")) deleted_at_index = col_i;
                if (version_field) |name| {
                    if (comptime std.mem.eql(u8, col.field_name, name)) version_index = col_i;
                }
                col_i += 1;
            }
            continue;
        }

        comptime var is_assoc = false;
        const relation_name = fname ++ "_relation";
        if (@hasDecl(T, relation_name)) {
            const cfg = @field(T, relation_name);
            const foreign_key = if (cfg.foreign_key.len > 0) cfg.foreign_key else modelForeignKey(T, cfg.model, cfg.kind);
            const foreign_keys = if (cfg.foreign_keys.len > 0) cfg.foreign_keys else &.{foreign_key};
            const primary_keys = if (cfg.primary_keys.len > 0) cfg.primary_keys else &.{cfg.primary_key};
            assocs = assocs ++ &[_]Assoc{.{
                .field_name = fname,
                .model = cfg.model,
                .foreign_key = foreign_key,
                .primary_key = cfg.primary_key,
                .foreign_keys = foreign_keys,
                .primary_keys = primary_keys,
                .join_table = cfg.join_table,
                .join_foreign_key = cfg.join_foreign_key,
                .join_association_key = cfg.join_association_key,
                .association_key = cfg.association_key,
                .polymorphic_type = cfg.polymorphic_type,
                .polymorphic_value = cfg.polymorphic_value,
                .cascade_delete = cfg.cascade_delete,
                .kind = cfg.kind,
            }};
            is_assoc = true;
        }
        if (@hasField(@TypeOf(opts), "associations")) {
            inline for (opts.associations) |cfg| {
                if (comptime std.mem.eql(u8, cfg.field, fname)) {
                    const foreign_key = if (cfg.foreign_key.len > 0) cfg.foreign_key else modelForeignKey(T, cfg.model, cfg.kind);
                    const foreign_keys = if (cfg.foreign_keys.len > 0) cfg.foreign_keys else &.{foreign_key};
                    const primary_keys = if (cfg.primary_keys.len > 0) cfg.primary_keys else &.{cfg.primary_key};
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = foreign_key,
                        .primary_key = cfg.primary_key,
                        .foreign_keys = foreign_keys,
                        .primary_keys = primary_keys,
                        .join_table = cfg.join_table,
                        .join_foreign_key = cfg.join_foreign_key,
                        .join_association_key = cfg.join_association_key,
                        .association_key = cfg.association_key,
                        .polymorphic_type = cfg.polymorphic_type,
                        .polymorphic_value = cfg.polymorphic_value,
                        .cascade_delete = cfg.cascade_delete,
                        .kind = cfg.kind,
                    }};
                    is_assoc = true;
                }
            }
        }

        // Association fields are handled by preload, not as columns.
        if (@hasField(@TypeOf(opts), "belongs_to")) {
            inline for (@typeInfo(@TypeOf(opts.belongs_to)).@"struct".field_names) |af_name| {
                if (comptime std.mem.eql(u8, af_name, fname)) {
                    const cfg = @field(opts.belongs_to, af_name);
                    const foreign_key = if (@hasField(@TypeOf(cfg), "foreign_key")) cfg.foreign_key else cfg.foreign_keys[0];
                    const primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else if (@hasField(@TypeOf(cfg), "primary_keys")) cfg.primary_keys[0] else "id";
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = foreign_key,
                        .primary_key = primary_key,
                        .foreign_keys = if (@hasField(@TypeOf(cfg), "foreign_keys")) cfg.foreign_keys else &.{foreign_key},
                        .primary_keys = if (@hasField(@TypeOf(cfg), "primary_keys")) cfg.primary_keys else &.{primary_key},
                        .kind = .belongs_to,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (!is_assoc and @hasField(@TypeOf(opts), "has_one")) {
            inline for (@typeInfo(@TypeOf(opts.has_one)).@"struct".field_names) |af_name| {
                if (comptime std.mem.eql(u8, af_name, fname)) {
                    const cfg = @field(opts.has_one, af_name);
                    const primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else "id";
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = cfg.foreign_key,
                        .primary_key = primary_key,
                        .foreign_keys = &.{cfg.foreign_key},
                        .primary_keys = &.{primary_key},
                        .polymorphic_type = if (@hasField(@TypeOf(cfg), "polymorphic_type")) cfg.polymorphic_type else "",
                        .polymorphic_value = if (@hasField(@TypeOf(cfg), "polymorphic_value")) cfg.polymorphic_value else "",
                        .cascade_delete = if (@hasField(@TypeOf(cfg), "cascade_delete")) cfg.cascade_delete else false,
                        .kind = .has_one,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (!is_assoc and @hasField(@TypeOf(opts), "has_many")) {
            inline for (@typeInfo(@TypeOf(opts.has_many)).@"struct".field_names) |af_name| {
                if (comptime std.mem.eql(u8, af_name, fname)) {
                    const cfg = @field(opts.has_many, af_name);
                    const foreign_key = if (@hasField(@TypeOf(cfg), "foreign_key")) cfg.foreign_key else cfg.foreign_keys[0];
                    const primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else if (@hasField(@TypeOf(cfg), "primary_keys")) cfg.primary_keys[0] else "id";
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = foreign_key,
                        .primary_key = primary_key,
                        .foreign_keys = if (@hasField(@TypeOf(cfg), "foreign_keys")) cfg.foreign_keys else &.{foreign_key},
                        .primary_keys = if (@hasField(@TypeOf(cfg), "primary_keys")) cfg.primary_keys else &.{primary_key},
                        .polymorphic_type = if (@hasField(@TypeOf(cfg), "polymorphic_type")) cfg.polymorphic_type else "",
                        .polymorphic_value = if (@hasField(@TypeOf(cfg), "polymorphic_value")) cfg.polymorphic_value else "",
                        .cascade_delete = if (@hasField(@TypeOf(cfg), "cascade_delete")) cfg.cascade_delete else false,
                        .kind = .has_many,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (!is_assoc and @hasField(@TypeOf(opts), "many_to_many")) {
            inline for (@typeInfo(@TypeOf(opts.many_to_many)).@"struct".field_names) |af_name| {
                if (comptime std.mem.eql(u8, af_name, fname)) {
                    const cfg = @field(opts.many_to_many, af_name);
                    const primary_key = if (@hasField(@TypeOf(cfg), "primary_key")) cfg.primary_key else "id";
                    const association_key = if (@hasField(@TypeOf(cfg), "association_key")) cfg.association_key else "id";
                    assocs = assocs ++ &[_]Assoc{.{
                        .field_name = fname,
                        .model = cfg.model,
                        .foreign_key = cfg.foreign_key,
                        .primary_key = primary_key,
                        .foreign_keys = &.{cfg.foreign_key},
                        .primary_keys = &.{primary_key},
                        .join_table = cfg.join_table,
                        .join_foreign_key = cfg.join_foreign_key,
                        .join_association_key = cfg.join_association_key,
                        .association_key = association_key,
                        .cascade_delete = if (@hasField(@TypeOf(cfg), "cascade_delete")) cfg.cascade_delete else false,
                        .kind = .many_to_many,
                    }};
                    is_assoc = true;
                }
            }
        }
        if (!is_assoc) if (inferredAssoc(FT_raw)) |inferred| {
            const foreign_key = modelForeignKey(T, inferred.model, inferred.kind);
            assocs = assocs ++ &[_]Assoc{.{
                .field_name = fname,
                .model = inferred.model,
                .foreign_key = foreign_key,
                .foreign_keys = &.{foreign_key},
                .primary_keys = &.{"id"},
                .kind = inferred.kind,
            }};
            is_assoc = true;
        };
        if (is_assoc) continue;

        // Skip fields listed in `.ignore`.
        if (@hasField(@TypeOf(opts), "ignore")) {
            comptime var ignored = false;
            inline for (opts.ignore) |ig| {
                if (comptime std.mem.eql(u8, ig, fname)) ignored = true;
            }
            if (ignored) continue;
        }

        const col = comptime makeColumn(null, FT_raw, fname, opts, pk_field);
        columns = columns ++ &[_]Column{col};

        if (col.is_pk) pk_indexes = pk_indexes ++ &[_]usize{col_i};
        if (comptime std.mem.eql(u8, col.name, "created_at")) created_at_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "updated_at")) updated_at_index = col_i;
        if (comptime std.mem.eql(u8, col.name, "deleted_at")) deleted_at_index = col_i;
        if (version_field) |name| {
            if (comptime std.mem.eql(u8, col.field_name, name)) version_index = col_i;
        }
        col_i += 1;
    }

    // Detect duplicate column names (e.g. two embedded models colliding).
    inline for (columns, 0..) |a, i| {
        inline for (columns, 0..) |b, j| {
            if (j > i and comptime std.mem.eql(u8, a.name, b.name)) {
                @compileError("zgorm: model " ++ @typeName(T) ++ " has duplicate column name '" ++ a.name ++ "'");
            }
        }
    }

    if (@hasField(@TypeOf(opts), "primary_keys") and pk_indexes.len != opts.primary_keys.len)
        @compileError("zgorm: one or more configured primary-key fields do not exist on " ++ @typeName(T));
    const pk_index: ?usize = if (pk_indexes.len == 1) pk_indexes[0] else null;

    if (version_field != null and version_index == null)
        @compileError("zgorm: configured version field does not exist on " ++ @typeName(T));
    if (version_index) |index| {
        const version_col = columns[index];
        if (version_col.kind != .integer and version_col.kind != .unsigned)
            @compileError("zgorm: version field must be an integer on " ++ @typeName(T));
        if (version_col.is_optional)
            @compileError("zgorm: version field must be non-optional on " ++ @typeName(T));
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
        .pk_indexes = pk_indexes,
        .created_at_index = created_at_index,
        .updated_at_index = updated_at_index,
        .deleted_at_index = deleted_at_index,
        .version_index = version_index,
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

    pub const zgorm = .{
        .table = "custom_users",
        .primary_key = "uid",
        .unique = .{"email"},
        .indexes = .{"lastSeen"},
    };
};

const TypedOptions = struct {
    id: ?i64 = null,
    email: []const u8 = "",
    pub const zgorm = ModelConfig{
        .table = "typed_options",
        .unique = &.{"email"},
    };
};

const InferredChild = struct {
    id: ?i64 = null,
    person_id: ?i64 = null,
};

const InferredParent = struct {
    id: ?i64 = null,
    children: []InferredChild = &.{},
    pub const children_relation = hasManyWith(InferredChild, AssociationOptions{
        .foreign_key = "person_id",
    });
};

test "typed options and convention associations" {
    const configured = comptime tableOf(TypedOptions);
    try testing.expectEqualStrings("typed_options", configured.name);
    try testing.expectEqualStrings("email", configured.unique[0]);

    const inferred = comptime tableOf(InferredParent);
    try testing.expectEqual(@as(usize, 1), inferred.assocs.len);
    try testing.expectEqual(Assoc.Kind.has_many, inferred.assocs[0].kind);
    try testing.expectEqual(InferredChild, inferred.assocs[0].model);
    try testing.expectEqualStrings("person_id", inferred.assocs[0].foreign_key);
}

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

    pub const zgorm = .{
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
        pub const __zgorm_json = true;
    };

    pub const zgorm = .{
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
    deleted_at: ?time_mod.Time = null,

    pub const __zgorm_embedded = true;
};

const EmbPost = struct {
    base: EmbModel,
    title: []const u8 = "",

    pub const zgorm = .{ .table = "embedded_posts" };
};

test "embedded model fields flatten into columns" {
    const t = comptime tableOf(EmbPost);
    try testing.expectEqual(@as(usize, 5), t.columns.len); // id, three timestamps, title
    try testing.expectEqualStrings("id", t.columns[0].name);
    try testing.expectEqualStrings("base", t.columns[0].embed.?);
    try testing.expect(t.columns[0].is_auto);
    try testing.expectEqualStrings("created_at", t.columns[1].name);
    try testing.expectEqualStrings("updated_at", t.columns[2].name);
    try testing.expectEqualStrings("deleted_at", t.columns[3].name);
    for (t.columns[1..4]) |col| try testing.expectEqualStrings("timestamptz", col.ddl_type);
    try testing.expectEqualStrings("title", t.columns[4].name);
    try testing.expect(t.columns[4].embed == null);
}
