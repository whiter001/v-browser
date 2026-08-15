# [Bug] macOS 上 `sync.Mutex` 结构体字段未初始化，完全不互斥

> 标签: `bug`, `P0`, `area/server`
> 工作量: S
> 状态: ✅ 已修复（`new_cdp_session` / `new_server` 显式 init，待提交）
> 相关文件:
>
> - `packages/server/src/cdp_session.v` (`new_cdp_session`，8 个 Mutex 字段)
> - `packages/server/src/server.v` (`new_server`，ext_mu)
> - `packages/server/src/axref.v` (`AxRefStore.mu`)

## 背景

排查 #23 的并发测试偶发失败与段错误（`map_set` / `DenseArray_delete` /
`Channel_try_push_priv`）时定位到此根因。

## 问题描述

V 的 `sync.Mutex` 作为结构体字段时不会被自动初始化（vlib 的
`init_with` 支持仍是 TODO）。各平台表现：

- **Linux**：全零 `pthread_mutex_t` 恰好等于 `PTHREAD_MUTEX_INITIALIZER`，
  正常工作，问题被掩盖
- **macOS**：Darwin 静态初始化器含非零签名，全零 mutex 非法，
  `pthread_mutex_lock` 静默失败 → **完全不互斥**

后果：所有"加锁保护"的临界区实际裸奔，出现 map 瞬时 lookup 丢失、
写撕裂、偶发段错误。影响面覆盖 `CdpSession` 全部 8 个 mutex、
`VBrowserServer.ext_mu`、`AxRefStore.mu`。

最小复现与完整分析见 `docs/upstream-issue-v-sync-mutex-darwin.md`，
已提交上游：<https://github.com/vlang/v/issues/28091>。

## 修复方案

所有含 `sync.Mutex` 字段的结构体，在构造函数里对每个字段显式 `.init()`：

```v
mut s := &CdpSession{ ... }
s.pending_mu.init()
s.event_mu.init()
// ... 其余字段
return s
```

## 验收标准

- [x] `new_cdp_session` init 全部 9 个 mutex（含 `axref.mu`）
- [x] `new_server` init `ext_mu`
- [x] 回归测试：双线程 10 万次撕裂读检测（init 被回退时 macOS 必挂）
- [x] `v test ./src` 连续两轮全绿

## 防范规则

已写入 `AGENTS.md`：新增 `sync.Mutex` 字段必须在构造函数显式 `init()`。
`sync.RwMutex` 自带 `lazy_init`，不受此影响。
