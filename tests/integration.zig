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
