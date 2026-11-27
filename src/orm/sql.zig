//! SQL text helpers shared by the query builder, CRUD templates and preload:
//! identifier quoting (runtime and comptime), placeholder renumbering, named
//! parameters, and the soft-delete stamp expression.

const std = @import("std");
const schema = @import("schema.zig");
const time_mod = @import("time.zig");

pub fn writeNamed(w: *std.Io.Writer, frag: []const u8, comptime field_names: []const [:0]const u8, start: usize) !void {
    var i: usize = 0;
    while (i < frag.len) {
        const ch = frag[i];
        if (ch == '\'' or ch == '"') {
            i = try copyQuoted(w, frag, i);
            continue;
        }
        if (ch == ':') {
            if (i + 1 < frag.len and frag[i + 1] == ':') {
                try w.writeAll("::");
                i += 2;
                continue;
            }
            var end = i + 1;
            while (end < frag.len and (std.ascii.isAlphanumeric(frag[end]) or frag[end] == '_')) end += 1;
            if (end == i + 1) return error.InvalidQuery;
            const name = frag[i + 1 .. end];
            var found = false;
            for (field_names, 0..) |field_name, field_index| {
                if (std.mem.eql(u8, name, field_name)) {
                    try w.print("${d}", .{start + field_index + 1});
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidQuery;
            i = end;
            continue;
        }
        var j = i + 1;
        while (j < frag.len and frag[j] != ':' and frag[j] != '\'' and frag[j] != '"') j += 1;
        try w.writeAll(frag[i..j]);
        i = j;
    }
}

/// SQL expression used to stamp a soft-delete `deleted_at` column. Uses the
/// database clock so all writers agree on time.
pub fn softDeleteStampSql(comptime FType: type) []const u8 {
    const E = if (@typeInfo(FType) == .optional) @typeInfo(FType).optional.child else FType;
    return switch (E) {
        time_mod.Time => "now()",
        i64 => "(extract(epoch from now()) * 1000000)::bigint",
        else => @compileError("zgorm: deleted_at must be zgorm.Time or i64"),
    };
}

/// A compile-time quoted SQL identifier. Model and column metadata are
/// comptime values, so hot paths can reuse these bytes without allocation.
pub fn QuotedIdent(comptime name: []const u8) type {
    comptime var escaped_len: usize = 2;
    inline for (name) |ch| escaped_len += if (ch == '"') 2 else 1;
    return struct {
        pub const value: [escaped_len]u8 = blk: {
            var out: [escaped_len]u8 = undefined;
            var n: usize = 0;
            out[n] = '"';
            n += 1;
            for (name) |ch| {
                if (ch == '"') {
                    out[n] = '"';
                    n += 1;
                }
                out[n] = ch;
                n += 1;
            }
            out[n] = '"';
            break :blk out;
        };
    };
}

/// Zero-allocation access to a compile-time quoted identifier, for hot paths
/// where the name comes from comptime model metadata.
pub fn quoted(comptime name: []const u8) []const u8 {
    return &QuotedIdent(name).value;
}

pub fn DefaultSelectPrefix(comptime T: type) type {
    const table = schema.tableOf(T);
    return struct {
        pub const value = "SELECT * FROM " ++ QuotedIdent(table.name).value;
    };
}

pub fn writeIdent(w: *std.Io.Writer, identifier: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, identifier, i, '"')) |q| {
        try w.writeAll(identifier[i..q]);
        try w.writeAll("\"\"");
        i = q + 1;
    }
    try w.writeAll(identifier[i..]);
    try w.writeByte('"');
}

pub fn writeQualifiedIdent(w: *std.Io.Writer, relation: []const u8, column: []const u8) !void {
    try writeIdent(w, relation);
    try w.writeByte('.');
    try writeIdent(w, column);
}

/// Quotes an SQL identifier, escaping embedded double quotes.
pub fn quoteIdent(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '"') == null) {
        return std.fmt.allocPrint(arena, "\"{s}\"", .{name});
    }
    const out = try arena.alloc(u8, name.len * 2 + 2);
    out[0] = '"';
    var n: usize = 1;
    for (name) |ch| {
        if (ch == '"') {
            out[n] = '"';
            n += 1;
        }
        out[n] = ch;
        n += 1;
    }
    out[n] = '"';
    return out[0 .. n + 1];
}

/// Copies `frag` into `w`, shifting every `$N` placeholder by `base`.
/// Placeholders inside single/double-quoted literals are left untouched.
pub fn writeRenumbered(w: *std.Io.Writer, frag: []const u8, base: usize) !void {
    var i: usize = 0;
    while (i < frag.len) {
        const ch = frag[i];
        if (ch == '\'' or ch == '"') {
            i = try copyQuoted(w, frag, i);
            continue;
        }
        if (ch == '$' and i + 1 < frag.len and frag[i + 1] >= '0' and frag[i + 1] <= '9') {
            var j = i + 1;
            while (j < frag.len and frag[j] >= '0' and frag[j] <= '9') j += 1;
            const n = std.fmt.parseInt(usize, frag[i + 1 .. j], 10) catch {
                try w.writeAll(frag[i..j]);
                i = j;
                continue;
            };
            if (n == 0 or n > std.math.maxInt(usize) - base) {
                try w.writeAll(frag[i..j]);
            } else {
                try w.print("${d}", .{n + base});
            }
            i = j;
            continue;
        }
        // Plain run (including a non-placeholder '$') up to the next quote or
        // placeholder start.
        var j = i + 1;
        while (j < frag.len) {
            const c2 = frag[j];
            if (c2 == '\'' or c2 == '"') break;
            if (c2 == '$' and j + 1 < frag.len and frag[j + 1] >= '0' and frag[j + 1] <= '9') break;
            j += 1;
        }
        try w.writeAll(frag[i..j]);
        i = j;
    }
}

/// Copies a single/double-quoted run (handling doubled-quote escapes)
/// verbatim, returning the index just past the closing quote.
fn copyQuoted(w: *std.Io.Writer, frag: []const u8, start: usize) !usize {
    const q = frag[start];
    try w.writeByte(q);
    var i = start + 1;
    while (i < frag.len) {
        try w.writeByte(frag[i]);
        if (frag[i] == q) {
            if (i + 1 < frag.len and frag[i + 1] == q) {
                try w.writeByte(frag[i + 1]);
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return i;
}

const testing = std.testing;

test "placeholder renumbering" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRenumbered(&w, "age > $1 AND name LIKE $2", 3);
    try testing.expectEqualStrings("age > $4 AND name LIKE $5", w.buffered());
    var edge_buf: [256]u8 = undefined;
    var edge_writer: std.Io.Writer = .fixed(&edge_buf);
    try writeRenumbered(&edge_writer, "$0 $99999999999999999999999999999999999999", 3);
    try testing.expectEqualStrings("$0 $99999999999999999999999999999999999999", edge_writer.buffered());
}

test "placeholder renumbering skips quoted literals" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRenumbered(&w, "note = '$100' AND id = $1", 3);
    try testing.expectEqualStrings("note = '$100' AND id = $4", w.buffered());

    var buf2: [256]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    try writeRenumbered(&w2, "x = \"a$1b\" AND y = $2", 1);
    try testing.expectEqualStrings("x = \"a$1b\" AND y = $3", w2.buffered());

    var buf3: [256]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&buf3);
    try writeRenumbered(&w3, "s = 'it''s $1' AND id = $1", 5);
    try testing.expectEqualStrings("s = 'it''s $1' AND id = $6", w3.buffered());
}

test "quoteIdent escapes quotes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("\"users\"", try quoteIdent(a, "users"));
    try testing.expectEqualStrings("\"we\"\"ird\"", try quoteIdent(a, "we\"ird"));
    try testing.expectEqualStrings("\"users\"", QuotedIdent("users").value[0..]);
    try testing.expectEqualStrings("\"we\"\"ird\"", QuotedIdent("we\"ird").value[0..]);
}
