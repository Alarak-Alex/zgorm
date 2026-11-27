const std = @import("std");
const z = @import("zgorm");

const gpa = std.testing.allocator;

fn openDb() !*z.Db {
    const dsn = try @import("postgres_config.zig").dsn();
    defer gpa.free(dsn);
    const db = try z.Db.connectDsn(gpa, std.testing.io, dsn, 1);
    db.setLogger(z.Logger.discard);
    return db;
}

fn exec(db: anytype, sql: []const u8) !void {
    var res = try db.execRaw(sql);
    res.deinit();
}

fn expectValue(db: anytype, sql: []const u8, expected: []const u8) !void {
    var res = try db.execRaw(sql);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings(expected, res.rows[0][0].?);
}

test "commit reports a rollback after a caught PostgreSQL statement error" {
    const db = try openDb();
    defer db.deinit();
    try exec(db, "CREATE TEMP TABLE commit_rows (id int PRIMARY KEY)");
    var tx = try db.begin();
    defer tx.rollback();
    try exec(&tx, "INSERT INTO commit_rows VALUES (1)");
    try std.testing.expectError(error.UniqueViolation, exec(&tx, "INSERT INTO commit_rows VALUES (1)"));
    try std.testing.expectError(error.QueryFailed, tx.commit());
    try std.testing.expectEqualStrings("23505", db.lastError().?.code);
    try expectValue(db, "SELECT count(*) FROM commit_rows", "0");
    try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);
}

const Child = struct {
    id: ?i64 = null,
    owner_id: ?i64 = null,
    name: []const u8,
    pub const zgorm = .{ .table = "replace_children" };

    pub fn beforeCreate(self: *@This(), _: *z.Session) z.Error!void {
        if (std.mem.eql(u8, self.name, "hook failure")) return error.HookAborted;
    }
};

const Owner = struct {
    id: ?i64 = null,
    children: []Child = &.{},
    tags: []Child = &.{},
    pub const zgorm = .{
        .table = "replace_owners",
        .has_many = .{ .children = .{ .model = Child, .foreign_key = "owner_id" } },
        .many_to_many = .{ .tags = .{
            .model = Child,
            .foreign_key = "owner_id",
            .join_table = "replace_tags",
            .join_foreign_key = "owner_id",
            .join_association_key = "child_id",
        } },
    };
};

test "standalone many-to-many replacement rolls back the clear and saved children on a join failure" {
    const db = try openDb();
    defer db.deinit();
    try exec(db,
        \\CREATE TEMP TABLE replace_children (id bigserial PRIMARY KEY, owner_id bigint, name text);
        \\CREATE TEMP TABLE replace_tags (owner_id bigint, child_id bigint REFERENCES replace_children(id));
        \\INSERT INTO replace_children (name) VALUES ('old');
        \\INSERT INTO replace_tags VALUES (1, 1);
    );
    var owner = Owner{ .id = 1 };
    var tags = db.association(&owner, "tags");
    var replacements = [_]Child{ .{ .name = "new" }, .{ .id = 99, .name = "missing" } };
    try std.testing.expectError(error.ForeignKeyViolation, tags.replace(&replacements));
    try expectValue(db, "SELECT child_id FROM replace_tags WHERE owner_id = 1", "1");
    try expectValue(db, "SELECT count(*) FROM replace_children", "1");
    try std.testing.expectEqual(@as(?i64, null), replacements[0].id);
    try std.testing.expectEqual(@as(?i64, 99), replacements[1].id);
    replacements[1] = .{ .name = "fixed" };
    try tags.replace(&replacements);
    try std.testing.expect(replacements[0].id != null and replacements[1].id != null);
    try expectValue(db, "SELECT string_agg(name, ',' ORDER BY name) FROM replace_children JOIN replace_tags ON id = child_id WHERE replace_tags.owner_id = 1", "fixed,new");
}

test "caught nested association replacement errors preserve the old children and let the outer transaction commit" {
    const db = try openDb();
    defer db.deinit();
    try exec(db,
        \\CREATE TEMP TABLE replace_children (id bigserial PRIMARY KEY, owner_id bigint, name text CHECK (name <> 'check failure'));
        \\INSERT INTO replace_children (owner_id, name) VALUES (1, 'old');
    );
    const RejectControl = struct {
        enabled: bool = false,

        fn before(raw: ?*anyopaque, context: z.plugins.QueryContext) bool {
            const state: *@This() = @ptrCast(@alignCast(raw.?));
            return !state.enabled or !(std.mem.startsWith(u8, context.sql, "RELEASE") or std.mem.startsWith(u8, context.sql, "ROLLBACK"));
        }
    };
    var reject_control = RejectControl{};
    try db.addPlugin(.{ .context = &reject_control, .before_query = RejectControl.before });
    var owner = Owner{ .id = 1 };
    var tx = try db.begin();
    defer tx.rollback();
    var sp = try tx.begin();
    defer sp.rollback();
    var children = sp.association(&owner, "children");
    var hook_failure = [_]Child{ .{ .name = "first" }, .{ .name = "hook failure" } };
    try std.testing.expectError(error.HookAborted, children.replace(&hook_failure));
    try expectValue(&sp, "SELECT name FROM replace_children WHERE owner_id = 1", "old");
    var check_failure = [_]Child{ .{ .name = "first" }, .{ .name = "check failure" } };
    try std.testing.expectError(error.CheckViolation, children.replace(&check_failure));
    reject_control.enabled = true;
    var release_failure = [_]Child{.{ .name = "before veto" }};
    try std.testing.expectError(error.HookAborted, children.replace(&release_failure));
    try std.testing.expectEqual(@as(?i64, null), release_failure[0].id);
    reject_control.enabled = false;
    try exec(&sp, "INSERT INTO replace_children (owner_id, name) VALUES (2, 'other')");
    try sp.commit();
    try tx.commit();
    try expectValue(db, "SELECT name FROM replace_children WHERE owner_id = 1", "old");
    try expectValue(db, "SELECT name FROM replace_children WHERE owner_id = 2", "other");
}

test "updates refresh all supported updated_at types while preserving supplied insert timestamps" {
    const db = try openDb();
    defer db.deinit();
    inline for (.{ z.Time, ?z.Time, i64, ?i64 }) |Stamp| {
        const Row = struct {
            id: ?i64 = null,
            created_at: Stamp,
            updated_at: Stamp,
            pub const zgorm = .{ .table = "stamp_rows" };
        };
        const time_type = Stamp == z.Time or Stamp == ?z.Time;
        const sql_type = if (time_type) "timestamptz" else "bigint";
        try exec(db, "CREATE TEMP TABLE stamp_rows (id bigserial PRIMARY KEY, created_at " ++ sql_type ++ ", updated_at " ++ sql_type ++ ")");
        const original: Stamp = if (time_type) z.Time.fromUnix(123) else 123;
        var row = Row{ .created_at = original, .updated_at = original };
        try db.insert(&row);
        const loaded = (try db.find(Row, row.id)).?;
        try std.testing.expectEqual(original, loaded.created_at);
        try std.testing.expectEqual(original, loaded.updated_at);
        var update = loaded;
        try std.testing.expectEqual(@as(i64, 1), try db.update(&update));
        try std.testing.expect(!std.meta.eql(original, update.updated_at));
        const saved = (try db.find(Row, row.id)).?;
        try std.testing.expectEqual(update.updated_at, saved.updated_at);
        try std.testing.expectEqual(original, saved.created_at);
        const empty: Stamp = switch (Stamp) {
            z.Time => z.Time.fromUnix(0),
            i64 => 0,
            else => null,
        };
        var defaulted = Row{ .created_at = empty, .updated_at = empty };
        try db.insert(&defaulted);
        try std.testing.expect(!std.meta.eql(empty, defaulted.created_at));
        try std.testing.expectEqual(defaulted.created_at, defaulted.updated_at);
        try exec(db, "DROP TABLE stamp_rows");
    }
}

const SlowRow = struct {
    id: i64,
    pub const zgorm = .{ .table = "slow_rows" };
};

fn readAll(db: *z.Db) !void {
    const rows = try z.query(SlowRow, db).all(gpa);
    defer gpa.free(rows);
}

test "connection query timeout applies to all first and find with binary and text results" {
    const dsn = try @import("postgres_config.zig").dsn();
    defer gpa.free(dsn);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var cfg = try z.pq.parseDsn(arena.allocator(), dsn);
    cfg.query_timeout_ms = 50;
    for ([_]bool{ true, false }) |binary| {
        cfg.binary_results = binary;
        const db = try z.Db.connect(gpa, std.testing.io, cfg, 1);
        defer db.deinit();
        db.setLogger(z.Logger.discard);
        const create_view = "CREATE OR REPLACE TEMP VIEW slow_rows AS SELECT 1::bigint AS id FROM pg_sleep(0.5)";
        try exec(db, create_view);
        try std.testing.expectError(error.QueryTimeout, readAll(db));
        try exec(db, create_view);
        try std.testing.expectError(error.QueryTimeout, z.query(SlowRow, db).first());
        try exec(db, create_view);
        try std.testing.expectError(error.QueryTimeout, db.find(SlowRow, @as(i64, 1)));
        try db.ping();
        try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);
    }
}

const StreamRow = struct {
    id: i64,
    payload: []const u8,
    pub const zgorm = .{ .table = "slow_stream" };
};

test "explicit streams honor builder and connection deadlines after delivering an initial row" {
    const dsn = try @import("postgres_config.zig").dsn();
    defer gpa.free(dsn);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var cfg = try z.pq.parseDsn(arena.allocator(), dsn);
    const Timeouts = struct { connection: u64, query: u64 };
    for ([_]Timeouts{
        .{ .connection = 0, .query = 250 },
        .{ .connection = 250, .query = 0 },
        .{ .connection = 250, .query = 10_000 },
        .{ .connection = 10_000, .query = 250 },
    }) |timeouts| {
        cfg.query_timeout_ms = timeouts.connection;
        const db = try z.Db.connect(gpa, std.testing.io, cfg, 1);
        defer db.deinit();
        db.setLogger(z.Logger.discard);
        // PostgreSQL flushes the tail of row 1 while writing row 2, before row 3 sleeps.
        try exec(db,
            \\CREATE TEMP VIEW slow_stream AS
            \\SELECT i::bigint AS id, CASE WHEN i < 3 THEN repeat('x', 32768)
            \\    ELSE (SELECT 'late'::text FROM pg_sleep(5)) END AS payload
            \\FROM generate_series(1, 3) AS t(i)
        );
        var rows = try z.query(StreamRow, db).timeout(timeouts.query).stream(gpa);
        defer rows.deinit();
        const first = (try rows.next()).?;
        defer z.free(StreamRow, first, gpa);
        try std.testing.expectEqual(@as(i64, 1), first.id);
        const started = std.Io.Clock.awake.now(std.testing.io);
        while (rows.next()) |item| {
            const row = item orelse return error.TestExpectedError;
            defer z.free(StreamRow, row, gpa);
            try std.testing.expectEqual(@as(i64, 2), row.id);
        } else |err| try std.testing.expectEqual(error.QueryTimeout, err);
        try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds() < 3_000);
        try db.ping();
        try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);
    }
}

test "closing a timed stream disarms cancellation before the next pooled query" {
    const db = try openDb();
    defer db.deinit();
    try exec(db, "CREATE TEMP VIEW slow_rows AS SELECT i::bigint AS id FROM generate_series(1, 2) AS t(i)");
    for ([_]bool{ false, true }) |consume_all| {
        var rows = try z.query(SlowRow, db).timeout(200).stream(gpa);
        defer rows.deinit();
        try std.testing.expect((try rows.next()) != null);
        if (consume_all) while (try rows.next()) |_| {};
        rows.deinit();
        try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);
        // The temp view also verifies reuse of the original connection. A stale timer would cancel this query.
        try expectValue(db, "SELECT id FROM slow_rows, pg_sleep(0.4) WHERE id = 1", "1");
    }
}
