const std = @import("std");
const z = @import("zorm");
const options = @import("driver_options");

const DriverUser = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    age: i64 = 0,
    active: bool = true,

    pub const zorm = .{
        .table = "zorm_driver_users",
        .unique = .{"name"},
        .indexes = .{"age"},
    };
};

var before_create_calls: usize = 0;
var after_find_calls: usize = 0;
var observed_queries: usize = 0;

fn observeQuery(_: ?*anyopaque, _: z.drivers.QueryEvent) void {
    observed_queries += 1;
}

const RetryContext = struct {
    attempts: usize = 0,
};

fn retryOnce(context: *RetryContext, tx: *z.drivers.sqlite.Orm.Transaction) z.drivers.Error!void {
    context.attempts += 1;
    if (context.attempts == 1) return error.DeadlockDetected;
    try tx.db.exec("CREATE TABLE retry_succeeded (id INTEGER)");
}

fn rejectQuery(_: ?*anyopaque, _: z.drivers.plugins.QueryContext) bool {
    return false;
}

fn execDiscard(conn: *z.drivers.mysql.Conn, sql: []const u8) void {
    var result = conn.exec(sql) catch return;
    result.deinit();
}

const VersionedUser = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    version: i64 = 0,

    pub fn beforeCreate(self: *VersionedUser, _: *z.drivers.sqlite.Orm) z.Error!void {
        before_create_calls += 1;
        self.name = "hooked";
    }

    pub fn afterFind(_: *VersionedUser, _: *z.drivers.sqlite.Orm) z.Error!void {
        after_find_calls += 1;
    }
};

const TimestampedUser = struct {
    base: z.Model = .{},
    name: []const u8 = "",

    pub const zorm = .{ .table = "timestamped_users" };
};

const AssocChild = struct {
    id: ?i64 = null,
    parent_id: ?i64 = null,
    name: []const u8 = "",

    pub const zorm = .{ .table = "assoc_children" };
};

const AssocParent = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    children: []AssocChild = &.{},

    pub const zorm = .{
        .table = "assoc_parents",
        .has_many = .{ .children = .{ .model = AssocChild, .foreign_key = "parent_id" } },
    };
};

const AdditiveV1 = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    pub const zorm = .{ .table = "additive_users" };
};

const AdditiveV2 = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    age: i64 = 0,
    pub const zorm = .{ .table = "additive_users" };
};

test "SQLite driver executes CRUD" {
    const db = try z.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
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
    const pool = try z.drivers.sqlite.openPool(
        std.testing.allocator,
        threaded.io(),
        "file:zorm_pool?mode=memory&cache=shared",
        .{},
        .{ .min_size = 1, .max_size = 2 },
    );
    defer pool.deinit();
    var lease = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().in_use);
    var result = try lease.backend.exec("SELECT 1");
    result.deinit();
    lease.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);
}

test "SQLite migrator applies scripts and rolls back latest version" {
    const raw = try z.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = z.drivers.sqlite.orm(raw);
    var migrations = z.drivers.sqlite.migrator(&db);
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
    const raw = try z.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = z.drivers.sqlite.orm(raw);
    try db.autoMigrate(AdditiveV1);
    var original = AdditiveV1{ .name = "Ada" };
    try db.insert(&original);
    try db.autoMigrate(AdditiveV2);
    const migrated = (try db.find(AdditiveV2, original.id.?, std.testing.allocator)).?;
    defer z.free(AdditiveV2, migrated, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 0), migrated.age);
}

test "SQLite lifecycle hooks timestamps and optimistic locking" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const raw = try z.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer raw.deinit();
    var db = z.drivers.sqlite.orm(raw);
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
    defer z.free(VersionedUser, current, std.testing.allocator);
    var stale = (try db.find(VersionedUser, inserted.id.?, std.testing.allocator)).?;
    defer z.free(VersionedUser, stale, std.testing.allocator);
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
    try std.testing.expect((try db.find(TimestampedUser, timestamped.base.id.?, std.testing.allocator)) == null);
    try std.testing.expectEqual(@as(i64, 1), try db.restore(&timestamped));
    const restored = (try db.find(TimestampedUser, timestamped.base.id.?, std.testing.allocator)).?;
    defer z.free(TimestampedUser, restored, std.testing.allocator);
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
    const primary_raw = try z.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer primary_raw.deinit();
    const replica_raw = try z.drivers.sqlite.Db.openWithIo(std.testing.allocator, threaded.io(), ":memory:", .{});
    defer replica_raw.deinit();
    var primary = z.drivers.sqlite.orm(primary_raw);
    var replica = z.drivers.sqlite.orm(replica_raw);

    var metrics: z.drivers.plugins.Metrics = .{};
    try std.testing.expect(primary.addPlugin(metrics.plugin()));
    try primary.exec("CREATE TABLE plugin_users (id INTEGER)");
    try primary.exec("INSERT INTO plugin_users VALUES (1)");
    var selected = try primary.execRaw("SELECT 1");
    selected.deinit();
    try std.testing.expectEqual(@as(u64, 3), metrics.queries.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), metrics.mutations.load(.monotonic));
    const encryption = z.drivers.plugins.Encryption{ .key = [_]u8{7} ** 32 };
    const encrypted = try encryption.encrypt(threaded.io(), std.testing.allocator, "secret", "users.email");
    defer std.testing.allocator.free(encrypted);
    const decrypted = try encryption.decrypt(std.testing.allocator, encrypted, "users.email");
    defer std.testing.allocator.free(decrypted);
    try std.testing.expectEqualStrings("secret", decrypted);

    var context = RetryContext{};
    try primary.transactionRetry(.{ .base_delay_ms = 0 }, &context, retryOnce);
    try std.testing.expectEqual(@as(usize, 2), context.attempts);

    var router = z.drivers.Router(z.drivers.sqlite.Orm).init(std.testing.allocator, threaded.io(), &primary, &.{&replica});
    defer router.deinit();
    try std.testing.expect((try router.reader()) == &replica);
    try std.testing.expect((try router.writer()) == &primary);
    try router.setTenant("acme", &replica);
    try std.testing.expect((try router.tenant("acme")) == &replica);
    router.setShards(&.{ &primary, &replica });
    _ = try router.shard("customer-42");

    var blocked = z.drivers.sqlite.orm(primary_raw);
    try std.testing.expect(blocked.addPlugin(.{ .before_query = rejectQuery }));
    try std.testing.expectError(error.HookAborted, blocked.exec("SELECT 1"));
}
test "SQLite association manager appends counts and clears children" {
    const raw = try z.drivers.sqlite.Db.open(std.testing.allocator, ":memory:");
    defer raw.deinit();
    var db = z.drivers.sqlite.orm(raw);
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
    defer z.freeSlice(AssocParent, loaded, std.testing.allocator);
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
test "SQLite ORM executes typed lifecycle" {
    const gpa = std.testing.allocator;
    const raw = try z.drivers.sqlite.Db.open(gpa, ":memory:");
    defer raw.deinit();
    var db = z.drivers.sqlite.orm(raw);

    var bound = try raw.execParams("SELECT ?", &.{.{ .kind = .text, .data = "Ada' OR 1=1 --" }});
    defer bound.deinit();
    try std.testing.expectEqualStrings("Ada' OR 1=1 --", bound.rows[0][0].?);

    try db.autoMigrate(DriverUser);
    var ada = DriverUser{ .name = "Ada", .age = 37 };
    try db.insert(&ada);
    try std.testing.expect(ada.id != null);

    var found = (try db.find(DriverUser, ada.id.?, gpa)).?;
    defer z.free(DriverUser, found, gpa);
    try std.testing.expectEqualStrings("Ada", found.name);
    try std.testing.expect(found.active);

    found.age = 38;
    try db.update(&found);
    const matches = try db.whereEq(DriverUser, "age", @as(i64, 38), gpa);
    defer z.freeSlice(DriverUser, matches, gpa);
    try std.testing.expectEqual(@as(usize, 1), matches.len);

    const queried = try db.query(DriverUser).where("age >= ?", .{@as(i64, 38)}).orderBy(&.{"age DESC"}).all(gpa);
    defer z.freeSlice(DriverUser, queried, gpa);
    try std.testing.expectEqual(@as(usize, 1), queried.len);
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Ada").count());
    const updated = try db.query(DriverUser).whereEq("id", ada.id.?).updateReturning(.{ .age = @as(i64, 39) }, gpa);
    defer z.freeSlice(DriverUser, updated, gpa);
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(@as(i64, 39), updated[0].age);

    var upserted = DriverUser{ .name = "Ada", .age = 40 };
    try std.testing.expect(try db.upsert(&upserted, .{ .columns = &.{"name"}, .update = &.{"age"} }));
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Ada").count());
    const upserted_row = (try db.query(DriverUser).whereEq("name", "Ada").first(gpa)).?;
    defer z.free(DriverUser, upserted_row, gpa);
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

test "MySQL driver connects, pings, and executes CRUD" {
    const port = options.mysql_port orelse return;
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const temporary_database = options.mysql_database.len == 0;
    const database = if (temporary_database) "zorm_driver_test" else options.mysql_database;
    if (temporary_database) {
        const bootstrap = try z.drivers.mysql.Conn.connect(std.testing.allocator, threaded.io(), .{
            .host = options.mysql_host,
            .port = port,
            .user = options.mysql_user,
            .password = options.mysql_password,
            .ssl_mode = if (options.mysql_ssl) .require else .disable,
        });
        defer bootstrap.deinit();
        var created = try bootstrap.exec("CREATE DATABASE IF NOT EXISTS zorm_driver_test");
        created.deinit();
    }
    const pool = try z.drivers.mysql.openPool(std.testing.allocator, threaded.io(), .{
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
    defer if (temporary_database) execDiscard(conn, "DROP DATABASE IF EXISTS zorm_driver_test");
    try conn.ping();
    var setup = try conn.exec("CREATE TABLE IF NOT EXISTS zorm_driver_test (id bigint primary key, name varchar(255))");
    setup.deinit();
    var clear = try conn.exec("DELETE FROM zorm_driver_test");
    clear.deinit();
    var insert = try conn.exec("INSERT INTO zorm_driver_test VALUES (1, 'Ada')");
    defer insert.deinit();
    try std.testing.expectEqual(@as(i64, 1), insert.affected);
    var rows = try conn.exec("SELECT id, name FROM zorm_driver_test");
    defer rows.deinit();
    try std.testing.expectEqualStrings("1", rows.rows[0][0].?);
    try std.testing.expectEqualStrings("Ada", rows.rows[0][1].?);
    var drop_orm = try conn.exec("DROP TABLE IF EXISTS zorm_driver_users");
    drop_orm.deinit();
    var db = z.drivers.mysql.orm(conn);
    try db.autoMigrate(DriverUser);

    var linus = DriverUser{ .name = "Linus", .age = 55 };
    try db.insert(&linus);
    try std.testing.expect(linus.id != null);
    var found = (try db.find(DriverUser, linus.id.?, std.testing.allocator)).?;
    defer z.free(DriverUser, found, std.testing.allocator);
    try std.testing.expectEqualStrings("Linus", found.name);

    found.active = false;
    try db.update(&found);
    const inactive = try db.whereEq(DriverUser, "active", false, std.testing.allocator);
    defer z.freeSlice(DriverUser, inactive, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), inactive.len);
    try std.testing.expectEqual(@as(i64, 1), try db.query(DriverUser).whereEq("name", "Linus").count());
    const returned = try db.query(DriverUser).whereEq("id", linus.id.?).updateReturning(.{ .age = @as(i64, 56) }, std.testing.allocator);
    defer z.freeSlice(DriverUser, returned, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 56), returned[0].age);

    var replacement = DriverUser{ .name = "Linus", .age = 57 };
    try std.testing.expect(try db.upsert(&replacement, .{ .columns = &.{"name"}, .update = &.{"age"} }));
    const replacement_row = (try db.query(DriverUser).whereEq("name", "Linus").first(std.testing.allocator)).?;
    defer z.free(DriverUser, replacement_row, std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 57), replacement_row.age);

    execDiscard(conn, "DROP TABLE IF EXISTS additive_users");
    try db.autoMigrate(AdditiveV1);
    var additive = AdditiveV1{ .name = "Ada" };
    try db.insert(&additive);
    try db.autoMigrate(AdditiveV2);
    const additive_row = (try db.find(AdditiveV2, additive.id.?, std.testing.allocator)).?;
    defer z.free(AdditiveV2, additive_row, std.testing.allocator);
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
    defer z.freeSlice(AssocParent, parents, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), parents[0].children.len);

    execDiscard(conn, "DROP TABLE IF EXISTS schema_migrations");
    execDiscard(conn, "DROP TABLE IF EXISTS mysql_migration_users");
    var migrations = z.drivers.mysql.migrator(&db);
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

    const timeout_conn = try z.drivers.mysql.Conn.connect(std.testing.allocator, threaded.io(), .{
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
