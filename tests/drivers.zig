const std = @import("std");
const zg = @import("zgorm");
const options = @import("driver_options");

const DriverUser = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    age: i64 = 0,
    active: bool = true,

    pub const zgorm = .{
        .table = "zgorm_driver_users",
        .unique = .{"name"},
        .indexes = .{"age"},
    };
};

var before_create_calls: usize = 0;
var after_find_calls: usize = 0;
var observed_queries: usize = 0;

fn observeQuery(_: ?*anyopaque, _: zg.drivers.QueryEvent) void {
    observed_queries += 1;
}

const RetryContext = struct {
    attempts: usize = 0,
};

fn retryOnce(context: *RetryContext, tx: *zg.drivers.sqlite.Orm.Transaction) zg.drivers.Error!void {
    context.attempts += 1;
    if (context.attempts == 1) return error.DeadlockDetected;
    try tx.db.exec("CREATE TABLE retry_succeeded (id INTEGER)");
}

fn rejectQuery(_: ?*anyopaque, _: zg.drivers.plugins.QueryContext) bool {
    return false;
}

fn execDiscard(conn: *zg.drivers.mysql.Conn, sql: []const u8) void {
    var result = conn.exec(sql) catch return;
    result.deinit();
}

const VersionedUser = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    version: i64 = 0,

    pub fn beforeCreate(self: *VersionedUser, _: *zg.drivers.sqlite.Orm) zg.Error!void {
        before_create_calls += 1;
        self.name = "hooked";
    }

    pub fn afterFind(_: *VersionedUser, _: *zg.drivers.sqlite.Orm) zg.Error!void {
        after_find_calls += 1;
    }
};

const TimestampedUser = struct {
    base: zg.Model = .{},
    name: []const u8 = "",

    pub const zgorm = .{ .table = "timestamped_users" };
};

const AssocChild = struct {
    id: ?i64 = null,
    parent_id: ?i64 = null,
    name: []const u8 = "",

    pub const zgorm = .{ .table = "assoc_children" };
};

const AssocParent = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    children: []AssocChild = &.{},

    pub const zgorm = .{
        .table = "assoc_parents",
        .has_many = .{ .children = .{ .model = AssocChild, .foreign_key = "parent_id" } },
    };
};

const AdditiveV1 = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    pub const zgorm = .{ .table = "additive_users" };
};

const AdditiveV2 = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    age: i64 = 0,
    pub const zgorm = .{ .table = "additive_users" };
};

fn checkSoftDeletedPreloads(db: anytype) !void {
    const Member = struct {
        id: ?i64 = null,
        parent_id: ?i64 = null,
        name: []const u8 = "",
        deleted_at: ?zg.Time = null,
        pub const zgorm = .{ .table = "scope_children" };
    };
    const Group = struct {
        id: ?i64 = null,
        name: []const u8 = "",
        members: []Member = &.{},
        tags: []Member = &.{},
        pub const zgorm = .{ .table = "scope_groups" };
        pub const members_relation = zg.hasManyWith(Member, .{ .foreign_key = "parent_id" });
        pub const tags_relation = zg.manyToManyWith(Member, .{
            .join_table = "scope_memberships",
            .join_foreign_key = "group_id",
            .join_association_key = "child_id",
        });
    };
    const gpa = std.testing.allocator;
    try db.autoMigrateAll(.{ Group, Member });
    try db.exec("CREATE TEMPORARY TABLE scope_memberships (group_id bigint, child_id bigint)");
    var group = Group{ .name = "visibility" };
    try db.insert(&group);
    var live = Member{ .parent_id = group.id, .name = "live" };
    var hidden = Member{ .parent_id = group.id, .name = "hidden" };
    try db.insert(&live);
    try db.insert(&hidden);
    var links = try db.execArgs("INSERT INTO scope_memberships VALUES (?, ?), (?, ?)", .{ group.id, live.id, group.id, hidden.id });
    links.deinit();
    try db.delete(&hidden);
    for ([_]bool{ false, true }) |unscoped| {
        var query = db.query(Group).whereEq("id", group.id).preload("members").preload("tags");
        if (unscoped) _ = query.unscoped();
        const loaded = (try query.first(gpa)).?;
        defer zg.free(Group, loaded, gpa);
        const expected: usize = if (unscoped) 2 else 1;
        try std.testing.expectEqual(expected, loaded.members.len);
        try std.testing.expectEqual(expected, loaded.tags.len);
        if (!unscoped) {
            try std.testing.expectEqual(live.id, loaded.members[0].id);
            try std.testing.expectEqual(live.id, loaded.tags[0].id);
        }
    }
}

test "SQLite preloads apply soft-delete scope to children and joined rows" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try checkSoftDeletedPreloads(&db);
}

test "SQLite driver executes CRUD" {
    const db = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer db.deinit();
    var create = try db.exec("CREATE TABLE users (id integer primary key, name text)");
    create.deinit();
    var insert = try db.exec("INSERT INTO users (name) VALUES ('Ada')");
    defer insert.deinit();
    try std.testing.expectEqual(@as(i64, 1), insert.affected);
    var rows = try db.exec("SELECT name FROM users WHERE id = 1");
    defer rows.deinit();
    try std.testing.expectEqualStrings("Ada", rows.rows[0][0].?);
}

test "SQLite pool leases and reuses connections" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const pool = try zg.drivers.sqlite.openPool(
        std.testing.allocator,
        threaded.io(),
        "file:zgorm_pool?mode=memory&cache=shared",
        .{},
        .{ .min_size = 1, .max_size = 2 },
    );
    defer pool.deinit();
    var lease = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().in_use);
    var db = zg.drivers.sqlite.orm(lease.backend);
    try db.exec("CREATE TABLE lease_rows (id INTEGER)");
    var abandoned = try db.begin();
    try db.exec("INSERT INTO lease_rows VALUES (1)");
    lease.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);
    var reused = try pool.acquire();
    defer reused.deinit();
    try std.testing.expectEqual(db.backend, reused.backend);
    var next = try db.begin();
    try std.testing.expectError(error.TransactionFinished, abandoned.rollback());
    var count = try reused.backend.exec("SELECT count(*) FROM lease_rows");
    defer count.deinit();
    try std.testing.expectEqualStrings("0", count.rows[0][0].?);
    try next.commit();
}

test "SQLite migrator applies scripts and rolls back latest version" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    var migrations = zg.drivers.sqlite.migrator(&db);
    defer migrations.deinit();
    try migrations.add(&.{
        .{ .version = 2, .name = "seed_grace", .up = "INSERT INTO migration_users (name) VALUES ('Grace');", .down = "DELETE FROM migration_users WHERE name = 'Grace';" },
        .{ .version = 1, .name = "create_users", .up = "CREATE TABLE migration_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL); INSERT INTO migration_users (name) VALUES ('Ada');", .down = "DROP TABLE migration_users;" },
    });
    try std.testing.expectEqual(@as(usize, 2), try migrations.applyAll());
    try std.testing.expectEqual(@as(usize, 0), try migrations.applyAll());
    var count = try raw.exec("SELECT count(*) FROM migration_users");
    defer count.deinit();
    try std.testing.expectEqualStrings("2", count.rows[0][0].?);
    try std.testing.expectEqual(@as(?i64, 2), try migrations.rollbackLast());
    const versions = try migrations.appliedVersions(std.testing.allocator);
    defer std.testing.allocator.free(versions);
    try std.testing.expectEqualSlices(i64, &.{1}, versions);
}

test "SQLite auto migration adds missing columns" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try db.autoMigrate(AdditiveV1);
    var original = AdditiveV1{ .name = "Ada" };
    try db.insert(&original);
    try db.autoMigrate(AdditiveV2);
    const migrated = (try db.find(AdditiveV2, original.id.?, std.testing.allocator)).?;
    defer zg.free(AdditiveV2, migrated, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), migrated.age);
}

test "SQLite lifecycle hooks timestamps and optimistic locking" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const raw = try zg.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    before_create_calls = 0;
    after_find_calls = 0;

    try db.autoMigrate(VersionedUser);
    observed_queries = 0;
    db.setObserver(.{ .on_query = observeQuery });
    var inserted = VersionedUser{ .name = "seed" };
    try db.insert(&inserted);
    try std.testing.expectEqualStrings("hooked", inserted.name);
    try std.testing.expectEqual(@as(usize, 1), before_create_calls);

    var current = (try db.find(VersionedUser, inserted.id.?, std.testing.allocator)).?;
    defer zg.free(VersionedUser, current, std.testing.allocator);
    var stale = (try db.find(VersionedUser, inserted.id.?, std.testing.allocator)).?;
    defer zg.free(VersionedUser, stale, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), after_find_calls);
    std.testing.allocator.free(current.name);
    current.name = try std.testing.allocator.dupe(u8, "current");
    try db.update(&current);
    try std.testing.expectEqual(@as(i64, 1), current.version);
    try std.testing.expectError(error.OptimisticLockConflict, db.update(&stale));

    try db.autoMigrate(TimestampedUser);
    var timestamped = TimestampedUser{ .name = "clocked" };
    try db.insert(&timestamped);
    try std.testing.expect(timestamped.base.created_at != null);
    try std.testing.expect(timestamped.base.updated_at != null);
    try std.testing.expect(timestamped.base.id != null);
    try db.delete(&timestamped);
    try std.testing.expectEqual(@as(i64, 0), try db.query(TimestampedUser)
        .whereEq("name", "clocked").orWhere("name = ?", .{"absent"}).count());
    try std.testing.expectEqual(@as(i64, 0), try db.query(TimestampedUser)
        .whereEq("name", "clocked").orWhere("name = ?", .{"absent"}).update(.{ .name = "changed" }));
    try std.testing.expectEqual(@as(i64, 1), try db.query(TimestampedUser).unscoped()
        .whereEq("name", "clocked").orWhere("name = ?", .{"absent"}).count());
    try std.testing.expect((try db.find(TimestampedUser, timestamped.base.id.?, std.testing.allocator)) == null);
    try std.testing.expectEqual(@as(i64, 1), try db.restore(&timestamped));
    const restored = (try db.find(TimestampedUser, timestamped.base.id.?, std.testing.allocator)).?;
    defer zg.free(TimestampedUser, restored, std.testing.allocator);
    try std.testing.expectEqualStrings("clocked", restored.name);
    try std.testing.expect(observed_queries > 0);
    try std.testing.expectError(
        error.QueryTimeout,
        raw.execParamsTimeout(
            "WITH RECURSIVE counter(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM counter WHERE value < 100000000) SELECT sum(value) FROM counter",
            &.{},
            1,
        ),
    );
}

test "SQLite plugins transaction retry and routing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const primary_raw = try zg.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer primary_raw.deinit();
    const replica_raw = try zg.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer replica_raw.deinit();
    var primary = zg.drivers.sqlite.orm(primary_raw);
    var replica = zg.drivers.sqlite.orm(replica_raw);

    var metrics: zg.drivers.plugins.Metrics = .{};
    try std.testing.expect(primary.addPlugin(metrics.plugin()));
    try primary.exec("CREATE TABLE plugin_users (id INTEGER)");
    try primary.exec("INSERT INTO plugin_users VALUES (1)");
    var selected = try primary.execRaw("SELECT 1");
    selected.deinit();
    try std.testing.expectEqual(@as(u64, 3), metrics.queries.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.mutations.load(.monotonic));
    const encryption = zg.drivers.plugins.Encryption{ .key = @splat(7) };
    const encrypted = try encryption.encrypt(threaded.io(), std.testing.allocator, "secret", "users.email");
    defer std.testing.allocator.free(encrypted);
    const decrypted = try encryption.decrypt(std.testing.allocator, encrypted, "users.email");
    defer std.testing.allocator.free(decrypted);
    try std.testing.expectEqualStrings("secret", decrypted);

    var context = RetryContext{};
    try primary.transactionRetry(.{ .base_delay_ms = 0 }, &context, retryOnce);
    try std.testing.expectEqual(@as(usize, 2), context.attempts);

    var router = zg.drivers.Router(zg.drivers.sqlite.Orm).init(std.testing.allocator, threaded.io(), &primary, &.{&replica});
    defer router.deinit();
    try std.testing.expect((try router.reader()) == &replica);
    try std.testing.expect((try router.writer()) == &primary);
    try router.setTenant("acme", &replica);
    try std.testing.expect((try router.tenant("acme")) == &replica);
    router.setShards(&.{ &primary, &replica });
    _ = try router.shard("customer-42");

    var blocked = zg.drivers.sqlite.orm(primary_raw);
    try std.testing.expect(blocked.addPlugin(.{ .before_query = rejectQuery }));
    try std.testing.expectError(error.HookAborted, blocked.exec("SELECT 1"));
}
test "SQLite association manager appends counts and clears children" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try db.autoMigrateAll(.{ AssocParent, AssocChild });
    var parent = AssocParent{ .name = "parent" };
    try db.insert(&parent);
    var child = AssocChild{ .name = "child" };
    var children = db.association(&parent, "children");
    try children.append(&child);
    try std.testing.expectEqual(parent.id, child.parent_id);
    try std.testing.expectEqual(@as(i64, 1), try children.count());

    var parent2 = AssocParent{ .name = "parent-2" };
    try db.insert(&parent2);
    var child2 = AssocChild{ .name = "child-2" };
    var children2 = db.association(&parent2, "children");
    try children2.append(&child2);

    observed_queries = 0;
    db.setObserver(.{ .on_query = observeQuery });
    const loaded = try db.query(AssocParent).preload("children").all(std.testing.allocator);
    defer zg.freeSlice(AssocParent, loaded, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqual(@as(usize, 2), observed_queries);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].children.len);
    try std.testing.expectEqualStrings("child", loaded[0].children[0].name);
    try std.testing.expectEqual(@as(usize, 1), loaded[1].children.len);
    try std.testing.expectEqualStrings("child-2", loaded[1].children[0].name);
    try children.clear();
    try children2.clear();
    try std.testing.expectEqual(@as(i64, 0), try children.count());
    try std.testing.expectEqual(@as(i64, 0), try children2.count());
}
const ReplaceChild = struct {
    id: ?i64 = null,
    parent_id: ?i64 = null,
    name: []const u8 = "",

    pub const zgorm = .{ .table = "replace_children", .unique = .{"name"} };
};

const ReplaceParent = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    children: []ReplaceChild = &.{},
    tags: []ReplaceChild = &.{},

    pub const zgorm = .{
        .table = "replace_parents",
        .has_many = .{ .children = .{ .model = ReplaceChild, .foreign_key = "parent_id" } },
        .many_to_many = .{ .tags = .{
            .model = ReplaceChild,
            .foreign_key = "parent_id",
            .join_table = "replace_tags",
            .join_foreign_key = "parent_id",
            .join_association_key = "child_id",
        } },
    };
};

fn checkAssociationReplace(db: anytype) !void {
    try db.exec("DROP TABLE IF EXISTS replace_tags");
    try db.exec("DROP TABLE IF EXISTS replace_children");
    try db.exec("DROP TABLE IF EXISTS replace_parents");
    try db.autoMigrateAll(.{ ReplaceParent, ReplaceChild });
    try db.exec("CREATE TABLE replace_tags (parent_id BIGINT NOT NULL, child_id BIGINT NOT NULL, " ++
        "PRIMARY KEY (parent_id, child_id), FOREIGN KEY (child_id) REFERENCES replace_children(id))");
    var parent = ReplaceParent{ .name = "owner" };
    var old = ReplaceChild{ .name = "old" };
    var occupied = ReplaceChild{ .name = "occupied" };
    try db.insert(&parent);
    var children = db.association(&parent, "children");
    var tags = db.association(&parent, "tags");
    try children.append(&old);
    try tags.append(&occupied);

    var replacement = [_]ReplaceChild{ .{ .name = "fresh" }, .{ .name = "occupied" } };
    // The missing child makes the join fail after the first child was successfully saved.
    var missing = [_]ReplaceChild{ .{ .name = "tag" }, .{ .id = 9000, .name = "missing" } };
    for ([_]bool{ false, true }) |nested| {
        var outer = if (nested) @as(?@TypeOf(db.*).Transaction, try db.begin()) else null;
        errdefer if (outer) |*tx| tx.rollback() catch {};
        try std.testing.expectError(error.UniqueViolation, children.replace(&replacement));
        try std.testing.expectError(error.ForeignKeyViolation, tags.replace(&missing));
        try std.testing.expectEqual(null, replacement[0].id);
        try std.testing.expectEqual(null, missing[0].id);
        try std.testing.expectEqual(@as(i64, 1), try children.count());
        try std.testing.expectEqual(@as(i64, 1), try tags.count());
        try std.testing.expectEqual(@as(i64, 2), try db.query(ReplaceChild).count());
        if (outer) |*tx| {
            var marker = ReplaceParent{ .name = "still open" };
            try tx.insert(&marker);
            try tx.commit();
        }
    }
    try std.testing.expectEqual(@as(i64, 1), try db.query(ReplaceParent).whereEq("name", "still open").count());
    replacement[1].name = "second";
    try children.replace(&replacement);
    var duplicates = [_]ReplaceChild{ occupied, occupied };
    try tags.replace(&duplicates);
    try std.testing.expectEqual(@as(i64, 2), try children.count());
    try std.testing.expectEqual(@as(i64, 1), try tags.count());
    var outer = try db.begin();
    try children.replace(&.{});
    try tags.replace(&.{});
    try std.testing.expectEqual(@as(i64, 0), try children.count());
    try std.testing.expectEqual(@as(i64, 0), try tags.count());
    try outer.rollback();
    try std.testing.expectEqual(@as(i64, 2), try children.count());
    try std.testing.expectEqual(@as(i64, 1), try tags.count());
}

test "SQLite association replacement rolls back children and links" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try checkAssociationReplace(&db);
}

fn checkNestedBatches(db: anytype) !void {
    const count = try db.query(DriverUser).count();
    var outer = try db.begin();
    var caller = DriverUser{ .name = "outer batch" };
    try outer.insert(&caller);
    var batch = [_]DriverUser{ .{ .name = "generated one" }, .{ .name = "generated two" } };
    try outer.db.insertBatch(&batch);
    var mixed = [_]DriverUser{ .{ .id = 700, .name = "supplied key" }, .{ .name = "generated after supplied" } };
    try outer.insertBatch(&mixed);
    try std.testing.expectEqual(@as(?i64, 700), mixed[0].id);
    for (batch ++ mixed) |row| {
        const found = (try db.find(DriverUser, row.id.?, std.testing.allocator)).?;
        defer zg.free(DriverUser, found, std.testing.allocator);
        try std.testing.expectEqualStrings(row.name, found.name);
    }
    var inner = try outer.begin();
    var upserts = [_]DriverUser{.{ .name = "upsert batch" }};
    _ = try inner.upsertBatch(&upserts, .{ .columns = &.{"name"}, .update = &.{"age"} });
    try std.testing.expectError(error.InvalidQuery, outer.commit());
    try inner.rollback();
    try std.testing.expectEqual(@as(i64, 0), try db.query(DriverUser).whereEq("name", "upsert batch").count());
    var duplicate = [_]DriverUser{ .{ .name = "discard me" }, .{ .id = 700, .name = "duplicate" } };
    try std.testing.expectError(error.UniqueViolation, outer.insertBatch(&duplicate));
    try std.testing.expectEqual(null, duplicate[0].id);
    try std.testing.expectEqual(count + 5, try db.query(DriverUser).count());
    try outer.rollback();
    try std.testing.expectEqual(count, try db.query(DriverUser).count());
    try std.testing.expectError(error.TransactionFinished, inner.begin());

    try db.backend.beginTransaction();
    var alias = @TypeOf(db.*).init(db.backend);
    var raw_batch = [_]DriverUser{.{ .name = "raw outer" }};
    try alias.insertBatch(&raw_batch);
    try db.backend.rollback();
    try std.testing.expectEqual(count, try db.query(DriverUser).count());
}

test "SQLite nested batches preserve outer transactions and failed commits can roll back" {
    const raw = try zg.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try db.autoMigrate(DriverUser);
    try checkNestedBatches(&db);

    try db.exec("CREATE TABLE deferred_child (user_id INTEGER REFERENCES zgorm_driver_users(id) DEFERRABLE INITIALLY DEFERRED)");
    var outer = try db.begin();
    try db.exec("INSERT INTO deferred_child VALUES (987654)");
    try std.testing.expectError(error.ForeignKeyViolation, outer.commit());
    try outer.rollback();
    var next = try db.begin();
    try next.commit();

    const Hooked = struct {
        id: ?i64 = null,
        fail: bool = false,
        pub fn afterCreate(row: *@This(), _: *zg.drivers.sqlite.Orm) zg.drivers.Error!void {
            if (row.fail) return error.HookAborted;
        }
    };
    try db.autoMigrate(Hooked);
    var batch = [_]Hooked{ .{}, .{ .fail = true } };
    try std.testing.expectError(error.HookAborted, db.insertBatch(&batch));
    try std.testing.expectEqual(null, batch[0].id);
    try std.testing.expectEqual(@as(i64, 0), try db.query(Hooked).count());
}

test "SQLite ORM executes typed lifecycle" {
    const gpa = std.testing.allocator;
    const raw = try zg.drivers.sqlite.Db.open(gpa, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);

    var bound = try raw.execParams("SELECT ?", &.{.{ .kind = .text, .data = "Ada' OR 1=1 --" }});
    defer bound.deinit();
    try std.testing.expectEqualStrings("Ada' OR 1=1 --", bound.rows[0][0].?);

    try db.autoMigrate(DriverUser);
    var ada = DriverUser{ .name = "Ada", .age = 37 };
    try db.insert(&ada);
    try std.testing.expect(ada.id != null);

    var found = (try db.find(DriverUser, ada.id.?, gpa)).?;
    defer zg.free(DriverUser, found, gpa);
    try std.testing.expectEqualStrings("Ada", found.name);
    try std.testing.expect(found.active);

    found.age = 38;
    try db.update(&found);
    const matches = try db.whereEq(DriverUser, "age", @as(i64, 38), gpa);
    defer zg.freeSlice(DriverUser, matches, gpa);
    try std.testing.expectEqual(@as(usize, 1), matches.len);

    const queried = try db.query(DriverUser).where("age >= ?", .{@as(i64, 38)}).orderBy(&.{"age DESC"}).all(gpa);
    defer zg.freeSlice(DriverUser, queried, gpa);
    try std.testing.expectEqual(@as(usize, 1), queried.len);
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Ada").count());
    const updated = try db.query(DriverUser).whereEq("id", ada.id.?).updateReturning(.{ .age = @as(i64, 39) }, gpa);
    defer zg.freeSlice(DriverUser, updated, gpa);
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(@as(i64, 39), updated[0].age);

    var upserted = DriverUser{ .name = "Ada", .age = 40 };
    try std.testing.expect(try db.upsert(&upserted, .{ .columns = &.{"name"}, .update = &.{"age"} }));
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Ada").count());
    const upserted_row = (try db.query(DriverUser).whereEq("name", "Ada").first(gpa)).?;
    defer zg.free(DriverUser, upserted_row, gpa);
    try std.testing.expectEqual(@as(i64, 40), upserted_row.age);

    var batch = [_]DriverUser{
        .{ .name = "Grace", .age = 45 },
        .{ .name = "Linus", .age = 55 },
    };
    try db.insertBatch(&batch);
    try std.testing.expectEqual(@as(i64, 3), try db.query(DriverUser).count());

    var tx = try db.begin();
    var grace = DriverUser{ .name = "Rollback", .age = 45 };
    try tx.insert(&grace);
    try tx.rollback();
    const rolled_back = try db.find(DriverUser, grace.id.?, gpa);
    try std.testing.expect(rolled_back == null);

    try db.delete(&found);
    try std.testing.expect((try db.find(DriverUser, ada.id.?, gpa)) == null);
}

fn checkMySqlBatchChunks(db: *zg.drivers.mysql.Orm) !void {
    const Row = struct {
        id: ?i64 = null,
        a: i64 = 0,
        b: i64 = 0,
        c: i64 = 0,
        pub const zgorm = .{ .table = "batch_chunk_rows" };
    };
    try db.exec("CREATE TEMPORARY TABLE batch_chunk_rows (id BIGINT PRIMARY KEY AUTO_INCREMENT, a BIGINT, b BIGINT, c BIGINT)");
    const chunk = zg.drivers.Dialect.mysql.maxParameters() / 4;
    const rows = try std.testing.allocator.alloc(Row, chunk + 1);
    defer std.testing.allocator.free(rows);
    for (rows, 1..) |*row, id| row.* = .{ .id = @intCast(id) };
    var outer = try db.begin();
    rows[chunk].id = 1;
    try std.testing.expectError(error.UniqueViolation, outer.insertBatch(rows));
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).count());
    rows[chunk].id = @intCast(rows.len);
    try outer.insertBatch(rows);
    try std.testing.expectEqual(@as(i64, @intCast(rows.len)), try db.query(Row).count());
    try outer.rollback();
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).count());

    try db.exec("SET SESSION autocommit = 0");
    var generated = [_]Row{ .{}, .{} };
    try db.insertBatch(&generated);
    try db.exec("ROLLBACK");
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).count());
    try db.exec("SET SESSION autocommit = DEFAULT");
}

test "MySQL driver connects, pings, and executes CRUD" {
    const port = options.mysql_port orelse return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const temporary_database = options.mysql_database.len == 0;
    const database = if (temporary_database) "zgorm_driver_test" else options.mysql_database;
    if (temporary_database) {
        const bootstrap = try zg.drivers.mysql.Conn.connect(std.testing.allocator, threaded.io(), .{
            .host = options.mysql_host,
            .port = port,
            .user = options.mysql_user,
            .password = options.mysql_password,
            .ssl_mode = if (options.mysql_ssl) .require else .disable,
        });
        defer bootstrap.deinit();
        var created = try bootstrap.exec("CREATE DATABASE IF NOT EXISTS zgorm_driver_test");
        created.deinit();
    }
    const pool = try zg.drivers.mysql.openPool(std.testing.allocator, threaded.io(), .{
        .host = options.mysql_host,
        .port = port,
        .user = options.mysql_user,
        .password = options.mysql_password,
        .database = database,
        .ssl_mode = if (options.mysql_ssl) .require else .disable,
    }, .{ .min_size = 1, .max_size = 2 });
    defer pool.deinit();
    var lease = try pool.acquire();
    defer lease.deinit();
    const conn = lease.backend;
    defer if (temporary_database) execDiscard(conn, "DROP DATABASE IF EXISTS zgorm_driver_test");
    try conn.ping();
    var setup = try conn.exec("CREATE TABLE IF NOT EXISTS zgorm_driver_test (id bigint primary key, name varchar(255))");
    setup.deinit();
    var clear = try conn.exec("DELETE FROM zgorm_driver_test");
    clear.deinit();
    var insert = try conn.exec("INSERT INTO zgorm_driver_test VALUES (1, 'Ada')");
    defer insert.deinit();
    try std.testing.expectEqual(@as(i64, 1), insert.affected);
    var rows = try conn.exec("SELECT id, name FROM zgorm_driver_test");
    defer rows.deinit();
    try std.testing.expectEqualStrings("1", rows.rows[0][0].?);
    try std.testing.expectEqualStrings("Ada", rows.rows[0][1].?);
    var drop_orm = try conn.exec("DROP TABLE IF EXISTS zgorm_driver_users");
    drop_orm.deinit();
    var db = zg.drivers.mysql.orm(conn);
    try db.autoMigrate(DriverUser);
    try db.exec("SET SESSION auto_increment_increment = 2");
    try checkNestedBatches(&db);
    try checkMySqlBatchChunks(&db);
    try db.exec("SET SESSION auto_increment_increment = DEFAULT");
    try checkAssociationReplace(&db);

    var linus = DriverUser{ .name = "Linus", .age = 55 };
    try db.insert(&linus);
    try std.testing.expect(linus.id != null);
    var found = (try db.find(DriverUser, linus.id.?, std.testing.allocator)).?;
    defer zg.free(DriverUser, found, std.testing.allocator);
    try std.testing.expectEqualStrings("Linus", found.name);

    found.active = false;
    try db.update(&found);
    const inactive = try db.whereEq(DriverUser, "active", false, std.testing.allocator);
    defer zg.freeSlice(DriverUser, inactive, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), inactive.len);
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Linus").count());
    const returned = try db.query(DriverUser).whereEq("id", linus.id.?).updateReturning(.{ .age = @as(i64, 56) }, std.testing.allocator);
    defer zg.freeSlice(DriverUser, returned, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 56), returned[0].age);

    var replacement = DriverUser{ .name = "Linus", .age = 57 };
    try std.testing.expect(try db.upsert(&replacement, .{ .columns = &.{"name"}, .update = &.{"age"} }));
    const replacement_row = (try db.query(DriverUser).whereEq("name", "Linus").first(std.testing.allocator)).?;
    defer zg.free(DriverUser, replacement_row, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 57), replacement_row.age);

    execDiscard(conn, "DROP TABLE IF EXISTS additive_users");
    try db.autoMigrate(AdditiveV1);
    var additive = AdditiveV1{ .name = "Ada" };
    try db.insert(&additive);
    try db.autoMigrate(AdditiveV2);
    const additive_row = (try db.find(AdditiveV2, additive.id.?, std.testing.allocator)).?;
    defer zg.free(AdditiveV2, additive_row, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), additive_row.age);

    execDiscard(conn, "DROP TABLE IF EXISTS assoc_children");
    execDiscard(conn, "DROP TABLE IF EXISTS assoc_parents");
    try db.autoMigrateAll(.{ AssocParent, AssocChild });
    var parent = AssocParent{ .name = "parent" };
    try db.insert(&parent);
    var child = AssocChild{ .name = "child" };
    var association = db.association(&parent, "children");
    try association.append(&child);
    try std.testing.expectEqual(@as(i64, 1), try association.count());
    const parents = try db.query(AssocParent).preload("children").all(std.testing.allocator);
    defer zg.freeSlice(AssocParent, parents, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parents[0].children.len);

    try checkSoftDeletedPreloads(&db);

    execDiscard(conn, "DROP TABLE IF EXISTS schema_migrations");
    execDiscard(conn, "DROP TABLE IF EXISTS mysql_migration_users");
    var migrations = zg.drivers.mysql.migrator(&db);
    defer migrations.deinit();
    try migrations.add(&.{
        .{ .version = 1, .name = "create_mysql_users", .up = "CREATE TABLE mysql_migration_users (id BIGINT PRIMARY KEY); INSERT INTO mysql_migration_users VALUES (1);", .down = "DROP TABLE mysql_migration_users;" },
    });
    try std.testing.expectEqual(@as(usize, 1), try migrations.applyAll());
    try std.testing.expectEqual(@as(?i64, 1), try migrations.rollbackLast());

    var tx = try db.begin();
    var rolled_back_user = DriverUser{ .name = "Rollback", .age = 1 };
    try tx.insert(&rolled_back_user);
    try tx.rollback();
    try std.testing.expect((try db.find(DriverUser, rolled_back_user.id.?, std.testing.allocator)) == null);

    try db.delete(&found);
    try std.testing.expect((try db.find(DriverUser, linus.id.?, std.testing.allocator)) == null);

    const timeout_conn = try zg.drivers.mysql.Conn.connect(std.testing.allocator, threaded.io(), .{
        .host = options.mysql_host,
        .port = port,
        .user = options.mysql_user,
        .password = options.mysql_password,
        .database = database,
        .ssl_mode = if (options.mysql_ssl) .require else .disable,
        .query_timeout_ms = 5,
    });
    defer timeout_conn.deinit();
    try std.testing.expectError(error.QueryTimeout, timeout_conn.exec("SELECT SLEEP(1)"));
}

test "MySQL returning mutates exactly the locked primary-key tuples" {
    const port = options.mysql_port orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const conn = try zg.drivers.mysql.Conn.connect(gpa, threaded.io(), .{
        .host = options.mysql_host,
        .port = port,
        .user = options.mysql_user,
        .password = options.mysql_password,
        .database = options.mysql_database,
        .ssl_mode = if (options.mysql_ssl) .require else .disable,
    });
    defer conn.deinit();
    var db = zg.drivers.mysql.orm(conn);
    if (options.mysql_database.len == 0) try db.exec("CREATE DATABASE zgorm_returning_test");
    defer if (options.mysql_database.len == 0) execDiscard(conn, "DROP DATABASE zgorm_returning_test");
    if (options.mysql_database.len == 0) try db.exec("USE zgorm_returning_test");

    const Row = struct {
        tenant: []const u8 = "",
        id: ?i64 = null,
        label: []const u8 = "",
        score: i64 = 0,

        pub const zgorm = .{ .table = "returning_rows", .primary_keys = .{ "tenant", "id" } };

        pub fn afterFind(row: *@This(), db_: *zg.drivers.mysql.Orm) zg.drivers.Error!void {
            // Force commit to see an ended transaction after the returned strings are allocated.
            if (row.score == -1) try db_.exec("ROLLBACK");
        }
    };
    try db.exec("CREATE TEMPORARY TABLE returning_rows (tenant VARCHAR(16), id BIGINT, label VARCHAR(16), score BIGINT, PRIMARY KEY (tenant, id)) ENGINE=InnoDB");
    try db.exec("INSERT INTO returning_rows VALUES ('a', 1, 'first', 0), ('a', 2, 'second', 0), ('b', 1, 'third', 0), ('b', 2, 'fourth', 0)");

    const updated = try db.query(Row).whereEq("score", 0).order_by("tenant, id").limit(1).offset(1)
        .select(&.{"label"}).returning(&.{ "label", "score" }).updateReturning(.{ .score = 7 }, gpa);
    defer zg.freeSlice(Row, updated, gpa);
    try std.testing.expectEqual(@as(i64, 1), try db.query(Row).whereEq("score", 7).count());
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqualStrings("second", updated[0].label);
    try std.testing.expectEqual(@as(i64, 7), updated[0].score);
    try std.testing.expectEqual(@as(?i64, null), updated[0].id);
    try std.testing.expectEqualStrings("", updated[0].tenant);

    const deleted = try db.query(Row).whereEq("score", 0).order_by("id, tenant").limit(1).offset(1)
        .returning(&.{"label"}).deleteReturning(gpa);
    defer zg.freeSlice(Row, deleted, gpa);
    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expectEqualStrings("third", deleted[0].label);
    try std.testing.expectEqual(@as(?i64, null), deleted[0].id);
    try std.testing.expectEqual(@as(i64, 3), try db.query(Row).count());
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).whereEq("label", "third").count());

    const empty_update = try db.query(Row).limit(0).updateReturning(.{ .score = 9 }, gpa);
    defer zg.freeSlice(Row, empty_update, gpa);
    try std.testing.expectEqual(@as(usize, 0), empty_update.len);
    const empty_delete = try db.query(Row).order_by("id").offset(3).deleteReturning(gpa);
    defer zg.freeSlice(Row, empty_delete, gpa);
    try std.testing.expectEqual(@as(usize, 0), empty_delete.len);
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).whereEq("score", 9).count());
    try std.testing.expectEqual(@as(i64, 3), try db.query(Row).count());

    // The join yields three rows for two base tuples in the opposite of primary-key order.
    try db.exec("CREATE TEMPORARY TABLE returning_matches (id BIGINT, label VARCHAR(16), rank_ INT)");
    try db.exec("INSERT INTO returning_matches VALUES (2, 'fourth', 1), (2, 'fourth', 2), (1, 'first', 3)");
    var outer = try db.begin();
    errdefer outer.rollback() catch {};
    const joined = try db.query(Row).join("JOIN returning_matches AS m ON m.label = returning_rows.label AND m.id = returning_rows.id", .{})
        .order_by("m.rank_").returning(&.{"label"}).updateReturning(.{ .score = 5 }, gpa);
    defer zg.freeSlice(Row, joined, gpa);
    try std.testing.expectEqual(@as(usize, 2), joined.len);
    try std.testing.expectEqualStrings("fourth", joined[0].label);
    try std.testing.expectEqualStrings("first", joined[1].label);
    try std.testing.expectEqual(@as(i64, 2), try db.query(Row).whereEq("score", 5).count());
    try outer.rollback();
    try std.testing.expectEqual(@as(i64, 0), try db.query(Row).whereEq("score", 5).count());

    try std.testing.expectError(error.InvalidQuery, db.query(Row).limit(1).updateReturning(.{ .id = 99 }, gpa));
    const NoKey = struct {
        score: i64 = 0,
        pub const zgorm = .{ .table = "returning_rows" };
    };
    try std.testing.expectError(error.InvalidModel, db.query(NoKey).deleteReturning(gpa));
    try std.testing.expectError(error.InvalidQuery, db.query(Row).group_by("tenant").deleteReturning(gpa));
    try std.testing.expectError(error.TransactionFinished, db.query(Row).whereEq("label", "second").updateReturning(.{ .score = -1 }, gpa));
    try std.testing.expectEqual(@as(i64, 1), try db.query(Row).whereEq("score", 7).count());
    try std.testing.expectEqual(@as(i64, 3), try db.query(Row).count());
}
