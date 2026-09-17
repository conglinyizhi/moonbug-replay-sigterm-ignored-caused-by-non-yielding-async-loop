// 绕过形态：async main，循环每轮都回到事件循环。
//
// 收到 SIGTERM 正常退出（exit 143）。
// @async.sleep 的参数单位是毫秒。
///|
async fn main {
  println("async_loop: await every iteration")
  let mut i = 0
  while true {
    @async.sleep(1000)
    i = i + 1
  }
}
