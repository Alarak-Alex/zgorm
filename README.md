# zorm

[English](README.md) | [简体中文](README.zh-CN.md)

A GORM-inspired ORM for Zig 0.16. **PostgreSQL first**, with a pure-Zig PostgreSQL wire protocol driver built in (no libpq, zero C dependencies).

## Features

- **Pure-Zig PostgreSQL driver**: protocol 3.0, `SCRAM-SHA-256` / `MD5` / cleartext auth; simple query and extended query protocols (Parse/Bind/Describe/Execute, parameterized against SQL injection)
- **Binary-format parameters**: scalars (ints/floats/bools/timestamps) are sent in binary format with explicit type OIDs; `bytea` travels raw — better performance and precision
- **Array & JSON columns**: 1-D and multi-dimensional numeric/boolean arrays (`[]const i64`, `[][]const i64`, ...), text arrays (`[]const []const u8` = text[]), NULL elements via optional element types (`[]const ?f64`), plus `z.Json` (jsonb) and `z.Bytes` (bytea)
- **Binary-format results**: result sets are decoded from PostgreSQL's binary format (arrays, timestamps, jsonb, numeric scalars...) — opt out via `Config.binary_results = false`
- **Comptime model reflection**: plain Zig structs are models — no macros, no codegen, zero runtime registration
- **Convention over configuration**: camelCase → snake_case, `id` as the default primary key, auto-filled `created_at`/`updated_at`
- **GORM-style query builder**: `where` / `orWhere` / `whereEq` / `whereIn` / `order_by` / `limit` / `offset` / `group_by` / `having` / `for_update`, with automatic renumbering of `$1,$2...` placeholders across chained conditions
- **CRUD + transactions + pool**: `insert` (auto-increment ids filled back), `insertBatch` (auto-chunked, max 65535 params), `update`, `save`, `delete`, `deleteWhere`, `updateWhere`, `find`, transactions `commit/rollback`
- **autoMigrate**: creates tables, adds missing columns, creates indexes (unique/regular)
- **Associations & preloading**: `has_many` / `belongs_to` declarations + `query.preload("posts.comments")` nested preloading, batch-loaded per level — no N+1
- **Model hooks**: `beforeSave` / `beforeCreate` / `afterCreate` / `beforeUpdate` / `afterUpdate` / `beforeDelete` / `afterDelete` / `afterFind`
- **Savepoints / nested transactions**: `tx.begin()` creates a savepoint, `commit()` releases it, `rollback()` rolls back to it
- **Migration version management**: `Migrator` applies/rolls back versioned SQL migrations tracked in a `schema_migrations` table
- **Type mapping**: integers / floats / `bool` / `[]const u8` (text) / `[]u8` / enums (stored by name) / `zorm.Time` (timestamptz, microsecond precision) — plus optionals of all of those
- **Errors carry context**: server errors map to typed errors (`UniqueViolation`, `ForeignKeyViolation`, `SerializationFailure`, ...), with SQLSTATE, message and constraint details available via `lastError`

## Requirements

- Zig **0.16.0**
- PostgreSQL 10+ (14+ recommended; `trust` / `scram-sha-256` / `md5` password auth supported)

## Quick start

Add zorm as a dependency (build.zig.zon):

```sh
zig fetch --save <git-url-or-tarball>
```

```zig
// build.zig
const mod = b.addModule("zorm", .{
    .root_source_file = b.path("src/root.zig"), // omit when consumed as a path dependency
});
// add .{ .name = "zorm", .module = mod } to your module's .imports
```

### Defining a model

```zig
const std = @import("std");
const z = @import("zorm");

pub const User = struct {
    id: ?i64 = null,              // optional integer PK => bigserial, filled back on insert
    name: []const u8 = "",
    email: ?[]const u8 = null,    // optional => NULLable column
    age: i32 = 0,
    active: bool = true,
    balance: f64 = 0,
    status: Status = .draft,      // enums are stored as their name (text)
    created_at: ?z.Time = null,   // name match => auto timestamp
    updated_at: ?z.Time = null,

    pub const Status = enum { draft, review, published };

    pub const zorm = .{           // optional per-model config
        .table = "users",         // defaults to the type name in snake_case
        .unique = .{"email"},     // unique index (used by autoMigrate)
        .indexes = .{"age"},      // plain index
        // .primary_key = "email",
        // .columns = .{ .isActive = "active" },  // field -> column override
        // .ignore = .{.transient},               // ignored fields
    };
};
```

> Note: once a model declares `pub const zorm`, reference library types inside that struct through an import alias (e.g. `const z = @import("zorm")` and then `?z.Time`), otherwise you get an ambiguous-reference compile error.

### Connecting and using

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // DSN: URL or key=value form
    const db = try z.Db.connectDsn(gpa, io,
        "postgres://user:pass@127.0.0.1:5432/app?sslmode=disable", 8);
    defer db.deinit();

    try db.autoMigrate(User);

    // Insert (auto-increment id filled back, timestamps auto-stamped)
    var u = User{ .name = "Alice", .email = "alice@example.com", .age = 30 };
    try db.insert(&u);

    // Find by primary key (returns ?User; strings are allocated with gpa,
    // release them with z.free)
    const found = (try db.find(User, u.id.?)).?;
    defer z.free(User, found, gpa);

    // Update / save (inserts when the primary key is empty)
    found.age += 1;
    _ = try db.update(&found);

    // Query builder: placeholders are renumbered automatically
    const adults = try z.query(User, db)
        .where("age >= $1", .{18})
        .whereEq("active", true)
        .whereIn("status", .{ .published, .review })
        .order_by("created_at DESC")
        .limit(10)
        .all(gpa);
    defer z.freeSlice(User, adults, gpa);

    const n = try z.query(User, db).where("age > $1", .{20}).count();
    const exists = try z.query(User, db).whereEq("name", "Alice").exists();

    // Batch insert (auto-chunked)
    var posts = [_]Post{ .{ .title = "a" }, .{ .title = "b" } };
    try db.insertBatch(&posts); // posts[i].id filled back

    // Conditional update / delete
    _ = try db.updateWhere(User, .{ .active = false }, "age > $1", .{100});
    _ = try db.deleteWhere(User, "age < $1", .{5});

    // Transaction
    {
        var tx = try db.begin();
        defer tx.rollback(); // no-op if commit succeeded
        var ghost = User{ .name = "Ghost" };
        try tx.insert(&ghost);
        try tx.commit();
    }

    // Delete
    _ = try db.delete(&u);
}
```

## Memory ownership

- **Strings** decoded by `db.find` / `Query.all` / `Query.first` are allocated with the allocator you pass in; release them with `z.free(T, value, gpa)` / `z.freeSlice(T, slice, gpa)`.
- To free a whole batch at once, pass an `ArenaAllocator` allocator (`z.free*` are harmless on arenas).
- `db.exec` / `execRaw` return a `pq.Result` that owns its memory: call `res.deinit()`.
- Query builders are one-shot: terminal operations (`all`/`first`/`count`/`exists`/`delete`) release everything automatically.

## DSN

```
postgres://user:password@host:5432/dbname?sslmode=disable
postgresql://user@10.0.0.1:5433/app
host=/var/run/postgresql user=pg dbname=app          # unix socket directory
```

Parameters: `host`, `port`, `user`, `password`, `dbname`/`database`, `sslmode`, `application_name`.
`sslmode`: `disable` (default) | `require` (encrypted, no cert check) | `verify_ca` | `verify_full` (chain + hostname verification).

### Associations & preloading

Preload paths nest with dots and are validated at compile time:

```zig
const authors = try z.query(Author, db).preload("posts.comments").all(gpa);
// authors[0].posts[i].comments[j] are filled
```

```zig
pub const Author = struct {
    id: ?i64 = null,
    name: []const u8 = "",
    posts: []Post = &.{},                       // has_many field
    pub const zorm = .{
        .has_many = .{ .posts = .{ .model = Post, .foreign_key = "author_id" } },
    };
};

pub const Post = struct {
    id: ?i64 = null,
    author_id: ?i64 = null,                     // belongs_to foreign key
    title: []const u8 = "",
    author: ?Author = null,                     // belongs_to field
    tags: []const []const u8 = &.{},            // text[]
    meta: ?z.Json = null,                       // jsonb
    pub const zorm = .{
        .belongs_to = .{ .author = .{ .model = Author, .foreign_key = "author_id" } },
    };
};

const authors = try z.query(Author, db).preload("posts").all(gpa);   // batch-loaded, no N+1
const posts   = try z.query(Post, db).preload("author").all(gpa);
```

### Model hooks

```zig
pub const User = struct {
    // ...
    pub fn beforeCreate(self: *User, s: *z.Session) z.Error!void {
        self.name = std.fmt.allocPrint(...); // mutate fields
    }
    pub fn afterFind(self: *User, s: *z.Session) z.Error!void { ... }
};
```
Available hooks: `beforeSave`, `beforeCreate`, `afterCreate`, `beforeUpdate`, `afterUpdate`, `beforeDelete`, `afterDelete`, `afterFind` (declare them on the model, all optional; return `z.Error!void`, use `error.HookAborted` to abort the operation).

### Nested transactions (savepoints)

```zig
var tx = try db.begin();
defer tx.rollback();

var sp = try tx.begin();     // SAVEPOINT zorm_sp_1
var u2 = User{ .name = "maybe" };
try sp.insert(&u2);
try sp.rollback();           // undoes only this savepoint; use commit() to RELEASE
try tx.commit();
```

### Migration version management

```zig
var m = z.Migrator.init(db);
defer m.deinit();
m.add(&.{
    .{ .version = 1, .name = "create_users", .up = "CREATE TABLE users (...)", .down = "DROP TABLE users" },
    .{ .version = 2, .name = "add_email",    .up = "ALTER TABLE users ADD COLUMN email text" },
});
_ = try m.applyAll();        // applies pending migrations in ascending order, one txn each
try m.rollbackLast();        // rolls the latest version back with its down script
```
The tracking table is `schema_migrations (version bigint PK, name text, applied_at timestamptz)`.

## Error handling

```zig
db.insert(&user) catch |err| {
    switch (err) {
        error.UniqueViolation => { /* lastError(db).code == "23505" */ },
        error.SerializationFailure => retry(),
        else => {
            const e = z.lastError(db); // severity/code/message/detail/constraint...
        },
    }
};
```

## Building and testing

```sh
zig build                       # build library + example
zig build test                  # unit tests
zig build run -Ddsn='postgres://...'          # run the example
zig build test-integration -Ddsn='postgres://...'   # integration tests (needs a real PG)
zig build -Doptimize=ReleaseFast              # release build
```

Integration tests cover: table creation/migration, insert with id back-fill, unique-constraint errors, find by primary key, update, query building (where/whereIn/orWhere/select subsets/order/limit), enum and `zorm.Time` round trips, chunked batch insert, transaction commit & rollback, conditional update & delete.

## Design notes & trade-offs

- **Wire formats**: parameters are binary for scalars (int8/float8/bool/timestamptz/bytea/text with explicit OIDs) and text for arrays/JSON/enums; results are decoded from PostgreSQL's binary format by default (`Config.binary_results = false` to opt out for exotic column types).
- **Preloading**: any depth via dotted paths; string/array values of preloaded rows are deep-copied per parent. Multi-dimensional arrays are supported for numeric/boolean element types; text arrays are 1-D.
- **autoMigrate** only creates tables, adds missing columns and single-column indexes — it never drops columns or changes types. Use `Migrator` for anything more involved.
- **SQL injection surface**: values are always parameterized; `order_by`, `group_by`, `having` and `select` column names are string-interpolated (same as GORM) — never pass user input there.
- **Concurrency**: `Db`/the connection pool are thread-safe (`std.Io.Mutex`/`Condition`); a single `pq.Conn` and a `Session` with an in-flight operation are not.
- **Full-column updates**: `update` writes every column of the model (GORM `Save` semantics); use `updateWhere` for partial updates.

## Roadmap

- [x] Binary format + array/JSONB column types (v0.2.0)
- [x] Associations (belongs_to/has_many) & preloading (v0.2.0)
- [x] Model hooks (BeforeSave etc.) (v0.2.0)
- [x] Savepoints / nested transactions (v0.2.0)
- [x] Migration version management (schema_migrations) (v0.2.0)
- [x] Nested preloading (v0.3.0)
- [x] Binary-format result decoding (v0.3.0)
- [x] Multi-dimensional arrays / full NULL array elements (v0.3.0)
- [ ] MySQL/SQLite drivers

## License

MIT
