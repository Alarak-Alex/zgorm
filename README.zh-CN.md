# zorm

[English](README.md) | [简体中文](README.zh-CN.md)

一个受 GORM 启发、面向 Zig 0.16 的 ORM，PostgreSQL、MySQL/MariaDB、SQLite 均为一等驱动。PostgreSQL 与 MySQL 使用内置纯 Zig 线协议实现，SQLite 使用 `libsqlite3`。

## 特性

- **纯 Zig PostgreSQL 驱动**：协议 3.0，支持 `SCRAM-SHA-256`、`MD5`、明文认证；简单查询与扩展查询（Parse/Bind/Describe/Execute，参数化防注入）
- **二进制格式参数**：标量（整数/浮点/布尔/时间）以二进制格式发送并显式声明类型 OID，`bytea` 原样收发，性能与精度更佳
- **数组与 JSON 列**：一维与多维数值/布尔数组（`[]const i64`、`[][]const i64`…）、text 数组（`[]const []const u8`）、可选元素类型的 NULL 元素（`[]const ?f64`），以及 `z.Json`（jsonb）、`z.Bytes`（bytea）
- **结果集二进制格式解码**：查询结果默认从 PostgreSQL 二进制格式解码（数组、时间戳、jsonb 等）——`Config.binary_results = false` 可关闭
- **comptime 模型反射**：普通 Zig 结构体即模型，无宏、无代码生成、运行时零注册
- **约定优于配置**：驼峰转 snake_case、`id` 默认主键、`created_at`/`updated_at` 自动时间戳
- **扩展查询构建器**：JOIN、子查询、CTE/递归 CTE、UNION、`DISTINCT ON`、CASE/窗口/JSON/数组原始表达式、Hint、命名参数、Scope、Dry Run、`EXPLAIN` 与 `RETURNING`
- **生产级连接与执行控制**：Prepared Statement LRU、查询/获取连接/网络/事务超时、PostgreSQL CancelRequest、连接寿命与空闲限制、后台清理、预热、健康检查与 PoolStats
- **CRUD、Upsert、乐观锁与事务**：批量分块、可配置 `ON CONFLICT`、任意/批量 `RETURNING`、复合主键、Savepoint 与显式有界事务重试
- **流式结果**：首行到达即可解码/导出，保持大结果集内存有界，传播迭代器错误并在提前结束时释放连接
- **Schema 管理**：增量 `autoMigrate`；带 advisory lock、checksum、dirty 检测的版本迁移；Schema Diff、改类型/重命名/删列、约束与复合/部分/表达式索引
- **完整关联**：`belongs_to`、`has_one`、`has_many`、多对多、多态；嵌套/Join Preload；append/replace/delete/clear/count；级联与自动保存
- **自定义 Codec**：`zormEncode`/`zormDecode`，以及 UUID、Decimal、IP/CIDR、Range、Geometry、Enum、JSON 辅助类型
- **可观测性**：结构化事件、SQL 指纹、SQLSTATE/错误分类、OpenTelemetry span hook、Prometheus 指标、慢 SQL 聚合、Prepared Cache 与连接池指标
- **路由**：Primary/Replica 读写分离、Replica 轮询、租户/分片路由与健康检查 Failover
- **插件**：全局 Query/CRUD Callback，以及 tracing、metrics、AES-256-GCM 加密、租户过滤、审计、分页、缓存失效辅助插件
- **三个一等驱动**：MySQL/MariaDB 支持 `mysql_native_password`、`caching_sha2_password`（TLS 或 RSA 完整认证）、服务端 Prepared Statement、连接池与超时；SQLite 支持参数绑定、连接池、busy/query 超时、WAL 与外键配置。二者共享类型化 CRUD/Upsert、乐观锁、Hook、关联/Preload、查询组合、增量迁移、版本迁移、插件、路由、可观测性与显式事务重试。
- **错误携带上下文**：服务器错误映射为类型化错误（`UniqueViolation`、`ForeignKeyViolation`、`SerializationFailure`…），并可通过 `lastError` 读取 SQLSTATE、消息、约束名等明细

## 环境要求

- Zig **0.16.0**
- PostgreSQL 10+（推荐 14+；需允许 `trust`/`scram-sha-256`/`md5` 密码认证）
- 使用 `z.drivers.sqlite` 时需安装 SQLite 开发头文件与 `libsqlite3`

## 快速上手

把 zorm 作为依赖（build.zig.zon）：

```sh
zig fetch --save <git-url-or-tarball>
```

```zig
// build.zig
const mod = b.addModule("zorm", .{
    .root_source_file = b.path("src/root.zig"), // 若以路径依赖方式使用可省略
});
mod.linkSystemLibrary("sqlite3", .{}); // 仅使用 z.drivers.sqlite 时需要
// 在你的模块 .imports 中加入 .{ .name = "zorm", .module = mod }
```

### 定义模型

模型可以内嵌 `z.Model`（等价于 GORM 的 `gorm.Model`）自动获得 `id`、`created_at`、`updated_at`、`deleted_at` 四列。三个时间戳列均使用 PostgreSQL `timestamptz`（带时区）；内嵌字段在编译期扁平化进表结构：

```zig
pub const Post = struct {
    base: z.Model = .{},     // id, created_at, updated_at, deleted_at
    title: []const u8 = "",

    pub const zorm = .{ .table = "posts" };
};
// post.base.id 在插入后自动回填；时间戳自动填充
```

不使用内嵌的普通模型用法完全相同：

```zig
const std = @import("std");
const z = @import("zorm");

pub const User = struct {
    id: ?i64 = null,              // 可选整型主键 => bigserial，插入时自动回填
    name: []const u8 = "",
    email: ?[]const u8 = null,    // 可选 => NULL 列
    age: i32 = 0,
    active: bool = true,
    balance: f64 = 0,
    status: Status = .draft,      // 枚举按名字存储为 text
    created_at: ?z.Time = null,   // 命名匹配 => 自动时间戳
    updated_at: ?z.Time = null,

    pub const Status = enum { draft, review, published };

    pub const zorm = z.ModelConfig{
        .table = "users",         // 默认取类型名 snake_case
        .unique = &.{"email"},    // 唯一索引（autoMigrate 使用）
        .indexes = &.{"age"},     // 普通索引
    };
};
```

> 注意：模型内声明了 `pub const zorm` 后，在同一结构体体内引用库类型请使用导入别名（如 `const z = @import("zorm")` 后写 `?z.Time`），否则会产生歧义引用编译错误。

### 连接与使用

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // DSN：URL 或 key=value 两种形式
    const db = try z.Db.connectDsn(gpa, io,
        "postgres://user:pass@127.0.0.1:5432/app?sslmode=disable", 8);
    defer db.deinit();

    try db.autoMigrate(User);

    // 插入（自增 id 回填，时间戳自动填充）
    var u = User{ .name = "Alice", .email = "alice@example.com", .age = 30 };
    try db.insert(&u);

    // 按主键查找（返回 ?User；字符串字段用 gpa 分配，配合 z.free 释放）
    var found = (try db.find(User, u.id.?)).?;
    defer z.free(User, found, gpa);

    // 更新 / 保存（主键为空则插入）
    found.age += 1;
    _ = try db.update(&found);

    // 查询构建器：占位符自动重编号
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

    // 批量插入（自动分块）
    var posts = [_]Post{ .{ .title = "a" }, .{ .title = "b" } };
    try db.insertBatch(&posts); // posts[i].id 被回填

    // 条件更新 / 删除
    _ = try db.updateWhere(User, .{ .active = false }, "age > $1", .{100});
    _ = try db.deleteWhere(User, "age < $1", .{5});

    // 事务
    {
        var tx = try db.begin();
        defer tx.rollback(); // 提交成功时为空操作
        var ghost = User{ .name = "Ghost" };
        try tx.insert(&ghost);
        try tx.commit();
    }

    // 删除
    _ = try db.delete(&u);
}
```

## 内存所有权约定

- `db.find` / `Query.all` / `Query.first` 解码出的**字符串**由你传入的分配器分配，配套的 `z.free(T, value, gpa)` 与 `z.freeSlice(T, slice, gpa)` 负责释放。
- `z.free` 只能用于字符串/切片字段**未被重新赋值**的结果（给字段赋字面量会把堆指针换成静态指针）。拿不准时请改用 arena。
- 想要一次性释放整批结果，传 `ArenaAllocator` 的分配器即可（`z.free*` 对 arena 无害）。
- `db.exec` / `execRaw` 返回的 `pq.Result` 拥有自身内存：调用 `res.deinit()`。
- 查询构建器为一次性对象：终端操作（`all`/`first`/`count`/`exists`/`delete`）自动释放，无需手动清理。

## DSN

```
postgres://user:password@host:5432/dbname?sslmode=disable
postgresql://user@10.0.0.1:5433/app
host=/var/run/postgresql user=pg dbname=app          # unix socket 目录
```

参数：`host`、`port`、`user`、`password`、`dbname`/`database`、`sslmode`、`application_name`。
`sslmode`：`disable`（默认）| `require`（加密、不校验证书）| `verify_ca` | `verify_full`（校验自签名/主机名）。

### 关联与预加载

预加载路径用点号嵌套，整条路径在编译期校验：

```zig
const authors = try z.query(Author, db).preload("posts.comments").all(gpa);
// authors[0].posts[i].comments[j] 已填充
```

```zig
pub const Author = struct {
    base: z.Model = .{},
    name: []const u8 = "",
    posts: []Post = &.{},                    // 自动识别为 has_many
};

pub const Post = struct {
    base: z.Model = .{},
    author_id: ?i64 = null,
    title: []const u8 = "",
    author: ?Author = null,                  // 自动识别为 belongs_to
};

// 默认推导：
// Author.posts -> Post.author_id
// Post.author  -> Post.author_id
const authors = try z.query(Author, db).preload("posts").all(gpa);
const posts = try z.query(Post, db).preload("author").all(gpa);
```

不符合命名约定时，可以使用类型化配置显式声明关联：

```zig
pub const Author = struct {
    base: z.Model = .{},
    posts: []Post = &.{},

    pub const zorm = z.ModelConfig{
        .associations = &.{
            .{
                .field = "posts",
                .model = Post,
                .kind = .has_many,
                .foreign_key = "owner_id",
            },
        },
    };
};
```

### 模型 hook

```zig
pub const User = struct {
    // ...
    pub fn beforeCreate(self: *User, s: *z.Session) z.Error!void {
        self.name = std.fmt.allocPrint(...); // 修改字段
    }
    pub fn afterFind(self: *User, s: *z.Session) z.Error!void { ... }
};
```
可用 hook：`beforeSave`、`beforeCreate`、`afterCreate`、`beforeUpdate`、`afterUpdate`、`beforeDelete`、`afterDelete`、`afterFind`（在模型上声明即可，可选实现；返回 `z.Error!void`，可用 `error.HookAborted` 中止操作）。

### 日志

zorm 自带默认的 stderr 日志（类 GORM）：失败的查询以 error 级别记录，超过慢查询阈值的以 warn 记录，全部查询可在 info 级别 trace。默认级别 `warn`、慢查询阈值 200ms，常规使用保持安静。默认输出的级别标签带 ANSI 颜色；自定义日志宿主收到的消息不含颜色码。

```zig
// trace 每条查询：
db.setLogger(.{ .level = .info });

// 静默：
db.setLogger(z.Logger.discard);

// 自定义宿主（对接你自己的日志框架）：
const MyLogger = struct {
    fn log(ctx: ?*anyopaque, level: z.LogLevel, msg: []const u8) void {
        // `msg` 包含耗时、行数、内联参数后的 SQL
        my_log_framework.write(level, msg);
    }
};
db.setLogger(.{ .level = .info, .logFn = MyLogger.log, .context = null });

// 调整慢查询阈值：
db.setLogger(.{ .level = .warn, .slow_threshold_ms = 500 });
```

日志行会把参数值内联进 SQL（自动处理 NULL 与引号转义），可直接复制到 `psql` 执行。

### 软删除

模型带 `deleted_at` 列（`?z.Time` 或 `?i64`，`z.Model` 已内含）即启用 GORM 风格软删除：

```zig
_ = try db.delete(&user);            // UPDATE ... SET deleted_at = now()
_ = try db.find(User, id);           // 自动过滤已删除行
_ = try z.query(User, db).count();   // count/update/deleteWhere 同样过滤

_ = try z.query(User, db).unscoped().count();  // 包含已删除行
_ = try db.findUnscoped(User, id);   // 按主键取回已删除行
_ = try db.updateUnscoped(&user);    // 更新已删除行
_ = try db.restore(&user);           // 按主键清除 deleted_at
_ = try db.deleteHard(&user);        // 真 DELETE
_ = try db.deleteWhereHard(User, "age < $1", .{5});
```

### 嵌套事务（Savepoint）

```zig
var tx = try db.begin();
defer tx.rollback();

var sp = try tx.begin();     // SAVEPOINT zorm_sp_1
var u2 = User{ .name = "maybe" };
try sp.insert(&u2);
try sp.rollback();           // 仅撤销 savepoint 内的操作；commit() 则 RELEASE
try tx.commit();
```

### 迁移版本管理

```zig
var m = z.Migrator.init(db);
defer m.deinit();
m.add(&.{
    .{ .version = 1, .name = "create_users", .up = "CREATE TABLE users (...)", .down = "DROP TABLE users" },
    .{ .version = 2, .name = "add_email",    .up = "ALTER TABLE users ADD COLUMN email text" },
});
_ = try m.applyAll();        // 按版本升序应用待执行迁移，每个迁移一个事务
try m.rollbackLast();        // 用 down 脚本回滚最近一个版本
```
记录表包含 `version`、`name`、`checksum`、`dirty`、`applied_at`；`applyAll` 通过 PostgreSQL advisory lock 串行化迁移，并拒绝 checksum 变化或 dirty 的记录。

### 插件与显式事务重试

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

只有显式调用 `transactionRetry` 才会重放整个事务，且仅重试序列化失败、
死锁和可选的临时连接错误；普通 CRUD 与 `begin` 绝不会自动重放写操作。

租户过滤与分页是显式的 Query 转换：

```zig
var q = z.query(User, db);
q = (z.TenantFilterPlugin{}).apply(q, tenant_id);
q = (z.PaginationPlugin{ .page = 0, .per_page = 50 }).apply(q);
const page = try q.all(gpa);
```

### MySQL/MariaDB 与 SQLite

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

MySQL/MariaDB 与 SQLite ORM 共享同级的类型化 CRUD/Upsert、乐观锁、
生命周期 Hook、关联/Preload、查询构建、增量/版本迁移、连接池、插件、路由、
可观测性与显式事务重试 API。方言差异保持显式：`DISTINCT ON`、迁移 advisory
lock、破坏性 Schema Diff 与二进制流式结果仅适用于 PostgreSQL；MySQL 模拟写操作
`RETURNING`，SQLite 依赖 `libsqlite3`。

## 错误处理

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

## 构建与测试

```sh
zig build                       # 构建库 + example
zig build test                  # 单元测试
zig build run -Ddsn='postgres://...'          # 运行 example
zig build test-integration -Ddsn='postgres://...'   # 集成测试（需真实 PG）
zig build test-drivers                              # SQLite
zig build test-drivers -Dmysql-port=3307            # SQLite + 真实 MySQL/MariaDB
zig build -Doptimize=ReleaseFast              # 发布构建
```

集成测试覆盖 CRUD/批量、事务/Savepoint/重试、迁移与 Schema Diff、Prepared Cache、超时/取消、流式结果、可观测性、路由、插件、复合主键、Upsert/Returning、自定义 Codec 与关联。`test-drivers` 验证内存 SQLite，并可选验证真实 MySQL/MariaDB。

## 设计与取舍

- **线格式**：参数对标量（int8/float8/bool/timestamptz/bytea/text）用二进制格式并显式声明 OID，数组/JSON/枚举走文本；结果默认按 PostgreSQL 二进制格式解码（`Config.binary_results = false` 可为特殊列类型关闭）。
- **预加载**：点号路径支持任意深度；预加载行的字符串/数组值会按父行深拷贝。多维数组仅支持数值/布尔元素；text 数组为一维。
- **autoMigrate** 保持增量语义；改类型、删列、重命名、约束和高级索引通过 `Migrator` 显式执行。
- **SQL 注入面**：值一律参数化；`order_by`、`group_by`、`having`、`select` 列名为字符串拼接（同 GORM），请勿拼接用户输入。
- **并发**：`Db`/连接池线程安全（`std.Io.Mutex`/`Condition`）；单个 `pq.Conn` 与进行中的 `Session` 非线程安全。
- **更新全列**：`update` 写出模型所有列（GORM `Save` 语义）；部分更新用 `updateWhere`。

## 路线图

- [x] 二进制格式 + 数组/JSONB 列类型（v0.2.0）
- [x] 关联（belongs_to/has_many）与预加载（v0.2.0）
- [x] 模型 hook（BeforeSave 等）（v0.2.0）
- [x] Savepoint / 嵌套事务（v0.2.0）
- [x] 迁移版本管理（schema_migrations）（v0.2.0）
- [x] 嵌套预加载（v0.3.0）
- [x] 结果集二进制格式解码（v0.3.0）
- [x] 多维数组 / 数组元素的 NULL 完整支持（v0.3.0）
- [x] MySQL/SQLite 直接驱动与类型化 CRUD ORM
- [x] 生产级执行控制、路由、插件、Codec、高级迁移与显式事务重试

## 致谢

zorm 受到 [GORM](https://github.com/go-gorm/gorm) 的启发，尤其借鉴了其易用的模型约定、链式查询 API、Hook、关联、预加载、软删除与迁移体验。感谢 GORM 的维护者和贡献者为 Go 生态打造并持续演进这一优秀 ORM。

## License

MIT
