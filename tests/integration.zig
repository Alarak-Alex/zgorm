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

const StreamRow = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    pub const zorm = .{ .table = "zorm_stream_rows" };
};

const VersionedRow = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    version: i64 = 0,
    pub const zorm = .{ .table = "zorm_versioned_rows" };
};

const ExplicitVersionRow = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    lock_version: i64 = 0,
    pub const zorm = .{ .table = "zorm_explicit_version_rows", .version = "lock_version" };
};

const UpsertRow = struct {
    id: ?i64 = null,
    email: []const u8 = "",
    name: []const u8 = "",
    note: []const u8 = "",
    pub const zorm = .{ .table = "zorm_upsert_rows", .unique = &.{"email"} };
};

const ReturningProjection = struct {
    id: ?i64 = null,
    name: []const u8 = "",
};

const CompositeRow = struct {
    tenant_id: i64,
    code: []const u8,
    name: []const u8 = "",
    pub const zorm = .{
        .table = "zorm_composite_rows",
        .primary_keys = &.{ "tenant_id", "code" },
    };
};

const CompositeChild = struct {
    id: ?i64 = null,
    tenant_id: i64,
    parent_code: []const u8,
    body: []const u8 = "",
    pub const zorm = .{ .table = "zorm_composite_children" };
};

const CompositeParent = struct {
    tenant_id: i64,
    code: []const u8,
    name: []const u8 = "",
    children: []CompositeChild = &.{},
    pub const zorm = .{
        .table = "zorm_composite_parents",
        .primary_keys = &.{ "tenant_id", "code" },
        .has_many = .{
            .children = .{
                .model = CompositeChild,
                .foreign_keys = &.{ "tenant_id", "parent_code" },
                .primary_keys = &.{ "tenant_id", "code" },
            },
        },
    };
};

const AssocProfile = struct {
    id: ?i64 = null,
    owner_id: ?i64 = null,
    bio: []const u8 = "",
    pub const zorm = .{ .table = "zorm_assoc_profiles" };
};

const AssocNote = struct {
    id: ?i64 = null,
    owner_id: ?i64 = null,
    owner_type: []const u8 = "",
    body: []const u8 = "",
    pub const zorm = .{ .table = "zorm_assoc_notes" };
};

const AssocTag = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    pub const zorm = .{ .table = "zorm_assoc_tags" };
};

const AssocOwner = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    profile: ?AssocProfile = null,
    notes: []AssocNote = &.{},
    tags: []AssocTag = &.{},
    pub const zorm = .{
        .table = "zorm_assoc_owners",
        .has_one = .{ .profile = .{
            .model = AssocProfile,
            .foreign_key = "owner_id",
            .cascade_delete = true,
        } },
        .has_many = .{ .notes = .{
            .model = AssocNote,
            .foreign_key = "owner_id",
            .polymorphic_type = "owner_type",
            .polymorphic_value = "owner",
            .cascade_delete = true,
        } },
        .many_to_many = .{ .tags = .{
            .model = AssocTag,
            .foreign_key = "owner_id",
            .join_table = "zorm_owner_tags",
            .join_foreign_key = "owner_id",
            .join_association_key = "tag_id",
            .cascade_delete = true,
        } },
    };
};

const CustomState = enum {
    ready,
    stopped,
    pub const zormDdl = "text";
    pub fn zormEncode(self: @This(), _: std.mem.Allocator) z.pq.Error!z.pq.Param {
        return .{ .oid = 0, .format = 0, .data = if (self == .ready) "R" else "S" };
    }
    pub fn zormDecode(data: []const u8, _: u32, _: u16, _: std.mem.Allocator) z.value.DecodeError!@This() {
        if (std.mem.eql(u8, data, "R")) return .ready;
        if (std.mem.eql(u8, data, "S")) return .stopped;
        return error.TypeMismatch;
    }
};

const CustomJson = struct {
    data: []const u8,
    pub const zormDdl = "jsonb";
    pub fn zormEncode(self: @This(), _: std.mem.Allocator) z.pq.Error!z.pq.Param {
        return .{ .oid = 0, .format = 0, .data = self.data };
    }
    pub fn zormDecode(data: []const u8, _: u32, _: u16, gpa: std.mem.Allocator) z.value.DecodeError!@This() {
        return .{ .data = gpa.dupe(u8, data) catch return error.OutOfMemory };
    }
};

const CodecRow = struct {
    id: ?i64 = null,
    uuid: z.Uuid,
    amount: z.Decimal,
    address: z.Inet,
    network: z.Cidr,
    span: z.Range,
    state: CustomState,
    payload: CustomJson,
    pub const zorm = .{ .table = "zorm_codec_rows" };
};

fn drop(res: z.pq.Result) void {
    var r = res;
    r.deinit();
}

fn backendPid(db: *z.Db) !i64 {
    var result = try db.execRaw("SELECT pg_backend_pid()");
    defer result.deinit();
    return try std.fmt.parseInt(i64, result.rows[0][0].?, 10);
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
    weights: ?[]const ?f64 = null, // double precision[] with NULL elements
    meta: ?z.Json = null, // jsonb
    attachment: ?z.Bytes = null, // bytea
    author: ?BlogAuthor = null, // preloaded belongs_to
    comments: []Comment = &.{}, // preloaded has_many

    pub const zorm = .{
        .table = "v2_posts",
        .belongs_to = .{ .author = .{ .model = BlogAuthor, .foreign_key = "author_id" } },
        .has_many = .{ .comments = .{ .model = Comment, .foreign_key = "post_id" } },
    };
};

const Matrix = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    cells: []const []const i64 = &.{}, // 2-D bigint[]
    weights: ?[]const ?f64 = null, // double precision[] with NULL elements

    pub const zorm = .{
        .table = "v2_matrix",
    };
};

const Comment = struct {
    id: ?i64 = null,
    post_id: ?i64 = null,
    text: []const u8 = "",

    pub const zorm = .{
        .table = "v2_comments",
        .belongs_to = .{ .post = .{ .model = RichPost, .foreign_key = "post_id" } },
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

    // NULL array elements (optional f64 elements)
    var pw = RichPost{ .title = "nulls", .weights = &[_]?f64{ 1.5, null, -2.5 }, .scores = &.{} };
    try db.insert(&pw);
    const pw_back = (try db.find(RichPost, pw.id.?)).?;
    try std.testing.expectEqual(@as(usize, 3), pw_back.weights.?.len);
    try std.testing.expectEqual(@as(?f64, 1.5), pw_back.weights.?[0]);
    try std.testing.expectEqual(@as(?f64, null), pw_back.weights.?[1]);
    try std.testing.expectEqual(@as(?f64, -2.5), pw_back.weights.?[2]);
    z.free(RichPost, pw_back, gpa);

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

    const queried = (try z.query(Hooked, db).whereEq("id", h.id.?).first()).?;
    defer z.free(Hooked, queried, gpa);
    try std.testing.expectEqual(@as(i32, 1), queried.calls);

    const queried_all = try z.query(Hooked, db).all(gpa);
    defer z.freeSlice(Hooked, queried_all, gpa);
    try std.testing.expectEqual(@as(usize, 1), queried_all.len);
    try std.testing.expectEqual(@as(i32, 1), queried_all[0].calls);

    var multi = try db.execRaw("SELECT 1 AS n; SELECT 2 AS n");
    defer multi.deinit();
    try std.testing.expectEqual(@as(usize, 1), multi.rows.len);
    try std.testing.expectEqualStrings("2", multi.rows[0][0].?);
    _ = try db.delete(&found);

    // insert -> B C; update -> U; find/query/query -> F F F; delete -> D
    try std.testing.expectEqualStrings("BCUFFFD", Hooked.log[0..Hooked.log_len]);

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
    drop(try db.execRaw("DROP TABLE IF EXISTS plain CASCADE"));
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

test "v2: nested preloading and 2-D arrays" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v2_comments CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v2_posts CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v2_authors2 CASCADE"));
    try db.autoMigrateAll(.{ BlogAuthor, RichPost, Comment, Matrix });

    var alice = BlogAuthor{ .name = "Alice" };
    try db.insert(&alice);

    var posts = [_]RichPost{
        .{ .title = "p1", .author_id = alice.id, .scores = &.{ 1, 2 }, .tags = &.{"z"} },
        .{ .title = "p2", .author_id = alice.id, .scores = &.{} },
    };
    try db.insertBatch(&posts);

    var comments = [_]Comment{
        .{ .post_id = posts[0].id, .text = "nice" },
        .{ .post_id = posts[0].id, .text = "again" },
        .{ .post_id = posts[1].id, .text = "meh" },
    };
    try db.insertBatch(&comments);

    // two-level nested preload: author -> posts -> comments
    const authors = try z.query(BlogAuthor, db).preload("posts.comments").all(gpa);
    defer z.freeSlice(BlogAuthor, authors, gpa);
    try std.testing.expectEqual(@as(usize, 1), authors.len);
    try std.testing.expectEqual(@as(usize, 2), authors[0].posts.len);
    try std.testing.expectEqual(@as(usize, 2), authors[0].posts[0].comments.len);
    try std.testing.expectEqualStrings("nice", authors[0].posts[0].comments[0].text);
    try std.testing.expectEqualStrings("again", authors[0].posts[0].comments[1].text);
    try std.testing.expectEqual(@as(usize, 1), authors[0].posts[1].comments.len);
    try std.testing.expectEqualStrings("meh", authors[0].posts[1].comments[0].text);

    // 2-D array column (bigint[] holding {{1,2},{3,4}})
    var m = Matrix{ .name = "m1", .cells = &.{ &.{ 1, 2 }, &.{ 3, 4 } } };
    try db.insert(&m);
    const m_back = (try db.find(Matrix, m.id.?)).?;
    try std.testing.expectEqual(@as(usize, 2), m_back.cells.len);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, m_back.cells[0]);
    try std.testing.expectEqualSlices(i64, &.{ 3, 4 }, m_back.cells[1]);
    z.free(Matrix, m_back, gpa);

    _ = try db.deleteWhere(Comment, "true", .{});
    _ = try db.deleteWhere(RichPost, "true", .{});
    _ = try db.deleteWhere(BlogAuthor, "true", .{});
    _ = try db.deleteWhere(Matrix, "true", .{});
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

const MigrationShape = struct {
    code: []const u8 = "",
    amount: i64 = 0,

    pub const zorm = .{ .table = "v5_migration_shape" };
};

test "v5: migration schema operations, diffs, checksums, and dirty state" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_child CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_parent CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_shape CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_checksum CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS schema_migrations CASCADE"));
    drop(try db.execRaw("CREATE TABLE v5_migration_parent (id integer PRIMARY KEY)"));
    drop(try db.execRaw(
        "CREATE TABLE v5_migration_child (parent_id integer, old_value text, extra text, a integer, b integer)",
    ));
    drop(try db.execRaw("CREATE TABLE v5_migration_shape (code text, amount integer, extra text)"));

    var m = z.Migrator.init(db);
    defer m.deinit();
    try m.renameColumn("v5_migration_child", "old_value", "value");
    try m.alterColumnType("v5_migration_child", "value", "bigint", "value::bigint");
    try m.dropColumn("v5_migration_child", "extra");
    try m.addForeignKey(
        "v5_migration_child",
        "v5_migration_child_parent_fk",
        &.{"parent_id"},
        "v5_migration_parent",
        &.{"id"},
        "CASCADE",
    );
    try m.addCheck("v5_migration_child", "v5_migration_child_a_check", "a > 0");
    try m.createIndex("v5_migration_child", "v5_migration_child_ab_idx", .{ .columns = &.{ "a", "b" } });
    try m.createIndex("v5_migration_child", "v5_migration_child_partial_idx", .{
        .columns = &.{"a"},
        .where = "a > 10",
    });
    try m.createIndex("v5_migration_child", "v5_migration_child_expression_idx", .{
        .expression = "(a + b)",
    });

    var indexes = try db.execRaw(
        "SELECT count(*) FROM pg_indexes WHERE tablename = 'v5_migration_child' AND indexname LIKE 'v5_migration_child_%_idx'",
    );
    defer indexes.deinit();
    try std.testing.expectEqualStrings("3", indexes.rows[0][0].?);
    try std.testing.expectError(error.ForeignKeyViolation, db.execRaw(
        "INSERT INTO v5_migration_child (parent_id, value, a, b) VALUES (999, 1, 1, 1)",
    ));
    try std.testing.expectError(error.CheckViolation, db.execRaw(
        "INSERT INTO v5_migration_child (parent_id, value, a, b) VALUES (NULL, 1, -1, 1)",
    ));

    const changes = try m.schemaDiff(MigrationShape, gpa);
    defer {
        for (changes) |change| change.deinit(gpa);
        gpa.free(changes);
    }
    var alters: usize = 0;
    var drops: usize = 0;
    for (changes) |change| switch (change.kind) {
        .alter => alters += 1,
        .drop => drops += 1,
        .add => {},
    };
    try std.testing.expectEqual(@as(usize, 1), alters);
    try std.testing.expectEqual(@as(usize, 1), drops);

    m.add(&.{.{
        .version = 100,
        .name = "checksum",
        .up = "CREATE TABLE v5_migration_checksum (id bigint)",
        .down = "DROP TABLE v5_migration_checksum",
    }});
    try std.testing.expectEqual(@as(usize, 1), try m.applyAll());

    var changed = z.Migrator.init(db);
    defer changed.deinit();
    changed.add(&.{.{ .version = 100, .name = "checksum", .up = "CREATE TABLE v5_migration_checksum (id integer)" }});
    try std.testing.expectError(error.MigrationChecksumMismatch, changed.applyAll());

    drop(try db.execRaw("UPDATE schema_migrations SET dirty = true WHERE version = 100"));
    try std.testing.expectError(error.DirtyMigration, m.applyAll());
    drop(try db.execRaw("UPDATE schema_migrations SET dirty = false WHERE version = 100"));
    m.add(&.{.{ .version = 200, .name = "fails", .up = "INSERT INTO v5_missing_migration_table VALUES (1)" }});
    try std.testing.expectError(error.UndefinedTable, m.applyAll());
    try std.testing.expectError(error.DirtyMigration, m.applyAll());

    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_child CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_parent CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_shape CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_migration_checksum CASCADE"));
    drop(try db.execRaw("DROP TABLE IF EXISTS schema_migrations CASCADE"));
}

const EmbeddedUser = struct {
    base: z.Model = .{}, // id, created_at, updated_at, deleted_at
    name: []const u8 = "",
    email: ?[]const u8 = null,

    pub const zorm = .{ .table = "v3_embedded_users", .unique = .{"email"} };
};

test "v3: embedded zorm.Model round trip and soft delete" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v3_embedded_users CASCADE"));
    try db.autoMigrate(EmbeddedUser);

    var u = EmbeddedUser{ .name = "Alice", .email = "alice@example.com" };
    try db.insert(&u);
    try std.testing.expect(u.base.id != null); // auto PK filled into the embedded model
    try std.testing.expect(u.base.created_at != null);
    try std.testing.expect(u.base.updated_at != null);
    try std.testing.expect(u.base.deleted_at == null);

    const found = (try db.find(EmbeddedUser, u.base.id.?)).?;
    defer z.free(EmbeddedUser, found, gpa);
    try std.testing.expectEqualStrings("Alice", found.name);
    try std.testing.expectEqual(u.base.id.?, found.base.id.?);

    // Update through a copy so `found` keeps its heap-owned strings
    // (z.free requires the value's strings to be unmodified).
    var upd = found;
    upd.name = "Alice2";
    _ = try db.update(&upd);
    const after = (try db.find(EmbeddedUser, u.base.id.?)).?;
    defer z.free(EmbeddedUser, after, gpa);
    try std.testing.expectEqualStrings("Alice2", after.name);
    // updated_at was refreshed by the update
    try std.testing.expect(after.base.updated_at.?.micros >= found.base.updated_at.?.micros);

    const n = try z.query(EmbeddedUser, db).whereEq("name", "Alice2").count();
    try std.testing.expectEqual(@as(i64, 1), n);

    _ = try db.delete(&u);
    try std.testing.expect((try db.find(EmbeddedUser, u.base.id.?)) == null);
    _ = try db.deleteWhereHard(EmbeddedUser, "true", .{});
}

const QueryLogEntry = struct {
    id: ?i64 = null,
    name: []const u8 = "",
};

const CapturingLogger = struct {
    buf: std.ArrayList(u8) = .empty,
    level: z.LogLevel = .info,
    calls: usize = 0,
    last_level: z.LogLevel = .silent,
    gpa: std.mem.Allocator,

    fn log(ctx: ?*anyopaque, level: z.LogLevel, msg: []const u8) void {
        const self: *CapturingLogger = @ptrCast(@alignCast(ctx.?));
        if (@intFromEnum(level) > @intFromEnum(self.level)) return;
        self.calls += 1;
        self.last_level = level;
        self.buf.appendSlice(self.gpa, msg) catch {};
        self.buf.appendSlice(self.gpa, "\n") catch {};
    }

    fn logger(self: *CapturingLogger) z.Logger {
        return .{
            .context = self,
            .level = self.level,
            .slow_threshold_ms = 0, // trace everything
            .logFn = log,
        };
    }

    fn reset(self: *CapturingLogger) void {
        self.buf.clearRetainingCapacity();
        self.calls = 0;
        self.last_level = .silent;
    }

    fn expectOne(self: *const CapturingLogger, level: z.LogLevel) !void {
        try std.testing.expectEqual(@as(usize, 1), self.calls);
        try std.testing.expectEqual(level, self.last_level);
    }
};

test "v4: default logger traces queries and can be replaced" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    // Default logger: warn level, must stay silent for a successful fast query.
    var sink = CapturingLogger{ .gpa = gpa, .level = .info };
    db.setLogger(sink.logger());
    defer db.setLogger(z.Logger.default);

    var r1 = try db.execRaw("SELECT 1");
    r1.deinit();
    try std.testing.expect(sink.buf.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "SELECT 1") != null);

    // Errors are logged at error level with the server message (custom sinks
    // receive the raw message without the default logger's tag prefix).
    sink.buf.clearRetainingCapacity();
    _ = db.execRaw("SELECT * FROM __no_such_table__") catch {};
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "SQL error") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "__no_such_table__") != null);

    // Silent logger: nothing is emitted.
    db.setLogger(z.Logger.discard);
    sink.buf.clearRetainingCapacity();
    var r3 = try db.execRaw("SELECT 2");
    r3.deinit();
    try std.testing.expectEqual(@as(usize, 0), sink.buf.items.len);
    sink.buf.deinit(gpa);
}

test "query builder logs every terminal operation" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS query_log_entry CASCADE"));
    try db.autoMigrate(QueryLogEntry);
    var entry = QueryLogEntry{ .name = "logged" };
    try db.insert(&entry);

    var sink = CapturingLogger{ .gpa = gpa };
    defer sink.buf.deinit(gpa);
    db.setLogger(sink.logger());
    defer db.setLogger(z.Logger.default);

    const rows = try z.query(QueryLogEntry, db).whereEq("name", "logged").all(gpa);
    defer z.freeSlice(QueryLogEntry, rows, gpa);
    try sink.expectOne(.info);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "ms, rows=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "\"name\" = 'logged'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "$1='logged'") != null);

    sink.reset();
    const first = (try z.query(QueryLogEntry, db).whereEq("name", "logged").first()).?;
    defer z.free(QueryLogEntry, first, gpa);
    try sink.expectOne(.info);

    sink.reset();
    try std.testing.expectEqual(@as(i64, 1), try z.query(QueryLogEntry, db).count());
    try sink.expectOne(.info);

    sink.reset();
    try std.testing.expect(try z.query(QueryLogEntry, db).exists());
    try sink.expectOne(.info);

    sink.reset();
    try std.testing.expectEqual(@as(i64, 1), try z.query(QueryLogEntry, db).whereEq("name", "logged").delete());
    try sink.expectOne(.info);

    sink.reset();
    try std.testing.expectError(
        error.UndefinedColumn,
        z.query(QueryLogEntry, db).where("definitely_missing_column = $1::bigint", .{@as(i64, 1)}).count(),
    );
    try sink.expectOne(.err);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "SQL error") != null);

    var slow_entry = QueryLogEntry{ .name = "slow" };
    try db.insert(&slow_entry);
    sink.reset();
    var slow_logger = sink.logger();
    slow_logger.slow_threshold_ms = 1;
    db.setLogger(slow_logger);
    _ = try z.query(QueryLogEntry, db)
        .where("EXISTS (SELECT 1 FROM pg_sleep(0.01))", .{})
        .count();
    try sink.expectOne(.warn);
    try std.testing.expect(std.mem.indexOf(u8, sink.buf.items, "SLOW SQL") != null);

    sink.reset();
    var silent_logger = sink.logger();
    silent_logger.level = .silent;
    db.setLogger(silent_logger);
    _ = try z.query(QueryLogEntry, db).count();
    try std.testing.expectEqual(@as(usize, 0), sink.calls);
    try std.testing.expectEqual(@as(usize, 0), sink.buf.items.len);
}

test "v3: issue fixes regression" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dsn = test_options.dsn orelse return error.SkipZigTest;

    // Issue #5: a failed connect (wrong password) must not leak conn state.
    // The DebugAllocator above reports leaks on deinit, so this test failing
    // to clean up would surface as an error log.
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
        var bad = cfg;
        bad.password = "definitely-not-the-password";
        try std.testing.expectError(error.AuthenticationFailed, z.Db.connect(gpa, io, bad, 1));
    }

    const db = try z.Db.connectDsn(gpa, io, dsn, 8);
    defer db.deinit();

    // Issue #8: adding missing columns to an existing table keeps the same
    // constraints as CREATE TABLE (NOT NULL + DEFAULT; serial for auto PK).
    drop(try db.execRaw("DROP TABLE IF EXISTS v3_fix CASCADE"));
    var created = try db.execRaw("CREATE TABLE v3_fix (title text NOT NULL)"); // no id yet
    created.deinit();
    const OldShape = struct {
        title: []const u8 = "",
    };
    _ = OldShape;
    const Full = struct {
        id: ?i64 = null,
        title: []const u8 = "",
        note: []const u8 = "",
        flag: bool = false,
        pub const zorm = .{ .table = "v3_fix" };
    };
    try db.autoMigrate(Full);
    var row = Full{ .title = "t" };
    try db.insert(&row); // would fail if id serial/NOT NULL constraints were missing
    var info = try db.exec(
        \\SELECT column_name, is_nullable, column_default FROM information_schema.columns
        \\WHERE table_schema = current_schema() AND table_name = 'v3_fix' AND column_name IN ('id','note','flag')
        \\ORDER BY column_name
    , .{});
    defer info.deinit();
    try std.testing.expectEqual(@as(usize, 3), info.rows.len);
    // note/flag must be NOT NULL with a non-null default.
    for (info.rows) |r| {
        const name = r[0].?;
        if (std.mem.eql(u8, name, "note") or std.mem.eql(u8, name, "flag")) {
            try std.testing.expectEqualStrings("NO", r[1].?);
            try std.testing.expect(r[2] != null);
        }
    }

    // Issue #2: the pool can open new connections long after connectDsn
    // returned (DSN strings must remain valid). Force an extra connection
    // through a second session + transaction while one is pinned.
    {
        var tx = try db.begin();
        var pinned = try db.execRaw("SELECT 1");
        pinned.deinit();
        var other = try z.Db.connectDsn(gpa, io, dsn, 1); // fresh pool, same path
        defer other.deinit();
        var r2 = try other.execRaw("SELECT 2");
        r2.deinit();
        try tx.commit();
    }

    // Issue #6: lastErrorCopy returns a deep-copied snapshot.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var dup = User{ .name = "dup", .email = "dup@example.com" };
    try db.insert(&dup);
    var dup2 = User{ .name = "dup2", .email = "dup@example.com" };
    try std.testing.expectError(error.UniqueViolation, db.insert(&dup2));
    const snapshot = z.lastErrorCopy(db, arena_state.allocator());
    try std.testing.expect(snapshot != null);
    try std.testing.expectEqualStrings("23505", snapshot.?.code);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.?.message, "unique") != null);

    _ = try db.deleteWhere(User, "true", .{});
    _ = try db.deleteWhere(Full, "true", .{});
    drop(try db.execRaw("DROP TABLE IF EXISTS v3_fix CASCADE"));
}

const SoftPost = struct {
    id: ?i64 = null,
    title: []const u8 = "",
    deleted_at: ?z.Time = null, // enables soft delete

    pub const zorm = .{ .table = "v4_soft" };
};

test "v4: soft delete semantics" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS v4_soft CASCADE"));
    try db.autoMigrate(SoftPost);

    var a = SoftPost{ .title = "alive" };
    var b = SoftPost{ .title = "doomed" };
    var c = SoftPost{ .title = "counted" };
    try db.insert(&a);
    try db.insert(&b);
    try db.insert(&c);

    // Model-level delete is a soft delete.
    try std.testing.expectEqual(@as(i64, 1), try db.delete(&b));
    try std.testing.expect(b.deleted_at != null);

    // Filtered out of find/count/exists by default.
    try std.testing.expect((try db.find(SoftPost, b.id.?)) == null);
    try std.testing.expectEqual(@as(i64, 0), try z.query(SoftPost, db).whereEq("title", "doomed").count());
    try std.testing.expectEqual(@as(i64, 2), try z.query(SoftPost, db).count());

    // Update does not touch soft-deleted rows.
    _ = try db.updateWhere(SoftPost, .{ .title = "x" }, "title = $1", .{"doomed"});
    try std.testing.expectEqual(@as(i64, 0), try z.query(SoftPost, db).whereEq("title", "x").count());

    // unscoped() sees them.
    try std.testing.expectEqual(@as(i64, 3), try z.query(SoftPost, db).unscoped().count());

    // findUnscoped fetches soft-deleted rows by pk; updateUnscoped can modify them.
    const doomed = (try db.findUnscoped(SoftPost, b.id.?)).?;
    defer z.free(SoftPost, doomed, gpa);
    try std.testing.expectEqualStrings("doomed", doomed.title);
    try std.testing.expect(doomed.deleted_at != null);
    var upd = doomed;
    upd.title = "doomed-v2";
    try std.testing.expectEqual(@as(i64, 1), try db.updateUnscoped(&upd));
    const renamed = (try db.findUnscoped(SoftPost, b.id.?)).?;
    defer z.free(SoftPost, renamed, gpa);
    try std.testing.expectEqualStrings("doomed-v2", renamed.title);
    // default find still excludes it
    try std.testing.expect((try db.find(SoftPost, b.id.?)) == null);

    // restore brings the row back (title was renamed to "doomed-v2" above).
    var target = SoftPost{ .id = b.id };
    _ = try db.restore(&target);
    try std.testing.expectEqual(@as(i64, 1), try z.query(SoftPost, db).whereEq("title", "doomed-v2").count());

    // Builder-level delete soft-deletes too.
    _ = try z.query(SoftPost, db).whereEq("title", "counted").delete();
    try std.testing.expectEqual(@as(i64, 0), try z.query(SoftPost, db).whereEq("title", "counted").count());
    try std.testing.expectEqual(@as(i64, 3), try z.query(SoftPost, db).unscoped().count());

    // unscoped delete is a hard delete (removes the restored "doomed-v2";
    // "counted" remains as a soft-deleted row).
    _ = try z.query(SoftPost, db).unscoped().whereEq("title", "doomed-v2").delete();
    try std.testing.expectEqual(@as(i64, 2), try z.query(SoftPost, db).unscoped().count());

    // Model-level hard delete.
    var alive = (try db.find(SoftPost, a.id.?)).?;
    defer z.free(SoftPost, alive, gpa);
    _ = try db.deleteHard(&alive);
    try std.testing.expectEqual(@as(i64, 1), try z.query(SoftPost, db).unscoped().count());

    // deleteWhere hard variant removes the new row but the soft-deleted
    // "counted" row remains visible under unscoped.
    var d2 = SoftPost{ .title = "hard" };
    try db.insert(&d2);
    _ = try db.deleteWhereHard(SoftPost, "title = $1", .{"hard"});
    try std.testing.expectEqual(@as(i64, 1), try z.query(SoftPost, db).unscoped().count());
    try std.testing.expectEqual(@as(i64, 0), try z.query(SoftPost, db).count());
}

test "prepared statement cache keys by SQL and OIDs and evicts LRU" {
    const dsn = test_options.dsn orelse return;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    cfg.prepared_statement_cache_size = 2;
    const db = try z.Db.connectWithOptions(gpa, threaded.io(), cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
    });
    defer db.deinit();
    const before = db.poolStats();

    drop(try db.exec("SELECT $1", .{@as(i64, 1)}));
    drop(try db.exec("SELECT $1", .{@as(i64, 2)}));
    var stats = db.poolStats();
    try std.testing.expectEqual(@as(u64, 1), stats.prepared_hits - before.prepared_hits);
    try std.testing.expectEqual(@as(u64, 1), stats.prepared_misses - before.prepared_misses);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), @as(f64, @floatFromInt(stats.prepared_hits - before.prepared_hits)) / @as(f64, @floatFromInt(stats.prepared_hits + stats.prepared_misses - before.prepared_hits - before.prepared_misses)), 0.0001);

    // Same SQL with a different parameter OID is a distinct cache key.
    drop(try db.exec("SELECT $1", .{"three"}));
    // A third key evicts the least-recently-used i64 entry.
    drop(try db.exec("SELECT $1::text", .{"four"}));
    drop(try db.exec("SELECT $1", .{@as(i64, 5)}));
    stats = db.poolStats();
    try std.testing.expectEqual(@as(u64, 1), stats.prepared_hits - before.prepared_hits);
    try std.testing.expectEqual(@as(u64, 4), stats.prepared_misses - before.prepared_misses);
    try std.testing.expectEqual(@as(u64, 2), stats.prepared_evictions - before.prepared_evictions);
}

test "prepared statement cache reparses an invalidated PostgreSQL plan" {
    const dsn = test_options.dsn orelse return;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    cfg.prepared_statement_cache_size = 8;
    const db = try z.Db.connectWithOptions(gpa, threaded.io(), cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
    });
    defer db.deinit();
    const before = db.poolStats();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_plan_invalidation"));
    drop(try db.execRaw("CREATE TABLE zorm_plan_invalidation (id bigint PRIMARY KEY, value integer NOT NULL)"));
    drop(try db.execRaw("INSERT INTO zorm_plan_invalidation VALUES (1, 7)"));
    drop(try db.exec("SELECT value FROM zorm_plan_invalidation WHERE id = $1", .{@as(i64, 1)}));
    drop(try db.execRaw("ALTER TABLE zorm_plan_invalidation ALTER COLUMN value TYPE bigint"));
    // PostgreSQL reports 0A000 for the cached result-type change. zorm closes
    // the stale named statement, reparses it, and retries once.
    drop(try db.exec("SELECT value FROM zorm_plan_invalidation WHERE id = $1", .{@as(i64, 1)}));

    const stats = db.poolStats();
    try std.testing.expectEqual(@as(u64, 1), stats.prepared_hits - before.prepared_hits);
    try std.testing.expectEqual(@as(u64, 2), stats.prepared_misses - before.prepared_misses);
}

test "query deadline sends CancelRequest and leaves connection reusable" {
    const db = (try makeDb(std.testing.allocator, std.testing.io)) orelse return;
    defer db.deinit();
    db.setLogger(z.Logger.discard);

    try std.testing.expectError(error.QueryTimeout, db.execRawTimeout("SELECT pg_sleep(0.2)", 20));
    try db.ping();
}

test "explicit PostgreSQL CancelRequest reports QueryCanceled" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const conn = try z.pq.Conn.connect(std.testing.allocator, std.testing.io, cfg);
    defer conn.close();

    const Runner = struct {
        conn: *z.pq.Conn,
        err: ?z.pq.Error = null,

        fn run(r: *@This()) void {
            var result = r.conn.execSimple("SELECT pg_sleep(5)") catch |err| {
                r.err = err;
                return;
            };
            result.deinit();
        }
    };
    var runner = Runner{ .conn = conn };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{&runner});
    try std.testing.io.sleep(.fromMilliseconds(20), .awake);
    try conn.sendCancelRequest();
    thread.join();
    try std.testing.expectEqual(error.QueryCanceled, runner.err.?);
    try conn.ping();
}

test "network read timeout retires and rebuilds the connection" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    cfg.read_timeout_ms = 20;
    const db = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
    });
    defer db.deinit();
    db.setLogger(z.Logger.discard);

    try std.testing.expectError(error.NetworkReadTimeout, db.execRaw("SELECT pg_sleep(0.2)"));
    try db.ping();
}

test "pool acquire and transaction deadlines return distinct errors" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const db = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
        .acquire_timeout_ms = 20,
    });
    defer db.deinit();
    db.setLogger(z.Logger.discard);

    var tx = try db.begin();
    try std.testing.expectError(error.AcquireTimeout, db.execRaw("SELECT 1"));
    tx.rollback();
    try std.testing.expect(db.poolStats().wait_count >= 1);

    var timed = try db.beginTimeout(20);
    try std.testing.expectError(error.TransactionTimeout, timed.execRaw("SELECT pg_sleep(0.2)"));
    timed.rollback();
    try db.ping();
}

test "pool hands connections to waiters in FIFO order without barging" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const db = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .min_idle_connections = 1,
        .max_idle_connections = 1,
        .cleanup_interval_ms = 0,
    });
    defer db.deinit();

    const held = try db.pool.acquire();
    const Pool = @TypeOf(db.pool);
    const waiter_count = 8;
    const Worker = struct {
        pool: *Pool,
        id: usize,
        next: *std.atomic.Value(usize),
        order: *[waiter_count]usize,
        failed: *std.atomic.Value(bool),

        fn run(worker: @This()) std.Io.Cancelable!void {
            const conn = worker.pool.acquire() catch {
                worker.failed.store(true, .release);
                return;
            };
            const position = worker.next.fetchAdd(1, .monotonic);
            worker.order[position] = worker.id;
            worker.pool.release(conn);
        }
    };

    var next: std.atomic.Value(usize) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    var order: [waiter_count]usize = undefined;
    var group: std.Io.Group = .init;
    for (0..waiter_count) |id| {
        try group.concurrent(std.testing.io, Worker.run, .{Worker{
            .pool = &db.pool,
            .id = id,
            .next = &next,
            .order = &order,
            .failed = &failed,
        }});
        while (db.poolStats().wait_count < id + 1) {
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
    }

    db.pool.release(held);
    const barger = try db.pool.acquire();
    db.pool.release(barger);
    try group.await(std.testing.io);
    try std.testing.expect(!failed.load(.acquire));
    for (order, 0..) |id, expected| try std.testing.expectEqual(expected, id);
}

test "pool bounds concurrent connection establishment" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const db = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 32,
        .max_connecting = 2,
        .max_idle_connections = 32,
        .cleanup_interval_ms = 0,
    });
    defer db.deinit();

    const Pool = @TypeOf(db.pool);
    const worker_count = 32;
    const Worker = struct {
        pool: *Pool,
        done: *std.atomic.Value(usize),
        failed: *std.atomic.Value(bool),

        fn run(worker: @This()) std.Io.Cancelable!void {
            const conn = worker.pool.acquire() catch {
                worker.failed.store(true, .release);
                _ = worker.done.fetchAdd(1, .release);
                return;
            };
            worker.pool.release(conn);
            _ = worker.done.fetchAdd(1, .release);
        }
    };

    var done: std.atomic.Value(usize) = .init(0);
    var failed: std.atomic.Value(bool) = .init(false);
    var group: std.Io.Group = .init;
    for (0..worker_count) |_| try group.concurrent(std.testing.io, Worker.run, .{Worker{
        .pool = &db.pool,
        .done = &done,
        .failed = &failed,
    }});

    var peak_connecting: usize = 0;
    while (done.load(.acquire) < worker_count) {
        db.pool.mutex.lockUncancelable(std.testing.io);
        peak_connecting = @max(peak_connecting, db.pool.connecting);
        db.pool.mutex.unlock(std.testing.io);
        try std.testing.io.sleep(.fromMicroseconds(100), .awake);
    }
    try group.await(std.testing.io);
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(peak_connecting <= 2);
}

test "pool prewarms minimum idle and enforces maximum idle" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);

    const warm = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 3,
        .min_idle_connections = 2,
        .max_idle_connections = 2,
        .cleanup_interval_ms = 0,
    });
    defer warm.deinit();
    var stats = warm.poolStats();
    try std.testing.expectEqual(@as(usize, 2), stats.open);
    try std.testing.expectEqual(@as(usize, 2), stats.idle);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);

    var first = try warm.begin();
    var second = try warm.begin();
    stats = warm.poolStats();
    try std.testing.expectEqual(@as(usize, 2), stats.in_use);
    first.rollback();
    second.rollback();
    try std.testing.expectEqual(@as(usize, 2), warm.poolStats().idle);

    const capped = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 2,
        .max_idle_connections = 1,
        .cleanup_interval_ms = 0,
    });
    defer capped.deinit();
    var one = try capped.begin();
    var two = try capped.begin();
    one.rollback();
    two.rollback();
    stats = capped.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.open);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
}

test "pool background maintenance replaces lifetime and idle expirations" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);

    const lifetime = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .min_idle_connections = 1,
        .max_idle_connections = 1,
        .max_connection_lifetime_ms = 20,
        .cleanup_interval_ms = 5,
    });
    defer lifetime.deinit();
    const old_lifetime_pid = try backendPid(lifetime);
    try std.testing.io.sleep(.fromMilliseconds(60), .awake);
    const new_lifetime_pid = try backendPid(lifetime);
    try std.testing.expect(old_lifetime_pid != new_lifetime_pid);

    const idle = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .min_idle_connections = 1,
        .max_idle_connections = 1,
        .idle_timeout_ms = 20,
        .cleanup_interval_ms = 5,
    });
    defer idle.deinit();
    const old_idle_pid = try backendPid(idle);
    try std.testing.io.sleep(.fromMilliseconds(60), .awake);
    const new_idle_pid = try backendPid(idle);
    try std.testing.expect(old_idle_pid != new_idle_pid);
}

test "pool health check rebuilds a terminated connection" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const target = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
        .health_check_interval_ms = 1,
        .cleanup_interval_ms = 0,
    });
    defer target.deinit();
    target.setLogger(z.Logger.discard);
    const killer = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
        .cleanup_interval_ms = 0,
    });
    defer killer.deinit();
    killer.setLogger(z.Logger.discard);

    const old_pid = try backendPid(target);
    drop(try killer.exec("SELECT pg_terminate_backend($1::integer)", .{old_pid}));
    try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    try target.ping();
    try std.testing.expect(old_pid != try backendPid(target));
    const stats = target.poolStats();
    try std.testing.expectEqual(@as(usize, 1), stats.open);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
}

test "streaming model rows support early close, CSV, and iterator errors" {
    const db = (try makeDb(std.testing.allocator, std.testing.io)) orelse return;
    defer db.deinit();
    db.setLogger(z.Logger.discard);
    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_stream_rows"));
    try db.autoMigrate(StreamRow);

    var models: [2_000]StreamRow = undefined;
    var names: [2_000][24]u8 = undefined;
    for (&models, &names, 0..) |*model, *name_buf, i| {
        model.* = .{ .name = try std.fmt.bufPrint(name_buf, "row-{d}", .{i}) };
    }
    try db.insertBatch(&models);
    const before_find = db.poolStats();
    const found_first = (try db.find(StreamRow, @as(i64, 1))).?;
    try std.testing.expectEqualStrings("row-0", found_first.name);
    z.free(StreamRow, found_first, std.testing.allocator);
    const found_again = (try db.find(StreamRow, @as(i64, 1))).?;
    z.free(StreamRow, found_again, std.testing.allocator);
    const after_find = db.poolStats();
    try std.testing.expectEqual(@as(u64, 1), after_find.prepared_misses - before_find.prepared_misses);
    try std.testing.expectEqual(@as(u64, 1), after_find.prepared_hits - before_find.prepared_hits);

    var early = try z.query(StreamRow, db).order_by("id").stream(std.testing.allocator);
    const first = (try early.next()).?;
    try std.testing.expectEqualStrings("row-0", first.name);
    z.free(StreamRow, first, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), db.poolStats().in_use);
    early.deinit();
    try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);
    try db.ping();

    var rows = try z.query(StreamRow, db).order_by("id").stream(std.testing.allocator);
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        z.free(StreamRow, row, std.testing.allocator);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2_000), count);
    try std.testing.expectEqual(@as(usize, 0), db.poolStats().in_use);

    var csv_rows = try z.query(StreamRow, db).order_by("id").limit(2).stream(std.testing.allocator);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try csv_rows.exportCsv(&output.writer);
    try std.testing.expectEqualStrings("id,name\r\n1,row-0\r\n2,row-1\r\n", output.writer.buffered());

    var bad = try z.query(StreamRow, db)
        .where("CASE WHEN id = 5 THEN name::integer ELSE 1 END = 1", .{})
        .order_by("id")
        .stream(std.testing.allocator);
    defer bad.deinit();
    while (true) {
        const item = bad.next() catch |err| {
            try std.testing.expectEqual(error.InvalidTextRepresentation, err);
            break;
        };
        if (item) |row| {
            z.free(StreamRow, row, std.testing.allocator);
        } else {
            return error.TestExpectedError;
        }
    }
    try db.ping();
}

test "structured events, spans, metrics, slow SQL, and Prometheus output" {
    const dsn = test_options.dsn orelse return;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cfg = try z.pq.parseDsn(arena_state.allocator(), dsn);
    const db = try z.Db.connectWithOptions(std.testing.allocator, std.testing.io, cfg, .{
        .max_connections = 1,
        .max_idle_connections = 1,
        .acquire_timeout_ms = 20,
    });
    defer db.deinit();
    db.setLogger(z.Logger.discard);

    const Capture = struct {
        events: usize = 0,
        spans: usize = 0,
        returned_rows: usize = 0,
        pool_wait_ns: u128 = 0,
        prepared_hit_rate: f64 = 0,
        error_class: z.ErrorClass = .none,
        sqlstate: [5]u8 = .{0} ** 5,
        sqlstate_len: usize = 0,

        fn query(context: ?*anyopaque, event: z.QueryEvent) void {
            const capture: *@This() = @ptrCast(@alignCast(context.?));
            capture.events += 1;
            capture.returned_rows = event.returned_rows;
            capture.pool_wait_ns = event.pool_wait_ns;
            capture.prepared_hit_rate = event.prepared_hit_rate;
            capture.error_class = event.error_class;
            capture.sqlstate_len = @min(capture.sqlstate.len, event.sqlstate.len);
            @memcpy(capture.sqlstate[0..capture.sqlstate_len], event.sqlstate[0..capture.sqlstate_len]);
        }

        fn span(context: ?*anyopaque, _: z.QueryEvent) void {
            const capture: *@This() = @ptrCast(@alignCast(context.?));
            capture.spans += 1;
        }
    };
    var capture: Capture = .{};
    var metrics: z.Metrics = .{};
    var slow = z.SlowQueryLog.init(0);
    db.setObserver(.{
        .context = &capture,
        .on_query = Capture.query,
        .on_span = Capture.span,
        .metrics = &metrics,
        .slow_queries = &slow,
    });

    drop(try db.exec("SELECT $1::bigint", .{@as(i64, 1)}));
    drop(try db.exec("SELECT $1::bigint", .{@as(i64, 2)}));
    try std.testing.expect(capture.prepared_hit_rate > 0);
    try std.testing.expectEqual(@as(usize, 1), capture.returned_rows);

    try std.testing.expectError(error.UndefinedColumn, db.execRaw("SELECT zorm_missing_column"));
    try std.testing.expectEqual(z.ErrorClass.syntax, capture.error_class);
    try std.testing.expectEqualStrings("42703", capture.sqlstate[0..capture.sqlstate_len]);

    var tx = try db.begin();
    try std.testing.expectError(error.AcquireTimeout, db.execRaw("SELECT 1"));
    tx.rollback();
    try std.testing.expect(capture.pool_wait_ns > 0);
    try std.testing.expectEqual(z.ErrorClass.timeout, capture.error_class);

    try std.testing.expectEqual(capture.events, capture.spans);
    try std.testing.expectEqual(@as(u64, @intCast(capture.events)), metrics.queries.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), metrics.errors.load(.monotonic));
    var slow_entries: [z.SlowQueryLog.capacity]z.SlowQueryLog.Entry = undefined;
    try std.testing.expect(slow.snapshot(&slow_entries).len > 0);

    var prometheus: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer prometheus.deinit();
    try db.writePrometheus(&metrics, &prometheus.writer);
    const text = prometheus.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "zorm_queries_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zorm_pool_connections{state=\"idle\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "zorm_prepared_statement_hit_ratio") != null);
}

test "optimistic locking detects conflicts and batches roll back atomically" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_versioned_rows, zorm_explicit_version_rows CASCADE"));
    try db.autoMigrateAll(.{ VersionedRow, ExplicitVersionRow });

    var row = VersionedRow{ .name = "initial" };
    try db.insert(&row);
    var current = (try db.find(VersionedRow, row.id.?)).?;
    defer z.free(VersionedRow, current, gpa);
    var stale = (try db.find(VersionedRow, row.id.?)).?;
    defer z.free(VersionedRow, stale, gpa);

    gpa.free(current.name);
    current.name = try gpa.dupe(u8, "current");
    try std.testing.expectEqual(@as(i64, 1), try db.update(&current));
    try std.testing.expectEqual(@as(i64, 1), current.version);
    gpa.free(stale.name);
    stale.name = try gpa.dupe(u8, "stale");
    try std.testing.expectError(error.OptimisticLockConflict, db.save(&stale));
    try std.testing.expectEqual(@as(i64, 0), stale.version);

    var explicit = ExplicitVersionRow{ .name = "explicit" };
    try db.insert(&explicit);
    _ = try db.update(&explicit);
    try std.testing.expectEqual(@as(i64, 1), explicit.lock_version);

    var first = VersionedRow{ .name = "first" };
    var second = VersionedRow{ .name = "second" };
    try db.insert(&first);
    try db.insert(&second);
    var batch = [_]VersionedRow{
        (try db.find(VersionedRow, first.id.?)).?,
        (try db.find(VersionedRow, second.id.?)).?,
    };
    defer z.free(VersionedRow, batch[0], gpa);
    defer z.free(VersionedRow, batch[1], gpa);
    var competing = (try db.find(VersionedRow, second.id.?)).?;
    defer z.free(VersionedRow, competing, gpa);
    gpa.free(competing.name);
    competing.name = try gpa.dupe(u8, "winner");
    _ = try db.update(&competing);

    gpa.free(batch[0].name);
    batch[0].name = try gpa.dupe(u8, "must-roll-back");
    gpa.free(batch[1].name);
    batch[1].name = try gpa.dupe(u8, "must-conflict");
    try std.testing.expectError(error.OptimisticLockConflict, db.updateBatch(&batch));
    const first_after = (try db.find(VersionedRow, first.id.?)).?;
    defer z.free(VersionedRow, first_after, gpa);
    try std.testing.expectEqualStrings("first", first_after.name);
    try std.testing.expectEqual(@as(i64, 0), first_after.version);

    var tx = try db.begin();
    var tx_row = (try tx.find(VersionedRow, row.id.?)).?;
    defer z.free(VersionedRow, tx_row, gpa);
    gpa.free(tx_row.name);
    tx_row.name = try gpa.dupe(u8, "transaction");
    _ = try tx.update(&tx_row);
    try tx.commit();
    try std.testing.expectEqual(@as(i64, 2), tx_row.version);
}

test "upsert supports conflict policies, excluded updates, batches, and returning ids" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_upsert_rows CASCADE"));
    try db.autoMigrate(UpsertRow);
    const replace_name = z.OnConflict{ .columns = &.{"email"}, .update = &.{"name"} };

    var original = UpsertRow{ .email = "a@example.com", .name = "one", .note = "keep" };
    try std.testing.expect(try db.upsert(&original, replace_name));
    try std.testing.expect(original.id != null);

    var replacement = UpsertRow{ .email = "a@example.com", .name = "two", .note = "discard" };
    try std.testing.expect(try db.upsert(&replacement, replace_name));
    try std.testing.expectEqual(original.id, replacement.id);
    const updated = (try db.find(UpsertRow, original.id.?)).?;
    defer z.free(UpsertRow, updated, gpa);
    try std.testing.expectEqualStrings("two", updated.name);
    try std.testing.expectEqualStrings("keep", updated.note);

    var ignored = UpsertRow{ .email = "a@example.com", .name = "ignored" };
    try std.testing.expect(!(try db.upsert(&ignored, .{ .columns = &.{"email"} })));
    try std.testing.expectEqual(@as(?i64, null), ignored.id);

    var batch = [_]UpsertRow{
        .{ .email = "a@example.com", .name = "batch-update" },
        .{ .email = "b@example.com", .name = "batch-one" },
        .{ .email = "c@example.com", .name = "batch-two" },
    };
    try std.testing.expectEqual(@as(usize, 3), try db.upsertBatch(&batch, replace_name));
    for (batch) |item| try std.testing.expect(item.id != null);
}

test "RETURNING supports insert projections, batches, update, and delete" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_upsert_rows CASCADE"));
    try db.autoMigrate(UpsertRow);

    var one = UpsertRow{ .email = "return@example.com", .name = "return-one", .note = "note" };
    const projection = try db.insertReturning(&one, ReturningProjection, &.{ "id", "name" });
    defer z.free(ReturningProjection, projection, gpa);
    try std.testing.expectEqual(one.id, projection.id);
    try std.testing.expectEqualStrings("return-one", projection.name);

    var batch = [_]UpsertRow{
        .{ .email = "return-b@example.com", .name = "batch-b" },
        .{ .email = "return-c@example.com", .name = "batch-c" },
    };
    const projected = try db.insertBatchReturning(&batch, ReturningProjection, &.{"name"});
    defer {
        for (projected) |item| z.free(ReturningProjection, item, gpa);
        gpa.free(projected);
    }
    try std.testing.expectEqual(@as(usize, 2), projected.len);
    try std.testing.expectEqualStrings("batch-b", projected[0].name);
    try std.testing.expect(batch[0].id != null and batch[1].id != null);

    const updated = try z.query(UpsertRow, db)
        .whereEq("email", "return@example.com")
        .returning(&.{ "id", "email", "name", "note" })
        .updateReturning(.{ .name = "returned-update" }, gpa);
    defer {
        for (updated) |item| z.free(UpsertRow, item, gpa);
        gpa.free(updated);
    }
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqualStrings("returned-update", updated[0].name);

    const deleted = try z.query(UpsertRow, db)
        .whereEq("email", "return@example.com")
        .returning(&.{ "id", "name" })
        .deleteReturning(gpa);
    defer {
        for (deleted) |item| z.free(UpsertRow, item, gpa);
        gpa.free(deleted);
    }
    try std.testing.expectEqual(@as(usize, 1), deleted.len);
    try std.testing.expectEqualStrings("returned-update", deleted[0].name);
}

test "query builder supports advanced PostgreSQL composition" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_upsert_rows CASCADE"));
    try db.autoMigrate(UpsertRow);
    var rows = [_]UpsertRow{
        .{ .email = "advanced-a@example.com", .name = "alpha", .note = "json-note" },
        .{ .email = "advanced-b@example.com", .name = "beta", .note = "other" },
    };
    try db.insertBatch(&rows);

    const active_scope = struct {
        fn apply(q: *z.db.Query(UpsertRow)) *z.db.Query(UpsertRow) {
            return q.where("name <> $1", .{"never"});
        }
    }.apply;
    var dry = try z.query(UpsertRow, db)
        .join("JOIN (SELECT $1::text AS email) j ON j.email = zorm_upsert_rows.email", .{"advanced-a@example.com"})
        .whereExists("SELECT 1 WHERE $1::boolean", .{true})
        .whereNamed("name = :name", .{ .name = "alpha" })
        .scope(active_scope)
        .hint("SeqScan(zorm_upsert_rows)")
        .dryRun(gpa);
    defer dry.deinit();
    try std.testing.expectEqual(@as(usize, 4), dry.params.len);
    try std.testing.expect(std.mem.indexOf(u8, dry.sql, "JOIN (SELECT $1::text") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.sql, "EXISTS (SELECT 1 WHERE $2::boolean)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.sql, "name = $3") != null);
    try std.testing.expect(std.mem.indexOf(u8, dry.sql, "/*+ SeqScan") != null);

    try std.testing.expectEqual(@as(i64, 2), try z.query(UpsertRow, db)
        .with("chosen", "SELECT $1::text AS email", .{"unused@example.com"})
        .withRecursive("nums", "SELECT 1 AS n UNION ALL SELECT n + 1 FROM nums WHERE n < $1", .{@as(i64, 3)})
        .whereExists("SELECT 1 FROM nums WHERE n = $1", .{@as(i64, 3)})
        .count());

    const unioned = try z.query(UpsertRow, db)
        .whereEq("email", "advanced-a@example.com")
        .unionAll("SELECT * FROM zorm_upsert_rows WHERE email = $1", .{"advanced-b@example.com"})
        .order_by("id")
        .all(gpa);
    defer {
        for (unioned) |item| z.free(UpsertRow, item, gpa);
        gpa.free(unioned);
    }
    try std.testing.expectEqual(@as(usize, 2), unioned.len);

    const expressions = try z.query(UpsertRow, db)
        .distinctOn(&.{"id"})
        .selectRaw(&.{
            "id",
            "email",
            "CASE WHEN name = 'alpha' THEN 'case-ok' ELSE name END AS name",
            "row_number() OVER (ORDER BY id)::text AS note",
        })
        .where("ARRAY[name] @> ARRAY[$1::text] AND to_jsonb(note) @> $2::jsonb", .{ "alpha", "\"json-note\"" })
        .order_by("id")
        .all(gpa);
    defer {
        for (expressions) |item| z.free(UpsertRow, item, gpa);
        gpa.free(expressions);
    }
    try std.testing.expectEqual(@as(usize, 1), expressions.len);
    try std.testing.expectEqualStrings("case-ok", expressions[0].name);
    try std.testing.expectEqualStrings("1", expressions[0].note);

    var plan = try z.query(UpsertRow, db).whereEq("email", "advanced-a@example.com").explain(false);
    defer plan.deinit();
    try std.testing.expect(plan.rows.len > 0);
}

test "composite primary keys migrate and drive find update delete and upsert" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_composite_rows CASCADE"));
    try db.autoMigrate(CompositeRow);
    var row = CompositeRow{ .tenant_id = 7, .code = "alpha", .name = "first" };
    try db.insert(&row);

    var found = (try db.find(CompositeRow, .{ @as(i64, 7), "alpha" })).?;
    defer z.free(CompositeRow, found, gpa);
    gpa.free(found.name);
    found.name = try gpa.dupe(u8, "updated");
    try std.testing.expectEqual(@as(i64, 1), try db.update(&found));
    try db.save(&found);

    var replacement = CompositeRow{ .tenant_id = 7, .code = "alpha", .name = "upserted" };
    try std.testing.expect(try db.upsert(&replacement, .{ .update = &.{"name"} }));
    const after = (try db.find(CompositeRow, .{ @as(i64, 7), "alpha" })).?;
    defer z.free(CompositeRow, after, gpa);
    try std.testing.expectEqualStrings("upserted", after.name);

    var pk_info = try db.exec(
        \\SELECT count(*)::text
        \\FROM information_schema.key_column_usage
        \\WHERE table_schema = current_schema() AND table_name = $1
        \\  AND constraint_name = (SELECT constraint_name FROM information_schema.table_constraints
        \\                         WHERE table_schema = current_schema() AND table_name = $1
        \\                           AND constraint_type = 'PRIMARY KEY')
    , .{"zorm_composite_rows"});
    defer pk_info.deinit();
    try std.testing.expectEqualStrings("2", pk_info.rows[0][0].?);

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_composite_children, zorm_composite_parents CASCADE"));
    try db.autoMigrateAll(.{ CompositeParent, CompositeChild });
    var parent = CompositeParent{ .tenant_id = 7, .code = "parent", .name = "p" };
    try db.insert(&parent);
    var children = [_]CompositeChild{
        .{ .tenant_id = 7, .parent_code = "parent", .body = "match" },
        .{ .tenant_id = 8, .parent_code = "parent", .body = "other tenant" },
    };
    try db.insertBatch(&children);
    const loaded = (try z.query(CompositeParent, db)
        .where("tenant_id = $1 AND code = $2", .{ @as(i64, 7), "parent" })
        .preload("children")
        .first()).?;
    defer z.free(CompositeParent, loaded, gpa);
    try std.testing.expectEqual(@as(usize, 1), loaded.children.len);
    try std.testing.expectEqualStrings("match", loaded.children[0].body);

    try std.testing.expectEqual(@as(i64, 1), try db.delete(&replacement));
    try std.testing.expect((try db.find(CompositeRow, .{ @as(i64, 7), "alpha" })) == null);
}

test "association mode covers singular many-to-many polymorphic and cascades" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    const db = try z.Db.connectDsn(gpa, threaded.io(), dsn, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_owner_tags, zorm_assoc_notes, zorm_assoc_profiles, zorm_assoc_tags, zorm_assoc_owners CASCADE"));
    try db.autoMigrateAll(.{ AssocOwner, AssocProfile, AssocNote, AssocTag });
    drop(try db.execRaw(
        "CREATE TABLE zorm_owner_tags (owner_id bigint NOT NULL, tag_id bigint NOT NULL, PRIMARY KEY (owner_id, tag_id))",
    ));

    var profile = AssocProfile{ .bio = "auto profile" };
    var notes = [_]AssocNote{.{ .body = "auto note" }};
    var tags = [_]AssocTag{.{ .name = "auto tag" }};
    var owner = AssocOwner{
        .name = "owner",
        .profile = profile,
        .notes = &notes,
        .tags = &tags,
    };
    try db.insert(&owner);
    profile = owner.profile.?;
    try std.testing.expect(profile.id != null);
    try std.testing.expectEqual(owner.id, notes[0].owner_id);
    try std.testing.expectEqualStrings("owner", notes[0].owner_type);
    try std.testing.expect(tags[0].id != null);

    const loaded = (try z.query(AssocOwner, db)
        .whereEq("id", owner.id)
        .joinPreload("profile")
        .preload("notes")
        .preload("tags")
        .first()).?;
    defer z.free(AssocOwner, loaded, gpa);
    try std.testing.expect(loaded.profile != null);
    try std.testing.expectEqual(@as(usize, 1), loaded.notes.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.tags.len);

    var tag_assoc = db.association(&owner, "tags");
    try std.testing.expectEqual(@as(i64, 1), try tag_assoc.count());
    var extra = AssocTag{ .name = "extra" };
    try tag_assoc.append(&extra);
    try std.testing.expectEqual(@as(i64, 2), try tag_assoc.count());
    try tag_assoc.delete(&extra);
    try std.testing.expectEqual(@as(i64, 1), try tag_assoc.count());
    var replacement = [_]AssocTag{.{ .name = "replacement" }};
    try tag_assoc.replace(&replacement);
    try std.testing.expectEqual(@as(i64, 1), try tag_assoc.count());
    try tag_assoc.clear();
    try std.testing.expectEqual(@as(i64, 0), try tag_assoc.count());

    try std.testing.expectEqual(@as(i64, 1), try db.delete(&owner));
    try std.testing.expectEqual(@as(i64, 0), try z.query(AssocProfile, db).count());
    try std.testing.expectEqual(@as(i64, 0), try z.query(AssocNote, db).count());
}

test "custom codecs cover PostgreSQL scalar and user-defined formats" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const dsn = test_options.dsn orelse return error.SkipZigTest;
    var cfg_arena = std.heap.ArenaAllocator.init(gpa);
    defer cfg_arena.deinit();
    var cfg = try z.pq.parseDsn(cfg_arena.allocator(), dsn);
    cfg.binary_results = false;
    const db = try z.Db.connect(gpa, threaded.io(), cfg, 4);
    defer db.deinit();

    drop(try db.execRaw("DROP TABLE IF EXISTS zorm_codec_rows CASCADE"));
    try db.autoMigrate(CodecRow);
    var row = CodecRow{
        .uuid = .{ .data = "550e8400-e29b-41d4-a716-446655440000" },
        .amount = .{ .data = "12345.6789" },
        .address = .{ .data = "192.0.2.1" },
        .network = .{ .data = "192.0.2.0/24" },
        .span = .{ .data = "[1.25,9.5)" },
        .state = .ready,
        .payload = .{ .data = "{\"ok\":true}" },
    };
    try db.insert(&row);
    const found = (try db.find(CodecRow, row.id.?)).?;
    defer z.free(CodecRow, found, gpa);
    try std.testing.expectEqualStrings(row.uuid.data, found.uuid.data);
    try std.testing.expectEqualStrings(row.amount.data, found.amount.data);
    try std.testing.expectEqualStrings("192.0.2.1", found.address.data);
    try std.testing.expectEqualStrings("192.0.2.0/24", found.network.data);
    try std.testing.expectEqualStrings("[1.25,9.5)", found.span.data);
    try std.testing.expectEqual(CustomState.ready, found.state);
    try std.testing.expect(std.mem.indexOf(u8, found.payload.data, "\"ok\": true") != null or
        std.mem.indexOf(u8, found.payload.data, "\"ok\":true") != null);

    const GeoRow = struct {
        shape: z.Geometry,
    };
    try std.testing.expectEqualStrings("geometry", comptime z.schema.tableOf(GeoRow).columns[0].ddl_type);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const encoded = try z.value.toParam(z.Geometry{ .data = "POINT(1 2)" }, arena_state.allocator());
    try std.testing.expectEqualStrings("POINT(1 2)", encoded.data);
}

test "v5: primary replica tenant and shard routing" {
    const dsn = test_options.dsn orelse return;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const primary = (try makeDb(gpa, threaded.io())) orelse return;
    defer primary.deinit();
    const replica_a = (try makeDb(gpa, threaded.io())) orelse return;
    defer replica_a.deinit();
    const replica_b = (try makeDb(gpa, threaded.io())) orelse return;
    defer replica_b.deinit();

    var router = z.Router.init(gpa, primary, &.{ replica_a, replica_b });
    defer router.deinit();
    try std.testing.expect((try router.writer()) == primary);
    try std.testing.expect((try router.reader()) == replica_a);
    try std.testing.expect((try router.reader()) == replica_b);
    try std.testing.expect((try router.reader()) == replica_a);

    try router.setTenant("acme", replica_b);
    try std.testing.expect((try router.tenant("acme")) == replica_b);
    try std.testing.expectError(error.InvalidQuery, router.tenant("missing"));

    router.setShards(&.{ primary, replica_a, replica_b });
    const first = try router.shard("customer-42");
    try std.testing.expect(first == try router.shard("customer-42"));

    var read = try router.execRead("SELECT $1::text", .{@as(i64, 42)});
    defer read.deinit();
    try std.testing.expectEqualStrings("42", read.rows[0][0].?);
    var write_result = try router.execWrite("CREATE TEMP TABLE IF NOT EXISTS v5_router_write (id bigint)", .{});
    write_result.deinit();

    var cfg_arena = std.heap.ArenaAllocator.init(gpa);
    defer cfg_arena.deinit();
    const failed_primary = try z.Db.connect(gpa, threaded.io(), try z.pq.parseDsn(cfg_arena.allocator(), dsn), 1);
    failed_primary.pool.deinit();
    defer gpa.destroy(failed_primary);
    var failover = z.Router.init(gpa, failed_primary, &.{replica_a});
    defer failover.deinit();
    try std.testing.expect((try failover.writer()) == replica_a);
}

const PluginProbe = struct {
    before_queries: usize = 0,
    after_queries: usize = 0,
    before_crud: usize = 0,
    after_crud: usize = 0,
    traces: usize = 0,
    audits: usize = 0,
    invalidations: usize = 0,

    fn beforeQuery(raw: ?*anyopaque, _: z.plugins.QueryContext) bool {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.before_queries += 1;
        return true;
    }
    fn afterQuery(raw: ?*anyopaque, _: z.plugins.QueryContext) void {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.after_queries += 1;
    }
    fn beforeCrud(raw: ?*anyopaque, _: z.plugins.CrudContext) bool {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.before_crud += 1;
        return true;
    }
    fn afterCrud(raw: ?*anyopaque, _: z.plugins.CrudContext) void {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.after_crud += 1;
    }
    fn trace(raw: ?*anyopaque, _: z.QueryEvent) void {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.traces += 1;
    }
    fn audit(raw: ?*anyopaque, _: z.plugins.CrudContext) void {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.audits += 1;
    }
    fn invalidate(raw: ?*anyopaque, _: z.plugins.Operation) void {
        const probe: *PluginProbe = @ptrCast(@alignCast(raw.?));
        probe.invalidations += 1;
    }
};

const PluginRow = struct {
    id: ?i64 = null,
    tenant_id: i64,
    name: []const u8,
    pub const zorm = .{ .table = "v5_plugin_rows" };
};

test "v5: global callbacks and production plugins" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_plugin_rows"));
    try db.autoMigrate(PluginRow);

    var probe: PluginProbe = .{};
    var plugin_metrics: z.PluginMetrics = .{};
    var trace = z.TracePlugin{ .context = &probe, .emit = PluginProbe.trace };
    var audit = z.AuditPlugin{ .context = &probe, .record = PluginProbe.audit };
    var cache = z.CacheInvalidationPlugin{ .context = &probe, .invalidate = PluginProbe.invalidate };
    try db.addPlugin(.{
        .context = &probe,
        .before_query = PluginProbe.beforeQuery,
        .after_query = PluginProbe.afterQuery,
        .before_crud = PluginProbe.beforeCrud,
        .after_crud = PluginProbe.afterCrud,
    });
    try db.addPlugin(plugin_metrics.plugin());
    try db.addPlugin(trace.plugin());
    try db.addPlugin(audit.plugin());
    try db.addPlugin(cache.plugin());

    var a = PluginRow{ .tenant_id = 1, .name = "A" };
    var b = PluginRow{ .tenant_id = 1, .name = "B" };
    var other = PluginRow{ .tenant_id = 2, .name = "C" };
    try db.insert(&a);
    try db.insert(&b);
    try db.insert(&other);

    var query = z.query(PluginRow, db);
    query = (z.TenantFilterPlugin{}).apply(query, @as(i64, 1));
    query = (z.PaginationPlugin{ .page = 0, .per_page = 1 }).apply(query);
    const rows = try query.order_by("\"id\" ASC").all(gpa);
    defer z.freeSlice(PluginRow, rows, gpa);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), rows[0].tenant_id);

    try std.testing.expectEqual(@as(usize, 4), probe.before_queries);
    try std.testing.expectEqual(probe.before_queries, probe.after_queries);
    try std.testing.expectEqual(@as(usize, 3), probe.before_crud);
    try std.testing.expectEqual(probe.before_crud, probe.after_crud);
    try std.testing.expectEqual(probe.after_queries, probe.traces);
    try std.testing.expectEqual(probe.after_crud, probe.audits);
    try std.testing.expectEqual(probe.after_crud, probe.invalidations);
    try std.testing.expectEqual(@as(u64, 4), plugin_metrics.queries.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), plugin_metrics.mutations.load(.monotonic));

    drop(try db.execRaw("DROP TABLE v5_plugin_rows"));
}

const RetryProbe = struct {
    attempts: usize = 0,
    fail_until: usize,
    failure: z.Error,

    fn run(probe: *RetryProbe, tx: *z.Tx) z.Error!void {
        probe.attempts += 1;
        if (probe.attempts <= probe.fail_until) return probe.failure;
        var result = try tx.exec("INSERT INTO v5_retry_log (attempts) VALUES ($1)", .{@as(i64, @intCast(probe.attempts))});
        result.deinit();
    }
};

test "v5: explicit transaction retries are bounded and selective" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const db = (try makeDb(gpa, threaded.io())) orelse return;
    defer db.deinit();
    drop(try db.execRaw("DROP TABLE IF EXISTS v5_retry_log"));
    drop(try db.execRaw("CREATE TABLE v5_retry_log (attempts bigint)"));

    const options = z.RetryOptions{ .max_attempts = 4, .base_delay_ms = 1, .max_delay_ms = 2 };
    var serialization = RetryProbe{ .fail_until = 2, .failure = error.SerializationFailure };
    try db.transactionRetry(options, &serialization, RetryProbe.run);
    try std.testing.expectEqual(@as(usize, 3), serialization.attempts);

    var deadlock = RetryProbe{ .fail_until = 1, .failure = error.DeadlockDetected };
    try db.transactionRetry(options, &deadlock, RetryProbe.run);
    try std.testing.expectEqual(@as(usize, 2), deadlock.attempts);

    var connection = RetryProbe{ .fail_until = 1, .failure = error.ConnectionClosed };
    try db.transactionRetry(options, &connection, RetryProbe.run);
    try std.testing.expectEqual(@as(usize, 2), connection.attempts);

    var bounded = RetryProbe{ .fail_until = 10, .failure = error.SerializationFailure };
    try std.testing.expectError(error.SerializationFailure, db.transactionRetry(
        .{ .max_attempts = 2, .base_delay_ms = 0 },
        &bounded,
        RetryProbe.run,
    ));
    try std.testing.expectEqual(@as(usize, 2), bounded.attempts);

    var arbitrary = RetryProbe{ .fail_until = 10, .failure = error.UniqueViolation };
    try std.testing.expectError(error.UniqueViolation, db.transactionRetry(options, &arbitrary, RetryProbe.run));
    try std.testing.expectEqual(@as(usize, 1), arbitrary.attempts);

    var committed = try db.execRaw("SELECT count(*) FROM v5_retry_log");
    defer committed.deinit();
    try std.testing.expectEqualStrings("3", committed.rows[0][0].?);
    drop(try db.execRaw("DROP TABLE v5_retry_log"));
}
