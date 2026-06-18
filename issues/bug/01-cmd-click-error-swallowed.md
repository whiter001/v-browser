# [Bug] `cmd_click/dblclick/hover` 内层 fallback 报错被外层吞掉

> 标签: `bug`, `P0`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:1607-1619` (`cmd_click`)
> - `packages/server/src/commands.v:1622-1632` (`cmd_dblclick`)
> - `packages/server/src/commands.v:1661-1671` (`cmd_hover`)

## 问题描述

```v
// commands.v:1615-1618
run_element_action(mut sess, sel, build_click_action_body()) or {
    pointer_action_for_selector(mut sess, sel, 'click') or { return 'ERROR:${err}' }
}
return 'null'
```

控制流：
- 假设 `run_element_action` 失败 → 进入外层 `or` 块
- 块内调用 `pointer_action_for_selector`，
  - **若它成功**（返回 `void`），外层 `or` 块什么都不返回，函数继续往下走 → `return 'null'` ✅ 看上去正常
  - **若它失败**，`or { return 'ERROR:${err}' }` 抛出 → 函数退出 ✅

听起来对，但**真实 bug**在于：
- 内层 `pointer_action_for_selector` 即使最终失败（如 mouseMoved 报错），由于它内部已经 fallback 处理过一层错误并返回 `void`，外层以为成功。
- 实际行为：第一次 `run_element_action` 失败 → 走 mouse 路径 → mouse 也失败但函数仍返回 `'null'`，调用方以为点击成功。

## 复现步骤

```bash
# 关闭 page javascript 后再 click
v-browser eval 'document.documentElement.style.pointerEvents = "none"'
v-browser eval 'delete window.HTMLAnchorElement.prototype.click'
v-browser click "#some-link"
# 期望：ERROR: ... (实际：null)
```

## 建议方案

把内层 `or` 改成显式 propagate：

```v
pointer_action_for_selector(mut sess, sel, 'click') or {
    return 'ERROR:${err}'
}
return 'null'
```

或者统一抽出：

```v
fn click_with_fallback(mut sess CdpSession, sel string) string {
    run_element_action(mut sess, sel, build_click_action_body()) or {
        return pointer_action_for_selector(mut sess, sel, 'click').str()
    }
    return 'null'
}
```

`cmd_dblclick` / `cmd_hover` 同样问题。

## 验收标准

- [ ] 所有 `cmd_click/dblclick/hover/focus/check/uncheck` 在两层 fallback 都失败时返回 `ERROR:...`
- [ ] 加单测：mock 一个 `run_element_action` 必失败 + `pointer_click` 必失败的 session，验证返回 `ERROR:`
- [ ] help 中明确"click 失败 = error"