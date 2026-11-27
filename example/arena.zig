//! Arena "easy mode" demo — every decoded value lands in one arena and is
//! released by a single `deinit`. No `zg.free` / `zg.freeSlice` anywhere.
//!
//!   zig build run-arena -Ddsn='postgres://user:pass@host:5432/db?sslmode=disable'
//!
//! Compare with example/main.zig, which shows the per-value release style.

const std = @import("std");
const zg = @import("zgorm");

pub const Author = struct {
    base: zg.Model = .{},
    name: []const u8 = "",
    posts: []Post = &.{}, // inferred has_many

    pub const zgorm = .{ .table = "arena_authors" };
};

pub const Post = struct {
    base: zg.Model = .{},
    author_id: ?i64 = null,
    title: []const u8 = "",
    author: ?Author = null, // inferred belongs_to

    pub const zgorm = .{ .table = "arena_posts" };
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const dsn = init.environ_map.get("ZORM_DSN") orelse
        "postgres://zorm:zorm@127.0.0.1:5433/zorm?sslmode=disable";
    const db = try zg.Db.connectDsn(gpa, io, dsn, 4);
    defer db.deinit();

    {
        var res = try db.execRaw("DROP TABLE IF EXISTS \"arena_posts\" CASCADE");
        res.deinit();
    }
    {
        var res = try db.execRaw("DROP TABLE IF EXISTS \"arena_authors\" CASCADE");
        res.deinit();
    }
    try db.autoMigrateAll(.{ Author, Post });

    // ---- the whole request/task runs on one arena -------------------------
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit(); // Reclaim decoded models together.
    const arena = arena_state.allocator();

    // Writes need no release: insert stamps ids/timestamps into your structs.
    var posts = [_]Post{
        .{ .title = "hello arena" },
        .{ .title = "one deinit to free them all" },
    };
    var author = Author{ .name = "Ada", .posts = &posts };
    try db.insert(&author); // saves the posts association too

    // all(arena): rows, strings and preloaded children all live in the arena.
    const authors = try zg.query(Author, db)
        .whereEq("name", "Ada")
        .preload("posts")
        .all(arena);
    for (authors) |a| {
        std.debug.print("{s} wrote {d} post(s)\n", .{ a.name, a.posts.len });
        for (a.posts) |p| std.debug.print("  - {s}\n", .{p.title});
    }

    // find / first use the session gpa; point a session at the arena and
    // they join the same single-release lifecycle.
    var s = db.session();
    s.gpa = arena;
    const one = (try s.find(Author, author.base.id.?)).?;
    const first_post = try s.query(Post).whereEq("author_id", author.base.id.?).first();
    std.debug.print("find: {s}, first post: {s}\n", .{
        one.name,
        if (first_post) |p| p.title else "<none>",
    });

    {
        var rows = try s.query(Post).order_by("id").stream(arena);
        defer rows.deinit(); // Return the connection even when only one row is read.
        if (try rows.next()) |post| std.debug.print("stream: {s}\n", .{post.title});
    }

    // Raw exec still returns an owning Result; deinit it as usual.
    // (::text keeps the cell readable — exec cells default to binary format.)
    var res = try s.exec("SELECT count(*)::text FROM \"arena_posts\"", .{});
    defer res.deinit();
    std.debug.print("post count: {s}\n", .{res.rows[0][0].?});

    // No zg.free / zg.freeSlice calls anywhere in this file —
    // arena_state.deinit() above reclaims every decoded byte.
    std.debug.print("arena demo OK\n", .{});
}
