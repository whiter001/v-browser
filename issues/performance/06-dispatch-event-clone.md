# [Perf] `dispatch_event` 每次都 `clone()` 订阅者列表

> 标签: `performance`, `P1`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/cdp_session.v:857-868` (`dispatch_event`)
> - `packages/server/src/cdp_session.v:866-889` (`subscribe` / `unsubscribe`)

## 背景

`dispatch_event` 是每个 CDP event 进来时必走的 hot path：找到订阅这个 method 的 channel 列表，把事件投递过去。

## 问题描述

```v
fn (mut s CdpSession) dispatch_event(method string, evt ProtocolResponse) {
    s.event_mu.@lock()
    subs := if method in s.event_subs {
        s.event_subs[method].clone()        // ← 每次都克隆整条数组
    } else {
        []chan ProtocolResponse{}
    }
    s.event_mu.unlock()
    for sub in subs {
        sub <- evt
    }
}
```

- 每个 CDP event 都克隆一次订阅者数组
- `subscribe` / `unsubscribe` 都需要遍历数组
- 在高流量场景下（推特时间线、监控页），每秒可达几百个 Network.* events → 几百次 `clone()`

`subscribe` / `unsubscribe` 也会遍历：

```v
fn (mut s CdpSession) unsubscribe(method string, ch chan ProtocolResponse) {
    s.event_mu.@lock()
    defer { s.event_mu.unlock() }
    if method in s.event_subs {
        mut filtered := []chan ProtocolResponse{}
        for c in s.event_subs[method] {
            if c != ch {
                filtered << c
            }
        }
        s.event_subs[method] = filtered   // ← 每次 unsubscribe 也全量复制
    }
}
```

## 量化预估

V 的 `[]chan` clone 是逐元素浅拷贝：
- 单次 clone：~100ns + N×50ns（chan 引用拷贝）
- 100 events/s × 5 subscribers × 100ns ≈ 50μs/s CPU（占空载 0.05% — 不大）
- 高峰 1000 events/s 时 ~500μs/s
- 但和高频 Network.* events 一起放大后可见

不算顶级 hot path，但和 #23（spawn 风暴）+ #35（substring 解析）叠加后影响明显。

## 建议方案

去掉 clone，**直接在锁内迭代**：

```v
fn (mut s CdpSession) dispatch_event(method string, evt ProtocolResponse) {
    s.event_mu.@lock()
    defer { s.event_mu.unlock() }
    if method in s.event_subs {
        for sub in s.event_subs[method] {
            sub <- evt   // 在锁内 send，非阻塞（channel cap > 1）
        }
    }
}
```

`chan cap=32` 的 send 在 buffer 未满时是非阻塞的，所以锁持有时间极短（只是写入 buffer 指针）。V stdlib 的 sync.Mutex 是非公平锁，短临界区不会饿死其他 goroutine。

`unsubscribe` 同样优化：先找到下标，再 swap-remove：

```v
fn (mut s CdpSession) unsubscribe(method string, ch chan ProtocolResponse) {
    s.event_mu.@lock()
    defer { s.event_mu.unlock() }
    if method in s.event_subs {
        mut subs := &s.event_subs[method]
        for i, c in subs {
            if c == ch {
                subs.delete(i)
                break
            }
        }
    }
}
```

## 验收标准

- [ ] `dispatch_event` 不再 clone 订阅者数组
- [ ] `unsubscribe` 用 delete + break 而不是过滤拷贝
- [ ] 单测覆盖：dispatch 后事件到达所有订阅者；unsubscribe 后订阅者数量正确
- [ ] benchmark：1k events × 5 subscribers 下 CPU 时间下降 ≥2×

## 备注

不是顶级 hot path 但属于"很容易顺手做掉"的优化。建议合并到 #23（spawn 风暴）或单独 PR。

关联 issue：#23 (network spawn storm), #35 (cdp msg json decode)