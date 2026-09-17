# async 紧循环收不到 SIGTERM（只能 kill -9）

## 1. 这个 bug 是什么

### 原因

`main` 是 `async fn`。只要 async 运行时已经起来、而任务又长时间不 yield，进程就收不到 `SIGTERM`：

```moonbit
async fn main {
  println("async_tight: tight loop after one await")
  @async.sleep(1000)   // 参数单位是毫秒：先让 async 运行时真正跑起来
  let mut i = 0
  while true {          // 之后再也不回到事件循环
    i = i + 1
  }
}
```

启动 2 秒后（此刻早已进入紧循环）发 `SIGTERM`：进程不退出，宽限 3 秒后仍然活着，只能 `SIGKILL`。

对照只改循环体一个变量：

| 程序 | 循环体 | SIGTERM | 退出码 |
| --- | --- | --- | --- |
| `loop/` | 非 async 纯忙等 | 有效（一次轮询内判定退出） | 143（128+15） |
| `async_loop/` | `@async.sleep(1000)`，每轮回到事件循环 | 有效（一次轮询内判定退出） | 143 |
| `async_tight/` | `@async.sleep(1000)` 一次后紧循环 | **无效**，进程仍在跑 | 只有 `SIGKILL` 收得掉，137 |

也就是说：非 async 正常、会回到事件循环的 async 正常，**只有「async 运行时已启动、但任务长时间不 yield」时不响应 TERM**。

### 机制（在 async 源码里能对上）

`moonbitlang/async@0.22.1` 里信号不走进程默认处置，而是被接管后投给事件循环：

- `src/internal/event_loop/signal.c`：`pthread_sigmask(SIG_SETMASK, 0, &signals_to_block)` 先把取消信号屏蔽掉，
  另起一个 `sigwait_thread_worker` 线程用 `sigwait(&wait_set, &sig)` 收信号，收到后
  `moonbitlang_async_notify_event_loop(sig | (1 << 31))` 把它当通知投给事件循环
- `src/internal/event_loop/signal.mbt:89`：`setup_signal_handler_unix` 调 `set_global_cancellation_signals(all_signals)`
  并 `start_signal_handler_ffi()`；调用点在 `event_loop.mbt:142`，也就是事件循环起来的时候

所以事件循环不跑 → 通知没人处理 → `TERM` 看起来被忽略。紧循环正好永远不回到事件循环。
（依赖源码在仓库旁的 `.mooncakes/moonbitlang/async/`，也可以 `moon fetch moonbitlang/async@0.22.1` 单独拉下来看。）

影响面：`timeout(1)`、CI 的超时兜底、进程管理器（systemd / supervisor / 容器 `stop`）都停不掉这类进程，只剩 `SIGKILL`。

### 复现平台

| 平台 | 工具链 | 结果 |
| --- | --- | --- |
| 本机 Linux x86-64 | `moon 0.1.20260916 (e4f45e4)`，nightly 频道 | 复现（`make bug` 绿） |
| GitHub Actions `ubuntu-latest` | `moon 0.1.20260915 (2e1a46d)`，latest 频道 | 复现（[run 35218987137](https://github.com/conglinyizhi/moonbug-replay-sigterm-ignored-caused-by-non-yielding-async-loop/actions/runs/35218987137)：三条 lane 全绿） |
| GitHub Actions `ubuntu-latest` | `moon 0.1.20260916 (e4f45e4)`，nightly 频道（与本机同版本） | 复现（[run 35219983330](https://github.com/conglinyizhi/moonbug-replay-sigterm-ignored-caused-by-non-yielding-async-loop/actions/runs/35219983330)：三条 lane 全绿，`async_tight` 同样是 `term_ignored exit=137`） |

## 2. 快速复现

### 最少需要什么

| 文件 | 内容 |
| --- | --- |
| `moon.mod` | `name = "repro/sigterm"` / `preferred_target = "native"` / `import { "moonbitlang/async@0.22.1" }` |
| `async_tight/moon.pkg` | `import { "moonbitlang/async" }` + `pkgtype(kind: "executable")` |
| `async_tight/main.mbt` | 上面那 8 行 |

```bash
make bug
```

期望输出（命中问题即通过）：

```
命中问题 lane —— 紧循环收到 TERM 期望仍存活（term_ignored） —— 期望 verdict=term_ignored
  async_tight  term_ignored  TERM 后仍存活（SIGKILL 收场 exit=137）    PASS  async 紧循环（await 一次后不再 yield）—— 复现
```

不想用 Makefile：

```bash
moon update --quiet                       # 首次需要同步 registry 索引
MOON_CC=clang moon run --target native cases.mbtx -- bug
```

### 文件清单：哪些和这个 bug 有关

| 文件 | 行数 | 和 bug 的关系 |
| --- | --- | --- |
| `moon.mod` | 15 | **必需** —— 标记模块，`preferred_target = "native"`，依赖 `moonbitlang/async` |
| `async_tight/moon.pkg` | 5 | **必需** —— 标记 package（可执行） |
| `async_tight/main.mbt` | 17 | **必需** —— 复现本体 |
| `loop/main.mbt` | 12 | **对照必需** —— 非 async 忙等，说明「忙等」本身不是问题 |
| `async_loop/main.mbt` | 13 | **对照必需** —— 每轮回到事件循环就正常 |
| `cases.mbtx` | 363 | **与 bug 无关** —— 可执行规格，负责断言 |
| `Makefile` | 61 | **与 bug 无关** —— 调用规格的入口 |
| `.github/workflows/repro.yml` | 58 | **与 bug 无关** —— CI |
| `README.md` | — | **与 bug 无关** —— 本文档 |

最小复现就是前三个（约 30 行代码），后三个对照与骨架删掉照样复现。

## 3. 其他

### 触发矩阵

| 程序 | `SIGTERM` 后 | 退出码 |
| --- | --- | --- |
| `loop`（非 async 忙等） | 退出 | 143 |
| `async_loop`（每轮 await） | 退出 | 143 |
| `async_tight`（await 一次后紧循环） | **仍在跑**（`ps` 状态 `Rl`） | 137（探针 `SIGKILL` 收场） |

### 可执行规格

单文件 `.mbtx`：`moon run cases.mbtx -- <子命令>`。它自己构建三个程序，然后用 `@process.spawn_orphan`
起进程、`@async.sleep` 等到指定时刻、`kill(2)` 发信号，判决用 `waitpid(..., WNOHANG)` 收尸得到。

```bash
make verify      # 命中问题 lane + 绕过 lane + 对照 lane，本地应全绿
make bug         # 只跑命中问题 lane
make workaround  # 只跑绕过 lane
make contrast    # 只跑对照 lane
make fixed       # 修复验收 lane（上游修好后转 PASS）
make cases       # 列出用例
make diagnose    # 打印探针参数与三个程序的循环形态
make deps        # 同步 registry 索引（首次运行需要，各 lane 会自动先跑）
```

**注意：复现本体只依赖 `moonbitlang/async`（它本身就是被测对象）；`cases.mbtx` 额外用到 async 的 `process`/`fs`。**

判活为什么不用 `kill(pid, 0)`：子进程被信号打死后、被收尸之前是僵尸，僵尸也是「kill 成功」，
会把「已经退出」误判成「TERM 无效」。`waitpid` 非阻塞收尸一次就能同时给出「还在跑」和「退出码」。
（本机实测：把 `reap` 换成 `kill(pid, 0)` 判活，`loop` 与 `async_loop` 会被僵尸误判成 `term_ignored`，
workaround / contrast 两条 lane 由 PASS 变 FAIL。探针的父进程就是 `cases.mbtx` 自己，宽限窗口里没人收尸，
`ps` 全程显示 `Z <defunct>` 而 `kill(pid,0)` 恒为 0。）

### 用例

| case | lane | 期望 | 说明 |
| --- | --- | --- | --- |
| `async_tight` | bug | `term_ignored` | 紧循环收到 TERM 仍存活（命中问题） |
| `async_loop` | workaround | `term_ok` | 每轮回到事件循环就正常 |
| `loop` | contrast | `term_ok` | 非 async 忙等也正常 |

`fixed` lane 跑的是 `async_tight`，期望 `term_ok` —— 上游修好后这一条转 PASS。

### CI

两个 workflow，每个四条 job（`hit-the-bug` / `workaround` / `contrast` / `upstream-fix-status`，
最后一个 `continue-on-error`，专门用来看上游修没修）：

| workflow | 工具链频道 | 触发 |
| --- | --- | --- |
| `repro.yml` | `latest`（安装脚本不带参数时的默认频道） | push / PR / 手动 |
| `nightly.yml` | `nightly` | push + 每天 04:00 UTC 定时 + 手动 |

两个频道各跑一遍，是为了给上游两条数据：这个问题不是某个频道独有的。nightly 每天在变，
定时跑也能当「上游是否已修」的探针。每个 job 开头都会 `make diagnose`，日志里有完整的
`moon / moonc / moonrun` 版本，报 bug 时直接引。

`latest` 那轮（2026-09-17，[run 35218987137](https://github.com/conglinyizhi/moonbug-replay-sigterm-ignored-caused-by-non-yielding-async-loop/actions/runs/35218987137)）：
三条 lane 全绿，`upstream-fix-status` 是 failure 但 workflow 结论仍是 success；
runner 上装到 `moon 0.1.20260915 (2e1a46d 2026-09-15)`，与本机不同版本，结论一致。

`nightly` 那轮（[run 35219983330](https://github.com/conglinyizhi/moonbug-replay-sigterm-ignored-caused-by-non-yielding-async-loop/actions/runs/35219983330)）：
在干净的 runner 上装到的就是本机那个 `moon 0.1.20260916 (e4f45e4 2026-09-16)`
（`moonc v0.10.13+75bd53fc8-nightly`、`moonrun 0.1.20260916`），`async_tight` 同样是 `term_ignored`、SIGKILL 收场 `exit=137`，
所以这个复现不是本机环境特有。
（后续一次 push 顺手把 `checkout` 从 v4 升到 v5，消掉了日志里的 Node 20 弃用提示。）

### 注意

- `@async.sleep` 的参数是毫秒；探针在启动 2000 ms 后发信号，`async_tight` 在 1000 ms 时进紧循环。
  本机扫过翻转点：`ready_wait` 要 1050 ms 以上才是「TERM 被忽略」，1000 ms 时信号落在 sleep 里。
  2000 ms 留了约 1 s 余量；机器慢到把这个余量吃掉，`bug` lane 会假 FAIL、`fixed` lane 会假 PASS。
- native 编译需要一个 C 驱动：Makefile 默认按 `FIX_CC=clang` 传给 `MOON_CC`，可用 `make FIX_CC=gcc ...` 覆盖。
  `FIX_CC` 给绝对路径时 moon 会去同目录找归档器（`ar`），那个目录里没有 `ar` 就会构建失败。
- 三个程序都不会自己退出（`loop` / `async_loop` / `async_tight`），手工 `&` 跑测试记得收尾。

### 环境

```
# 本机（本文所有数字的来源）
moon 0.1.20260916 (e4f45e4 2026-09-16)      # nightly 频道
moonc v0.10.13+75bd53fc8-nightly (2026-09-15)
moonbitlang/async 0.22.1
Linux x86-64（内核 7.2.3-arch1-3），clang 22.1.8

# CI（ubuntu-latest）
moon 0.1.20260915 (2e1a46d 2026-09-15)      # latest 频道（run 35218987137）
moon 0.1.20260916 (e4f45e4 2026-09-16)      # nightly 频道（run 35219983330，与本机同版本）
```

### 相关上游 issue

已投 **[moonbitlang/async#612](https://github.com/moonbitlang/async/issues/612)**
（`SIGTERM is silently ignored when a task never suspends`，2026-09-17 开，尚无维护者回复）。
目标仓库就是 [moonbitlang/async](https://github.com/moonbitlang/async) —— `async fn main` 的运行时、
以及接管信号的那段代码（`src/internal/event_loop/signal.{c,mbt}`）都在这里。

投之前搜过：`SIGTERM` **2 命中**，分别是 #22、#232，都已关闭且是 process 取消 API 的事；`signal` **50 命中**，
绝大多数是 wasm / cancellation 方向，开着的 #442 是 native runtime 的 followups 追踪，列的是 Windows `sync` 之类，都不覆盖这条。

`moonbitlang/moon` 里 #1341 / #1342 / #1344 / #1351 讨论的是「moon 把信号传给它启动的子进程」，属于另一层，不冲突。

### 姊妹仓库

同批的另一个问题（native 深递归栈溢出是裸 SIGSEGV，与这条无关）：
[moonbug-replay-bare-sigsegv-caused-by-native-stack-overflow](https://github.com/conglinyizhi/moonbug-replay-bare-sigsegv-caused-by-native-stack-overflow)

同一套结构的既有仓库：
[test-driver-argv](https://github.com/conglinyizhi/moonbug-replay-test-driver-argv-caused-by-missing-bounds-check)、
[broken-pipe](https://github.com/conglinyizhi/moonbug-replay-broken-pipe-caused-by-panic-abort)、
[lib.exe 归档器](https://github.com/conglinyizhi/moonbug-replay-native-build-fails-caused-by-lib-exe-archiver)
