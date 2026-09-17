// 最小复现：async 运行时起来之后，不 yield 的紧循环收不到 SIGTERM
//
// 三个程序只有循环形态不同：非 async 忙等 / async 每轮 await / async await 一次后紧循环。
// 前两个收到 SIGTERM 正常退出，第三个不退出，只能 SIGKILL。
//
// 详细说明、触发矩阵与上游情况见 README.md。
name = "repro/sigterm"

version = "0.1.0"

preferred_target = "native"

import {
  "moonbitlang/async@0.22.1",
}
