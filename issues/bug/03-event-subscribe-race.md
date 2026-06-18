# [Bug] `subscribe` 前已触发的事件会通过新 channel 立刻投递

> 标签: `bug`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/commands.v:521-529` (`cmd_open`)
> - `packages/server/src/commands.v:521-529`, `1009-1015` (`wait_for_navigation_state`)
> - `packages/server/src/cdp_session.v:866-889` (`subscribe` / `unsubscribe`)

## 背景

```v
ch := sess.subscribe('Page.loadEventFired')
defer { sess.unsubscribe('Page.loadEventFired', ch) }
sess.send_command('Page.navigate', ...)
select {
    _ := <-ch {}
    30 * time.second {}
}
```

## 问题描述

`subscribe` 给 method 名分配 channel cap=32。如果之前的事件已经被 enqueue 但没人收，新 channel 会立刻收到。

例如：
1. 用户在 A 页点击 `<a href="/slow">` 触发导航
2. 切换到 tab B（旧的 axref 还指向 A 页 DOM）
3. 调用 `cmd_open` 在 tab B 上 `subscribe('Page.loadEventFired')`
4. 此时 A 页 `loadEventFired` 触发，但 `on_message` 投递的目标 method 名是 `'Page.loadEventFired'`，**不区分 tab**
5. tab B 的等待代码立刻收到事件，误判"加载完成"

## 复现步骤

1. 在 tab A 打开 `https://httpbin.org/delay/2`
2. 立即 `v-browser tab switch <B>`
3. `v-browser open https://example.com` 在 tab B
4. tab A 的 loadEvent 在切换后到达，cmd_open 立即返回 success

## 建议方案

1. **tab 标记**：扩展在每个 CDP event 里附带当前 tabId，server 在 `on_message` 时按 tabId 过滤
2. **or** 切换 tab 时清空所有 event channel：`event_subs[method] = []`
3. **or** 用一次性 channel（cap=1，接收一次后立即 unsubscribe）

最简单方案：

```v
fn (mut s CdpSession) subscribe_once(method string) chan ProtocolResponse {
    ch := chan ProtocolResponse{cap: 1}
    s.event_mu.@lock()
    if method !in s.event_subs { s.event_subs[method] = [] }
    s.event_subs[method] << ch
    s.event_mu.unlock()
    return ch
}
```

调用方：`<-ch` 收到一个事件后 `unsubscribe(method, ch)`，再尝试第二次事件会被丢弃。

## 验收标准

- [ ] 切换 tab 后旧 tab 的事件不再影响新 tab
- [ ] 单测：构造两个 tab，验证 `subscribe` 后只收到当前 tab 事件
- [ ] `cmd_open` 在页面 navigate 失败时返回明确错误（依赖 S4 修复）