# [Perf] `Network.loadingFinished` 每个请求都 spawn 协程

> 标签: `performance`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/cdp_session.v:782-792` (`on_message` Network 分支)
> - `packages/server/src/cdp_session.v:1412-1415` (`cache_response_body`)

## 背景

`auto_body_cache = true` 时，每条 `Network.loadingFinished` 事件触发一次 `spawn`，子协程调用 `Network.getResponseBody` 把响应缓存到本地。

## 问题描述

高频页面（推特时间线：每页 ~200 张图）会在 1~2s 内 spawn 200+ 协程：

- 每个协程 = 1 个 CDP round-trip
- 共享同一个 `network_requests` map 的 mutex
- 在 GIL 风格 runtime 下并发 200+ 时 GIL 切换开销明显

同时 `track_network_event` 在 `on_message` 主路径上 `@lock` 全 map，每个事件 2 次锁。

## 量化收益

- 高频页面下 CPU 占用降到 1/3
- 网络事件 throughput 3–10×

## 建议方案

1. **批量 worker**：开 N 个 worker goroutine（默认 8），事件塞 channel，worker 批量 `getResponseBody`。
2. **拆分读写锁**：`network_requests` 读多写少，用 `sync.RwMutex`（V 已支持）或 sharded map。
3. **`auto_body_cache` 默认关闭**：当前 `--capture-body` 才开，但 `loadingFinished` 分支每次都 spawn；改成 `if do_cache` 才 spawn。
4. **去重**：`requestId` 已经 `loadingFinished` 过的不再 spawn。

## 验收标准

- [ ] 单测：构造 1000 个 `loadingFinished` 事件，验证 goroutine count 不超过 8 + 在合理时间内全部缓存完
- [ ] `auto_body_cache = false` 时不 spawn 任何协程
- [ ] benchmark：高频网络下 `track_network_event` 锁等待时间降到 < 1ms p99
- [ ] 不破坏 `cache_response_body_payload` 的并发安全