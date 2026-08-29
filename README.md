# zorm

一个受 GORM 启发、面向 Zig 0.16 的 ORM。首个版本 **PostgreSQL 优先**，自带纯 Zig 实现的 PostgreSQL 线协议驱动（无需 libpq，零 C 依赖）。

## 特性

- **纯 Zig PostgreSQL 驱动**：协议 3.0，支持 `SCRAM-SHA-256`、`MD5`、明文认证；简单查询与扩展查询（Parse/Bind/Describe/Execute，参数化防注入）
- **comptime 模型反射**：普通 Zig 结构体即模型，无宏、无代码生成、运行时零注册
- **约定优于配置**：驼峰转 snake_case、`id` 默认主键、`created_at`/`updated_at` 自动时间戳
- **GORM 风格查询构建器**：`where` / `orWhere` / `whereEq` / `whereIn` / `order_by` / `limit` / `offset` / `group_by` / `having` / `for_update`，占位符 `$1,$2...` 跨条件自动重编号
- **CRUD + 事务 + 连接池**：`insert`（自动回填自增主键）、`insertBatch`（自动分块、最多 65535 参数）、`update`、`save`、`delete`、`deleteWhere`、`updateWhere`、`find`、事务 `commit/rollback`
- **autoMigrate**：建表、补列、创建索引（唯一/普通）
- **类型映射**：整数/浮点/`bool`/`[]const u8`(text)/`[]u8`/枚举(按名存储)/`zorm.Time`(timestamptz, 微秒精度) 及其可选版本
- **错误携带上下文**：服务器错误映射为类型化错误（`UniqueViolation`、`ForeignKeyViolation`、`SerializationFailure`…），并可通过 `session.last_error` 读取 SQLSTATE、消息、约束名等明细

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

## 错误处理

```zig
db.insert(&user) catch |err| {
    switch (err) {
        error.UniqueViolation => { /* session.last_error.code == "23505" */ },
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

## 设计与取舍（v1）

- **文本格式收发**：参数与结果均走 PostgreSQL 文本格式，简单可靠；`bytea` 以 hex 自动编解码。
- **无关联加载**：不支持 `preload`/join 映射，关联表用两次查询自行组装。
- **hook 较少**：暂无 GORM 的 BeforeCreate/AfterFind 回调；时间戳通过 `created_at`/`updated_at` 命名约定内建。
- **迁移**仅限建表/补列/单列索引，不删列不改类型。
- **SQL 注入面**：值一律参数化；`order_by`、`group_by`、`having`、`select` 列名为字符串拼接（同 GORM），请勿拼接用户输入。
- **并发**：`Db`/连接池线程安全（`std.Io.Mutex`/`Condition`）；单个 `pq.Conn` 与进行中的 `Session` 非线程安全。
- **更新全列**：`update` 写出模型所有列（GORM `Save` 语义）；部分更新用 `updateWhere`。

## 路线图

- [ ] 二进制格式 + 数组/JSONB 列类型
- [ ] 关联（belongs_to/has_many）与预加载
- [ ] 模型 hook（BeforeSave 等）
- [ ] Savepoint / 嵌套事务
- [ ] 迁移版本管理（schema_migrations）
- [ ] MySQL/SQLite 驱动

## License

MIT
