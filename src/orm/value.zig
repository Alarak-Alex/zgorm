//! Value codec: Zig values -> query parameters, and text result cells ->
//! typed Zig values. All decoding happens against PostgreSQL's text format.

const std = @import("std");
const pq = @import("../pq.zig");
const time_mod = @import("time.zig");
const schema = @import("schema.zig");

pub const Time = time_mod.Time;
pub const Error = pq.Error;
const Param = pq.Param;

/// Converts a comptime-typed value into a driver parameter.
/// `buf` receives textual forms that need rendering (e.g. Time).
pub fn toParam(value: anytype, arena: std.mem.Allocator) Error!Param {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .null => Param.null_,
        .bool => Param{ .boolean = value },
        .int => Param{ .int = std.math.cast(i64, value) orelse return error.TypeMismatch },
        .comptime_int => Param{ .int = std.math.cast(i64, value) orelse return error.TypeMismatch },
        .float => Param{ .float = @floatCast(value) },
        .comptime_float => Param{ .float = @floatCast(value) },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) Param{ .text = value } else error.TypeMismatch,
            .one => blk: {
                const C = ptr.child;
                switch (@typeInfo(C)) {
                    // String literals (`*const [N:0]u8`): the pointee is
                    // static, so slice off the sentinel without copying.
                    .array => |ai| {
                        if (ai.child == u8 and ai.sentinel_ptr != null) {
                            break :blk Param{ .text = value[0..ai.len] };
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
                // A by-value array parameter lives in this frame; the text
                // must be copied out.
                const text = std.mem.sliceTo(&value, 0);
                break :blk Param{ .text = arena.dupe(u8, text) catch return error.OutOfMemory };
            }
            @compileError("zorm: unsupported parameter type " ++ @typeName(T));
        },
        .@"enum", .enum_literal => Param{ .text = @tagName(value) },
        .optional => if (value) |v| try toParam(v, arena) else Param.null_,
        .@"struct" => blk: {
            if (@hasDecl(T, "__zorm_time")) {
                var buf: [Time.pg_text_len]u8 = undefined;
                const text = value.toPgText(&buf);
                break :blk Param{ .text = arena.dupe(u8, text) catch return error.OutOfMemory };
            }
            @compileError("zorm: unsupported parameter type " ++ @typeName(T));
        },
        else => @compileError("zorm: unsupported parameter type " ++ @typeName(T)),
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
            if (ptr.size == .slice and ptr.child == u8) {
                if (type_oid == pq.proto.Oid.bytea) {
                    break :blk decodeBytea(text, gpa) catch return error.TypeMismatch;
                }
                break :blk gpa.dupe(u8, text) catch return error.OutOfMemory;
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
        .pointer => |ptr| if (ptr.size == .slice and ptr.child == u8) {
            gpa.free(value);
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
    try testing.expectEqual(@as(i64, 42), params[0].int);
    try testing.expectEqualStrings("x", params[1].text);
    try testing.expect(params[2].boolean);
    try testing.expect(params[3] == .null_);
    try testing.expectEqual(@as(f64, 1.5), params[4].float);
    try testing.expectEqualStrings("inactive", params[5].text);
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
