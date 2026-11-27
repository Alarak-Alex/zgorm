//! Association preloading: batched child queries for belongs_to / has_one /
//! has_many / many_to_many, composite keys, and nested (dotted) paths.
//! One query per association level, joined back to parents in memory.

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const session_mod = @import("session.zig");
const schema = @import("schema.zig");
const sqlutil = @import("sql.zig");
const value = @import("value.zig");

pub const Error = pq.Error;

/// Compile-time validation of a (possibly dotted) preload path against
/// model `M`: every segment must be a declared association of the previous
/// segment's model.
pub fn validatePreloadPath(comptime M: type, comptime path: []const u8) void {
    comptime {
        @setEvalBranchQuota(200_000);
        var model = M;
        var rest = path;
        while (rest.len > 0) {
            const dot = std.mem.indexOfScalar(u8, rest, '.');
            const seg = if (dot) |d| rest[0..d] else rest;
            const tbl = schema.tableOf(model);
            var found: ?schema.Assoc = null;
            for (tbl.assocs) |a| {
                if (std.mem.eql(u8, a.field_name, seg)) found = a;
            }
            if (found == null) {
                @compileError("zgorm: preload('" ++ path ++ "'): '" ++ seg ++
                    "' is not a declared association of " ++ @typeName(model) ++
                    " (declare it via `pub const zgorm = .{ .has_many = ... }` or `.belongs_to = ...`)");
            }
            model = found.?.model;
            rest = if (dot) |d| rest[d + 1 ..] else "";
        }
    }
}

/// Applies a (possibly dotted) preload path to decoded rows of model `M`.
/// Runs one query per association level (batched over all rows).
pub fn applyPreloadPath(
    comptime M: type,
    rows: []M,
    path: []const u8,
    s: *session_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const tbl = comptime schema.tableOf(M);
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const seg = if (dot) |d| path[0..d] else path;
    const nested: []const u8 = if (dot) |d| path[d + 1 ..] else "";
    inline for (tbl.assocs) |assoc| {
        if (std.mem.eql(u8, assoc.field_name, seg)) {
            try loadAssoc(M, rows, assoc, nested, s, gpa);
        }
    }
}

fn loadAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *session_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    if (assoc.primary_keys.len != assoc.foreign_keys.len)
        @compileError("zgorm: association primary_keys and foreign_keys must have equal length");
    if (assoc.primary_keys.len > 1)
        return loadCompositeAssoc(M, rows, assoc, nested, s, gpa);

    switch (assoc.kind) {
        .many_to_many => return loadManyToMany(M, rows, assoc, nested, s, gpa),
        .belongs_to, .has_one, .has_many => return loadSingleAssoc(M, rows, assoc, nested, s, gpa),
    }
}

fn loadSingleAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *session_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    const child_table = comptime schema.tableOf(Child);
    const parent_key = if (comptime assoc.kind == .belongs_to) assoc.foreign_key else assoc.primary_key;
    const child_key = if (comptime assoc.kind == .belongs_to) assoc.primary_key else assoc.foreign_key;
    const parent_col = comptime ColumnOfT(M, parent_key);
    const child_col = comptime ColumnOfT(Child, child_key);
    const ParentKey = value.columnFieldType(M, parent_col);

    var keys: std.ArrayList(ParentKey) = .empty;
    defer keys.deinit(gpa);
    keys.ensureTotalCapacity(gpa, rows.len) catch return error.OutOfMemory;
    if (comptime assoc.kind == .belongs_to and value.keyMapType(ParentKey) != null) {
        // Many parents can reference the same child; deduplicate the IN list
        // so fan-in doesn't bloat the SQL and parameter count.
        var seen: value.keyMapType(ParentKey).? = .init(gpa);
        defer seen.deinit();
        for (rows) |*parent| {
            const key = value.getColumn(parent, parent_col);
            if (value.normalizedKey(ParentKey, key)) |nk| {
                const gop = seen.getOrPut(nk) catch return error.OutOfMemory;
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0;
                    keys.appendAssumeCapacity(key);
                }
            }
        }
    } else {
        for (rows) |*parent| {
            const key = value.getColumn(parent, parent_col);
            if (keyPresent(ParentKey, key)) keys.appendAssumeCapacity(key);
        }
    }
    if (keys.items.len == 0) {
        if (assoc.kind != .has_many) {
            for (rows) |*parent| @field(parent, assoc.field_name) = null;
        }
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var children = try queryChildrenForKeys(
        Child,
        child_table,
        child_key,
        keys.items,
        assoc.polymorphic_type,
        assoc.polymorphic_value,
        s,
        arena,
    );
    defer children.deinit(arena);
    if (nested.len > 0) try applyPreloadPath(Child, children.items, nested, s, arena);

    switch (assoc.kind) {
        .has_many => {
            const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
                return error.OutOfMemory;
            defer gpa.free(slices);
            const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(fill);
            const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
            defer gpa.free(counts);
            @memset(counts, 0);

            const owners = gpa.alloc(usize, children.items.len) catch return error.OutOfMemory;
            defer gpa.free(owners);
            const ChildKey = value.columnFieldType(Child, child_col);
            if (comptime value.keysHashable(ParentKey, ChildKey)) {
                var map: value.keyMapType(ParentKey).? = .init(gpa);
                defer map.deinit();
                for (rows, 0..) |*parent, parent_index| {
                    if (value.normalizedKey(ParentKey, value.getColumn(parent, parent_col))) |k| {
                        const gop = map.getOrPut(k) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = parent_index;
                    }
                }
                for (children.items, 0..) |*child, child_index| {
                    owners[child_index] = std.math.maxInt(usize);
                    if (value.normalizedKey(ChildKey, value.getColumn(child, child_col))) |k| {
                        if (map.get(k)) |parent_index| {
                            owners[child_index] = parent_index;
                            counts[parent_index] += 1;
                        }
                    }
                }
            } else {
                for (children.items, 0..) |*child, child_index| {
                    owners[child_index] = std.math.maxInt(usize);
                    for (rows, 0..) |*parent, parent_index| {
                        if (keyEqual(
                            ChildKey,
                            value.getColumn(child, child_col),
                            ParentKey,
                            value.getColumn(parent, parent_col),
                        )) {
                            owners[child_index] = parent_index;
                            counts[parent_index] += 1;
                            break;
                        }
                    }
                }
            }
            for (rows, 0..) |*parent, parent_index| {
                slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
                // Zero so a mid-fill error path frees only initialized slots.
                @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
                fill[parent_index] = 0;
                @field(parent, assoc.field_name) = slices[parent_index];
            }
            for (children.items, 0..) |*child, child_index| {
                const owner = owners[child_index];
                if (owner != std.math.maxInt(usize)) {
                    slices[owner][fill[owner]] = try value.deepCopy(Child, child.*, gpa);
                    fill[owner] += 1;
                }
            }
        },
        .belongs_to, .has_one => {
            const ChildKey = value.columnFieldType(Child, child_col);
            if (comptime value.keysHashable(ParentKey, ChildKey)) {
                var map: value.keyMapType(ChildKey).? = .init(gpa);
                defer map.deinit();
                for (children.items, 0..) |*child, child_index| {
                    if (value.normalizedKey(ChildKey, value.getColumn(child, child_col))) |k| {
                        const gop = map.getOrPut(k) catch return error.OutOfMemory;
                        if (!gop.found_existing) gop.value_ptr.* = child_index;
                    }
                }
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    if (value.normalizedKey(ParentKey, value.getColumn(parent, parent_col))) |k| {
                        if (map.get(k)) |child_index| {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, children.items[child_index], gpa);
                        }
                    }
                }
            } else {
                for (rows) |*parent| {
                    @field(parent, assoc.field_name) = null;
                    for (children.items) |*child| {
                        if (keyEqual(
                            ChildKey,
                            value.getColumn(child, child_col),
                            ParentKey,
                            value.getColumn(parent, parent_col),
                        )) {
                            @field(parent, assoc.field_name) = try value.deepCopy(Child, child.*, gpa);
                            break;
                        }
                    }
                }
            }
        },
        .many_to_many => unreachable,
    }
}

fn loadManyToMany(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *session_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    const child_table = comptime schema.tableOf(Child);
    const ParentKey = FieldOfT(M, assoc.primary_key);

    var keys: std.ArrayList(ParentKey) = .empty;
    defer keys.deinit(gpa);
    keys.ensureTotalCapacity(gpa, rows.len) catch return error.OutOfMemory;
    for (rows) |*parent| {
        const key = @field(parent, assoc.primary_key);
        if (keyPresent(ParentKey, key)) keys.appendAssumeCapacity(key);
    }
    if (keys.items.len == 0) {
        for (rows) |*parent| @field(parent, assoc.field_name) = &.{};
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var joined = try queryJoinedChildren(
        M,
        Child,
        child_table,
        assoc,
        keys.items,
        s,
        arena,
    );
    defer joined.deinit(arena);

    const child_rows = arena.alloc(Child, joined.items.len) catch return error.OutOfMemory;
    for (joined.items, 0..) |item, i| child_rows[i] = item.child;
    if (nested.len > 0) try applyPreloadPath(Child, child_rows, nested, s, arena);
    for (joined.items, 0..) |*item, i| item.child = child_rows[i];

    const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
        return error.OutOfMemory;
    defer gpa.free(slices);
    const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
    defer gpa.free(fill);
    const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
    defer gpa.free(counts);
    @memset(counts, 0);

    const owners = gpa.alloc(usize, joined.items.len) catch return error.OutOfMemory;
    defer gpa.free(owners);
    if (comptime value.keyMapType(ParentKey) != null) {
        var map: value.keyMapType(ParentKey).? = .init(gpa);
        defer map.deinit();
        for (rows, 0..) |*parent, parent_index| {
            if (value.normalizedKey(ParentKey, @field(parent, assoc.primary_key))) |k| {
                const gop = map.getOrPut(k) catch return error.OutOfMemory;
                if (!gop.found_existing) gop.value_ptr.* = parent_index;
            }
        }
        for (joined.items, 0..) |item, child_index| {
            owners[child_index] = std.math.maxInt(usize);
            if (value.normalizedKey(ParentKey, item.parent_key)) |k| {
                if (map.get(k)) |parent_index| {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                }
            }
        }
    } else {
        for (joined.items, 0..) |item, child_index| {
            owners[child_index] = std.math.maxInt(usize);
            for (rows, 0..) |*parent, parent_index| {
                if (keyEqual(ParentKey, item.parent_key, ParentKey, @field(parent, assoc.primary_key))) {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                    break;
                }
            }
        }
    }
    for (rows, 0..) |*parent, parent_index| {
        slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
        // Zero so a mid-fill error path frees only initialized slots.
        @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
        fill[parent_index] = 0;
        @field(parent, assoc.field_name) = slices[parent_index];
    }
    for (joined.items, 0..) |*item, child_index| {
        const owner = owners[child_index];
        if (owner != std.math.maxInt(usize)) {
            slices[owner][fill[owner]] = try value.deepCopy(Child, item.child, gpa);
            fill[owner] += 1;
        }
    }
}

fn loadCompositeAssoc(
    comptime M: type,
    rows: []M,
    comptime assoc: schema.Assoc,
    nested: []const u8,
    s: *session_mod.Session,
    gpa: std.mem.Allocator,
) Error!void {
    const Child = assoc.model;
    if (assoc.kind == .has_one or assoc.kind == .many_to_many)
        @compileError("zgorm: composite has-one and many-to-many keys are not supported");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const child_keys = if (assoc.kind == .belongs_to) assoc.primary_keys else assoc.foreign_keys;
    const parent_keys = if (assoc.kind == .belongs_to) assoc.foreign_keys else assoc.primary_keys;
    var children = try queryCompositeChildren(M, Child, rows, child_keys, parent_keys, s, arena);
    defer children.deinit(arena);
    if (nested.len > 0) try applyPreloadPath(Child, children.items, nested, s, arena);

    if (assoc.kind == .has_many) {
        const slices = gpa.alloc(@TypeOf(@field(@as(M, undefined), assoc.field_name)), rows.len) catch
            return error.OutOfMemory;
        defer gpa.free(slices);
        const fill = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
        defer gpa.free(fill);
        const counts = gpa.alloc(usize, rows.len) catch return error.OutOfMemory;
        defer gpa.free(counts);
        @memset(counts, 0);
        const owners = gpa.alloc(usize, children.items.len) catch return error.OutOfMemory;
        defer gpa.free(owners);
        if (comptime compositeHashable(Child, child_keys, M, parent_keys)) {
            var map: std.StringHashMap(usize) = .init(gpa);
            defer map.deinit();
            var kbuf: std.ArrayList(u8) = .empty;
            defer kbuf.deinit(gpa);
            for (rows, 0..) |*parent, parent_index| {
                kbuf.clearRetainingCapacity();
                if (!try appendCompositeKey(M, parent_keys, parent.*, &kbuf, gpa)) continue;
                const key_copy = arena.dupe(u8, kbuf.items) catch return error.OutOfMemory;
                const gop = map.getOrPut(key_copy) catch return error.OutOfMemory;
                if (!gop.found_existing) gop.value_ptr.* = parent_index;
            }
            for (children.items, 0..) |*child, child_index| {
                owners[child_index] = std.math.maxInt(usize);
                kbuf.clearRetainingCapacity();
                if (!try appendCompositeKey(Child, child_keys, child.*, &kbuf, gpa)) continue;
                if (map.get(kbuf.items)) |parent_index| {
                    owners[child_index] = parent_index;
                    counts[parent_index] += 1;
                }
            }
        } else {
            for (children.items, 0..) |*child, child_index| {
                owners[child_index] = std.math.maxInt(usize);
                for (rows, 0..) |*parent, parent_index| {
                    if (compositeKeyEqual(Child, child.*, child_keys, M, parent.*, parent_keys)) {
                        owners[child_index] = parent_index;
                        counts[parent_index] += 1;
                        break;
                    }
                }
            }
        }
        for (rows, 0..) |*parent, parent_index| {
            slices[parent_index] = gpa.alloc(Child, counts[parent_index]) catch return error.OutOfMemory;
            // Zero so a mid-fill error path frees only initialized slots.
            @memset(std.mem.sliceAsBytes(slices[parent_index]), 0);
            fill[parent_index] = 0;
            @field(parent, assoc.field_name) = slices[parent_index];
        }
        for (children.items, 0..) |*child, child_index| {
            const owner = owners[child_index];
            if (owner != std.math.maxInt(usize)) {
                slices[owner][fill[owner]] = try value.deepCopy(Child, child.*, gpa);
                fill[owner] += 1;
            }
        }
        return;
    }

    if (comptime compositeHashable(Child, child_keys, M, parent_keys)) {
        var map: std.StringHashMap(usize) = .init(gpa);
        defer map.deinit();
        var kbuf: std.ArrayList(u8) = .empty;
        defer kbuf.deinit(gpa);
        for (children.items, 0..) |*child, child_index| {
            kbuf.clearRetainingCapacity();
            if (!try appendCompositeKey(Child, child_keys, child.*, &kbuf, gpa)) continue;
            const key_copy = arena.dupe(u8, kbuf.items) catch return error.OutOfMemory;
            const gop = map.getOrPut(key_copy) catch return error.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = child_index;
        }
        for (rows) |*parent| {
            @field(parent, assoc.field_name) = null;
            kbuf.clearRetainingCapacity();
            if (!try appendCompositeKey(M, parent_keys, parent.*, &kbuf, gpa)) continue;
            if (map.get(kbuf.items)) |child_index| {
                @field(parent, assoc.field_name) = try value.deepCopy(Child, children.items[child_index], gpa);
            }
        }
    } else {
        for (rows) |*parent| {
            @field(parent, assoc.field_name) = null;
            for (children.items) |*child| {
                if (compositeKeyEqual(Child, child.*, child_keys, M, parent.*, parent_keys)) {
                    @field(parent, assoc.field_name) = try value.deepCopy(Child, child.*, gpa);
                    break;
                }
            }
        }
    }
}

fn keyPresent(comptime T: type, value_: T) bool {
    return switch (@typeInfo(T)) {
        .optional => if (value_) |unwrapped| keyPresent(@TypeOf(unwrapped), unwrapped) else false,
        else => true,
    };
}

fn keyEqual(comptime A: type, a: A, comptime B: type, b: B) bool {
    if (A == B) {
        return switch (@typeInfo(A)) {
            .pointer => |info| if (info.size == .slice and info.child == u8)
                std.mem.eql(u8, a, b)
            else
                std.meta.eql(a, b),
            else => std.meta.eql(a, b),
        };
    }
    return switch (@typeInfo(A)) {
        .optional => if (a) |unwrapped| keyEqual(@TypeOf(unwrapped), unwrapped, B, b) else false,
        else => switch (@typeInfo(B)) {
            .optional => if (b) |unwrapped| keyEqual(A, a, @TypeOf(unwrapped), unwrapped) else false,
            else => intKeyEqual(A, a, B, b),
        },
    };
}

/// Cross-width/signedness integer keys compare numerically (SQL coerces them),
/// so an i32 foreign key still matches an i64 primary key.
fn intKeyEqual(comptime A: type, a: A, comptime B: type, b: B) bool {
    if (@typeInfo(A) == .int and @typeInfo(B) == .int) {
        const ia = std.math.cast(i128, a) orelse return false;
        const ib = std.math.cast(i128, b) orelse return false;
        return ia == ib;
    }
    return false;
}

fn compositeKeyEqual(
    comptime Left: type,
    left: Left,
    comptime left_keys: []const []const u8,
    comptime Right: type,
    right: Right,
    comptime right_keys: []const []const u8,
) bool {
    if (left_keys.len != right_keys.len) return false;
    inline for (left_keys, 0..) |left_key, i| {
        if (!keyEqual(
            @TypeOf(@field(left, left_key)),
            @field(left, left_key),
            @TypeOf(@field(right, right_keys[i])),
            @field(right, right_keys[i]),
        )) return false;
    }
    return true;
}

/// True when every composite key position has an identical, hashable
/// normalized type on both sides, so matching can use a hash map.
fn compositeHashable(
    comptime L: type,
    comptime lkeys: []const []const u8,
    comptime R: type,
    comptime rkeys: []const []const u8,
) bool {
    if (lkeys.len != rkeys.len) return false;
    for (lkeys, 0..) |lk, i| {
        const LT = value.UnwrappedKey(@TypeOf(@field(@as(L, undefined), lk)));
        const RT = value.UnwrappedKey(@TypeOf(@field(@as(R, undefined), rkeys[i])));
        if (LT != RT) return false;
        // Only types with an unambiguous, compile-safe byte serialization.
        // Floats (±0.0), >64-bit ints and signed enums fall back to linear
        // matching via compositeKeyEqual.
        switch (@typeInfo(LT)) {
            .int => |info| if (info.bits > 64) return false,
            .bool => {},
            .@"enum" => |e| if (e.is_signed) return false,
            .pointer => |p| if (!(p.size == .slice and p.child == u8)) return false,
            else => return false,
        }
    }
    return true;
}

/// Serializes a composite key to canonical bytes. Returns false when any
/// component is null (such a row can never match, mirroring `keyEqual`).
fn appendCompositeKey(
    comptime M: type,
    comptime keys: []const []const u8,
    m: M,
    buf: *std.ArrayList(u8),
    buf_alloc: std.mem.Allocator,
) Error!bool {
    inline for (keys) |k| {
        const FT = @TypeOf(@field(m, k));
        const nk = value.normalizedKey(FT, @field(m, k)) orelse return false;
        const U = value.UnwrappedKey(FT);
        switch (@typeInfo(U)) {
            .int => |info| {
                var b: [8]u8 = undefined;
                const wide: u64 = if (info.signedness == .signed) @bitCast(@as(i64, nk)) else @as(u64, nk);
                std.mem.writeInt(u64, &b, wide, .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .bool => buf.append(buf_alloc, @intFromBool(nk)) catch return error.OutOfMemory,
            .@"enum" => {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @backingInt(nk), .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .float => {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, @bitCast(@as(f64, nk)), .big);
                buf.appendSlice(buf_alloc, &b) catch return error.OutOfMemory;
            },
            .pointer => {
                var lb: [8]u8 = undefined;
                std.mem.writeInt(u64, &lb, nk.len, .big);
                buf.appendSlice(buf_alloc, &lb) catch return error.OutOfMemory;
                buf.appendSlice(buf_alloc, nk) catch return error.OutOfMemory;
            },
            else => return error.UnsupportedType,
        }
    }
    return true;
}

fn JoinedChild(comptime Child: type, comptime ParentKey: type) type {
    return struct {
        child: Child,
        parent_key: ParentKey,
    };
}

fn queryChildrenForKeys(
    comptime Child: type,
    comptime child_table: schema.Table,
    key_column: []const u8,
    keys: anytype,
    extra_column: []const u8,
    extra_value: []const u8,
    s: *session_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    if (keys.len == 0) return .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("SELECT * FROM {s} WHERE {s} IN (", .{
        sqlutil.quoted(child_table.name),
        try sqlutil.quoteIdent(arena, key_column),
    }) catch return error.OutOfMemory;
    for (keys, 0..) |_, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("${d}", .{i + 1}) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;

    const extra = extra_column.len > 0;
    const params = arena.alloc(pq.Param, keys.len + @intFromBool(extra)) catch return error.OutOfMemory;
    for (keys, 0..) |key, i| params[i] = try value.toParam(key, arena);
    if (extra) {
        w.print(" AND {s} = ${d}", .{
            try sqlutil.quoteIdent(arena, extra_column),
            keys.len + 1,
        }) catch return error.OutOfMemory;
        params[keys.len] = try value.toParam(extra_value, arena);
    }
    return queryChildrenSql(Child, child_table, w.buffered(), params, s, arena);
}

fn queryChildrenSql(
    comptime Child: type,
    comptime child_table: schema.Table,
    sql: []const u8,
    params: []const pq.Param,
    s: *session_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    var res = try s.runExec(sql, params);
    defer res.deinit();

    var column_map: [child_table.columns.len]?usize = undefined;
    value.buildColumnMap(child_table, res.columns, &column_map);
    var items: std.ArrayList(Child) = .empty;
    items.ensureTotalCapacity(arena, res.rows.len) catch return error.OutOfMemory;
    for (res.rows) |row| {
        var child = try value.scanCellsMapped(Child, child_table, res.columns, row, &column_map, arena);
        try session_mod.Session.callHook(Child, "afterFind", &child, s);
        items.appendAssumeCapacity(child);
    }
    return items;
}

fn queryJoinedChildren(
    comptime Parent: type,
    comptime Child: type,
    comptime child_table: schema.Table,
    comptime assoc: schema.Assoc,
    keys: anytype,
    s: *session_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(JoinedChild(Child, FieldOfT(Parent, assoc.primary_key))) {
    const ParentKey = FieldOfT(Parent, assoc.primary_key);
    const Joined = JoinedChild(Child, ParentKey);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll("SELECT ") catch return error.OutOfMemory;
    inline for (child_table.columns, 0..) |column, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        try sqlutil.writeQualifiedIdent(w, child_table.name, column.name);
    }
    w.writeAll(", ") catch return error.OutOfMemory;
    try sqlutil.writeQualifiedIdent(w, assoc.join_table, assoc.join_foreign_key);
    w.writeAll(" AS ") catch return error.OutOfMemory;
    try sqlutil.writeIdent(w, "__zgorm_parent_key");
    w.writeAll(" FROM ") catch return error.OutOfMemory;
    try sqlutil.writeIdent(w, child_table.name);
    w.writeAll(" JOIN ") catch return error.OutOfMemory;
    try sqlutil.writeIdent(w, assoc.join_table);
    w.writeAll(" ON ") catch return error.OutOfMemory;
    try sqlutil.writeQualifiedIdent(w, assoc.join_table, assoc.join_association_key);
    w.writeAll(" = ") catch return error.OutOfMemory;
    try sqlutil.writeQualifiedIdent(w, child_table.name, assoc.association_key);
    w.writeAll(" WHERE ") catch return error.OutOfMemory;
    try sqlutil.writeQualifiedIdent(w, assoc.join_table, assoc.join_foreign_key);
    w.writeAll(" IN (") catch return error.OutOfMemory;
    for (keys, 0..) |_, i| {
        if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
        w.print("${d}", .{i + 1}) catch return error.OutOfMemory;
    }
    w.writeByte(')') catch return error.OutOfMemory;

    const params = arena.alloc(pq.Param, keys.len) catch return error.OutOfMemory;
    for (keys, 0..) |key, i| params[i] = try value.toParam(key, arena);
    var res = try s.runExec(w.buffered(), params);
    defer res.deinit();

    var key_index: ?usize = null;
    for (res.columns, 0..) |column, i| {
        if (std.mem.eql(u8, column.name, "__zgorm_parent_key")) {
            key_index = i;
            break;
        }
    }
    const key_column = key_index orelse return error.ProtocolViolation;
    var column_map: [child_table.columns.len]?usize = undefined;
    value.buildColumnMap(child_table, res.columns, &column_map);
    var items: std.ArrayList(Joined) = .empty;
    items.ensureTotalCapacity(arena, res.rows.len) catch return error.OutOfMemory;
    for (res.rows) |row| {
        var item = Joined{
            .child = try value.scanCellsMapped(Child, child_table, res.columns, row, &column_map, arena),
            .parent_key = try value.decodeCell(
                ParentKey,
                row[key_column],
                res.columns[key_column].type_oid,
                res.columns[key_column].format,
                arena,
            ),
        };
        try session_mod.Session.callHook(Child, "afterFind", &item.child, s);
        items.appendAssumeCapacity(item);
    }
    return items;
}

fn queryCompositeChildren(
    comptime Parent: type,
    comptime Child: type,
    rows: []Parent,
    comptime child_keys: []const []const u8,
    comptime parent_keys: []const []const u8,
    s: *session_mod.Session,
    arena: std.mem.Allocator,
) Error!std.ArrayList(Child) {
    if (rows.len == 0) return .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("SELECT * FROM {s} WHERE ", .{sqlutil.quoted(schema.tableOf(Child).name)}) catch
        return error.OutOfMemory;
    const params = arena.alloc(pq.Param, rows.len * child_keys.len) catch return error.OutOfMemory;
    var param_index: usize = 0;
    for (rows, 0..) |row, row_index| {
        if (row_index > 0) w.writeAll(" OR ") catch return error.OutOfMemory;
        w.writeByte('(') catch return error.OutOfMemory;
        inline for (child_keys, 0..) |child_key, key_index| {
            if (key_index > 0) w.writeAll(" AND ") catch return error.OutOfMemory;
            try sqlutil.writeIdent(w, child_key);
            w.print(" = ${d}", .{param_index + 1}) catch return error.OutOfMemory;
            params[param_index] = try value.toParam(@field(row, parent_keys[key_index]), arena);
            param_index += 1;
        }
        w.writeByte(')') catch return error.OutOfMemory;
    }
    return queryChildrenSql(Child, schema.tableOf(Child), w.buffered(), params, s, arena);
}

fn asI64(comptime FT: type, v: FT) ?i64 {
    return switch (@typeInfo(FT)) {
        .int => std.math.cast(i64, v),
        .optional => |oi| if (v) |x| asI64(oi.child, x) else null,
        else => null,
    };
}

/// Resolves a model column by Zig field name or SQL column name.
pub fn ColumnOfT(comptime M: type, comptime name: []const u8) schema.Column {
    inline for (schema.tableOf(M).columns) |column| {
        if (comptime std.mem.eql(u8, column.field_name, name) or
            std.mem.eql(u8, column.name, name)) return column;
    }
    @compileError("zgorm: model " ++ @typeName(M) ++ " has no field " ++ name);
}

/// Resolves the leaf field type, including embedded model fields.
pub fn FieldOfT(comptime M: type, comptime name: []const u8) type {
    return value.columnFieldType(M, ColumnOfT(M, name));
}

const testing = std.testing;

test "cross-width integer association keys match numerically" {
    try testing.expect(keyEqual(i32, @as(i32, 7), i64, @as(i64, 7)));
    try testing.expect(keyEqual(i64, @as(i64, 7), i32, @as(i32, 7)));
    try testing.expect(!keyEqual(i32, @as(i32, 7), i64, @as(i64, 8)));
    try testing.expect(keyEqual(?i32, @as(?i32, 7), i64, @as(i64, 7)));
    try testing.expect(!keyEqual(?i32, @as(?i32, null), i64, @as(i64, 7)));
    try testing.expect(keyEqual(u32, @as(u32, 9), i64, @as(i64, 9)));
}

test "association IDs outside i64 are ignored" {
    try testing.expectEqual(@as(?i64, null), asI64(u64, std.math.maxInt(u64)));
}
