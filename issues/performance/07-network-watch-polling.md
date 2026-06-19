# [Perf] `sync_network_watch_records` 每 200ms 轮询 JS 字符串

> 标签: `performance`, `P2`, `area/server`
> 工作量: L
> 相关文件:
> - `packages/server/src/commands.v:5025-5080` (`sync_network_watch_records` 系列)
> - `packages/server/src/commands.v:4071-4086` (`sync_network_watch_records` 调用点)
> - `packages/server/src/cdp_session.v:1418-1435` (`handle_hook_binding_push`)

## 背景

hook 系统的设计是让浏览器端 JS hook 把每条 fetch/xhr 记录 push 到 server（通过 `Runtime.addBinding` + `__vBrowserHookPush` binding）。

但 sync_network_watch_records 是个**轮询**路径，每 200ms 调一次 `Runtime.evaluate` 读 `window.__vBrowserHookState.events.slice(last_synced_index)`，把新记录 pull 到 server。

## 问题描述

```v
// commands.v:4071
fn sync_network_hook_records(mut sess CdpSession) !int {
    sess.hook_mu.@lock()
    last_synced_index := sess.hook_state.last_synced_index
    sess.hook_mu.unlock()
    read_js := 'JSON.stringify(window.__vBrowserHookState && window.__vBrowserHookState.events ? window.__vBrowserHookState.events.slice(${last_synced_index}) : [])'
    raw := eval_scoped_expression(mut sess, read_js, false) or { return error(err.msg()) }
    ...
}
```

调用点：
- `cmd_network hook records` 时主动调
- `cmd_wait --download` 时每 200ms 调（wait_for_download 内部）
- `cmd_network hook summary/templates` 时调

`wait --download` 场景：每 200ms 一次 CDP round-trip 跑 `Runtime.evaluate`，读数组，解析 JSON，遍历比对记录。30s 默认超时 = 150 次轮询。

## 量化预估

- 每次 poll：1 次 CDP round-trip + JSON 解析 + 字符串 diff
- 30s 下载等待：~150 次空轮询（如果下载没有发生）
- 高频路径下是显著的常数项开销
- **更糟**：与 `track_network_event` 的 Network.* events 路径**重复**——同一份数据被两套机制各算一遍

## 建议方案

**彻底改造**：移除 polling 路径，只用 push（binding 机制）。

1. **删除** `sync_network_hook_records` 的轮询实现
2. **保留** `handle_hook_binding_push` 作为唯一入口（已经实现）
3. **改造** `cmd_network hook records/summary/templates`：直接读 server 端已缓存的 `sess.hook_records`（不再问浏览器）
4. **改造** `cmd_wait --download`：用 `handle_network_watch_loading_finished`（已存在）而不是 polling

`wait --download` 改用 Page.downloadWillBegin / Browser.downloadWillBegin + Page.downloadProgress 事件流，**已经是 push 机制**，不需要 polling。

## 验收标准

- [ ] `sync_network_hook_records` 完全移除
- [ ] `cmd_network hook records/summary/templates` 走 `sess.hook_records` 直读
- [ ] `cmd_wait --download` 用 downloadWillBegin/downloadProgress 事件流，零 polling
- [ ] 高流量下 Network hook 不再触发额外的 Runtime.evaluate
- [ ] 单测：wait --download 在下载完成后 200ms 内返回（之前可能等满 polling interval）

## 备注

属于"二次清理"级别优化。单独 PR 可以包含：
- 移除 sync_network_hook_records
- 改造 cmd_network hook 输出路径
- wait --download 改事件驱动

关联 issue：#23 (network spawn storm) — 都在 network event 处理路径上。