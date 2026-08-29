//! zorm smoke demo — exercises the full ORM surface against a real PostgreSQL.
//!
//! Configure with a DSN:
//!   ZORM_DSN="postgres://user:pass@host:5432/db?sslmode=disable" zig build run -p example
//! Defaults to the local dev container on 127.0.0.1:5433.

const std = @import("std");
const z = @import("zorm");

pub const User = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    email: ?[]const u8 = null,
    age: i32 = 0,
    active: bool = true,
    balance: f64 = 0,
    created_at: ?z.Time = null,
    updated_at: ?z.Time = null,

    posts: []Post = &.{}, // has_many (filled by preload)

    pub const zorm = .{
        .unique = .{"email"},
        .indexes = .{"age"},
        .has_many = .{ .posts = .{ .model = Post, .foreign_key = "author_id" } },
    };
};

pub const Post = struct {
    id: ?i64 = null,
    author_id: ?i64 = null,
    title: []const u8 = "",
    tags: []const []const u8 = &.{}, // text[]
    scores: []const i64 = &.{}, // bigint[]
    meta: ?z.Json = null, // jsonb
    attachment: ?z.Bytes = null, // bytea
    author: ?User = null, // belongs_to (filled by preload)

    pub const zorm = .{
        .belongs_to = .{ .author = .{ .model = User, .foreign_key = "author_id" } },
    };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const dsn = init.environ_map.get("ZORM_DSN") orelse
        "postgres://zorm:zorm@127.0.0.1:5433/zorm?sslmode=disable";
    const db = try z.Db.connectDsn(gpa, io, dsn, 8);
    defer db.deinit();

    var dropped = try db.execRaw("DROP TABLE IF EXISTS \"user\" CASCADE");
    dropped.deinit();
    var dropped2 = try db.execRaw("DROP TABLE IF EXISTS \"post\" CASCADE");
    dropped2.deinit();
    try db.autoMigrateAll(.{ User, Post });

    var u = User{ .name = "Alice", .email = "alice@example.com", .age = 30, .balance = 12.5 };
    try db.insert(&u);
    std.debug.print("inserted id={?d}\n", .{u.id});

    const found = (try db.find(User, u.id.?)).?;
    std.debug.print("found: {s} {s} age={d} active={} balance={d}\n", .{
        found.name, found.email.?, found.age, found.active, found.balance,
    });
    defer z.free(User, found, gpa);

    var upd = found;
    upd.age = 31;
    _ = try db.update(&upd);

    const users = try z.query(User, db)
        .where("age >= $1", .{18})
        .whereEq("active", true)
        .order_by("created_at DESC")
        .all(gpa);
    defer z.freeSlice(User, users, gpa);
    std.debug.print("query all: {d} rows, first={s}\n", .{ users.len, users[0].name });

    const n = try z.query(User, db).where("age > $1", .{20}).count();
    std.debug.print("count(age>20)={d}\n", .{n});

    // Transaction: insert + rollback.
    {
        var tx = try db.begin();
        defer tx.rollback();
        var ghost = User{ .name = "Ghost", .age = 99 };
        try tx.insert(&ghost);
    }
    const ghosts = try z.query(User, db).where("name = $1", .{"Ghost"}).count();
    std.debug.print("ghosts after rollback={d}\n", .{ghosts});

    // Transaction: commit.
    {
        var tx = try db.begin();
        var kept = User{ .name = "Bob", .email = "bob@example.com", .age = 25 };
        try tx.insert(&kept);
        try tx.commit();
    }

    // Batch insert.
    var batch = [_]User{
        .{ .name = "C1", .age = 41 },
        .{ .name = "C2", .age = 42 },
        .{ .name = "C3", .age = 43 },
    };
    try db.insertBatch(&batch);
    std.debug.print("batch ids: {d} {d} {d}\n", .{ batch[0].id.?, batch[1].id.?, batch[2].id.? });

    const updated = try db.updateWhere(User, .{ .active = false }, "age > $1", .{40});
    std.debug.print("updateWhere affected={d}\n", .{updated});

    const deleted = try db.deleteWhere(User, "age >= $1", .{40});
    std.debug.print("deleteWhere affected={d}\n", .{deleted});

    var one = try z.query(User, db).whereEq("name", "Bob").first();
    if (one) |*b| {
        _ = try db.delete(b);
        std.debug.print("deleted Bob\n", .{});
    }

    var rich = Post{
        .author_id = u.id,
        .title = "rich post",
        .tags = &.{ "zig", "orm" },
        .scores = &.{ 5, 4, 5 },
        .meta = z.Json{ .data = "{\"views\": 42}" },
        .attachment = z.Bytes{ .data = "bin" },
    };
    try db.insert(&rich);

    // Associations + preloading (posts rendered with arrays/jsonb columns).
    const with_posts = try z.query(User, db).preload("posts").all(gpa);
    defer z.freeSlice(User, with_posts, gpa);
    for (with_posts) |usr| {
        std.debug.print("{s} has {d} post(s)\n", .{ usr.name, usr.posts.len });
        for (usr.posts) |p| {
            std.debug.print("  - {s} tags={d} meta={s}\n", .{ p.title, p.tags.len, p.meta.?.data });
        }
    }

    const preloaded = try z.query(Post, db).preload("author").whereEq("title", "rich post").first();
    if (preloaded) |p| {
        std.debug.print("preloaded post author: {s}\n", .{p.author.?.name});
        z.free(Post, p, gpa);
    }

    const total = try z.query(User, db).count();
    std.debug.print("total={d}\n", .{total});
    z.free(User, one.?, gpa);
    std.debug.print("smoke OK\n", .{});
}
