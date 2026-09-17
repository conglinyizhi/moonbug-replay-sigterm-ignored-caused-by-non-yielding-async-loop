// 对照：非 async 的纯忙等循环。
//
// 收到 SIGTERM 正常退出（exit 143）。说明「忙等」本身不是问题，
// 问题出在 async 运行时起来之后、任务长时间不 yield。

///|
fn main {
  println("loop: busy loop, non-async")
  let mut i = 0
  while true {
    i = i + 1
  }
}
