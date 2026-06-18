# [Perf] `pointer_action_for_selector` 重复 resolve 元素坐标 2~3 次

> 标签: `performance`, `P1`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:294-304` (`pointer_action_for_selector`)
> - `packages/server/src/commands.v:259-268` (`scroll_resolved_element_into_view`)

## 背景

```v
fn pointer_action_for_selector(mut sess CdpSession, sel string, action string) ! {
    mut el := resolve_selector(mut sess, sel)!           // ← resolve #1
    scroll_resolved_element_into_view(mut sess, sel, el)!
    el = resolve_selector(mut sess, sel) or { el }      // ← resolve #2 (scroll 后重读)
    match action {
        'click' { pointer_click(mut sess, el.x, el.y, 1)! }
        ...
    }
}
```

`resolve_selector` = 1 次 `Runtime.evaluate`（含 `getBoundingClientRect` + `DOM.requestNode` + `DOM.describeNode`，可能 2~3 次 CDP round-trip）。

`scroll_resolved_element_into_view` 在 backendNodeId 存在时调 `DOM.scrollIntoViewIfNeeded`（1 次），否则 `evaluate_bool_js`（1 次）。

## 问题描述

每次 click：
- resolve #1：1 次 evaluate + 1 次 DOM.requestNode + 1 次 DOM.describeNode ≈ 3 次 CDP round-trip
- scrollIntoViewIfNeeded：1 次 round-trip
- resolve #2：再 3 次 round-trip
- pointer_click：2 次 round-trip（move + down + up）

**合计：~9 次 round-trip**，其中 6 次都是为获取坐标。

## 量化收益

每次 click 节省 **150–250ms**（LAN：~30ms/round-trip × 6）。

## 建议方案

合并为单次 eval：

```v
fn build_action_point_query_js(mut sess CdpSession, sel string) string {
    return build_element_scope_js(mut sess, sel, '
        el.scrollIntoView({block:"center",inline:"center"});
        var s = win.getComputedStyle(el);
        if (s.visibility === "hidden" || s.display === "none") return null;
        if ("disabled" in el && el.disabled) return null;
        var r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return null;
        if (frame) {
            var fr = frame.getBoundingClientRect();
            return { x: fr.x + r.x + r.width/2, y: fr.y + r.y + r.height/2, w: r.width, h: r.height };
        }
        return { x: r.x + r.width/2, y: r.y + r.height/2, w: r.width, h: r.height };
    ')
}
```

然后 `pointer_action_for_selector` 简化为一次 eval + 一次 click。

## 验收标准

- [ ] `cmd_click` 平均延迟下降 ≥ 100ms（CI benchmark）
- [ ] 单测：覆盖 sticky 元素（需 scroll 后才能点）
- [ ] 不破坏 fallback 到 CDP mouse 的逻辑