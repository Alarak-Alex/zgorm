# 交叉编译与 sqlite3 链接

记录一个在真实项目里踩到的问题：zgorm 的 `build.zig` 无条件链接系统 `sqlite3`，导致消费者无法交叉编译，也无法在静态链接场景使用。

> 状态：v0.11.1 已修复，采用下方「方案一」。`zgorm` 模块不再携带 `-lsqlite3`，使用 SQLite 驱动的构建目标自行 `linkSystemLibrary("sqlite3")`；本仓库的 example、单元测试与驱动测试已各自链接。以下保留原始分析与下游绕过记录。

## 现象

消费者即使自己没有调用 `linkSystemLibrary("sqlite3")`，只要 import 了 zgorm 的模块，交叉编译就会失败：

```
$ zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
error: unable to find dynamic system library "sqlite3" using strategy paths_first.
       searched paths: none
```

原生编译（macOS / 桌面 Linux）正常，因为本机有 `libsqlite3.dylib` 或 `libsqlite3.so`。只有交叉编译才暴露。

## 根因

`build.zig` 第 20 行附近：

```zig
mod.linkSystemLibrary("sqlite3", .{});
```

这行在 `addModule` 里无条件执行，写进了模块的链接属性。消费者通过

```zig
const zgorm = b.dependency("zgorm", .{ .target = target, .optimize = optimize }).module("zgorm");
```

拿到模块时，`-lsqlite3` 会跟着进入最终链接命令。Zig 交叉编译不会自动寻找目标平台的系统库，于是直接报错。

实测的链接命令片段（消费者侧）：

```
-Mzgorm=.../src/root.zig -lsqlite3 -Osmall -target aarch64-linux-musl
                                        ^^^^^^^^^ 这段来自 zgorm 的模块属性
```

## 影响面

| 场景 | 是否受影响 |
|---|---|
| 原生编译，系统装了 sqlite3 dev 包 | 正常 |
| 交叉编译到 aarch64 / riscv / wasm | 失败 |
| 想把 sqlite3 静态编进二进制（单文件部署） | 无法做到，仍被要求链系统库 |
| 只用 MySQL / PostgreSQL 驱动，完全不用 SQLite | 仍被要求装 sqlite3 开发包 |

最后一条尤其别扭：`zg.drivers.mysql` 和 `zg.drivers.postgres` 是纯 Zig 实现，与 sqlite3 无关，但链接属性是模块级的，无法按驱动拆分。

## 下游绕过方式

不消费 `b.dependency(...).module(...)`，改为直接引用包内源码建模块：

```zig
const zgorm_dep = b.dependency("zgorm", .{
    .target = target,
    .optimize = optimize,
});

// 不走 .module()，避免继承 zgorm 的 linkSystemLibrary。
const zgorm = b.createModule(.{
    .root_source_file = zgorm_dep.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zgorm", zgorm);

// sqlite 由消费者自己提供，可以是静态编译的 amalgamation。
exe.root_module.addCSourceFile(.{
    .file = b.path("third/sqlite3.c"),
    .flags = &.{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
    },
});
exe.root_module.addIncludePath(b.path("third"));
```

代价：

- 拿不到 zgorm `build.zig` 里可能新增的编译选项或依赖传递。目前 0.11.0 的 `build.zig` 只有这一行 linkSystemLibrary，所以安全；将来若它加了别的模块依赖，这条路会断。
- 消费者要自己保证 `libsqlite3` 的实现与 zgorm 期望的 ABI 一致。zgorm 的 `src/drivers/sqlite/c.zig` 是手写 C ABI 声明，期望 64 位 Unix ABI。

## 上游修复建议

三个方向，按推荐度排序。

### 方案一：交给消费者（推荐）

删掉 `linkSystemLibrary`，在 README 写明「使用 `zg.drivers.sqlite` 时需自行链接 libsqlite3」。理由：

- 驱动是可选功能，不该强制所有消费者承担。
- 纯 Zig 驱动（MySQL / PostgreSQL）不需要任何 C 库。
- 消费者对静态/动态、系统/内置有最终决定权。

### 方案二：提供编译选项

```zig
pub fn build(b: *std.Build) void {
    const sqlite = b.option(std.builtin.LinkMode, "sqlite", "Link sqlite3: dynamic, static, none") orelse .dynamic;

    const mod = b.createModule(.{ .root_source_file = b.path("src/root.zig") });
    switch (sqlite) {
        .dynamic => mod.linkSystemLibrary("sqlite3", .{}),
        .static => {
            mod.addCSourceFile(.{ .file = b.path("deps/sqlite3.c"), .flags = &.{ "-DSQLITE_THREADSAFE=1" } });
            mod.addIncludePath(b.path("deps"));
        },
        .none => {},
    }
}
```

默认值保持 `.dynamic` 以免破坏现有消费者，需要静态或交叉编译的显式传参。

缺点：消费者要传 `-Dsqlite=static`，且仍然无法完全关闭（除非 `.none`）。

### 方案三：内置 amalgamation

把 `sqlite3.c` 放进仓库，默认静态编译，彻底摆脱系统库。

优点：零配置，交叉编译开箱即用。
缺点：仓库体积增加约 9 MB，sqlite 版本需要跟人工升级，与系统 sqlite 可能存在版本冲突。

## 附：sqlite 源码从哪来

在受限网络里 `curl sqlite.org` 常常失败，`zig fetch` 走 git 协议通常可用：

```sh
zig fetch --save 'git+https://github.com/leroycep/sqlite-zig'
# 在 zig-pkg/sqlite-<version>-*/ 下取 sqlite3.c 与 sqlite3.h
```

实测拿到 sqlite 3.48.0，8.7 MB，可直接 `addCSourceFile`。

## 复现步骤

```sh
zig init
zig fetch --save 'git+https://github.com/<zgorm-repo>'
# build.zig 里 import zgorm 模块后：
zig build -Dtarget=aarch64-linux-musl
```

预期：`unable to find dynamic system library "sqlite3"`。

## 相关记录

- Zig 0.17 移除了 `@cImport`，zgorm 因此改为手写 C ABI 声明（见 `src/drivers/sqlite/c.zig`）。这意味着链接期必须能解析 `sqlite3_open_v2`、`sqlite3_prepare_v2` 等符号，静态库与动态库都可以，只要能被链接器找到。
- 同一份构建配置在原生 macOS 上正常，说明问题只在跨目标时出现，容易漏测。
