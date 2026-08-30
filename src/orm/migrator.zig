//! Migration version management backed by a `schema_migrations` table.
//!
//! ```zig
//! var m = z.Migrator.init(db);
//! defer m.deinit();
//! m.add(&.{
//!     .{ .version = 1, .name = "create_users",
//!        .up = "CREATE TABLE users (...)", .down = "DROP TABLE users" },
//!     .{ .version = 2, .name = "add_email", .up = "ALTER TABLE users ADD COLUMN email text" },
//! });
//! try m.applyAll(); // runs pending migrations, each in its own transaction
//! ```

const std = @import("std");
const pq = @import("../drivers/postgres/root.zig");
const db_mod = @import("db.zig");
const qb = @import("qb.zig");
const schema = @import("schema.zig");

pub const SchemaChange = struct {
    kind: enum { add, drop, alter },
    column: []u8,
    expected: []u8,
    actual: []u8,

    pub fn deinit(change: SchemaChange, gpa: std.mem.Allocator) void {
        gpa.free(change.column);
        gpa.free(change.expected);
        gpa.free(change.actual);
    }
};

pub const IndexOptions = struct {
    unique: bool = false,
    columns: []const []const u8 = &.{},
    expression: []const u8 = "",
    where: []const u8 = "",
};

pub const Error = pq.Error;

pub const Migration = struct {
    /// Monotonic version number; recorded in `schema_migrations`.
    version: i64,
    name: []const u8,
    /// SQL applied when migrating up (multiple statements allowed).
    up: []const u8,
    /// SQL applied by `rollbackLast` (optional).
    down: ?[]const u8 = null,
};

pub const Migrator = struct {
    db: *db_mod.Db,
    migrations: std.ArrayList(Migration) = .empty,

    pub fn init(db: *db_mod.Db) Migrator {
        return .{ .db = db };
    }

    pub fn deinit(m: *Migrator) void {
        m.migrations.deinit(m.db.gpa);
    }

    /// Registers migrations. Versions are applied in ascending order,
    /// regardless of registration order.
    pub fn add(m: *Migrator, migs: []const Migration) void {
        m.migrations.appendSlice(m.db.gpa, migs) catch @panic("zorm: out of memory");
    }

    /// Creates the `schema_migrations` table if it does not exist.
    pub fn setup(m: *Migrator) Error!void {
        var s = m.db.session();
        var res = try s.execRaw(
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\    version bigint PRIMARY KEY,
            \\    name text NOT NULL,
            \\    checksum bigint NOT NULL,
            \\    dirty boolean NOT NULL DEFAULT false,
            \\    applied_at timestamptz NOT NULL DEFAULT now()
            \\)
        );
        res.deinit();
        var upgrade = try s.execRaw(
            \\ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum bigint NOT NULL DEFAULT 0;
            \\ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS dirty boolean NOT NULL DEFAULT false
        );
        upgrade.deinit();
    }

    /// Versions already applied, ascending. Caller frees the slice.
    pub fn appliedVersions(m: *Migrator, gpa: std.mem.Allocator) Error![]i64 {
        var s = m.db.session();
        var res = try s.execRaw("SELECT version FROM schema_migrations ORDER BY version");
        defer res.deinit();
        var out: std.ArrayList(i64) = .empty;
        errdefer out.deinit(gpa);
        if (res.rows.len > 0 and res.columns.len == 0) return error.ProtocolViolation;
        for (res.rows) |row| {
            if (row.len == 0) return error.ProtocolViolation;
            const v = try @import("value.zig").decodeCell(
                i64,
                row[0],
                res.columns[0].type_oid,
                res.columns[0].format,
                gpa,
            );
            out.append(gpa, v) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }

    /// Applies every pending migration in ascending version order, each one
    /// inside its own transaction. Returns the number applied.
    pub fn applyAll(m: *Migrator) Error!usize {
        try m.setup();
        const gpa = m.db.gpa;
        {
            var s = m.db.session();
            var state = try s.execRaw("SELECT version, checksum, dirty FROM schema_migrations");
            defer state.deinit();
            for (state.rows) |row| {
                const version = try @import("value.zig").decodeCell(i64, row[0], state.columns[0].type_oid, state.columns[0].format, gpa);
                const checksum = try @import("value.zig").decodeCell(i64, row[1], state.columns[1].type_oid, state.columns[1].format, gpa);
                const dirty = try @import("value.zig").decodeCell(bool, row[2], state.columns[2].type_oid, state.columns[2].format, gpa);
                if (dirty) return error.DirtyMigration;
                for (m.migrations.items) |mig| {
                    if (mig.version == version) {
                        const expected: i64 = @bitCast(std.hash.Fnv1a_64.hash(mig.up));
                        if (checksum == 0) {
                            var updated = try s.exec("UPDATE schema_migrations SET checksum = $1 WHERE version = $2", .{ expected, version });
                            updated.deinit();
                        } else if (checksum != expected) {
                            return error.MigrationChecksumMismatch;
                        }
                    }
                }
            }
        }

        const applied = try m.appliedVersions(gpa);
        defer gpa.free(applied);

        // Sorted copy (small N; insertion sort keeps it simple).
        const sorted = gpa.dupe(Migration, m.migrations.items) catch return error.OutOfMemory;
        defer gpa.free(sorted);
        for (1..sorted.len) |i| {
            const key = sorted[i];
            var j = i;
            while (j > 0 and sorted[j - 1].version > key.version) : (j -= 1) {
                sorted[j] = sorted[j - 1];
            }
            sorted[j] = key;
        }

        var s = m.db.session();
        var count: usize = 0;
        for (sorted) |mig| {
            var already = false;
            for (applied) |v| {
                if (v == mig.version) already = true;
            }
            if (already) continue;

            var tx = try s.begin();
            errdefer tx.rollback();
            var lock_res = try tx.execRaw("SELECT pg_advisory_xact_lock(802766)");
            lock_res.deinit();
            var locked_state = try tx.exec("SELECT count(*) FROM schema_migrations WHERE version = $1", .{mig.version});
            defer locked_state.deinit();
            const existing = try @import("value.zig").decodeCell(
                i64,
                locked_state.rows[0][0],
                locked_state.columns[0].type_oid,
                locked_state.columns[0].format,
                gpa,
            );
            if (existing != 0) {
                try tx.commit();
                continue;
            }
            const checksum: i64 = @bitCast(std.hash.Fnv1a_64.hash(mig.up));
            var rec_res = try tx.exec(
                "INSERT INTO schema_migrations (version, name, checksum, dirty) VALUES ($1, $2, $3, true)",
                .{ mig.version, mig.name, checksum },
            );
            rec_res.deinit();
            var up_res = tx.execRaw(mig.up) catch |migration_err| {
                tx.rollback();
                var dirty_res = s.exec(
                    \\INSERT INTO schema_migrations (version, name, checksum, dirty)
                    \\VALUES ($1, $2, $3, true)
                    \\ON CONFLICT (version) DO UPDATE
                    \\SET name = EXCLUDED.name, checksum = EXCLUDED.checksum, dirty = true
                , .{ mig.version, mig.name, checksum }) catch return migration_err;
                dirty_res.deinit();
                return migration_err;
            };
            up_res.deinit();
            var clean_res = try tx.exec("UPDATE schema_migrations SET dirty = false WHERE version = $1", .{mig.version});
            clean_res.deinit();
            try tx.commit();
            count += 1;
        }
        return count;
    }

    /// Rolls back the most recently applied migration using its `down` SQL
    /// and removes its `schema_migrations` row.
    pub fn rollbackLast(m: *Migrator) Error!void {
        var s = m.db.session();

        const latest: ?i64 = blk: {
            var res = try s.execRaw("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
            defer res.deinit();
            if (res.rows.len == 0) break :blk null;
            if (res.rows[0].len == 0 or res.columns.len == 0) return error.ProtocolViolation;
            break :blk try @import("value.zig").decodeCell(
                i64,
                res.rows[0][0],
                res.columns[0].type_oid,
                res.columns[0].format,
                s.gpa,
            );
        };
        const version = latest orelse return; // nothing applied

        var down: ?[]const u8 = null;
        for (m.migrations.items) |mig| {
            if (mig.version == version) down = mig.down;
        }
        if (down == null) {
            // Unknown or irreversible migration: refuse rather than desync.
            return error.TypeMismatch;
        }

        var tx = try s.begin();
        errdefer tx.rollback();
        var down_res = try tx.execRaw(down.?);
        down_res.deinit();
        var del_res = try tx.exec("DELETE FROM schema_migrations WHERE version = $1", .{version});
        del_res.deinit();
        try tx.commit();
    }

    pub fn alterColumnType(m: *Migrator, table: []const u8, column: []const u8, ddl: []const u8, using: ?[]const u8) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sql = std.fmt.allocPrint(arena, "ALTER TABLE {s} ALTER COLUMN {s} TYPE {s}{s}{s}", .{
            try qb.quoteIdent(arena, table),
            try qb.quoteIdent(arena, column),
            ddl,
            if (using != null) " USING " else "",
            using orelse "",
        }) catch return error.OutOfMemory;
        var res = try m.db.execRaw(sql);
        res.deinit();
    }

    pub fn dropColumn(m: *Migrator, table: []const u8, column: []const u8) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sql = std.fmt.allocPrint(arena, "ALTER TABLE {s} DROP COLUMN {s}", .{
            try qb.quoteIdent(arena, table), try qb.quoteIdent(arena, column),
        }) catch return error.OutOfMemory;
        var res = try m.db.execRaw(sql);
        res.deinit();
    }

    pub fn renameColumn(m: *Migrator, table: []const u8, old: []const u8, new: []const u8) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sql = std.fmt.allocPrint(arena, "ALTER TABLE {s} RENAME COLUMN {s} TO {s}", .{
            try qb.quoteIdent(arena, table), try qb.quoteIdent(arena, old), try qb.quoteIdent(arena, new),
        }) catch return error.OutOfMemory;
        var res = try m.db.execRaw(sql);
        res.deinit();
    }

    pub fn addForeignKey(
        m: *Migrator,
        table: []const u8,
        name: []const u8,
        columns: []const []const u8,
        ref_table: []const u8,
        ref_columns: []const []const u8,
        on_delete: []const u8,
    ) Error!void {
        if (columns.len == 0 or columns.len != ref_columns.len) return error.InvalidQuery;
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.print("ALTER TABLE {s} ADD CONSTRAINT {s} FOREIGN KEY (", .{
            try qb.quoteIdent(arena, table), try qb.quoteIdent(arena, name),
        }) catch return error.OutOfMemory;
        for (columns, 0..) |column, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(try qb.quoteIdent(arena, column)) catch return error.OutOfMemory;
        }
        w.print(") REFERENCES {s} (", .{try qb.quoteIdent(arena, ref_table)}) catch return error.OutOfMemory;
        for (ref_columns, 0..) |column, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(try qb.quoteIdent(arena, column)) catch return error.OutOfMemory;
        }
        w.print(") ON DELETE {s}", .{on_delete}) catch return error.OutOfMemory;
        var res = try m.db.execRaw(aw.writer.buffered());
        res.deinit();
    }

    pub fn addCheck(m: *Migrator, table: []const u8, name: []const u8, expression: []const u8) Error!void {
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const sql = std.fmt.allocPrint(arena, "ALTER TABLE {s} ADD CONSTRAINT {s} CHECK ({s})", .{
            try qb.quoteIdent(arena, table), try qb.quoteIdent(arena, name), expression,
        }) catch return error.OutOfMemory;
        var res = try m.db.execRaw(sql);
        res.deinit();
    }

    pub fn createIndex(m: *Migrator, table: []const u8, name: []const u8, options: IndexOptions) Error!void {
        if (options.columns.len == 0 and options.expression.len == 0) return error.InvalidQuery;
        var arena_state = std.heap.ArenaAllocator.init(m.db.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        w.print("CREATE {s}INDEX {s} ON {s} (", .{
            if (options.unique) "UNIQUE " else "",
            try qb.quoteIdent(arena, name),
            try qb.quoteIdent(arena, table),
        }) catch return error.OutOfMemory;
        if (options.expression.len > 0) {
            w.writeAll(options.expression) catch return error.OutOfMemory;
        } else for (options.columns, 0..) |column, i| {
            if (i > 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.writeAll(try qb.quoteIdent(arena, column)) catch return error.OutOfMemory;
        }
        w.writeByte(')') catch return error.OutOfMemory;
        if (options.where.len > 0) w.print(" WHERE {s}", .{options.where}) catch return error.OutOfMemory;
        var res = try m.db.execRaw(aw.writer.buffered());
        res.deinit();
    }

    pub fn schemaDiff(m: *Migrator, comptime T: type, gpa: std.mem.Allocator) Error![]SchemaChange {
        const table = comptime schema.tableOf(T);
        var res = try m.db.exec(
            "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1",
            .{table.name},
        );
        defer res.deinit();
        var changes: std.ArrayList(SchemaChange) = .empty;
        errdefer {
            for (changes.items) |change| change.deinit(gpa);
            changes.deinit(gpa);
        }
        inline for (table.columns) |column| {
            var actual: ?[]const u8 = null;
            for (res.rows) |row| {
                if (std.mem.eql(u8, row[0].?, column.name)) actual = row[1].?;
            }
            if (actual == null) {
                changes.append(gpa, .{
                    .kind = .add,
                    .column = gpa.dupe(u8, column.name) catch return error.OutOfMemory,
                    .expected = gpa.dupe(u8, column.ddl_type) catch return error.OutOfMemory,
                    .actual = gpa.dupe(u8, "") catch return error.OutOfMemory,
                }) catch return error.OutOfMemory;
            } else if (!std.mem.eql(u8, actual.?, column.ddl_type) and
                !(std.mem.eql(u8, actual.?, "character varying") and std.mem.eql(u8, column.ddl_type, "text")))
            {
                changes.append(gpa, .{
                    .kind = .alter,
                    .column = gpa.dupe(u8, column.name) catch return error.OutOfMemory,
                    .expected = gpa.dupe(u8, column.ddl_type) catch return error.OutOfMemory,
                    .actual = gpa.dupe(u8, actual.?) catch return error.OutOfMemory,
                }) catch return error.OutOfMemory;
            }
        }
        for (res.rows) |row| {
            var found = false;
            inline for (table.columns) |column| {
                if (std.mem.eql(u8, row[0].?, column.name)) found = true;
            }
            if (!found) changes.append(gpa, .{
                .kind = .drop,
                .column = gpa.dupe(u8, row[0].?) catch return error.OutOfMemory,
                .expected = gpa.dupe(u8, "") catch return error.OutOfMemory,
                .actual = gpa.dupe(u8, row[1].?) catch return error.OutOfMemory,
            }) catch return error.OutOfMemory;
        }
        return changes.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }

    /// Creates the table for `T` if missing / adds missing columns (uses the
    /// same logic as `Db.autoMigrate`).
    pub fn autoMigrate(m: *Migrator, comptime T: type) Error!void {
        var s = m.db.session();
        try s.autoMigrate(T);
    }

    /// Runs autoMigrate for every model in the tuple.
    pub fn autoMigrateAll(m: *Migrator, comptime models: anytype) Error!void {
        var s = m.db.session();
        try s.autoMigrateAll(models);
    }
};
