# zorm

[English](README.md) | [简体中文](README.zh-CN.md)

一个受 GORM 启发、面向 Zig 0.16 的 ORM。**PostgreSQL 优先**，自带纯 Zig 实现的 PostgreSQL 线协议驱动（无需 libpq，零 C 依赖）。

## 特性

- **纯 Zig PostgreSQL 驱动**：协议 3.0，支持 `SCRAM-SHA-256`、`MD5`、明文认证；简单查询与扩展查询（Parse/Bind/Describe/Execute，参数化防注入）
- **二进制格式参数**：标量（整数/浮点/布尔/时间）以二进制格式发送并显式声明类型 OID，`bytea` 原样收发，性能与精度更佳
- **数组与 JSON 列**：一维与多维数值/布尔数组（`[]const i64`、`[][]const i64`…）、text 数组（`[]const []const u8`）、可选元素类型的 NULL 元素（`[]const ?f64`），以及 `z.Json`（jsonb）、`z.Bytes`（bytea）
- **结果集二进制格式解码**：查询结果默认从 PostgreSQL 二进制格式解码（数组、时间戳、jsonb 等）——`Config.binary_results = false` 可关闭
- **comptime 模型反射**：普通 Zig 结构体即模型，无宏、无代码生成、运行时零注册
- **约定优于配置**：驼峰转 snake_case、`id` 默认主键、`created_at`/`updated_at` 自动时间戳
- **GORM 风格查询构建器**：`where` / `orWhere` / `whereEq` / `whereIn` / `order_by` / `limit` / `offset` / `group_by` / `having` / `for_update`，占位符 `$1,$2...` 跨条件自动重编号
- **CRUD + 事务 + 连接池**：`insert`（自动回填自增主键）、`insertBatch`（自动分块、最多 65535 参数）、`update`、`save`、`delete`、`deleteWhere`、`updateWhere`、`find`、事务 `commit/rollback`
- **autoMigrate**：建表、补列、创建索引（唯一/普通）
- **关联与预加载**：`has_many` / `belongs_to` 声明 + `query.preload("posts.comments")` 嵌套预加载，逐层批量装配，避免 N+1
- **模型 hook**：`beforeSave` / `beforeCreate` / `afterCreate` / `beforeUpdate` / `afterUpdate` / `beforeDelete` / `afterDelete` / `afterFind`
- **Savepoint / 嵌套事务**：`tx.begin()` 创建 savepoint，`commit()` 释放、`rollback()` 回滚到保存点
- **迁移版本管理**：`Migrator` 基于 `schema_migrations` 表按版本应用/回滚 SQL 迁移
- **类型映射**：整数/浮点/`bool`/`[]const u8`(text)/`[]u8`/枚举(按名存储)/`zorm.Time`(timestamptz, 微秒精度) 及其可选版本
- **错误携带上下文**：服务器错误映射为类型化错误（`UniqueViolation`、`ForeignKeyViolation`、`SerializationFailure`…），并可通过 `lastError` 读取 SQLSTATE、消息、约束名等明细

## 环境要求

- Zig **0.16.0**
- PostgreSQL 10+（推荐 14+；需允许 `trust`/`scram-sha-256`/`md5` 密码认证）

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
// 在你的模块 .imports 中加入 .{ .name = "zorm", .module = mod }
```

### 定义模型

模型可以内嵌 `z.Model`（等价于 GORM 的 `gorm.Model`）自动获得 `id`、`created_at`、`updated_at` 三列——内嵌字段在编译期扁平化进表结构：

```zig
pub const Post = struct {
    base: z.Model = .{},     // id, created_at, updated_at
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

    pub const zorm = .{           // 可选的模型级配置
        .table = "users",         // 默认取类型名 snake_case
        .unique = .{"email"},     // 唯一索引（autoMigrate 使用）
        .indexes = .{"age"},      // 普通索引
        // .primary_key = "email",
        // .columns = .{ .isActive = "active" },  // 字段名 -> 列名覆盖
        // .ignore = .{.transient},               // 忽略字段
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
    const found = (try db.find(User, u.id.?)).?;
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
    id: ?i64 = null,
    name: []const u8 = "",
    posts: []Post = &.{},                       // has_many 字段
    pub const zorm = .{
        .has_many = .{ .posts = .{ .model = Post, .foreign_key = "author_id" } },
    };
};

pub const Post = struct {
    id: ?i64 = null,
    author_id: ?i64 = null,                     // belongs_to 外键
    title: []const u8 = "",
    author: ?Author = null,                     // belongs_to 字段
    tags: []const []const u8 = &.{},            // text[]
    meta: ?z.Json = null,                       // jsonb
    pub const zorm = .{
        .belongs_to = .{ .author = .{ .model = Author, .foreign_key = "author_id" } },
    };
};

const authors = try z.query(Author, db).preload("posts").all(gpa);   // 批量装配，无 N+1
const posts   = try z.query(Post, db).preload("author").all(gpa);
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
记录表 `schema_migrations (version bigint PK, name text, applied_at timestamptz)`。

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
zig build -Doptimize=ReleaseFast              # 发布构建
```

集成测试覆盖：建表/迁移、插入回填、唯一约束错误、按主键查找、更新、查询构建（where/whereIn/orWhere/select 子集/order/limit）、枚举与 `zorm.Time` 往返、批量插入分块、事务提交与回滚、条件更新与删除。

## 设计与取舍

- **线格式**：参数对标量（int8/float8/bool/timestamptz/bytea/text）用二进制格式并显式声明 OID，数组/JSON/枚举走文本；结果默认按 PostgreSQL 二进制格式解码（`Config.binary_results = false` 可为特殊列类型关闭）。
- **预加载**：点号路径支持任意深度；预加载行的字符串/数组值会按父行深拷贝。多维数组仅支持数值/布尔元素；text 数组为一维。
- **autoMigrate** 仅限建表/补列/单列索引，不删列不改类型；更复杂的变更请用 `Migrator`。
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
- [ ] MySQL/SQLite 驱动

## License

MIT
