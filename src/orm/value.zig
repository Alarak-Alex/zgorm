//! Value codec: Zig values -> query parameters, and text result cells ->
//! typed Zig values. All decoding happens against PostgreSQL's text format.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const time_mod = @import("time.zig");
const schema = @import("schema.zig");

pub const Time = time_mod.Time;
pub const Error = pq.Error;
const Param = pq.Param;
pub const DecodeError = error{ NullValue, TypeMismatch, OutOfMemory };

fn hasCodec(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => @hasDecl(T, "zormEncode") and @hasDecl(T, "zormDecode"),
        else => false,
    };
}

pub fn TextScalar(comptime ddl: []const u8) type {
    return struct {
        data: []const u8,
        pub const zormDdl = ddl;

        pub fn zormEncode(self: @This(), _: std.mem.Allocator) Error!Param {
            return .{ .oid = 0, .format = 0, .data = self.data };
        }

        pub fn zormDecode(
            data: []const u8,
            _: u32,
            _: u16,
            gpa: std.mem.Allocator,
        ) DecodeError!@This() {
            return .{ .data = gpa.dupe(u8, data) catch return error.OutOfMemory };
        }
    };
}

pub const Uuid = TextScalar("uuid");
pub const Decimal = TextScalar("numeric");
pub const Inet = TextScalar("inet");
pub const Cidr = TextScalar("cidr");
pub const Range = TextScalar("numrange");
pub const Geometry = TextScalar("geometry");

/// Converts a comptime-typed value into a driver parameter. Scalars are
/// pre-encoded in PostgreSQL's binary format (with an explicit type OID so
/// the server never has to infer); arrays, JSON and enums are sent in text
/// format. All scratch memory comes from `arena`.
pub fn toParam(value: anytype, arena: std.mem.Allocator) Error!Param {
    const T = @TypeOf(value);
    if (comptime hasCodec(T)) return value.zormEncode(arena);
    var num_buf: [64]u8 = undefined;
    return switch (@typeInfo(T)) {
        .null => Param.nullParam(proto.Oid.text),
        .bool => mkBinary(.{ .oid = proto.Oid.bool_, .data = if (value) "\x01" else "\x00" }),
        .int => blk: {
            // PostgreSQL has no unsigned types; declare int8 (binary i64).
            const v = std.math.cast(i64, value) orelse break :blk numericParam(
                std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch unreachable,
                arena,
            );
            break :blk try intParam(v, arena);
        },
        .comptime_int => blk: {
            if (std.math.cast(i64, value)) |v| break :blk try intParam(v, arena);
            break :blk numericParam(
                std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch unreachable,
                arena,
            );
        },
        .float, .comptime_float => blk: {
            const v: f64 = @floatCast(value);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(v), .big);
            break :blk mkBinary(.{
                .oid = proto.Oid.float8,
                .data = arena.dupe(u8, &buf) catch return error.OutOfMemory,
            });
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => blk: {
                if (ptr.child == u8) {
                    // Text binary format is the raw UTF-8 bytes.
                    break :blk mkBinary(.{ .oid = proto.Oid.text, .data = value });
                }
                break :blk try arrayParam(ptr.child, value, arena);
            },
            .one => blk: {
                const C = ptr.child;
                switch (@typeInfo(C)) {
                    // String literals (`*const [N:0]u8`): the pointee is
                    // static, so slice off the sentinel without copying.
                    .array => |ai| {
                        if (ai.child == u8 and ai.sentinel_ptr != null) {
                            break :blk mkBinary(.{ .oid = proto.Oid.text, .data = value[0..ai.len] });
                        }
                    },
                    .@"struct" => |si| {
                        if (!si.is_tuple) {
                            if (@hasDecl(C, "__zorm_json")) {
                                break :blk mkText(.{ .oid = proto.Oid.jsonb, .data = value.data });
                            }
                            if (@hasDecl(C, "__zorm_bytes")) {
                                break :blk mkBinary(.{ .oid = proto.Oid.bytea, .data = value.data });
                            }
                        }
                    },
                    else => {},
                }
                break :blk try toParam(value.*, arena);
            },
            else => error.TypeMismatch,
        },
        .array => |ai| blk: {
            if (ai.child == u8) {
                // A by-value u8 array parameter lives in this frame; copy out.
                const text = std.mem.sliceTo(&value, 0);
                break :blk mkText(.{ .oid = proto.Oid.text, .data = arena.dupe(u8, text) catch return error.OutOfMemory });
            }
            break :blk try arrayParam(ai.child, &value, arena);
        },
        .@"enum", .enum_literal => mkText(.{ .oid = proto.Oid.text, .data = @tagName(value) }),
        .optional => blk: {
            if (value) |v| {
                break :blk try toParam(v, arena);
            }
            break :blk Param.nullParam(nullOidOf(@TypeOf(value)));
        },
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) {
                // PostgreSQL receives its native binary instant; other
                // drivers use the canonical timestamp text.
                var buf: [8]u8 = undefined;
                const pg_micros = value.micros - pg_epoch_us;
                std.mem.writeInt(u64, &buf, @bitCast(pg_micros), .big);
                var text_buf: [Time.pg_text_len]u8 = undefined;
                break :blk mkBinary(.{
                    .oid = proto.Oid.timestamptz,
                    .canonical = arena.dupe(u8, value.toPgText(&text_buf)) catch return error.OutOfMemory,
                    .data = arena.dupe(u8, &buf) catch return error.OutOfMemory,
                });
            }
            if (@hasDecl(T, "__zorm_json")) {
                break :blk mkText(.{ .oid = proto.Oid.jsonb, .kind = .json, .data = value.data });
            }
            if (@hasDecl(T, "__zorm_bytes")) {
                break :blk mkBinary(.{ .oid = proto.Oid.bytea, .kind = .bytes, .data = value.data });
            }
            @compileError("zorm: unsupported parameter type " ++ @typeName(T));
        },
        else => @compileError("zorm: unsupported parameter type " ++ @typeName(T)),
    };
}

pub const proto = @import("../drivers/postgres/proto.zig");

/// PostgreSQL internal epoch: 2000-01-01T00:00:00Z, in Unix microseconds.
pub const pg_epoch_us: i64 = 946_684_800_000_000;

/// GORM-style embedded base model. A field of this type inside a model is
/// flattened into `id`, `created_at`, `updated_at`, and `deleted_at` columns:
///
/// ```zig
/// pub const Post = struct {
///     base: z.Model,          // id, created_at, updated_at, deleted_at
///     title: []const u8 = "",
/// };
/// ```
pub const Model = struct {
    id: ?i64 = null,
    created_at: ?Time = null,
    updated_at: ?Time = null,
    deleted_at: ?Time = null,

    pub const __zorm_embedded = true;
};

/// The leaf value type a column maps to (resolves through embedded models).
pub fn columnFieldType(comptime T: type, comptime col: schema.Column) type {
    if (col.embed) |parent| {
        return fieldOf(fieldOf(T, parent), col.field_name);
    }
    return fieldOf(T, col.field_name);
}

fn fieldOf(comptime T: type, comptime name: []const u8) type {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return f.type;
    }
    @compileError("zorm: model " ++ @typeName(T) ++ " has no field " ++ name);
}

/// Reads a column's leaf value (supports embedded models).
pub fn getColumn(m: anytype, comptime col: schema.Column) columnFieldType(@TypeOf(m.*), col) {
    if (col.embed) |parent| {
        return @field(@field(m.*, parent), col.field_name);
    }
    return @field(m.*, col.field_name);
}

/// Writes a column's leaf value (supports embedded models).
pub fn setColumn(m: anytype, comptime col: schema.Column, v: columnFieldType(@TypeOf(m.*), col)) void {
    if (col.embed) |parent| {
        @field(@field(m.*, parent), col.field_name) = v;
    } else {
        @field(m.*, col.field_name) = v;
    }
}

/// Wrapper mapping a raw-JSON field to a `jsonb` column.
pub const Json = struct {
    data: []const u8,

    pub const __zorm_json = true;
};

/// Wrapper mapping a raw-binary field to a `bytea` column.
pub const Bytes = struct {
    data: []const u8,

    pub const __zorm_bytes = true;
};

fn mkBinary(p: Param) Param {
    var r = p;
    r.format = 1;
    r.kind = switch (r.oid) {
        proto.Oid.bool_ => .boolean,
        proto.Oid.int8 => .signed,
        proto.Oid.float8 => .float,
        proto.Oid.timestamptz => .time,
        proto.Oid.bytea => .bytes,
        proto.Oid.jsonb => .json,
        else => .text,
    };
    return r;
}

fn mkText(p: Param) Param {
    var r = p;
    r.format = 0;
    r.kind = switch (r.oid) {
        proto.Oid.numeric => .signed,
        proto.Oid.json, proto.Oid.jsonb => .json,
        proto.Oid.bytea => .bytes,
        proto.Oid.timestamptz => .time,
        else => .text,
    };
    return r;
}

fn intParam(v: i64, arena: std.mem.Allocator) Error!Param {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .big);
    return .{
        .oid = proto.Oid.int8,
        .format = 1,
        .kind = .signed,
        .data = arena.dupe(u8, &buf) catch return error.OutOfMemory,
    };
}

fn numericParam(digits: []const u8, arena: std.mem.Allocator) Error!Param {
    return .{
        .oid = proto.Oid.numeric,
        .format = 0,
        .kind = .signed,
        .data = try arena.dupe(u8, digits),
    };
}

fn nullOidOf(comptime OptionalT: type) u32 {
    const Inner = @typeInfo(OptionalT).optional.child;
    return oidOf(Inner);
}

/// The type OID a parameter of `T` is declared with.
pub fn oidOf(comptime T: type) u32 {
    return switch (@typeInfo(T)) {
        .bool => proto.Oid.bool_,
        .int, .comptime_int => proto.Oid.int8,
        .float, .comptime_float => proto.Oid.float8,
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) proto.Oid.text else arrayOid(ptr.child),
            .one => blk: {
                const C = ptr.child;
                switch (@typeInfo(C)) {
                    .array => |ai| if (ai.child == u8) break :blk proto.Oid.text,
                    .@"struct" => |si| {
                        if (!si.is_tuple) {
                            if (@hasDecl(C, "__zorm_json")) break :blk proto.Oid.jsonb;
                            if (@hasDecl(C, "__zorm_bytes")) break :blk proto.Oid.bytea;
                        }
                    },
                    else => {},
                }
                break :blk oidOf(C);
            },
            else => proto.Oid.text,
        },
        .array => |ai| if (ai.child == u8) proto.Oid.text else arrayOid(ai.child),
        .@"enum", .enum_literal => proto.Oid.text,
        .optional => |oi| oidOf(oi.child),
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) break :blk proto.Oid.timestamptz;
            if (@hasDecl(T, "__zorm_json")) break :blk proto.Oid.jsonb;
            if (@hasDecl(T, "__zorm_bytes")) break :blk proto.Oid.bytea;
            break :blk proto.Oid.text;
        },
        else => proto.Oid.text,
    };
}

pub fn arrayOid(comptime Elem: type) u32 {
    // Optional elements unwrap to their scalar OID; nested slices recurse
    // (the element OID of a sub-array equals the element type's OID).
    const E = if (@typeInfo(Elem) == .optional) @typeInfo(Elem).optional.child else Elem;
    return switch (@typeInfo(E)) {
        .bool => proto.Oid.bool_array,
        .int, .comptime_int => proto.Oid.int8_array,
        .float, .comptime_float => proto.Oid.float8_array,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) break :blk proto.Oid.text_array;
                break :blk arrayOid(ptr.child);
            }
            break :blk proto.Oid.text_array;
        },
        .array => |ai| blk: {
            if (ai.child == u8) break :blk proto.Oid.text_array;
            break :blk arrayOid(ai.child);
        },
        else => proto.Oid.text_array,
    };
}

/// Encodes args into the driver parameter list. Tuples and slices expand
/// element-wise; any other value becomes a single parameter.
pub fn argsToParams(args: anytype, arena: std.mem.Allocator) Error![]Param {
    const T = @TypeOf(args);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (!info.is_tuple) {
                const single = try arena.alloc(Param, 1);
                single[0] = try toParam(args, arena);
                return single;
            }
            const params = try arena.alloc(Param, info.fields.len);
            inline for (info.fields, 0..) |f, i| {
                params[i] = try toParam(@field(args, f.name), arena);
            }
            return params;
        },
        .pointer => |p| {
            // Slices of values, and pointers to arrays/tuples, expand
            // element-wise (whereIn passes values this way).
            if (p.size == .slice and p.child != u8) {
                const params = try arena.alloc(Param, args.len);
                for (args, 0..) |v, i| {
                    params[i] = try toParam(v, arena);
                }
                return params;
            }
            if (p.size == .one) {
                const C = p.child;
                switch (@typeInfo(C)) {
                    .array => |ai| {
                        const params = try arena.alloc(Param, ai.len);
                        inline for (0..ai.len) |i| {
                            params[i] = try toParam(args[i], arena);
                        }
                        return params;
                    },
                    .@"struct" => |ci| {
                        if (ci.is_tuple) {
                            const params = try arena.alloc(Param, ci.fields.len);
                            inline for (ci.fields, 0..) |f, i| {
                                params[i] = try toParam(@field(args, f.name), arena);
                            }
                            return params;
                        }
                    },
                    else => {},
                }
            }
            const single = try arena.alloc(Param, 1);
            single[0] = try toParam(args, arena);
            return single;
        },
        else => {
            const single = try arena.alloc(Param, 1);
            single[0] = try toParam(args, arena);
            return single;
        },
    }
}

// -------------------------------------------------- array text codec

/// Encodes a 1-D slice as a PostgreSQL array literal, e.g. `{1,2,3}`.
fn arrayParam(comptime Elem: type, slice: []const Elem, arena: std.mem.Allocator) Error!Param {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeByte('{') catch return error.OutOfMemory;
    for (slice, 0..) |elem, i| {
        if (i > 0) w.writeByte(',') catch return error.OutOfMemory;
        writeArrayElement(Elem, elem, w) catch return error.OutOfMemory;
    }
    w.writeByte('}') catch return error.OutOfMemory;
    return .{
        .oid = arrayOid(Elem),
        .format = 0,
        .data = aw.writer.buffered(),
    };
}

fn writeArrayElement(comptime E: type, elem: E, w: *std.Io.Writer) !void {
    switch (@typeInfo(E)) {
        .optional => if (elem) |v| {
            try writeArrayElement(@typeInfo(E).optional.child, v, w);
        } else try w.writeAll("NULL"),
        .int, .comptime_int => try w.print("{d}", .{elem}),
        .float, .comptime_float => try w.print("{d}", .{elem}),
        .bool => try w.writeAll(if (elem) "t" else "f"),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writeQuotedArrayText(w, elem);
                return;
            }
            if (ptr.size == .slice and ptr.child != u8) {
                // Nested (multi-dimensional) sub-array.
                try w.writeByte('{');
                for (elem, 0..) |sub, i| {
                    if (i > 0) try w.writeByte(',');
                    try writeArrayElement(ptr.child, sub, w);
                }
                try w.writeByte('}');
                return;
            }
            @compileError("zorm: unsupported array element type " ++ @typeName(E));
        },
        .array => |ai| {
            if (ai.child == u8) {
                try writeQuotedArrayText(w, std.mem.sliceTo(&elem, 0));
            } else @compileError("zorm: unsupported array element type " ++ @typeName(E));
        },
        else => @compileError("zorm: unsupported array element type " ++ @typeName(E)),
    }
}

/// Text array elements need quoting when they contain separators, braces,
/// backslashes, quotes, whitespace, are empty, or could read as NULL.
fn writeQuotedArrayText(w: *std.Io.Writer, s: []const u8) !void {
    const needs_quotes = s.len == 0 or std.ascii.eqlIgnoreCase(s, "null") or blk: {
        for (s) |ch| {
            switch (ch) {
                '{', '}', '"', '\\', ',', ' ', '\t', '\n', '\r' => break :blk true,
                else => {},
            }
        }
        break :blk false;
    };
    if (!needs_quotes) {
        try w.writeAll(s);
        return;
    }
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try w.writeByte('\\');
        try w.writeByte(ch);
    }
    try w.writeByte('"');
}

/// Parses a PostgreSQL array literal (any dimension) into nested slices
/// matching `Elem`'s shape; the innermost element type may be optional
/// (NULL elements). Strings are duplicated with `gpa`.
pub fn parseArrayText(comptime Elem: type, text: []const u8, gpa: std.mem.Allocator) DecodeError![]Elem {
    if (text.len < 2 or text[0] != '{' or text[text.len - 1] != '}')
        return error.TypeMismatch;
    const inner = text[1 .. text.len - 1];
    if (inner.len == 0) return gpa.alloc(Elem, 0) catch return error.OutOfMemory;

    var items: std.ArrayList(Elem) = .empty;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);

    var i: usize = 0;
    while (true) {
        // Skip unquoted whitespace between elements.
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) i += 1;

        raw.clearRetainingCapacity();
        var quoted = false;
        var ever_quoted = false;
        var escaped = false;
        var element_present = false;
        var brace_depth: usize = 0;
        while (i < inner.len) {
            const ch = inner[i];
            if (quoted) {
                if (escaped) {
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    quoted = false;
                } else {
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                }
            } else switch (ch) {
                '"' => {
                    quoted = true;
                    ever_quoted = true;
                    element_present = true;
                },
                '{' => {
                    brace_depth += 1;
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                    element_present = true;
                },
                '}' => {
                    if (brace_depth > 0) brace_depth -= 1;
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                    element_present = true;
                },
                ',' => {
                    if (brace_depth > 0) {
                        // Comma inside a nested sub-array.
                        raw.append(gpa, ch) catch return error.OutOfMemory;
                        element_present = true;
                    } else {
                        i += 1;
                        break;
                    }
                },
                else => {
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                    element_present = true;
                },
            }
            i += 1;
        }
        items.append(gpa, try decodeArrayElement(Elem, raw.items, ever_quoted, element_present, gpa)) catch return error.OutOfMemory;
        if (i >= inner.len) break;
    }
    return items.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

fn nullElement(comptime E: type) DecodeError!E {
    switch (@typeInfo(E)) {
        .optional => return null,
        else => return error.NullValue,
    }
}

fn decodeArrayElement(comptime E: type, raw: []const u8, quoted: bool, present: bool, gpa: std.mem.Allocator) DecodeError!E {
    const is_null_text = !quoted and std.ascii.eqlIgnoreCase(raw, "null");
    if ((!present and raw.len == 0) or is_null_text) {
        // Absent/unquoted-NULL elements resolve to null when the element
        // type is optional, and are rejected otherwise.
        return nullElement(E);
    }
    // A sub-array (multi-dimensional arrays): only for unquoted `{...}` and
    // only when the element type is itself a slice.
    const elem_info = @typeInfo(E);
    const elem_is_slice = elem_info == .pointer and elem_info.pointer.size == .slice;
    const elem_is_nested = elem_is_slice and elem_info.pointer.child != u8;
    if (!quoted and raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}') {
        if (!elem_is_nested) return error.TypeMismatch;
        const inner_list = try parseArrayText(elem_info.pointer.child, raw, gpa);
        return inner_list;
    }
    switch (@typeInfo(E)) {
        .optional => |oi| {
            const inner = try decodeArrayElement(oi.child, raw, quoted, present, gpa);
            return @as(E, inner);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (comptime ptr.child == u8) {
                    return gpa.dupe(u8, raw) catch return error.OutOfMemory;
                }
                // Non-string scalar elements must appear as sub-arrays.
                return error.TypeMismatch;
            }
            @compileError("zorm: unsupported array element type " ++ @typeName(E));
        },
        .int => {
            const trimmed = if (quoted) raw else std.mem.trim(u8, raw, " \t");
            return std.fmt.parseInt(E, trimmed, 10) catch error.TypeMismatch;
        },
        .float => {
            const trimmed = if (quoted) raw else std.mem.trim(u8, raw, " \t");
            return std.fmt.parseFloat(E, trimmed) catch error.TypeMismatch;
        },
        .bool => {
            const trimmed = if (quoted) raw else std.mem.trim(u8, raw, " \t");
            if (std.ascii.eqlIgnoreCase(trimmed, "t") or std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
            if (std.ascii.eqlIgnoreCase(trimmed, "f") or std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
            return error.TypeMismatch;
        },
        .array => |ai| {
            if (ai.child == u8) {
                if (!present) return nullElement(E) catch unreachable;
                return gpa.dupe(u8, raw) catch return error.OutOfMemory;
            }
            @compileError("zorm: unsupported array element type " ++ @typeName(E));
        },
        else => @compileError("zorm: unsupported array element type " ++ @typeName(E)),
    }
}

/// Decodes one result cell into `T`. `format` selects the wire encoding:
/// 0 = text, 1 = binary. Returned strings/arrays are duplicated with `gpa`.
pub fn decodeCell(comptime T: type, cell: ?[]const u8, type_oid: u32, format: u16, gpa: std.mem.Allocator) DecodeError!T {
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (cell == null) return null;
        return try decodeCell(Child, cell, type_oid, format, gpa);
    }
    const data = cell orelse return error.NullValue;
    if (comptime hasCodec(T)) {
        return T.zormDecode(data, type_oid, format, gpa) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.TypeMismatch,
        };
    }
    return switch (format) {
        1 => decodeBinary(T, data, type_oid, gpa),
        else => decodeText(T, data, type_oid, gpa),
    };
}

/// Reads a big-endian two's-complement signed integer of `byte_len` bytes.
fn readSigned(data: []const u8) DecodeError!i64 {
    var v: u64 = 0;
    if (data.len == 0 or data.len > 8) return error.TypeMismatch;
    for (data) |b| v = (v << 8) | b;
    // Sign-extend from the actual width.
    const shift: u6 = @intCast(64 - @as(u64, data.len) * 8);
    const signed: i64 = @bitCast(v);
    return (signed << @intCast(shift)) >> @intCast(shift);
}

fn readUnsigned(data: []const u8) DecodeError!u64 {
    var v: u64 = 0;
    if (data.len == 0 or data.len > 8) return error.TypeMismatch;
    for (data) |b| v = (v << 8) | b;
    return v;
}

/// Decodes a binary-format cell into `T`. Supports the same type set as the
/// text path: integers, floats, bools, strings, arrays (any dimension),
/// enums, Time, Json and Bytes.
pub fn decodeBinary(comptime T: type, data: []const u8, type_oid: u32, gpa: std.mem.Allocator) DecodeError!T {
    return switch (@typeInfo(T)) {
        .optional => |oi| blk: {
            const inner = try decodeBinary(oi.child, data, type_oid, gpa);
            break :blk @as(T, inner);
        },
        .int => |info| blk: {
            const v: i64 = if (info.signedness == .signed)
                try readSigned(data)
            else
                @bitCast(try readUnsigned(data));
            break :blk std.math.cast(T, v) orelse return error.TypeMismatch;
        },
        .float => blk: {
            switch (data.len) {
                4 => {
                    const f: f32 = @bitCast(@as(u32, @intCast(std.mem.readInt(u32, data[0..4], .big))));
                    break :blk switch (@typeInfo(T).float.bits) {
                        32 => f,
                        else => @as(T, @floatCast(f)),
                    };
                },
                8 => {
                    const f: f64 = @bitCast(std.mem.readInt(u64, data[0..8], .big));
                    break :blk switch (@typeInfo(T).float.bits) {
                        64 => f,
                        else => @as(T, @floatCast(f)),
                    };
                },
                else => return error.TypeMismatch,
            }
        },
        .bool => if (data.len != 1)
            error.TypeMismatch
        else switch (data[0]) {
            0 => false,
            1 => true,
            else => error.TypeMismatch,
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    // Text-family OIDs are identical in binary format. bytea
                    // is raw bytes too (no hex escaping in binary).
                    break :blk gpa.dupe(u8, data) catch return error.OutOfMemory;
                }
                break :blk try decodeBinaryArray(T, data, type_oid, gpa);
            }
            @compileError("zorm: unsupported binary result type " ++ @typeName(T));
        },
        .@"enum" => blk: {
            const tag = std.meta.stringToEnum(T, data) orelse return error.TypeMismatch;
            break :blk tag;
        },
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) {
                if (data.len != 8) return error.TypeMismatch;
                const micros = std.mem.readInt(i64, data[0..8], .big);
                break :blk T{ .micros = micros + pg_epoch_us };
            }
            if (@hasDecl(T, "__zorm_json")) {
                // jsonb binary = 1-byte version (1) + json text; json = text.
                if (type_oid == pq.proto.Oid.jsonb) {
                    if (data.len == 0 or data[0] != 1) return error.TypeMismatch;
                    break :blk T{ .data = gpa.dupe(u8, data[1..]) catch return error.OutOfMemory };
                }
                break :blk T{ .data = gpa.dupe(u8, data) catch return error.OutOfMemory };
            }
            if (@hasDecl(T, "__zorm_bytes")) {
                break :blk T{ .data = gpa.dupe(u8, data) catch return error.OutOfMemory };
            }
            @compileError("zorm: unsupported binary result type " ++ @typeName(T));
        },
        else => @compileError("zorm: unsupported binary result type " ++ @typeName(T)),
    };
}

/// Decodes PostgreSQL's binary array format into nested Zig slices matching
/// the target depth (1-D `[]Elem`, 2-D `[][]Elem`, ...). The innermost
/// element type may be optional (NULL elements). `SliceT` is the target
/// slice type itself (e.g. `[][]i64` for a 2-D bigint[]).
fn decodeBinaryArray(
    comptime SliceT: type,
    data: []const u8,
    type_oid: u32,
    gpa: std.mem.Allocator,
) DecodeError!SliceT {
    _ = type_oid;
    if (data.len < 12) return error.TypeMismatch;
    const ndim = std.mem.readInt(i32, data[0..4], .big);
    if (ndim < 0) return error.TypeMismatch;
    if (ndim == 0) return gpa.alloc(@typeInfo(SliceT).pointer.child, 0) catch return error.OutOfMemory;

    const depth = depthOf(SliceT);
    if (ndim != depth or ndim > 8) return error.TypeMismatch;

    var dims_buf: [8]usize = undefined;
    var off: usize = 12;
    for (0..@intCast(ndim)) |d| {
        if (off + 8 > data.len) return error.TypeMismatch;
        const n = std.mem.readInt(i32, data[off..][0..4], .big);
        _ = std.mem.readInt(i32, data[off + 4 ..][0..4], .big); // lower bound
        if (n < 0) return error.TypeMismatch;
        dims_buf[d] = @intCast(n);
        off += 8;
    }
    var reader = ArrayBinReader{ .data = data, .off = off };
    const out = try decodeBinaryDims(SliceT, &reader, dims_buf[0..@intCast(ndim)], gpa);
    if (reader.off != data.len) {
        freeValue(SliceT, out, gpa);
        return error.TypeMismatch;
    }
    return out;
}

const ArrayBinReader = struct {
    data: []const u8,
    off: usize,

    fn readLen(r: *ArrayBinReader) DecodeError!i32 {
        if (r.off + 4 > r.data.len) return error.TypeMismatch;
        const n = std.mem.readInt(i32, r.data[r.off..][0..4], .big);
        r.off += 4;
        return n;
    }

    fn readBytes(r: *ArrayBinReader, n: usize) DecodeError![]const u8 {
        if (r.off + n > r.data.len) return error.TypeMismatch;
        const s = r.data[r.off..][0..n];
        r.off += n;
        return s;
    }
};

/// Number of array dimensions represented by the slice type `S`.
/// Text arrays (`[]const []const u8` and deeper u8 nesting) are always
/// treated as 1-D `text[]` leaves; multi-dimensional arrays are only
/// supported for numeric/boolean element types.
fn depthOf(comptime S: type) usize {
    const info = @typeInfo(S);
    if (info != .pointer or info.pointer.size != .slice) return 0;
    const Child = info.pointer.child;
    if (Child == u8) return 1;
    const child_depth = depthOf(Child);
    if (child_depth == 1 and isTextSlice(Child)) return 1; // text[] leaf
    return 1 + child_depth;
}

fn isTextSlice(comptime S: type) bool {
    const info = @typeInfo(S);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child == u8;
}

/// Recursively materializes one dimension level of a binary array. `dims`
/// holds the remaining dimension lengths; when one remains, the slice child
/// is the (optionally optional) element type.
fn decodeBinaryDims(
    comptime SliceT: type,
    reader: *ArrayBinReader,
    dims: []const usize,
    gpa: std.mem.Allocator,
) DecodeError!SliceT {
    const Child = @typeInfo(SliceT).pointer.child;
    const out = gpa.alloc(Child, dims[0]) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |item| freeValue(Child, item, gpa);
        gpa.free(out);
    }
    if (comptime depthOf(SliceT) == 1) {
        // Innermost level: length-prefixed elements (or NULL when optional).
        for (out) |*slot| {
            const len = try reader.readLen();
            if (len < 0) {
                if (@typeInfo(Child) != .optional) return error.NullValue;
                slot.* = null;
            } else {
                const bytes = try reader.readBytes(@intCast(len));
                slot.* = try decodeBinary(Child, bytes, 0, gpa);
            }
            initialized += 1;
        }
        return out;
    }
    for (out) |*slot| {
        slot.* = try decodeBinaryDims(Child, reader, dims[1..], gpa);
        initialized += 1;
    }
    return out;
}

fn decodeText(comptime T: type, text: []const u8, type_oid: u32, gpa: std.mem.Allocator) DecodeError!T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, text, 10) catch error.TypeMismatch,
        .float => std.fmt.parseFloat(T, text) catch error.TypeMismatch,
        .bool => if (std.ascii.eqlIgnoreCase(text, "t") or
            std.ascii.eqlIgnoreCase(text, "true") or
            std.mem.eql(u8, text, "1"))
            true
        else if (std.ascii.eqlIgnoreCase(text, "f") or
            std.ascii.eqlIgnoreCase(text, "false") or
            std.mem.eql(u8, text, "0"))
            false
        else
            error.TypeMismatch,
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    if (type_oid == pq.proto.Oid.bytea) {
                        break :blk decodeBytea(text, gpa) catch return error.TypeMismatch;
                    }
                    break :blk gpa.dupe(u8, text) catch return error.OutOfMemory;
                }
                // Array column (any dimension) decoded from the PostgreSQL
                // array literal.
                break :blk parseArrayText(ptr.child, text, gpa) catch return error.TypeMismatch;
            }
            @compileError("zorm: unsupported result type " ++ @typeName(T));
        },
        .@"enum" => blk: {
            const tag = std.meta.stringToEnum(T, text) orelse return error.TypeMismatch;
            break :blk tag;
        },
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) {
                break :blk Time.parsePg(text) catch return error.TypeMismatch;
            }
            if (@hasDecl(T, "__zorm_json")) {
                break :blk T{ .data = gpa.dupe(u8, text) catch return error.OutOfMemory };
            }
            if (@hasDecl(T, "__zorm_bytes")) {
                if (type_oid == pq.proto.Oid.bytea) {
                    break :blk T{ .data = decodeBytea(text, gpa) catch return error.TypeMismatch };
                }
                break :blk T{ .data = gpa.dupe(u8, text) catch return error.OutOfMemory };
            }
            @compileError("zorm: unsupported result type " ++ @typeName(T));
        },
        else => @compileError("zorm: unsupported result type " ++ @typeName(T)),
    };
}

/// Text-format bytea is `\x<hex>` (bytea_output = hex, the default).
fn decodeBytea(text: []const u8, gpa: std.mem.Allocator) ![]u8 {
    if (!std.mem.startsWith(u8, text, "\\x")) return error.InvalidBytea;
    const hex_part = text[2..];
    if (hex_part.len % 2 != 0) return error.InvalidBytea;
    const out = try gpa.alloc(u8, hex_part.len / 2);
    errdefer gpa.free(out);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try std.fmt.charToDigit(hex_part[i * 2], 16);
        const lo = try std.fmt.charToDigit(hex_part[i * 2 + 1], 16);
        out[i] = @as(u8, hi) * 16 + lo;
    }
    return out;
}

/// Frees any heap memory owned by `value`'s string/optional fields.
/// Only meaningful for values produced by `decodeCell` with the same `gpa`.
pub fn freeValue(comptime T: type, value: T, gpa: std.mem.Allocator) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice) {
            // Zero-length slices (including static defaults like `&.{}`)
            // never own memory.
            if (value.len == 0) return;
            if (ptr.child == u8) {
                gpa.free(value);
            } else {
                // Slices of structs/strings/arrays (preloads, text arrays...).
                for (value) |item| freeValue(ptr.child, item, gpa);
                gpa.free(value);
            }
        } else {},
        .@"struct" => |info| {
            if (@hasDecl(T, "__zorm_time")) return;
            inline for (info.fields) |f| {
                freeValue(f.type, @field(value, f.name), gpa);
            }
        },
        .optional => if (value) |v| freeValue(@TypeOf(v), v, gpa),
        else => {},
    }
}

/// Deep-copies a decoded value so each owner has independent string memory
/// (preloads assign one decoded row to several parents).
pub fn deepCopy(comptime T: type, value: T, gpa: std.mem.Allocator) DecodeError!T {
    return switch (@typeInfo(T)) {
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                // Empty slices (including static defaults) need no copy.
                if (value.len == 0) break :blk value;
                const copy = gpa.alloc(ptr.child, value.len) catch return error.OutOfMemory;
                for (value, 0..) |item, i| {
                    copy[i] = try deepCopy(ptr.child, item, gpa);
                }
                break :blk copy;
            }
            break :blk value;
        },
        .@"struct" => |info| blk: {
            if (@hasDecl(T, "__zorm_time")) break :blk value;
            var out: T = value;
            inline for (info.fields) |f| {
                @field(out, f.name) = try deepCopy(f.type, @field(value, f.name), gpa);
            }
            break :blk out;
        },
        .optional => |oi| blk: {
            if (value) |v| {
                break :blk @as(T, try deepCopy(oi.child, v, gpa));
            }
            break :blk value;
        },
        else => value,
    };
}

/// Frees a slice of decoded models.
pub fn freeSlice(comptime T: type, slice: []T, gpa: std.mem.Allocator) void {
    for (slice) |item| freeValue(T, item, gpa);
    gpa.free(slice);
}

const testing = std.testing;

const Row = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    nickname: ?[]const u8 = null,
    score: f64 = 0,
    ok: bool = false,
    status: enum { active, inactive } = .active,
};

test "decode struct row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var row: Row = .{};
    row.id = try decodeCell(?i64, "42", pq.proto.Oid.int8, 0, gpa);
    row.name = try decodeCell([]const u8, "alice", pq.proto.Oid.text, 0, gpa);
    row.nickname = try decodeCell(?[]const u8, null, pq.proto.Oid.text, 0, gpa);
    row.score = try decodeCell(f64, "3.25", pq.proto.Oid.float8, 0, gpa);
    row.ok = try decodeCell(bool, "t", pq.proto.Oid.bool_, 0, gpa);
    row.status = try decodeCell(@TypeOf(row.status), "active", pq.proto.Oid.text, 0, gpa);

    try testing.expectEqual(@as(?i64, 42), row.id);
    try testing.expectEqualStrings("alice", row.name);
    try testing.expect(row.nickname == null);
    try testing.expectEqual(@as(f64, 3.25), row.score);
    try testing.expect(row.ok);
    try testing.expectEqual(.active, row.status);
}

test "null into non-optional is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.NullValue, decodeCell(i64, null, pq.proto.Oid.int8, 0, arena_state.allocator()));
}

test "bytea hex round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const got = try decodeCell([]const u8, "\\x00ff10", pq.proto.Oid.bytea, 0, gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x10 }, got);
}

test "params from args tuple" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const params = try argsToParams(.{ 42, "x", true, null, @as(f64, 1.5), .inactive }, arena);
    try testing.expectEqual(@as(usize, 6), params.len);
    // 42 -> binary int8
    try testing.expectEqual(proto.Oid.int8, params[0].oid);
    try testing.expectEqual(@as(u16, 1), params[0].format);
    try testing.expectEqual(@as(usize, 8), params[0].data.len);
    try testing.expectEqual(@as(i64, 42), std.mem.readInt(i64, params[0].data[0..8], .big));
    // "x" -> binary text (raw bytes)
    try testing.expectEqual(proto.Oid.text, params[1].oid);
    try testing.expectEqualStrings("x", params[1].data);
    // true -> binary bool
    try testing.expectEqual(proto.Oid.bool_, params[2].oid);
    try testing.expectEqual(@as(u8, 1), params[2].data[0]);
    // null
    try testing.expect(params[3].is_null);
    // 1.5 -> binary float8
    const f: f64 = @bitCast(std.mem.readInt(u64, params[4].data[0..8], .big));
    try testing.expectEqual(@as(f64, 1.5), f);
    // enum literal -> text tag name
    try testing.expectEqualStrings("inactive", params[5].data);
}

/// Decodes one result row into model `T`, matching columns by name.
/// Fields not present in the result keep their default value.
pub fn scanRow(
    comptime T: type,
    comptime table: schema.Table,
    res: anytype,
    row: anytype,
    gpa: std.mem.Allocator,
) DecodeError!T {
    return scanCells(T, table, res.columns, row, gpa);
}

/// Decodes a cursor row directly, without first materializing a `pq.Result`.
pub fn scanCells(
    comptime T: type,
    comptime table: schema.Table,
    columns: anytype,
    row: anytype,
    gpa: std.mem.Allocator,
) DecodeError!T {
    var column_map: [table.columns.len]?usize = undefined;
    buildColumnMap(table, columns, &column_map);
    return scanCellsMapped(T, table, columns, row, &column_map, gpa);
}

/// Builds the result-column lookup once for all rows in a result set.
pub fn buildColumnMap(
    comptime table: schema.Table,
    columns: anytype,
    map: []?usize,
) void {
    @memset(map, null);
    inline for (table.columns, 0..) |col, i| {
        for (columns, 0..) |result_column, column_index| {
            if (std.mem.eql(u8, result_column.name, col.name)) {
                map[i] = column_index;
                break;
            }
        }
    }
}

/// Decodes a row using a column map prepared by `buildColumnMap`.
pub fn scanCellsMapped(
    comptime T: type,
    comptime table: schema.Table,
    columns: anytype,
    row: anytype,
    column_map: []const ?usize,
    gpa: std.mem.Allocator,
) DecodeError!T {
    var out = std.mem.zeroInit(T, .{});
    errdefer value_freePartiallyBuilt(T, &out, gpa);
    inline for (table.columns, 0..) |col, i| {
        if (column_map[i]) |ci| {
            const V = columnFieldType(T, col);
            setColumn(&out, col, try decodeCell(V, row[ci], columns[ci].type_oid, columns[ci].format, gpa));
        } else {
            const d = columnDefault(T, col);
            if (d) |dv| setColumn(&out, col, dv);
        }
    }
    return out;
}

/// The leaf field's default value for a column, when it has one.
fn columnDefault(comptime T: type, comptime col: schema.Column) ?columnFieldType(T, col) {
    if (col.embed) |parent| {
        const P = fieldOf(T, parent);
        inline for (@typeInfo(P).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, col.field_name)) {
                if (f.defaultValue()) |d| return d;
                return null;
            }
        }
        return null;
    }
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, col.field_name)) {
            if (f.defaultValue()) |d| return d;
            return null;
        }
    }
    return null;
}

/// Frees the already-decoded heap fields of a partially constructed value
/// (zeroed fields are empty/static and are skipped by freeValue).
fn value_freePartiallyBuilt(comptime T: type, out: *T, gpa: std.mem.Allocator) void {
    freeValue(T, out.*, gpa);
}

test "array param and parse round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tags = [_][]const u8{ "dev", "has,comma", "quote\"d", "NULL", "" };
    const p = try arrayParam([]const u8, &tags, arena);
    try testing.expectEqual(proto.Oid.text_array, p.oid);
    try testing.expectEqual(@as(u16, 0), p.format);
    try testing.expectEqualStrings(
        \\{dev,"has,comma","quote\"d","NULL",""}
    , p.data);

    const back = try parseArrayText([]const u8, p.data, arena);
    try testing.expectEqual(@as(usize, 5), back.len);
    try testing.expectEqualStrings("has,comma", back[1]);
    try testing.expectEqualStrings("quote\"d", back[2]);
    try testing.expectEqualStrings("NULL", back[3]);
    try testing.expectEqualStrings("", back[4]);
}

test "int array round trip with nulls" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nums = [_]?i64{ 1, null, -3, 9007199254740993 };
    const p = try arrayParam(?i64, &nums, arena);
    try testing.expectEqualStrings("{1,NULL,-3,9007199254740993}", p.data);
    const back = try parseArrayText(?i64, "{1,NULL,-3, 9007199254740993}", arena);
    try testing.expectEqual(@as(usize, 4), back.len);
    try testing.expectEqual(@as(?i64, 1), back[0]);
    try testing.expectEqual(@as(?i64, null), back[1]);
    try testing.expectEqual(@as(?i64, -3), back[2]);
    try testing.expectEqual(@as(?i64, 9007199254740993), back[3]);
}

test "json and bytes param wrappers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const jp = try toParam(Json{ .data = "{\"a\":1}" }, arena);
    try testing.expectEqual(proto.Oid.jsonb, jp.oid);
    try testing.expectEqual(@as(u16, 0), jp.format);
    try testing.expectEqualStrings("{\"a\":1}", jp.data);

    const bp = try toParam(Bytes{ .data = "\x00\x01" }, arena);
    try testing.expectEqual(proto.Oid.bytea, bp.oid);
    try testing.expectEqual(@as(u16, 1), bp.format);
    try testing.expectEqualSlices(u8, &.{ 0, 1 }, bp.data);
}

test "time param is binary timestamptz" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try toParam(Time.fromUnix(1_800_000_000), arena);
    try testing.expectEqual(proto.Oid.timestamptz, p.oid);
    try testing.expectEqual(@as(u16, 1), p.format);
    const micros = std.mem.readInt(i64, p.data[0..8], .big) + pg_epoch_us;
    try testing.expectEqual(@as(i64, 1_800_000_000_000_000), micros);
}

test "decode json/bytes/array cells" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    const j = try decodeCell(Json, "{\"x\": 2}", pq.proto.Oid.jsonb, 0, gpa);
    try testing.expectEqualStrings("{\"x\": 2}", j.data);

    const b = try decodeCell(Bytes, "\\xdead", pq.proto.Oid.bytea, 0, gpa);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, b.data);

    const ints = try decodeCell([]const i64, "{10,20,30}", pq.proto.Oid.int8_array, 0, gpa);
    try testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, ints);

    const strs = try decodeCell([]const []const u8, "{\"a b\",c}", pq.proto.Oid.text_array, 0, gpa);
    try testing.expectEqual(@as(usize, 2), strs.len);
    try testing.expectEqualStrings("a b", strs[0]);
    try testing.expectEqualStrings("c", strs[1]);

    try testing.expectError(error.TypeMismatch, decodeCell([]const i64, "{{1},{2}}", pq.proto.Oid.int8_array, 0, gpa));
}

test "binary i64 decode" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &buf, 42, .big);
    const v = try decodeBinary(i64, &buf, pq.proto.Oid.int8, testing.allocator);
    try testing.expectEqual(@as(i64, 42), v);
}

test "2-D text format round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const m = [_][]const i64{ &.{ 1, 2 }, &.{ 3, 4 } };
    const p = try arrayParam([]const i64, &m, arena);
    try testing.expectEqualStrings("{{1,2},{3,4}}", p.data);
    try testing.expectEqual(proto.Oid.int8_array, p.oid);

    const back = try parseArrayText([]const i64, "{{1,2},{3,4}}", arena);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, back[0]);
    try testing.expectEqualSlices(i64, &.{ 3, 4 }, back[1]);
}

test "binary array decode with nulls and 2 dims" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    // 1-D int8[] {1,NULL,3}: ndim=1, flags=1(hasnull), oid=20, dims=[3]
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const be32 = struct {
        fn w(list: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v, .big);
            try list.appendSlice(a, &b);
        }
    }.w;
    try be32(&buf, testing.allocator, 1); // ndim
    try be32(&buf, testing.allocator, 1); // flags
    try be32(&buf, testing.allocator, 20); // elem oid
    try be32(&buf, testing.allocator, 3); // dim 0
    try be32(&buf, testing.allocator, 1); // lower bound
    try be32(&buf, testing.allocator, 8);
    try buf.appendSlice(testing.allocator, &.{ 0, 0, 0, 0, 0, 0, 0, 1 });
    try be32(&buf, testing.allocator, -1); // NULL
    try be32(&buf, testing.allocator, 8);
    try buf.appendSlice(testing.allocator, &.{ 0, 0, 0, 0, 0, 0, 0, 3 });

    const got = try decodeCell([]const ?i64, buf.items, pq.proto.Oid.int8_array, 1, gpa);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(@as(?i64, 1), got[0]);
    try testing.expectEqual(@as(?i64, null), got[1]);
    try testing.expectEqual(@as(?i64, 3), got[2]);
}

test "binary 2-D array decode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const be32 = struct {
        fn w(list: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, v, .big);
            try list.appendSlice(a, &b);
        }
    }.w;
    try be32(&buf, testing.allocator, 2); // ndim
    try be32(&buf, testing.allocator, 0); // flags
    try be32(&buf, testing.allocator, 20); // elem oid
    try be32(&buf, testing.allocator, 2); // dim 0
    try be32(&buf, testing.allocator, 1); // lb
    try be32(&buf, testing.allocator, 2); // dim 1
    try be32(&buf, testing.allocator, 1); // lb
    for ([_]i64{ 1, 2, 3, 4 }) |v| {
        try be32(&buf, testing.allocator, 8);
        var b: [8]u8 = undefined;
        std.mem.writeInt(i64, &b, v, .big);
        try buf.appendSlice(testing.allocator, &b);
    }

    const got = try decodeCell([]const []const i64, buf.items, pq.proto.Oid.int8_array, 1, gpa);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, got[0]);
    try testing.expectEqualSlices(i64, &.{ 3, 4 }, got[1]);
}

test "malformed binary values fail without leaking" {
    try testing.expectError(error.TypeMismatch, decodeCell(bool, "", pq.proto.Oid.bool_, 0, testing.allocator));
    try testing.expectError(error.TypeMismatch, decodeBinary(bool, &.{2}, pq.proto.Oid.bool_, testing.allocator));
    try testing.expectError(error.TypeMismatch, decodeBinary(Json, &.{}, pq.proto.Oid.jsonb, testing.allocator));

    var array: [24]u8 = @splat(0);
    std.mem.writeInt(i32, array[0..4], 1, .big); // ndim
    std.mem.writeInt(i32, array[12..16], 1, .big); // length
    std.mem.writeInt(i32, array[16..20], 1, .big); // lower bound
    std.mem.writeInt(i32, array[20..24], -1, .big); // NULL element
    try testing.expectError(
        error.NullValue,
        decodeBinary([]const i64, &array, pq.proto.Oid.int8_array, testing.allocator),
    );
}

test "Model JSON timestamps are RFC 3339 strings" {
    const t = Time.fromUnixMicros(1_800_000_000_123_456);
    const payload = .{ .base = Model{
        .id = 1,
        .created_at = t,
        .updated_at = t,
    } };
    try testing.expectFmt(
        "{\"base\":{\"id\":1,\"created_at\":\"2027-01-15T08:00:00.123456Z\",\"updated_at\":\"2027-01-15T08:00:00.123456Z\",\"deleted_at\":null}}",
        "{f}",
        .{std.json.fmt(payload, .{})},
    );
}
