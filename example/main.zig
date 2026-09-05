//! zorm smoke demo — exercises the full ORM surface against a real PostgreSQL.
//!
//! Configure with a DSN:
//!   ZORM_DSN="postgres://user:pass@host:5432/db?sslmode=disable" zig build run -p example
//! Defaults to the local dev container on 127.0.0.1:5433.

const std = @import("std");
const zg = @import("zgorm");

pub const User = struct {
    base: zg.Model = .{},
    name: []const u8 = "",
    email: ?[]const u8 = null,
    age: i32 = 0,
    active: bool = true,
    balance: f64 = 0,
    posts: []Post = &.{}, // 自动识别为 has_many

    pub const zgorm = zg.ModelConfig{
        .unique = &.{"email"},
        .indexes = &.{"age"},
    };
};

pub const Post = struct {
    base: zg.Model = .{},
    user_id: ?i64 = null,
    title: []const u8 = "",
    tags: []const []const u8 = &.{},
    scores: []const i64 = &.{},
    meta: ?zg.Json = null,
    attachment: ?zg.Bytes = null,
    author: ?User = null, // 自动识别为 belongs_to
};

const EmbeddedUser = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    active: bool = true,

    pub const zgorm = .{ .table = "embedded_users" };
};

fn sqliteDemo(gpa: std.mem.Allocator) !void {
    const raw = try zg.drivers.sqlite.Db.open(gpa, ":memory:");
    defer raw.deinit();
    var db = zg.drivers.sqlite.orm(raw);
    try db.autoMigrate(EmbeddedUser);
    var user = EmbeddedUser{ .name = "SQLite" };
    try db.insert(&user);
    const found = (try db.find(EmbeddedUser, user.id.?, gpa)).?;
    defer zg.free(EmbeddedUser, found, gpa);
    std.debug.print("sqlite typed ORM: id={d} name={s}\n", .{ user.id.?, found.name });
}

fn insertRetried(user: *User, tx: *zg.Tx) zg.Error!void {
    try tx.insert(user);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    try sqliteDemo(gpa);

    const dsn = init.environ_map.get("ZORM_DSN") orelse
        "postgres://zorm:zorm@127.0.0.1:5433/zorm?sslmode=disable";
    const db = try zg.Db.connectDsn(gpa, io, dsn, 8);
    defer db.deinit();
    var plugin_metrics: zg.PluginMetrics = .{};
    try db.addPlugin(plugin_metrics.plugin());

    var dropped = try db.execRaw("DROP TABLE IF EXISTS \"user\" CASCADE");
    dropped.deinit();
    var dropped2 = try db.execRaw("DROP TABLE IF EXISTS \"post\" CASCADE");
    dropped2.deinit();
    try db.autoMigrateAll(.{ User, Post });

    var u = User{ .name = "Alice", .email = "alice@example.com", .age = 30, .balance = 12.5 };
    try db.insert(&u);
    std.debug.print("inserted id={?d}\n", .{u.base.id});

    const found = (try db.find(User, u.base.id.?)).?;
    std.debug.print("found: {s} {s} age={d} active={} balance={d}\n", .{
        found.name, found.email.?, found.age, found.active, found.balance,
    });
    defer zg.free(User, found, gpa);

    var upd = found;
    upd.age = 31;
    _ = try db.update(&upd);

    const users = try zg.query(User, db)
        .where("age >= $1", .{18})
        .whereEq("active", true)
        .order_by("created_at DESC")
        .all(gpa);
    defer zg.freeSlice(User, users, gpa);
    std.debug.print("query all: {d} rows, first={s}\n", .{ users.len, users[0].name });

    const n = try zg.query(User, db).where("age > $1", .{20}).count();
    std.debug.print("count(age>20)={d}\n", .{n});

    // Transaction: insert + rollback.
    {
        var tx = try db.begin();
        defer tx.rollback();
        var ghost = User{ .name = "Ghost", .age = 99 };
        try tx.insert(&ghost);
    }
    const ghosts = try zg.query(User, db).where("name = $1", .{"Ghost"}).count();
    std.debug.print("ghosts after rollback={d}\n", .{ghosts});

    // Explicit whole-transaction retry; ordinary writes are never replayed.
    var kept = User{ .name = "Bob", .email = "bob@example.com", .age = 25 };
    try db.transactionRetry(
        .{ .max_attempts = 4, .base_delay_ms = 10, .max_delay_ms = 250 },
        &kept,
        insertRetried,
    );

    // Batch insert.
    var batch = [_]User{
        .{ .name = "C1", .age = 41 },
        .{ .name = "C2", .age = 42 },
        .{ .name = "C3", .age = 43 },
    };
    try db.insertBatch(&batch);
    std.debug.print("batch ids: {?d} {?d} {?d}\n", .{ batch[0].base.id, batch[1].base.id, batch[2].base.id });

    const updated = try db.updateWhere(User, .{ .active = false }, "age > $1", .{40});
    std.debug.print("updateWhere affected={d}\n", .{updated});

    const deleted = try db.deleteWhere(User, "age >= $1", .{40});
    std.debug.print("deleteWhere affected={d}\n", .{deleted});

    var one = try zg.query(User, db).whereEq("name", "Bob").first();
    if (one) |*b| {
        _ = try db.delete(b);
        std.debug.print("deleted Bob\n", .{});
    }

    var rich = Post{
        .user_id = u.base.id,
        .title = "rich post",
        .tags = &.{ "zig", "orm" },
        .scores = &.{ 5, 4, 5 },
        .meta = zg.Json{ .data = "{\"views\": 42}" },
        .attachment = zg.Bytes{ .data = "bin" },
    };
    try db.insert(&rich);

    // Associations + preloading (posts rendered with arrays/jsonb columns).
    const with_posts = try zg.query(User, db).preload("posts").all(gpa);
    defer zg.freeSlice(User, with_posts, gpa);
    for (with_posts) |usr| {
        std.debug.print("{s} has {d} post(s)\n", .{ usr.name, usr.posts.len });
        for (usr.posts) |p| {
            std.debug.print("  - {s} tags={d} meta={s}\n", .{ p.title, p.tags.len, p.meta.?.data });
        }
    }

    const preloaded = try zg.query(Post, db).preload("author").whereEq("title", "rich post").first();
    if (preloaded) |p| {
        std.debug.print("preloaded post author: {s}\n", .{p.author.?.name});
        zg.free(Post, p, gpa);
    }

    const total = try zg.query(User, db).count();
    std.debug.print("total={d}\n", .{total});
    std.debug.print("observed queries={d} mutations={d}\n", .{
        plugin_metrics.queries.load(.monotonic),
        plugin_metrics.mutations.load(.monotonic),
    });
    zg.free(User, one.?, gpa);
    std.debug.print("smoke OK\n", .{});
}
