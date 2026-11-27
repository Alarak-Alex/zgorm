# 结论修正：与 zgorm 无关

**这份文档最初把崩溃归因于 zgorm 的连接池，那是错的。**

真实原因是消费者的协程栈太小：`http.Server` 的 `.stack_size` 设成了 64 KiB，而 tardy 的框架默认是 1 MiB。Debug 构建下 tardy 会打印协程栈水位，64 KiB 时停在 `Used 60.875KiB / 64KiB`，已经写满并踩进相邻堆内存。换成 1 MiB 后同一查询实测 `Used 144.4KiB / 1MiB`，带请求体的 POST 峰值 `243.1KiB / 1MiB`。

因此 zzz 里 `free of invalid memory` 的 panic、以及 AArch64 Debug 首次请求就 Segfault，都是堆被写坏之后的下游症状。zgorm 的池、它的 `std.Io.Mutex`、SQLite 连接复用都正常。

排查过程中被排除的实验记录保留在下面，它们本身是对的，只是最终原因在更外层。

---

# 原始记录（结论已被否定）

记录一个集成层面的崩溃。zgorm 单独使用正常，接进 zzz 的 HTTP handler 后，任何访问数据库的请求都会崩溃。
## 现象

zzz v0.3.3 + tardy 0.3.3 的 handler 里通过 zgorm 连接池查询：

```zig
var lease = try database.pool.acquire();
defer lease.deinit();
var result = try lease.backend.exec(sql);
result.deinit();
```

结果：

- macOS Debug：第一个请求成功，第二个请求 `free of invalid memory`，崩溃点落在 zzz 的 `Server.mainLoop`。
- AArch64 Linux Debug：**第一个请求就 Segmentation fault**，日志停在请求行之后。
- 两端 ReleaseSmall 都不崩，但那是没有堆校验，不代表正常。

不访问数据库的 handler（例如只读配置返回 JSON）连续请求 5 次全部正常。所以问题与 HTTP 层无关，出在「handler 里访问数据库」这一步。

## 已排除

- **zzz 的全局问题**：无数据库请求稳定，排除。
- **双连接池设计**：改成单个可读写池后仍然崩溃。
- **zgorm 的基本用法**：单线程程序里 `openPool` → 5 轮 `acquire` / `exec("SELECT 1")` / `deinit` 全部通过。
- **结果集生命周期**：zgorm 的 SQLite 驱动把每列数据 `arena.dupe` 到结果集自己的 arena（`src/drivers/sqlite/db.zig:148`），`Result.deinit` 后不依赖连接。
- **SQL 本身**：换成最简单的 `SELECT COUNT(*)` 也一样崩。

## 排除项（补充）

**不是连接池的互斥锁。** 改成一个自建连接组（4 个直连 `sqlite.Db` + 原子自旋锁，完全绕开 `openPool` 与 `std.Io.Mutex`）后，行为完全不变：第一个请求成功，第二个请求进程直接消失，无 panic 输出。说明崩溃与池的锁无关。

这一点很重要，它把范围从「池的 io 绑定」收窄到了「连接复用本身」或「zzz 的请求上下文中访问 SQLite」。

## 原假设（已被上述实验否定）

zgorm 的连接池用 `std.Io.Mutex`，锁的是**创建池时传入的 io**：

```zig
pub fn acquire(pool: *Self) types.Error!Lease {
    pool.mutex.lockUncancelable(pool.io);
    ...
}
```

而 tardy 的 handler 运行在 tardy 自己的协程调度器上（`Runtime`），它有自己的 io 与栈。tardy 的协程栈默认 64 KiB，`std.Io.Mutex` 在跨 io 的协程里等待时可能触发栈切换或调度冲突。

单线程的独立程序里，池与调用方共用同一个 io，所以正常。这就是两类环境下结果不同的原因。

## 建议

短期：在 zig-eye 侧把数据库访问收敛到单一「数据库线程」，handler 通过队列请求数据，避免在 tardy 协程里直接 `acquire`。这也顺带解决了 SQLite 单写者的排队问题。

长期（zgorm 侧）：池的加锁应该使用调用方当前的 io，而不是创建时的 io。可以给 `acquire` 增加一个 io 参数，或者在池内部改用不依赖调度器的原子自旋锁，语义上够用，因为临界区只有几个字段的搬移。

## 复现

```zig
// 单线程：正常
const pool = try sqlite.openPool(gpa, io, ":memory:", .{}, .{ .max_size = 2 });
var i: usize = 0;
while (i < 5) : (i += 1) {
    var lease = try pool.acquire();
    var res = try lease.backend.exec("SELECT 1");
    res.deinit();
    lease.deinit();
}
```

把同样的代码放进 zzz 的 handler，并在 tardy 的协程里执行，就会崩溃。

## 相关

见 zig-eye 仓库的 `docs/known-issues.md`，那里记录了完整的排查过程与实测输出。
