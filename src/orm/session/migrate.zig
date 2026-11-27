//! Incremental PostgreSQL schema migration: create missing tables, add
//! missing columns, and ensure declared indexes.

const std = @import("std");
const pq = @import("../../drivers/postgres/root.zig");
const qb_mod = @import("../qb.zig");
const schema = @import("../schema.zig");
const crud_sql = @import("crud_sql.zig");
const session_mod = @import("../session.zig");

const Session = session_mod.Session;
pub const Error = pq.Error;
const SqlBuf = crud_sql.SqlBuf;
const zeroDefault = crud_sql.zeroDefault;

/// Creates the table for `T` if missing, and adds any missing columns.
pub fn autoMigrate(s: *Session, comptime T: type) Error!void {
    const table = comptime schema.tableOf(T);

    var arena_state = std.heap.ArenaAllocator.init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var existing: std.ArrayList([]const u8) = .empty;
    {
        var res = try s.exec(
            "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
            .{table.name},
        );
        defer res.deinit();
        for (res.rows) |row| {
            if (row[0]) |name| {
                existing.append(arena, arena.dupe(u8, name) catch return error.OutOfMemory) catch return error.OutOfMemory;
            }
        }
    }

    if (existing.items.len == 0) {
        var b = crud_sql.SqlBuf.init(arena);
        const w = b.w();
        w.print("CREATE TABLE IF NOT EXISTS {s} (", .{try qb_mod.quoteIdent(arena, table.name)}) catch return error.OutOfMemory;
        inline for (table.columns, 0..) |col, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            if (col.is_auto) {
                const serial: []const u8 = if (std.mem.eql(u8, col.ddl_type, "integer"))
                    "serial"
                else if (std.mem.eql(u8, col.ddl_type, "bigint"))
                    "bigserial"
                else
                    col.ddl_type;
                w.print("{s} {s} PRIMARY KEY", .{ try qb_mod.quoteIdent(arena, col.name), serial }) catch return error.OutOfMemory;
            } else {
                w.print("{s} {s}", .{ try qb_mod.quoteIdent(arena, col.name), col.ddl_type }) catch return error.OutOfMemory;
                if (!col.is_optional) w.writeAll(" NOT NULL") catch return error.OutOfMemory;
                if (col.is_pk and table.pk_indexes.len == 1) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
            }
        }
        if (table.pk_indexes.len > 1) {
            w.writeAll(", PRIMARY KEY (") catch return error.OutOfMemory;
            inline for (table.pk_indexes, 0..) |pk_index, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(qb_mod.quoted(table.columns[pk_index].name)) catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
        }
        w.writeAll(")") catch return error.OutOfMemory;
        var res = try s.execRaw(b.slice());
        res.deinit();
    } else {
        // Does the table already have a primary key? Auto-increment
        // columns can only carry PRIMARY KEY when none exists.
        var table_has_pk = false;
        {
            var res = try s.exec(
                \\SELECT 1 FROM information_schema.table_constraints
                \\WHERE table_schema = current_schema() AND table_name = $1
                \\  AND constraint_type = 'PRIMARY KEY' LIMIT 1
            ,
                .{table.name},
            );
            defer res.deinit();
            table_has_pk = res.rows.len > 0;
        }

        inline for (table.columns) |col| {
            var found = false;
            for (existing.items) |name| {
                if (std.mem.eql(u8, name, col.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var b = crud_sql.SqlBuf.init(arena);
                const w = b.w();
                w.print("ALTER TABLE {s} ADD COLUMN IF NOT EXISTS {s} ", .{
                    try qb_mod.quoteIdent(arena, table.name),
                    try qb_mod.quoteIdent(arena, col.name),
                }) catch return error.OutOfMemory;
                if (col.is_auto) {
                    // Serial implies NOT NULL + sequence default.
                    const serial: []const u8 = if (std.mem.eql(u8, col.ddl_type, "integer"))
                        "serial"
                    else if (std.mem.eql(u8, col.ddl_type, "bigint"))
                        "bigserial"
                    else
                        col.ddl_type;
                    w.writeAll(serial) catch return error.OutOfMemory;
                    if (!table_has_pk) w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                } else {
                    w.writeAll(col.ddl_type) catch return error.OutOfMemory;
                    if (!col.is_optional) {
                        w.print(" NOT NULL DEFAULT {s}", .{crud_sql.zeroDefault(col.kind)}) catch return error.OutOfMemory;
                    }
                    if (col.is_pk and table.pk_indexes.len == 1 and !table_has_pk) {
                        w.writeAll(" PRIMARY KEY") catch return error.OutOfMemory;
                    }
                }
                var res = try s.execRaw(b.slice());
                res.deinit();
            }
        }
        if (table.pk_indexes.len > 1 and !table_has_pk) {
            var b = crud_sql.SqlBuf.init(arena);
            const w = b.w();
            w.print("ALTER TABLE {s} ADD PRIMARY KEY (", .{
                try qb_mod.quoteIdent(arena, table.name),
            }) catch return error.OutOfMemory;
            inline for (table.pk_indexes, 0..) |pk_index, i| {
                if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
                w.writeAll(qb_mod.quoted(table.columns[pk_index].name)) catch return error.OutOfMemory;
            }
            w.writeByte(')') catch return error.OutOfMemory;
            var res = try s.execRaw(b.slice());
            res.deinit();
        }
    }

    // Single-column indexes.
    inline for (table.unique) |col_name| {
        const idx = std.fmt.allocPrint(arena, "uq_{s}_{s}", .{ table.name, col_name }) catch return error.OutOfMemory;
        var b = crud_sql.SqlBuf.init(arena);
        b.w().print("CREATE UNIQUE INDEX IF NOT EXISTS {s} ON {s} ({s})", .{
            try qb_mod.quoteIdent(arena, idx),
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, col_name),
        }) catch return error.OutOfMemory;
        var res = try s.execRaw(b.slice());
        res.deinit();
    }
    inline for (table.indexes) |col_name| {
        const idx = std.fmt.allocPrint(arena, "idx_{s}_{s}", .{ table.name, col_name }) catch return error.OutOfMemory;
        var b = crud_sql.SqlBuf.init(arena);
        b.w().print("CREATE INDEX IF NOT EXISTS {s} ON {s} ({s})", .{
            try qb_mod.quoteIdent(arena, idx),
            try qb_mod.quoteIdent(arena, table.name),
            try qb_mod.quoteIdent(arena, col_name),
        }) catch return error.OutOfMemory;
        var res = try s.execRaw(b.slice());
        res.deinit();
    }
}

/// Runs autoMigrate for every model in the tuple.
pub fn autoMigrateAll(s: *Session, comptime models: anytype) Error!void {
    inline for (models) |T| try s.autoMigrate(T);
}
