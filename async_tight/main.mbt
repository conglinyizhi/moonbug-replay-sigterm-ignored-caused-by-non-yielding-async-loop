// 复现：async main 里跑一个从不 yield 的紧循环。
//
// 先回到一次事件循环让 async 运行时真正起来（否则整个 async main 可能被优化掉），
// 之后再不回到事件循环。与非 async 的 loop/ 只差这一层「运行时已启动」。
//
// 收到 SIGTERM 不退出，只能 SIGKILL。
// @async.sleep 的参数单位是毫秒：这里等 1 秒再进紧循环，
// 探针在启动 2 秒后发信号，那时循环已经跑起来了。

///|
async fn main {
  println("async_tight: tight loop after one await")
  @async.sleep(1000)
  let mut i = 0
  while true {
    i = i + 1
  }
}
