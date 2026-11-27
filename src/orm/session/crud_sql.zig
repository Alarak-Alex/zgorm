//! Compile-time SQL statement templates for typed CRUD, plus the arena SQL
//! builder shared by session operations. The statements are fully determined
//! by the model at comptime; only parameter encoding happens at runtime.

const std = @import("std");
const pq = @import("../../drivers/postgres/root.zig");
const qb_mod = @import("../qb.zig");
const schema = @import("../schema.zig");
const value = @import("../value.zig");

pub const Error = pq.Error;

/// PostgreSQL ON CONFLICT policy. An empty `update` list means DO NOTHING;
/// otherwise each whitelisted column is assigned from `EXCLUDED`.
pub const OnConflict = struct {
    columns: []const []const u8 = &.{},
    update: []const []const u8 = &.{},
};

/// PostgreSQL's hard limit on bind parameters; batch inserts are chunked to
/// respect it.
pub const max_params = 65535;

/// SQL text builder over an arena. All SQL assembled here is released with
/// the arena that owns it.
pub const SqlBuf = struct {
    aw: std.Io.Writer.Allocating,

    pub fn init(arena: std.mem.Allocator) SqlBuf {
        return .{ .aw = std.Io.Writer.Allocating.init(arena) };
    }

    pub fn w(b: *SqlBuf) *std.Io.Writer {
        return &b.aw.writer;
    }

    pub fn slice(b: *SqlBuf) []const u8 {
        return b.aw.writer.buffered();
    }
};

/// Type-appropriate zero value used as DEFAULT when adding NOT NULL columns
/// to existing tables (PostgreSQL requires a default for existing rows).
pub fn zeroDefault(kind: schema.FieldKind) []const u8 {
    return switch (kind) {
        .integer, .unsigned, .float => "0",
        .boolean => "false",
        .text, .enum_, .bytes, .custom => "''",
        .time => "now()",
        .jsonb => "'{}'::jsonb",
        .int_array, .uint_array, .float_array, .bool_array, .text_array => "'{}'",
    };
}

pub fn containsName(comptime names: []const []const u8, comptime needle: []const u8) bool {
    inline for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

pub fn FindPredicates(comptime T: type, comptime index: usize) type {
    const table = schema.tableOf(T);
    if (index == table.pk_indexes.len) return struct {
        pub const value = [0]u8{};
    };
    const column = table.columns[table.pk_indexes[index]];
    const separator = if (index == 0) "" else " AND ";
    return struct {
        pub const value = separator ++
            qb_mod.QuotedIdent(column.name).value ++
            " = $" ++
            std.fmt.comptimePrint("{d}", .{index + 1}) ++
            FindPredicates(T, index + 1).value;
    };
}

pub fn FindSoftDelete(comptime T: type, comptime unscoped: bool) type {
    const table = schema.tableOf(T);
    if (!table.softDeletable() or unscoped) return struct {
        pub const value = [0]u8{};
    };
    const column = table.columns[table.deleted_at_index.?];
    return struct {
        pub const value = " AND " ++ qb_mod.QuotedIdent(column.name).value ++ " IS NULL";
    };
}

pub fn FindSql(comptime T: type, comptime unscoped: bool) type {
    const table = schema.tableOf(T);
    return struct {
        pub const value = "SELECT * FROM " ++
            qb_mod.QuotedIdent(table.name).value ++
            " WHERE " ++
            FindPredicates(T, 0).value ++
            FindSoftDelete(T, unscoped).value ++
            " LIMIT 1";
    };
}

pub fn updateSetCount(comptime table: schema.Table) usize {
    var n: usize = 0;
    for (table.columns, 0..) |col, i| {
        if (!col.is_pk and (table.version_index == null or table.version_index.? != i)) n += 1;
    }
    return n;
}

pub fn UpdateSetCols(comptime T: type, comptime index: usize, comptime np: usize) type {
    const table = schema.tableOf(T);
    if (index == table.columns.len) return struct {
        pub const value = [0]u8{};
    };
    const col = table.columns[index];
    if (col.is_pk or (table.version_index != null and table.version_index.? == index))
        return UpdateSetCols(T, index + 1, np);
    const separator = if (np == 0) "" else ", ";
    return struct {
        pub const value = separator ++
            qb_mod.QuotedIdent(col.name).value ++
            " = $" ++
            std.fmt.comptimePrint("{d}", .{np + 1}) ++
            UpdateSetCols(T, index + 1, np + 1).value;
    };
}

pub fn UpdateVersionSet(comptime T: type, comptime set_count: usize) type {
    const table = schema.tableOf(T);
    if (table.version_index == null) return struct {
        pub const value = [0]u8{};
    };
    const col = table.columns[table.version_index.?];
    const separator = if (set_count == 0) "" else ", ";
    return struct {
        pub const value = separator ++
            qb_mod.QuotedIdent(col.name).value ++
            " = " ++
            qb_mod.QuotedIdent(col.name).value ++
            " + 1";
    };
}

pub fn UpdatePkPredicates(comptime T: type, comptime index: usize, comptime offset: usize) type {
    const table = schema.tableOf(T);
    if (index == table.pk_indexes.len) return struct {
        pub const value = [0]u8{};
    };
    const column = table.columns[table.pk_indexes[index]];
    const separator = if (index == 0) "" else " AND ";
    return struct {
        pub const value = separator ++
            qb_mod.QuotedIdent(column.name).value ++
            " = $" ++
            std.fmt.comptimePrint("{d}", .{offset + index + 1}) ++
            UpdatePkPredicates(T, index + 1, offset).value;
    };
}

pub fn UpdateVersionWhere(comptime T: type, comptime param_index: usize) type {
    const table = schema.tableOf(T);
    if (table.version_index == null) return struct {
        pub const value = [0]u8{};
    };
    const col = table.columns[table.version_index.?];
    return struct {
        pub const value = " AND " ++
            qb_mod.QuotedIdent(col.name).value ++
            " = $" ++
            std.fmt.comptimePrint("{d}", .{param_index});
    };
}

/// The full UPDATE statement is determined by the model and `unscoped` alone;
/// building it at comptime leaves only parameter encoding at runtime.
pub fn UpdateSql(comptime T: type, comptime unscoped: bool) type {
    const table = schema.tableOf(T);
    const set_count = updateSetCount(table);
    return struct {
        pub const value = "UPDATE " ++
            qb_mod.QuotedIdent(table.name).value ++
            " SET " ++
            UpdateSetCols(T, 0, 0).value ++
            UpdateVersionSet(T, set_count).value ++
            " WHERE " ++
            UpdatePkPredicates(T, 0, set_count).value ++
            FindSoftDelete(T, unscoped).value ++
            UpdateVersionWhere(T, set_count + table.pk_indexes.len + 1).value;
    };
}

pub fn DeleteSql(comptime T: type, comptime hard: bool) type {
    const table = schema.tableOf(T);
    if (table.softDeletable() and !hard) {
        const del_col = table.columns[table.deleted_at_index.?];
        const stamp = qb_mod.softDeleteStampSql(value.columnFieldType(T, del_col));
        return struct {
            pub const value = "UPDATE " ++
                qb_mod.QuotedIdent(table.name).value ++
                " SET " ++
                qb_mod.QuotedIdent(del_col.name).value ++
                " = " ++
                stamp ++
                " WHERE " ++
                FindPredicates(T, 0).value;
        };
    }
    return struct {
        pub const value = "DELETE FROM " ++
            qb_mod.QuotedIdent(table.name).value ++
            " WHERE " ++
            FindPredicates(T, 0).value;
    };
}

pub fn RestoreSql(comptime T: type) type {
    const table = schema.tableOf(T);
    const pkc = table.columns[table.pk_index.?];
    const del_col = table.columns[table.deleted_at_index.?];
    return struct {
        pub const value = "UPDATE " ++
            qb_mod.QuotedIdent(table.name).value ++
            " SET " ++
            qb_mod.QuotedIdent(del_col.name).value ++
            " = NULL WHERE " ++
            qb_mod.QuotedIdent(pkc.name).value ++
            " = $1";
    };
}

pub fn autoColumnCount(comptime table: schema.Table) usize {
    var n: usize = 0;
    for (table.columns) |col| {
        if (col.is_auto) n += 1;
    }
    return n;
}

/// Compile-time INSERT for the common single-auto-increment-pk model.
/// `include_auto` selects whether the auto pk is present (non-zero) or omitted
/// (zero, to be generated); `returning` appends RETURNING for the omitted case.
pub fn InsertSql(comptime T: type, comptime include_auto: bool, comptime returning: bool) type {
    const table = schema.tableOf(T);
    return struct {
        pub const value = blk: {
            var s: []const u8 = "INSERT INTO " ++ qb_mod.QuotedIdent(table.name).value ++ " (";
            var first = true;
            var n: usize = 0;
            for (table.columns) |col| {
                if (col.is_auto and !include_auto) continue;
                if (!first) s = s ++ ", ";
                s = s ++ qb_mod.QuotedIdent(col.name).value;
                first = false;
                n += 1;
            }
            s = s ++ ") VALUES (";
            var k: usize = 0;
            while (k < n) : (k += 1) {
                if (k > 0) s = s ++ ", ";
                s = s ++ "$" ++ std.fmt.comptimePrint("{d}", .{k + 1});
            }
            s = s ++ ")";
            if (returning) s = s ++ " RETURNING " ++ qb_mod.QuotedIdent(table.pk().?.name).value;
            break :blk s;
        };
    };
}
