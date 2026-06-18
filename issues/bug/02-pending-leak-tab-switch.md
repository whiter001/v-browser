# [Bug] tab 切换时未清空 `pending`，旧请求可能投递到错误 tab

> 标签: `bug`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/cdp_session.v:683-747` (`restore_tab_context`)
> - `packages/server/src/cdp_session.v:608-681` (`save_current_tab_context`)

## 背景

`CdpSession` 维护一个全局 `pending: map[int]chan ProtocolResponse`，每个发出去的 CDP 命令占一个 id，等扩展回包时 `on_message` 按 id 找 channel 投递。

`TabContext` 保存/恢复只覆盖 axref/runtime_context/network/hook/console_msgs 等，**没碰 `pending`**。

## 问题描述

```v
// restore_tab_context (cdp_session.v:683-747)
ctx := s.tab_contexts[tab_id] or {
    // not found branch: 清空一堆状态
    s.runtime_contexts.clear()
    ...
}
s.runtime_contexts = clone_runtime_context_map(ctx.runtime_contexts)
s.network_requests = clone_tracked_request_map(ctx.network_requests)
// ⚠️ pending 完全没动
```

切换到 tab B 后，如果 tab A 还有未回的 CDP 命令：
1. 扩展最终回包，`on_message` 按 id 找到 channel
2. channel 被旧 goroutine 接收
3. 旧代码用 `sess`（共享 session）继续操作，但 `axref.runtime_context_id` 已经指向 tab B → 错误操作

## 复现步骤

1. `v-browser connect` 选中 tab A
2. 启动一个慢 CDP 命令（如 `Page.printToPDF`），不等待
3. `v-browser tab switch <B>`
4. 旧 PDF 命令回包，触发 `on_message`，channel 投递到等待中的 goroutine
5. 该 goroutine 后续基于 axref / context_id 操作时，**目标 tab 是 B 不是 A**

## 建议方案

切换 tab 前主动 reject 所有 pending：

```v
// 在 save_current_tab_context 之后
s.pending_mu.@lock()
for id, ch in s.pending {
    ch <- ProtocolResponse{id: id, err: 'tab switched away'}
}
s.pending.clear()
s.pending_mu.unlock()
```

或者更安全：在 `save_current_tab_context` 之前，先 snapshot pending id 到 TabContext（连同错误消息），恢复时一并处理。

## 验收标准

- [ ] 切换 tab 时所有未回 CDP 命令收到 `tab switched` 错误
- [ ] 单测：构造 pending map 非空 + 切换 tab，验证 channel 收到错误
- [ ] 文档：明确 tab 切换的取消语义