# zorm

[English](README.md) | [简体中文](README.zh-CN.md)

A GORM-inspired ORM for Zig 0.16 with first-class PostgreSQL, MySQL/MariaDB, and SQLite drivers. PostgreSQL and MySQL use built-in pure-Zig wire protocol implementations; SQLite uses `libsqlite3`.

## Features

- **Pure-Zig PostgreSQL driver**: protocol 3.0, `SCRAM-SHA-256` / `MD5` / cleartext auth; simple query and extended query protocols (Parse/Bind/Describe/Execute, parameterized against SQL injection)
- **Binary-format parameters**: scalars (ints/floats/bools/timestamps) are sent in binary format with explicit type OIDs; `bytea` travels raw — better performance and precision
- **Array & JSON columns**: 1-D and multi-dimensional numeric/boolean arrays (`[]const i64`, `[][]const i64`, ...), text arrays (`[]const []const u8` = text[]), NULL elements via optional element types (`[]const ?f64`), plus `z.Json` (jsonb) and `z.Bytes` (bytea)
- **Binary-format results**: result sets are decoded from PostgreSQL's binary format (arrays, timestamps, jsonb, numeric scalars...) — opt out via `Config.binary_results = false`
- **Comptime model reflection**: plain Zig structs are models — no macros, no codegen, zero runtime registration
- **Convention over configuration**: camelCase → snake_case, `id` as the default primary key, auto-filled `created_at`/`updated_at`
- **Extended query builder**: joins, subqueries, CTE/recursive CTE, unions, `DISTINCT ON`, raw CASE/window/JSON/array expressions, hints, named parameters, scopes, dry-run, `EXPLAIN`, and `RETURNING`
- **Production pool and execution controls**: prepared-statement LRU caches, query/acquire/network/transaction deadlines, PostgreSQL cancellation, connection lifetime/idle limits, background cleanup, prewarming, health checks, and pool statistics
- **CRUD, upsert, optimistic locks, and transactions**: chunked batches, configurable `ON CONFLICT`, arbitrary/batch `RETURNING`, composite primary keys, savepoints, and explicit bounded transaction retries
- **Streaming rows**: model decoding and CSV export begin at the first row, keep large-result memory bounded, propagate iterator errors, and release connections after early termination
- **Schema management**: additive `autoMigrate`, versioned migrations with advisory locking/checksums/dirty-state validation, schema diffs, type/rename/drop operations, constraints, and composite/partial/expression indexes
- **Associations**: `belongs_to`, `has_one`, `has_many`, many-to-many and polymorphic declarations; nested and join preloading; association append/replace/delete/clear/count; cascade and auto-save support
- **Custom codecs**: `zormEncode`/`zormDecode` plus UUID, decimal, IP/CIDR, range, geometry, enum, and JSON helpers
- **Observability**: structured query events, fingerprints, SQLSTATE/error classes, OpenTelemetry-compatible span hooks, Prometheus metrics, slow-query aggregation, prepared-cache rates, and pool metrics
- **Routing**: primary/replica read-write routing, round-robin replicas, tenant and shard maps, health-based failover
- **Plugins**: global query/CRUD callbacks plus tracing, metrics, AES-256-GCM encryption, tenant filtering, audit, pagination, and cache-invalidation helpers
- **Three first-class drivers**: MySQL/MariaDB supports `mysql_native_password`, `caching_sha2_password` (TLS or RSA full authentication), server prepared statements, pools, and timeouts; SQLite supports bound parameters, pools, busy/query timeouts, WAL, and foreign-key configuration. Both share typed CRUD/upsert, optimistic locking, hooks, associations/preload, query composition, additive migrations, versioned migrations, plugins, routing, observability, and explicit transaction retries.
- **Errors carry context**: server errors map to typed errors (`UniqueViolation`, `ForeignKeyViolation`, `SerializationFailure`, ...), with SQLSTATE, message and constraint details available via `lastError`

## Requirements

- Zig **0.16.0**
- PostgreSQL 10+ (14+ recommended; `trust` / `scram-sha-256` / `md5` password auth supported)
- SQLite development headers/library when using `z.drivers.sqlite` (`libsqlite3`)

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
mod.linkSystemLibrary("sqlite3", .{}); // required only when using z.drivers.sqlite
// add .{ .name = "zorm", .module = mod } to your module's .imports
```

### Defining a model

Models can embed `z.Model` (GORM `gorm.Model` equivalent) to get `id`,
`created_at`, `updated_at`, and `deleted_at` columns automatically. All three
timestamp columns use PostgreSQL `timestamptz`; embedded fields are flattened
into the table at comptime:

```zig
pub const Post = struct {
    base: z.Model = .{},     // id, created_at, updated_at, deleted_at
    title: []const u8 = "",

    pub const zorm = .{ .table = "posts" };
};
// post.base.id is filled back on insert; timestamps are auto-stamped
```

Plain models without embedding work exactly the same way:

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
    var found = (try db.find(User, u.id.?)).?;
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
- `z.free` must only be called on values whose string/slice fields were **not reassigned** after decoding (assigning a literal replaces the heap pointer with a static one). When in doubt, pass an arena.
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

### Logging

zorm ships with a default stderr logger (GORM-style): failed queries log at
error level, queries slower than the threshold at warn, and everything traces
at info. Default level is `warn` with a 200ms slow-query threshold, so normal
usage stays quiet. Its level tags use ANSI colors; custom sinks receive plain messages.

```zig
// Trace every query:
db.setLogger(.{ .level = .info });

// Silence:
db.setLogger(z.Logger.discard);

// Custom sink (e.g. your log framework):
const MyLogger = struct {
    fn log(ctx: ?*anyopaque, level: z.LogLevel, msg: []const u8) void {
        // `msg` contains elapsed time, row count, inlined SQL and params
        my_log_framework.write(level, msg);
    }
};
db.setLogger(.{ .level = .info, .logFn = MyLogger.log, .context = null });

// Tune the slow-query threshold:
db.setLogger(.{ .level = .warn, .slow_threshold_ms = 500 });
```

Logged lines inline the parameter values into the SQL (with `NULL` and
quoting handled), so they can be copied straight into `psql`.

### Soft delete

Models with a `deleted_at` column (`?z.Time` or `?i64`, also included in `z.Model`) get GORM-style soft deletes:

```zig
_ = try db.delete(&user);            // UPDATE ... SET deleted_at = now()
_ = try db.find(User, id);           // excludes soft-deleted rows
_ = try z.query(User, db).count();   // filtered too; update/deleteWhere as well

_ = try z.query(User, db).unscoped().count();  // include soft-deleted rows
_ = try db.findUnscoped(User, id);   // fetch a soft-deleted row by pk
_ = try db.updateUnscoped(&user);    // update it too
_ = try db.restore(&user);           // clear deleted_at by primary key
_ = try db.deleteHard(&user);        // real DELETE
_ = try db.deleteWhereHard(User, "age < $1", .{5});
```

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
The tracking table stores `version`, `name`, `checksum`, `dirty`, and `applied_at`. `applyAll` serializes runners with a PostgreSQL advisory lock and rejects changed or dirty migrations.

### Plugins and explicit transaction retries

```zig
var metrics: z.PluginMetrics = .{};
try db.addPlugin(metrics.plugin());

const Retry = struct {
    fn run(user: *User, tx: *z.Tx) z.Error!void {
        try tx.insert(user);
    }
};
var user = User{ .name = "retry-safe" };
try db.transactionRetry(
    .{ .max_attempts = 4, .base_delay_ms = 10, .max_delay_ms = 500 },
    &user,
    Retry.run,
);
```

Only `transactionRetry` replays a transaction, and only for serialization,
deadlock, and optionally temporary connection failures. Ordinary CRUD and
`begin` never replay writes.

Tenant filtering and pagination remain explicit query transformations:

```zig
var q = z.query(User, db);
q = (z.TenantFilterPlugin{}).apply(q, tenant_id);
q = (z.PaginationPlugin{ .page = 0, .per_page = 50 }).apply(q);
const page = try q.all(gpa);
```

### MySQL/MariaDB and SQLite

```zig
const sqlite = try z.drivers.sqlite.Db.open(gpa, ":memory:");
defer sqlite.deinit();
var sqlite_db = z.drivers.sqlite.orm(sqlite);
try sqlite_db.autoMigrate(User);
var local_user = User{ .name = "Ada" };
try sqlite_db.insert(&local_user);
const local_rows = try sqlite_db.whereEq(User, "name", "Ada", gpa);
defer z.freeSlice(User, local_rows, gpa);

const mysql = try z.drivers.mysql.Conn.connect(gpa, io, .{
    .host = "127.0.0.1", .port = 3306,
    .user = "app", .password = "secret", .database = "app",
});
defer mysql.deinit();
var mysql_db = z.drivers.mysql.orm(mysql);
try mysql_db.autoMigrate(User);
var remote_user = User{ .name = "Grace" };
try mysql_db.insert(&remote_user);
```

The MySQL/MariaDB and SQLite ORM has the same shared typed CRUD/upsert,
optimistic-locking, lifecycle-hook, association/preload, query-builder,
additive/versioned-migration, pool, plugin, routing, observability, and explicit
transaction-retry APIs. Dialect-specific SQL remains explicit: PostgreSQL alone
supports `DISTINCT ON`, advisory migration locks, destructive schema diffs, and
binary streaming; MySQL emulates mutation `RETURNING`, while SQLite requires
`libsqlite3`.

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
zig build test-drivers                              # SQLite
zig build test-drivers -Dmysql-port=3307            # SQLite + live MySQL/MariaDB
zig build -Doptimize=ReleaseFast              # release build
```

Integration coverage includes CRUD and batches, transactions/savepoints/retries, migrations and schema diffs, prepared caches, deadlines/cancellation, streaming, observability, routing, plugins, composite keys, upsert/returning, custom codecs, and associations. `test-drivers` exercises SQLite in memory and optionally a live MySQL/MariaDB server.

## Design notes & trade-offs

- **Wire formats**: parameters are binary for scalars (int8/float8/bool/timestamptz/bytea/text with explicit OIDs) and text for arrays/JSON/enums; results are decoded from PostgreSQL's binary format by default (`Config.binary_results = false` to opt out for exotic column types).
- **Preloading**: any depth via dotted paths; string/array values of preloaded rows are deep-copied per parent. Multi-dimensional arrays are supported for numeric/boolean element types; text arrays are 1-D.
- **autoMigrate** remains additive. Destructive/type-changing work is explicit through `Migrator` (`alterColumnType`, `dropColumn`, `renameColumn`, constraints and advanced indexes).
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
- [x] MySQL/SQLite direct drivers and typed CRUD ORM
- [x] Production execution, routing, plugins, codecs, advanced migrations, and explicit transaction retries

## Acknowledgements

zorm is inspired by [GORM](https://github.com/go-gorm/gorm), especially its approachable model conventions, chainable query API, hooks, associations, preloading, soft deletes, and migration ergonomics. Thanks to the GORM maintainers and contributors for building and evolving an excellent ORM for the Go ecosystem.

## License

MIT
