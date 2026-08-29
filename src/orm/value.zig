//! Value codec: Zig values -> query parameters, and text result cells ->
//! typed Zig values. All decoding happens against PostgreSQL's text format.

const std = @import("std");
const pq = @import("../pq.zig");
const time_mod = @import("time.zig");
const schema = @import("schema.zig");

pub const Time = time_mod.Time;
pub const Error = pq.Error;
const Param = pq.Param;

/// Converts a comptime-typed value into a driver parameter. Scalars are
/// pre-encoded in PostgreSQL's binary format (with an explicit type OID so
/// the server never has to infer); arrays, JSON and enums are sent in text
/// format. All scratch memory comes from `arena`.
pub fn toParam(value: anytype, arena: std.mem.Allocator) Error!Param {
    const T = @TypeOf(value);
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
                // timestamptz binary format: i64 microseconds since
                // 2000-01-01T00:00:00Z (PostgreSQL's internal epoch).
                var buf: [8]u8 = undefined;
                const pg_micros = value.micros - pg_epoch_us;
                std.mem.writeInt(u64, &buf, @bitCast(pg_micros), .big);
                break :blk mkBinary(.{
                    .oid = proto.Oid.timestamptz,
                    .data = arena.dupe(u8, &buf) catch return error.OutOfMemory,
                });
            }
            if (@hasDecl(T, "__zorm_json")) {
                break :blk mkText(.{ .oid = proto.Oid.jsonb, .data = value.data });
            }
            if (@hasDecl(T, "__zorm_bytes")) {
                break :blk mkBinary(.{ .oid = proto.Oid.bytea, .data = value.data });
            }
            @compileError("zorm: unsupported parameter type " ++ @typeName(T));
        },
        else => @compileError("zorm: unsupported parameter type " ++ @typeName(T)),
    };
}

pub const proto = @import("../pq/proto.zig");

/// PostgreSQL internal epoch: 2000-01-01T00:00:00Z, in Unix microseconds.
pub const pg_epoch_us: i64 = 946_684_800_000_000;

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
    return r;
}

fn mkText(p: Param) Param {
    var r = p;
    r.format = 0;
    return r;
}

fn intParam(v: i64, arena: std.mem.Allocator) Error!Param {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, @bitCast(v), .big);
    return .{
        .oid = proto.Oid.int8,
        .format = 1,
        .data = arena.dupe(u8, &buf) catch return error.OutOfMemory,
    };
}

fn numericParam(digits: []const u8, arena: std.mem.Allocator) Error!Param {
    return .{
        .oid = proto.Oid.numeric,
        .format = 0,
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
    return switch (@typeInfo(Elem)) {
        .bool => proto.Oid.bool_array,
        .int, .comptime_int => proto.Oid.int8_array,
        .float, .comptime_float => proto.Oid.float8_array,
        .pointer, .array => proto.Oid.text_array,
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
            } else @compileError("zorm: unsupported array element type " ++ @typeName(E));
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

/// Parses a 1-D PostgreSQL array literal into `[]Elem`; `Elem` may be an
/// optional (NULL elements map to null). Strings are duplicated with `gpa`.
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
        var escaped = false;
        var element_present = false;
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
                    element_present = true;
                },
                ',' => {
                    i += 1;
                    break;
                },
                else => {
                    raw.append(gpa, ch) catch return error.OutOfMemory;
                    element_present = true;
                },
            }
            i += 1;
        }
        if (!element_present and raw.items.len == 0) {
            // `{,}`-style hole: treat as NULL (valid only for optional elems).
            items.append(gpa, try nullElement(Elem)) catch return error.OutOfMemory;
        } else {
            items.append(gpa, try decodeArrayElement(Elem, raw.items, gpa)) catch return error.OutOfMemory;
        }
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

fn decodeArrayElement(comptime E: type, raw: []const u8, gpa: std.mem.Allocator) DecodeError!E {
    switch (@typeInfo(E)) {
        .optional => |oi| {
            if (std.ascii.eqlIgnoreCase(raw, "null")) return null;
            const inner = try decodeArrayElement(oi.child, raw, gpa);
            return @as(E, inner);
        },
        .int => return std.fmt.parseInt(E, raw, 10) catch error.TypeMismatch,
        .float => return std.fmt.parseFloat(E, raw) catch error.TypeMismatch,
        .bool => {
            if (std.ascii.eqlIgnoreCase(raw, "t") or std.ascii.eqlIgnoreCase(raw, "true")) return true;
            if (std.ascii.eqlIgnoreCase(raw, "f") or std.ascii.eqlIgnoreCase(raw, "false")) return false;
            return error.TypeMismatch;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return gpa.dupe(u8, raw) catch return error.OutOfMemory;
            }
            @compileError("zorm: unsupported array element type " ++ @typeName(E));
        },
        else => @compileError("zorm: unsupported array element type " ++ @typeName(E)),
    }
}

pub const DecodeError = error{ NullValue, TypeMismatch, OutOfMemory };

/// Decodes one result cell (text format, possibly NULL) into `T`.
/// Returned strings are duplicated with `gpa`.
pub fn decodeCell(comptime T: type, cell: ?[]const u8, type_oid: u32, gpa: std.mem.Allocator) DecodeError!T {
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (cell == null) return null;
        return try decodeCell(Child, cell, type_oid, gpa);
    }
    const text = cell orelse return error.NullValue;
    return decodeText(T, text, type_oid, gpa);
}

fn decodeText(comptime T: type, text: []const u8, type_oid: u32, gpa: std.mem.Allocator) DecodeError!T {
    return switch (@typeInfo(T)) {
        .int => |info| blk: {
            const v = std.fmt.parseInt(T, text, 10) catch return error.TypeMismatch;
            _ = info;
            break :blk v;
        },
        .float => std.fmt.parseFloat(T, text) catch return error.TypeMismatch,
        .bool => switch (text[0]) {
            't', 'T', '1' => true,
            'f', 'F', '0' => false,
            else => error.TypeMismatch,
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                if (ptr.child == u8) {
                    if (type_oid == pq.proto.Oid.bytea) {
                        break :blk decodeBytea(text, gpa) catch return error.TypeMismatch;
                    }
                    break :blk gpa.dupe(u8, text) catch return error.OutOfMemory;
                }
                // 1-D array column (e.g. bigint[], text[]) decoded from the
                // PostgreSQL array literal.
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
    row.id = try decodeCell(?i64, "42", pq.proto.Oid.int8, gpa);
    row.name = try decodeCell([]const u8, "alice", pq.proto.Oid.text, gpa);
    row.nickname = try decodeCell(?[]const u8, null, pq.proto.Oid.text, gpa);
    row.score = try decodeCell(f64, "3.25", pq.proto.Oid.float8, gpa);
    row.ok = try decodeCell(bool, "t", pq.proto.Oid.bool_, gpa);
    row.status = try decodeCell(@TypeOf(row.status), "active", pq.proto.Oid.text, gpa);

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
    try testing.expectError(error.NullValue, decodeCell(i64, null, pq.proto.Oid.int8, arena_state.allocator()));
}

test "bytea hex round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const got = try decodeCell([]const u8, "\\x00ff10", pq.proto.Oid.bytea, gpa);
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
    res: *pq.Result,
    row: pq.Result.Row,
    gpa: std.mem.Allocator,
) DecodeError!T {
    var out = std.mem.zeroInit(T, .{});
    inline for (@typeInfo(T).@"struct".fields) |f| {
        inline for (table.columns) |col| {
            if (comptime std.mem.eql(u8, col.field_name, f.name)) {
                if (res.colIndex(col.name)) |ci| {
                    @field(out, f.name) = try decodeCell(f.type, row[ci], res.columns[ci].type_oid, gpa);
                } else if (f.defaultValue()) |d| {
                    @field(out, f.name) = d;
                }
            }
        }
    }
    return out;
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

    const j = try decodeCell(Json, "{\"x\": 2}", pq.proto.Oid.jsonb, gpa);
    try testing.expectEqualStrings("{\"x\": 2}", j.data);

    const b = try decodeCell(Bytes, "\\xdead", pq.proto.Oid.bytea, gpa);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, b.data);

    const ints = try decodeCell([]const i64, "{10,20,30}", pq.proto.Oid.int8_array, gpa);
    try testing.expectEqualSlices(i64, &.{ 10, 20, 30 }, ints);

    const strs = try decodeCell([]const []const u8, "{\"a b\",c}", pq.proto.Oid.text_array, gpa);
    try testing.expectEqual(@as(usize, 2), strs.len);
    try testing.expectEqualStrings("a b", strs[0]);
    try testing.expectEqualStrings("c", strs[1]);

    try testing.expectError(error.TypeMismatch, decodeCell([]const i64, "{{1},{2}}", pq.proto.Oid.int8_array, gpa));
}
