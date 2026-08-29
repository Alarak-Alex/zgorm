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
const pq = @import("../pq.zig");
const db_mod = @import("db.zig");

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
            \\    applied_at timestamptz NOT NULL DEFAULT now()
            \\)
        );
        res.deinit();
    }

    /// Versions already applied, ascending. Caller frees the slice.
    pub fn appliedVersions(m: *Migrator, gpa: std.mem.Allocator) Error![]i64 {
        var s = m.db.session();
        var res = try s.execRaw("SELECT version FROM schema_migrations ORDER BY version");
        defer res.deinit();
        var out: std.ArrayList(i64) = .empty;
        for (res.rows) |row| {
            const cell = row[0] orelse continue;
            const v = @import("value.zig").decodeCell(i64, cell, res.columns[0].type_oid, res.columns[0].format, gpa) catch continue;
            out.append(gpa, v) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(gpa) catch return error.OutOfMemory;
    }

    /// Applies every pending migration in ascending version order, each one
    /// inside its own transaction. Returns the number applied.
    pub fn applyAll(m: *Migrator) Error!usize {
        try m.setup();
        const gpa = m.db.gpa;

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
            var up_res = try tx.execRaw(mig.up);
            up_res.deinit();
            var rec_res = try tx.exec(
                "INSERT INTO schema_migrations (version, name) VALUES ($1, $2)",
                .{ mig.version, mig.name },
            );
            rec_res.deinit();
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
            if (res.rows.len == 0 or res.rows[0][0] == null) break :blk null;
            break :blk @import("value.zig").decodeCell(i64, res.rows[0][0], res.columns[0].type_oid, res.columns[0].format, s.gpa) catch null;
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
