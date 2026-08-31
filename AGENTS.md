# Repository Guidelines

## Project Overview

zorm 是面向 Zig 0.16 的 GORM-inspired ORM。提供纯 Zig PostgreSQL/MySQL 协议驱动、SQLite 驱动，以及类型化 CRUD、查询构建、事务、迁移、关联、连接池和可观测性能力。

## Architecture & Data Flow

- `src/root.zig` 是公共模块入口，导出 ORM、驱动、查询、schema、迁移、插件和观测 API。
- 模型在 comptime 通过 `src/orm/schema.zig:tableOf` 反射。默认使用 snake_case、`id` 主键、时间戳约定；`z.Model` 会嵌入基础字段。
- 查询流：`Db/Session` → `src/orm/qb.zig` 构建 SQL 与绑定参数 → `src/orm/pool.zig` 获取连接 → driver 执行 → `src/orm/value.zig` 解码模型。
- `src/drivers/shared/` 提供后端、方言、结果集、参数、统一 ORM、迁移和插件基础；PostgreSQL/MySQL/SQLite facade 复用这套实现。
- 关联默认按字段类型和命名推导；显式关系使用 `<field>_relation`，例如 `posts_relation = z.hasMany(Post)`。
- `Db`/`Pool` 可并发使用；单个连接和进行中的 `Session` 不应跨线程并发使用。事务会固定连接，嵌套事务使用 savepoint。

## Key Directories

- `src/orm/`: ORM 核心：`db.zig`、`qb.zig`、`schema.zig`、`value.zig`、`pool.zig`、`migrator.zig`、`plugins.zig`、`observability.zig`。
- `src/drivers/postgres/`: 纯 Zig PostgreSQL 协议、DSN、TLS、认证和 prepared statement。
- `src/drivers/mysql/`: MySQL/MariaDB 协议和连接实现。
- `src/drivers/sqlite/`: SQLite C API facade，需系统 `sqlite3`。
- `src/drivers/shared/`: 三个驱动共享的 backend、dialect、ORM、结果和错误类型。
- `tests/`: 驱动测试和需要真实 PostgreSQL 的集成测试。
- `example/`: 可运行的 PostgreSQL/SQLite smoke example。
- `benchmark/`: zorm 性能程序和 GORM 对照程序。

## Development Commands

```sh
zig build
zig build test
zig build test-drivers
zig build test-integration -Ddsn='postgres://user:pass@host:5432/db'
zig build run -Ddsn='postgres://user:pass@host:5432/db'
zig build -Doptimize=ReleaseFast
zig build benchmark
zig build benchmark-build
```

- `zig build` 默认构建并安装 `zorm-example`。
- `test-integration` 需要可写、专用 PostgreSQL 数据库；测试会 `DROP TABLE ... CASCADE`。
- `test-drivers` 默认覆盖 SQLite；传 `-Dmysql-port=3307` 才运行 live MySQL 测试。
- 发布前运行：`zig fmt --check build.zig.zon`、`zig build test`、`zig build -Doptimize=ReleaseSafe`。
- 版本只在 `build.zig.zon` 的 `.version` 维护；发布使用 annotated `vX.Y.Z` tag 和 GitHub Release。

## Code Conventions & Common Patterns

- 目标 Zig 版本为 `0.16.0`；格式化使用 `zig fmt`，不要手工调整格式。
- 命名转换统一使用 `src/orm/naming.zig:toSnakeCase`；SQL 标识符必须通过 driver/dialect 的 quote helper。
- 所有用户值使用参数绑定；不要把用户输入拼接进 `where/order/group/select` SQL 片段。
- 公共操作使用 `Error!T` 传播错误；不要用 `unwrap` 式 panic 替代模型、连接、事务或协议错误处理。
- 查询 builder 使用 arena 管理临时 SQL/参数；终端 query、result、arena 必须释放。
- `find`/`all` 解码出的模型、字符串、数组、JSON/Bytes 使用 `z.free` 或 `z.freeSlice`；`Result` 调用 `deinit`。
- 事务重试只使用显式 `transactionRetry`；普通写操作不会自动重放。
- schema、列名、主键和关联尽量使用 comptime 校验，非法模型应让编译期报错。

## Important Files

- `src/root.zig`: 公共 API 和模块导出。
- `src/orm/schema.zig`: 模型反射、字段类型、表元数据和关联推导。
- `src/orm/db.zig`: Db/Session/Tx、CRUD、连接执行和关联操作。
- `src/orm/qb.zig`: 查询 builder、SQL 组合、preload 和结果装配。
- `src/orm/value.zig`: Zig 值编码、驱动参数、结果解码和释放。
- `src/orm/pool.zig`: 连接池、超时、健康检查、预热和维护。
- `src/orm/migrator.zig`: 版本迁移、schema diff、约束和索引。
- `src/drivers/shared/dialect.zig`: 方言能力、参数上限、标识符和 DDL 差异。
- `build.zig`: 构建步骤、测试目标、示例、benchmark 和自定义选项。
- `build.zig.zon`: 包名、版本、最低 Zig 版本和依赖。

## Runtime/Tooling Preferences

- 必须使用 Zig `0.16.0`；构建由 Zig build system 管理，不使用 Makefile、justfile 或额外脚本。
- PostgreSQL 和 MySQL 不需要客户端库；SQLite 需要系统开发头文件和 `libsqlite3`。
- DSN 可通过 `-Ddsn=...` 或 `ZORM_DSN` 提供。支持 URL、key=value 和 PostgreSQL Unix socket 形式。
- benchmark 需要 PostgreSQL；`benchmark/gorm` 另需 Go 工具链和其 `go.mod` 依赖。
- `.zig-cache/`、`zig-out/`、`.zcode/` 是忽略目录；`.zcode/config.json` 仅是编辑器/MCP 配置，不是构建配置。

## Testing & QA

- 测试使用 Zig 内建 test runner 和 `std.testing`，无第三方测试框架。
- `zig build test` 运行 `src/root.zig` 及其导入模块中的单元测试。
- `zig build test-drivers` 运行 `tests/drivers.zig`；SQLite 测试通常使用 `:memory:`，MySQL 未配置端口时会跳过。
- `zig build test-integration -Ddsn=...` 运行 `tests/integration.zig` 的 PostgreSQL 集成覆盖，包括协议、CRUD、关联、迁移、事务、连接池、流式结果、插件和观测。
- 无 DSN 时部分集成测试会静默 skip；CI/助手必须确认日志确实连接并执行了测试。
- benchmark 是性能观测，不是正确性测试；默认 PostgreSQL DSN 为 `127.0.0.1:5433`，初始化会删除并重建 benchmark 表，禁止使用共享或生产数据库。
- 行为变更至少运行相关测试目标和 `zig build -Doptimize=ReleaseSafe`；不要把 benchmark 当作回归测试替代品。
