const std = @import("std");
const types = @import("types.zig");

pub const Migration = struct {
    version: i64,
    name: []const u8,
    up: []const u8,
    down: ?[]const u8 = null,
};

pub fn Migrator(comptime Db: type) type {
    return struct {
        const Self = @This();

        db: *Db,
        migrations: std.ArrayList(Migration) = .empty,

        pub fn init(db: *Db) Self {
            return .{ .db = db };
        }

        pub fn deinit(m: *Self) void {
            m.migrations.deinit(m.db.backend.gpa);
        }

        pub fn add(m: *Self, migrations: []const Migration) types.Error!void {
            m.migrations.appendSlice(m.db.backend.gpa, migrations) catch return error.OutOfMemory;
        }

        pub fn setup(m: *Self) types.Error!void {
            try m.db.exec(
                \\CREATE TABLE IF NOT EXISTS schema_migrations (
                \\    version BIGINT PRIMARY KEY,
                \\    name TEXT NOT NULL,
                \\    checksum BIGINT NOT NULL,
                \\    dirty BOOLEAN NOT NULL DEFAULT FALSE,
                \\    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
                \\)
            );
        }

        pub fn appliedVersions(m: *Self, gpa: std.mem.Allocator) types.Error![]i64 {
            try m.setup();
            var result = try m.db.execRaw("SELECT version FROM schema_migrations ORDER BY version");
            defer result.deinit();
            const versions = gpa.alloc(i64, result.rows.len) catch return error.OutOfMemory;
            errdefer gpa.free(versions);
            for (result.rows, 0..) |row, index| {
                if (row.len == 0 or row[0] == null) return error.ProtocolViolation;
                versions[index] = std.fmt.parseInt(i64, row[0].?, 10) catch return error.TypeMismatch;
            }
            return versions;
        }

        pub fn applyAll(m: *Self) types.Error!usize {
            try m.setup();
            const gpa = m.db.backend.gpa;
            var state = try m.db.execRaw("SELECT version, checksum, dirty FROM schema_migrations ORDER BY version");
            defer state.deinit();
            var applied: std.ArrayList(i64) = .empty;
            defer applied.deinit(gpa);
            for (state.rows) |row| {
                if (row.len < 3 or row[0] == null or row[1] == null or row[2] == null)
                    return error.ProtocolViolation;
                const version = std.fmt.parseInt(i64, row[0].?, 10) catch return error.TypeMismatch;
                const checksum = std.fmt.parseInt(i64, row[1].?, 10) catch return error.TypeMismatch;
                if (parseBool(row[2].?) catch return error.TypeMismatch) return error.DirtyMigration;
                for (m.migrations.items) |migration| {
                    if (migration.version == version and checksum != checksumOf(migration.up))
                        return error.MigrationChecksumMismatch;
                }
                applied.append(gpa, version) catch return error.OutOfMemory;
            }

            const sorted = gpa.dupe(Migration, m.migrations.items) catch return error.OutOfMemory;
            defer gpa.free(sorted);
            insertionSort(sorted);
            var count: usize = 0;
            for (sorted) |migration| {
                if (contains(applied.items, migration.version)) continue;
                try m.applyOne(migration);
                count += 1;
            }
            return count;
        }

        pub fn rollbackLast(m: *Self) types.Error!?i64 {
            try m.setup();
            var latest = try m.db.execRaw("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1");
            defer latest.deinit();
            if (latest.rows.len == 0) return null;
            if (latest.rows[0].len == 0 or latest.rows[0][0] == null) return error.ProtocolViolation;
            const version = std.fmt.parseInt(i64, latest.rows[0][0].?, 10) catch return error.TypeMismatch;
            const migration = for (m.migrations.items) |candidate| {
                if (candidate.version == version) break candidate;
            } else return error.InvalidQuery;
            const down = migration.down orelse return error.InvalidQuery;
            try m.execDiscard("UPDATE schema_migrations SET dirty = TRUE WHERE version = ?", .{version});
            try m.db.execScript(down);
            try m.execDiscard("DELETE FROM schema_migrations WHERE version = ?", .{version});
            return version;
        }

        fn applyOne(m: *Self, migration: Migration) types.Error!void {
            try m.execDiscard(
                "INSERT INTO schema_migrations (version, name, checksum, dirty) VALUES (?, ?, ?, TRUE)",
                .{ migration.version, migration.name, checksumOf(migration.up) },
            );
            try m.db.execScript(migration.up);
            try m.execDiscard("UPDATE schema_migrations SET dirty = FALSE WHERE version = ?", .{migration.version});
        }

        fn execDiscard(m: *Self, sql: []const u8, args: anytype) types.Error!void {
            var result = try m.db.execArgs(sql, args);
            result.deinit();
        }
    };
}

fn checksumOf(sql: []const u8) i64 {
    return @bitCast(std.hash.Fnv1a_64.hash(sql));
}

fn contains(values: []const i64, needle: i64) bool {
    return for (values) |value| {
        if (value == needle) break true;
    } else false;
}

fn insertionSort(migrations: []Migration) void {
    for (1..migrations.len) |i| {
        const item = migrations[i];
        var j = i;
        while (j > 0 and migrations[j - 1].version > item.version) : (j -= 1)
            migrations[j] = migrations[j - 1];
        migrations[j] = item;
    }
}

fn parseBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "false")) return false;
    return error.InvalidCharacter;
}
