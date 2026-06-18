# [Bug] `network route` 启动的 goroutine 缺少兜底退出，可能永久泄漏

> 标签: `bug`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/commands.v:3198-3241` (`cmd_network 'route'`)
> - `packages/server/src/commands.v:3273-3282` (`cmd_network 'unroute'`)

## 背景

`route` 通过 `Fetch.enable` + `Fetch.requestPaused` 事件来拦截/改写/失败请求。后台 spawn 一个 goroutine 处理每个被拦截的请求。

## 问题描述

```v
// commands.v:3218-3239
spawn fn [mut sess, ch, stop_ch, abort, body] () {
    for {
        select {
            evt := <-ch {
                request_id := cdp_extract_str(evt.params, 'requestId')
                ...
            }
            _ := <-stop_ch { break }
        }
    }
}()
```

- `stop_ch` 是 `chan bool{cap: 1}`，只有 `unroute` 写一次
- 如果客户端在 `route` 之后 crash / 连接断 / 直接 kill server，**没有人写 stop_ch**，goroutine 永远卡在 `select`
- `has_route = true` 状态不释放，再次 `route` 会因为"已存在 route"路径再次 spawn 一个 goroutine 接管旧 channel → 旧 goroutine 收不到 close 信号，永远泄漏

## 建议方案

1. **监听 `sess.close()`**：
   ```v
   sess_close_ch := sess.subscribe('__internal_session_closed')
   ...
   select {
       evt := <-ch { ... }
       _ := <-stop_ch { break }
       _ := <-sess_close_ch { break }
   }
   ```
2. **心跳超时**：30s 内无 `Fetch.requestPaused`，自动退出。
3. **defer unsubscribe**：goroutine 退出时自动 `unsubscribe('Fetch.requestPaused', ch)`。

## 验收标准

- [ ] 关闭连接（kill server）后无 goroutine 泄漏（用 `runtime.NumGoroutine` 验证）
- [ ] `unroute` 失败时不会 spawn 第二个 goroutine
- [ ] 30s 心跳自动退出
- [ ] 单测：构造 `route` + 模拟 close，验证 goroutine count 恢复到初始值