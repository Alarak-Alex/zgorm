//! Integration tests against a real PostgreSQL server.
//! Run with:  ZORM_DSN="postgres://user:pass@host:5432/db" zig build test-integration
//! Without ZORM_DSN the tests are skipped.

const std = @import("std");
const z = @import("zorm");
const test_options = @import("test_options");

const User = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    email: ?[]const u8 = null,
    age: i32 = 0,
    active: bool = true,
    balance: f64 = 0,
    created_at: ?z.Time = null,
    updated_at: ?z.Time = null,

    pub const zorm = .{ .unique = .{"email"}, .indexes = .{"age"} };
};

const Post = struct {
    id: ?i64 = null,
    author_id: i64 = 0,
    title: []const u8 = "",
    body: []const u8 = "",
    views: i64 = 0,
    published: bool = false,
    rating: f32 = 0,
    status: Status = .draft,
    created_at: ?z.Time = null,

    pub const Status = enum { draft, review, published };

    pub const zorm = .{ .indexes = .{"author_id"} };
};

fn drop(res: z.pq.Result) void {
    var r = res;
    r.deinit();
}

fn makeDb(gpa: std.mem.Allocator, io: std.Io) !?*z.Db {
    const dsn = test_options.dsn orelse {
        std.debug.print("no DSN given; skipping integration tests\n", .{});
        std.debug.print("run: zig build test-integration -Ddsn='postgres://user:pass@host:5432/db'\n", .{});
        return null;
    };
    return try z.Db.connectDsn(gpa, io, dsn, 4);
}

test "full orm lifecycle" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db = (try makeDb(gpa, io)) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS \"user\" CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS \"post\" CASCADE"));
    try db.autoMigrateAll(.{ User, Post });

    // insert
    var u = User{ .name = "Alice", .email = "alice@example.com", .age = 30, .balance = 100.5 };
    try db.insert(&u);
    try std.testing.expect(u.id != null);
    try std.testing.expect(u.created_at != null);
    try std.testing.expect(u.updated_at != null);

    // unique violation surfaces as a typed error
    var dup = User{ .name = "Alice2", .email = "alice@example.com" };
    try std.testing.expectError(error.UniqueViolation, db.insert(&dup));

    // find
    const found = (try db.find(User, u.id.?)).?;
    try std.testing.expectEqualStrings("Alice", found.name);
    try std.testing.expectEqualStrings("alice@example.com", found.email.?);
    try std.testing.expectEqual(@as(i32, 30), found.age);
    try std.testing.expectEqual(@as(f64, 100.5), found.balance);
    try std.testing.expect(found.active);
    z.free(User, found, gpa);

    // update
    var upd = u;
    upd.age = 31;
    upd.balance = 200.25;
    const affected = try db.update(&upd);
    try std.testing.expectEqual(@as(i64, 1), affected);
    const after = (try db.find(User, u.id.?)).?;
    try std.testing.expectEqual(@as(i32, 31), after.age);
    try std.testing.expectEqual(@as(f64, 200.25), after.balance);
    z.free(User, after, gpa);

    // save (update path)
    upd.age = 32;
    try db.save(&upd);
    const after2 = (try db.find(User, u.id.?)).?;
    try std.testing.expectEqual(@as(i32, 32), after2.age);
    z.free(User, after2, gpa);

    // query builder
    const users = try z.query(User, db)
        .where("age >= $1", .{18})
        .whereEq("active", true)
        .order_by("age DESC")
        .all(gpa);
    defer z.freeSlice(User, users, gpa);
    try std.testing.expect(users.len >= 1);

    try std.testing.expectEqual(@as(i64, 1), try z.query(User, db).whereEq("name", "Alice").count());
    try std.testing.expect(try z.query(User, db).whereEq("name", "Alice").exists());
    try std.testing.expect(!(try z.query(User, db).whereEq("name", "Nobody").exists()));

    // renumbered chained conditions + IN
    const mixed = try z.query(User, db)
        .where("age > $1", .{0})
        .whereIn("name", &.{ "Alice", "Bob", "Carol" })
        .all(gpa);
    defer z.freeSlice(User, mixed, gpa);
    try std.testing.expectEqual(@as(usize, 1), mixed.len);

    // orWhere
    const ors = try z.query(User, db)
        .whereEq("name", "Alice")
        .orWhere("name = $1", .{"Zed"})
        .all(gpa);
    defer z.freeSlice(User, ors, gpa);
    try std.testing.expectEqual(@as(usize, 1), ors.len);

    // select subset: missing columns keep defaults
    const partial = try z.query(User, db).select(&.{ "id", "name" }).whereEq("id", u.id.?).first();
    try std.testing.expect(partial != null);
    try std.testing.expectEqualStrings("Alice", partial.?.name);
    try std.testing.expectEqual(@as(i32, 0), partial.?.age);
    z.free(User, partial.?, gpa);

    // enums + f32 + batches through a transaction
    {
        var tx = try db.begin();
        errdefer tx.rollback();
        var posts = [_]Post{
            .{ .author_id = u.id.?, .title = "One", .body = "body one", .views = 10, .rating = 4.5, .status = .published },
            .{ .author_id = u.id.?, .title = "Two", .body = "body two", .views = 3, .rating = 3.5 },
            .{ .author_id = u.id.?, .title = "Three", .body = "body three", .views = 7, .rating = 5.0, .status = .review },
        };
        try tx.insertBatch(&posts);
        try std.testing.expect(posts[2].id != null);
        try tx.commit();
    }

    const popular = try z.query(Post, db)
        .where("views >= $1", .{5})
        .whereIn("status", .{ .published, .review })
        .order_by("views DESC")
        .all(gpa);
    defer z.freeSlice(Post, popular, gpa);
    try std.testing.expectEqual(@as(usize, 2), popular.len);
    try std.testing.expectEqualStrings("One", popular[0].title); // views DESC: 10, 7
    try std.testing.expectEqualStrings("Three", popular[1].title);

    // updateWhere / deleteWhere
    const marked = try db.updateWhere(Post, .{ .published = true, .views = 100 }, "title = $1", .{"Two"});
    try std.testing.expectEqual(@as(i64, 1), marked);
    const removed = try db.deleteWhere(Post, "views = $1", .{100});
    try std.testing.expectEqual(@as(i64, 1), removed);

    // delete by model
    var by_id = (try z.query(Post, db).whereEq("title", "One").first()).?;
    _ = try db.delete(&by_id);
    z.free(Post, by_id, gpa);

    // rollback leaves no trace
    {
        var tx = try db.begin();
        defer tx.rollback();
        var ghost = User{ .name = "Ghost" };
        try tx.insert(&ghost);
    }
    try std.testing.expectEqual(@as(i64, 0), try z.query(User, db).whereEq("name", "Ghost").count());

    // time round trip through timestamptz
    var timed = Post{ .author_id = u.id.?, .title = "Timed", .created_at = z.Time.fromUnix(1_800_000_000) };
    try db.insert(&timed);
    const timed_back = (try z.query(Post, db).whereEq("title", "Timed").first()).?;
    try std.testing.expectEqual(@as(i64, 1_800_000_000_000_000), timed_back.created_at.?.micros);
    z.free(Post, timed_back, gpa);

    // cleanup
    _ = try db.deleteWhere(User, "true", .{});
    _ = try db.deleteWhere(Post, "true", .{});

    std.debug.print("integration lifecycle OK\n", .{});
}

// --------------------------------------------------------------- v2 models

const BlogAuthor = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    posts: []RichPost = &.{}, // has_many

    pub const zorm = .{
        .has_many = .{ .posts = .{ .model = RichPost, .foreign_key = "author_id" } },
    };
};

const RichPost = struct {
    id: ?i64 = null,
    author_id: ?i64 = null, // belongs_to BlogAuthor
    title: []const u8 = "",
    tags: []const []const u8 = &.{}, // text[]
    scores: []const i64 = &.{}, // bigint[]
    weights: ?[]const f64 = null, // double precision[]
    meta: ?z.Json = null, // jsonb
    attachment: ?z.Bytes = null, // bytea
    author: ?BlogAuthor = null, // preloaded belongs_to

    // hook bookkeeping
    pub var hook_log: []const u8 = "";

    pub const zorm = .{
        .table = "v2_posts",
        .belongs_to = .{ .author = .{ .model = BlogAuthor, .foreign_key = "author_id" } },
    };
};

const Hooked = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    calls: i32 = 0,

    pub var log: [64]u8 = undefined;
    pub var log_len: usize = 0;

    fn note(comptime tag: []const u8) void {
        @memcpy(log[log_len..][0..tag.len], tag);
        log_len += tag.len;
    }

    pub fn beforeCreate(self: *Hooked, s: *z.Session) z.Error!void {
        _ = s;
        note("B");
        self.name = "hooked:" ++ "seed";
    }

    pub fn afterCreate(self: *Hooked, s: *z.Session) z.Error!void {
        _ = s;
        _ = self;
        note("C");
    }

    pub fn beforeUpdate(self: *Hooked, s: *z.Session) z.Error!void {
        _ = s;
        _ = self;
        note("U");
    }

    pub fn afterFind(self: *Hooked, s: *z.Session) z.Error!void {
        _ = s;
        self.calls += 1;
        note("F");
    }

    pub fn beforeDelete(self: *Hooked, s: *z.Session) z.Error!void {
        _ = s;
        _ = self;
        note("D");
    }

    pub const zorm = .{};
};

test "v2: binary params, arrays, jsonb, bytea round trip" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v2_posts CASCADE"));
    try db.autoMigrate(RichPost);

    var p = RichPost{
        .title = "rich",
        .tags = &.{ "dev", "has,comma", "quo\"te", null_safe_tag },
        .scores = &.{ 1, -2, 3 },
        .weights = &.{ 0.5, 1.5 },
        .meta = z.Json{ .data = "{\"k\": [1, 2], \"s\": \"v\"}" },
        .attachment = z.Bytes{ .data = &.{ 0, 0xff, 0x7f } },
    };
    try db.insert(&p);
    try std.testing.expect(p.id != null);

    const back = (try db.find(RichPost, p.id.?)).?;
    try std.testing.expectEqualStrings("rich", back.title);
    try std.testing.expectEqual(@as(usize, 4), back.tags.len);
    try std.testing.expectEqualStrings("has,comma", back.tags[1]);
    try std.testing.expectEqualStrings("quo\"te", back.tags[2]);
    try std.testing.expectEqualSlices(i64, &.{ 1, -2, 3 }, back.scores);
    try std.testing.expectEqual(@as(usize, 2), back.weights.?.len);
    try std.testing.expectEqual(@as(f64, 0.5), back.weights.?[0]);
    try std.testing.expectEqualStrings("{\"k\": [1, 2], \"s\": \"v\"}", back.meta.?.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0x7f }, back.attachment.?.data);
    z.free(RichPost, back, gpa);

    // empty array round trip
    var p2 = RichPost{ .title = "empty", .scores = &.{}, .tags = &.{} };
    try db.insert(&p2);
    const back2 = (try db.find(RichPost, p2.id.?)).?;
    try std.testing.expectEqual(@as(usize, 0), back2.scores.len);
    try std.testing.expectEqual(@as(usize, 0), back2.tags.len);
    z.free(RichPost, back2, gpa);

    _ = try db.deleteWhere(RichPost, "true", .{});
}

const null_safe_tag = "safe";

test "v2: associations and preloading" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v2_posts CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS blog_author CASCADE"));
    try db.autoMigrateAll(.{ BlogAuthor, RichPost });

    var alice = BlogAuthor{ .name = "Alice" };
    var bob = BlogAuthor{ .name = "Bob" };
    try db.insert(&alice);
    try db.insert(&bob);

    var posts = [_]RichPost{
        .{ .title = "a1", .author_id = alice.id, .scores = &.{} },
        .{ .title = "a2", .author_id = alice.id, .scores = &.{} },
        .{ .title = "b1", .author_id = bob.id, .scores = &.{} },
        .{ .title = "orphan", .scores = &.{} }, // no author
    };
    try db.insertBatch(&posts);

    // has_many preload
    const authors = try z.query(BlogAuthor, db).preload("posts").order_by("id").all(gpa);
    defer z.freeSlice(BlogAuthor, authors, gpa);
    try std.testing.expectEqual(@as(usize, 2), authors.len);
    try std.testing.expectEqualStrings("Alice", authors[0].name);
    try std.testing.expectEqual(@as(usize, 2), authors[0].posts.len);
    try std.testing.expectEqualStrings("a1", authors[0].posts[0].title);
    try std.testing.expectEqualStrings("a2", authors[0].posts[1].title);
    try std.testing.expectEqual(@as(usize, 1), authors[1].posts.len);
    try std.testing.expectEqualStrings("b1", authors[1].posts[0].title);

    // belongs_to preload (including NULL fk -> null author)
    const all_posts = try z.query(RichPost, db).preload("author").order_by("id").all(gpa);
    defer z.freeSlice(RichPost, all_posts, gpa);
    try std.testing.expectEqual(@as(usize, 4), all_posts.len);
    try std.testing.expectEqualStrings("Alice", all_posts[0].author.?.name);
    try std.testing.expectEqualStrings("Alice", all_posts[1].author.?.name);
    try std.testing.expectEqualStrings("Bob", all_posts[2].author.?.name);
    try std.testing.expect(all_posts[3].author == null);

    // first() also preloads
    const one = (try z.query(RichPost, db).preload("author").whereEq("title", "b1").first()).?;
    try std.testing.expectEqualStrings("Bob", one.author.?.name);
    z.free(RichPost, one, gpa);

    _ = try db.deleteWhere(RichPost, "true", .{});
    _ = try db.deleteWhere(BlogAuthor, "true", .{});

}

test "v2: model hooks" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v2_hooked CASCADE"));
    try db.autoMigrate(Hooked);

    Hooked.log = [_]u8{0} ** 64;
    Hooked.log_len = 0;

    var h = Hooked{ .name = "orig" };
    try db.insert(&h);
    try std.testing.expectEqualStrings("hooked:seed", h.name); // beforeCreate mutated

    h.name = "changed";
    _ = try db.update(&h);

    var found = (try db.find(Hooked, h.id.?)).?;
    defer z.free(Hooked, found, gpa);
    try std.testing.expectEqual(@as(i32, 1), found.calls); // afterFind ran
    _ = try db.delete(&found);

    // insert -> B C; update -> U; find -> F; delete -> D
    try std.testing.expectEqualStrings("BCUFD", Hooked.log[0..Hooked.log_len]);

    _ = try db.deleteWhere(Hooked, "true", .{});
}

const Plain = struct {
    id: ?i64 = null,
    name: []const u8 = "",

    pub const zorm = .{};
};

test "v2: savepoints and nested transactions" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v2_hooked CASCADE"));
    try db.autoMigrate(Plain);

    // Outer txn keeps A; savepoint 1 rolled back drops B; savepoint 2 commits C.
    {
        var tx = try db.begin();
        defer tx.rollback();

        var a = Plain{ .name = "A" };
        try tx.insert(&a);

        {
            var sp1 = try tx.begin();
            var b = Plain{ .name = "B" };
            try sp1.insert(&b);
            sp1.rollback(); // B is undone
        }

        {
            var sp2 = try tx.begin();
            var c = Plain{ .name = "C" };
            try sp2.insert(&c);
            try sp2.commit(); // C survives within the txn
        }

        // Deep nesting: savepoint inside savepoint.
        {
            var sp3 = try tx.begin();
            defer sp3.rollback();
            var d = Plain{ .name = "D" };
            try sp3.insert(&d);
        }

        try tx.commit();
    }

    const a_count = try z.query(Plain, db).whereEq("name", "A").count();
    const b_count = try z.query(Plain, db).whereEq("name", "B").count();
    const c_count = try z.query(Plain, db).whereEq("name", "C").count();
    const d_count = try z.query(Plain, db).whereEq("name", "D").count();
    try std.testing.expectEqual(@as(i64, 1), a_count);
    try std.testing.expectEqual(@as(i64, 0), b_count);
    try std.testing.expectEqual(@as(i64, 1), c_count);
    try std.testing.expectEqual(@as(i64, 0), d_count);

    _ = try db.deleteWhere(Plain, "true", .{});
}

test "v2: migration versioning" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS m_demo CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS schema_migrations CASCADE"));

    var m = z.Migrator.init(db);
    defer m.deinit();
    // Registered out of order to prove version ordering.
    m.add(&.{
        .{ .version = 20, .name = "add_note", .up = "ALTER TABLE m_demo ADD COLUMN IF NOT EXISTS note text", .down = "ALTER TABLE m_demo DROP COLUMN IF EXISTS note" },
        .{ .version = 10, .name = "create_m_demo", .up = "CREATE TABLE m_demo (id bigserial PRIMARY KEY, title text)", .down = "DROP TABLE m_demo" },
        .{ .version = 30, .name = "seed", .up = "INSERT INTO m_demo (title) VALUES ('seeded')" },
    });

    const applied_count = try m.applyAll();
    try std.testing.expectEqual(@as(usize, 3), applied_count);

    // Second run is a no-op.
    try std.testing.expectEqual(@as(usize, 0), try m.applyAll());

    // The seed ran (v10 created the table before v30 seeded).
    var seeded = try db.execRaw("SELECT count(*) FROM m_demo");
    defer seeded.deinit();
    try std.testing.expectEqualStrings("1", seeded.rows[0][0].?);

    const applied = try m.appliedVersions(gpa);
    defer gpa.free(applied);
    try std.testing.expectEqual(@as(usize, 3), applied.len);
    try std.testing.expectEqual(@as(i64, 10), applied[0]);
    try std.testing.expectEqual(@as(i64, 30), applied[2]);

    // Roll back v30 (no down -> refused), then v20, then v10.
    try std.testing.expectError(error.TypeMismatch, m.rollbackLast()); // v30 has no down
    m.add(&.{.{ .version = 30, .name = "seed", .up = "INSERT INTO m_demo (title) VALUES ('seeded')", .down = "DELETE FROM m_demo WHERE title = 'seeded'" }});
    try m.rollbackLast(); // v30 down runs
    try m.rollbackLast(); // v20 down runs
    try m.rollbackLast(); // v10 down drops the table

    drop(try db.execRaw("DROP TABLE IF EXISTS schema_migrations CASCADE"));
}
