# [Bug/Security] `cmd_open` / `wait_load` 等 select 分支静默吞掉超时

> 标签: `bug`, `P0`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:526-529` (`cmd_open`)
> - `packages/server/src/commands.v:1011-1014`, `1022-1025`, `1038-1040` (`wait_for_navigation_state`)
> - `packages/server/src/commands.v:1074-1078` (`navigate_and_wait`)
> - `packages/server/src/commands.v:2216-2222` (`wait_load`)

## 背景

V 的 `select` 用于多通道监听。所有 `case` 表达式必须是编译期常量。常见模式：

```v
select {
    _ := <-ch {}
    30 * time.second {}    // ← timeout 分支无任何处理
}
```

## 问题描述

30 秒后 select 仍然往下走，函数返回 `'null'` / `"success"`，**调用方不知道页面没加载完**就继续发命令。

涉及至少 5 处：

```v
// commands.v:526-529
select {
    _ := <-load_ch {}
    30 * time.second {}
}
clear_document_context(mut sess)
return json_str('navigated to ${url}')   // 即使页面还在 spinner
```

```v
// commands.v:1074-1078
select {
    _ := <-ch {}
    30 * time.second {
        return error('CDP ${method} timed out (30s)')  // 这个有 return — 但其他几处没有
    }
}
```

> `send_command_to` 系列在 cdp_session.v:313-326 有 return error，但 `wait_load` / `cmd_open` / `navigate_and_wait` 直接吞。

## 复现步骤

1. `v-browser open https://httpbin.org/delay/60`
2. 服务端 30s 后仍然返回 `"navigated to ..."`
3. 立刻 `v-browser eval document.title` → 拿到 loading 中或空白页的 title

## 建议方案

把所有 `30 * time.second {}` 替换为显式返回错误：

```v
select {
    _ := <-ch {}
    30 * time.second {
        return error('timeout waiting for ${event}')
    }
}
```

把 `cdp_default_timeout` 常量从 60s 提取到统一 config（`v_browser_timeout`），方便统一调整。

## 验收标准

- [ ] 所有 `select` timeout 分支都有 `return error(...)`
- [ ] `cmd_open` 加载失败返回 `ERROR:timeout waiting for Page.loadEventFired`
- [ ] 加单测：mock 永不触发 load_event，验证 30s 后报错（可用更短 timeout）
- [ ] 文档：help 增加 `--timeout` flag 的说明（目前仅个别命令支持）

## 参考

- V select 文档：https://github.com/vlang/v/blob/master/doc/docs.md#select