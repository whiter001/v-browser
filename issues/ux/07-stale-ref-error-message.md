# [UX] snapshot 后导航使 `@eN` 引用过期，错误信息应明确提示

> 标签: `ux`, `P2`, `area/server`, `area/extension`
> 工作量: S
> 相关文件:
> - `packages/server/src/resolver.v:29-48` (`resolve_axref`)
> - `packages/server/src/axref.v:27-32` (`axref_clear`)
> - `packages/server/src/commands.v:519-538` (`clear_document_context` in cmd_open)

## 背景

`@eN` 引用在 snapshot 时建立，存到 `AxRefStore`。每次 `cmd_open` 会清空 store：

```v
fn clear_document_context(mut sess CdpSession) {
    sess.set_current_frame_selector('')
    axref_clear(mut sess.axref)
}
```

但 navigate 到同 tab 内新 URL（不切换 tab）时，`@eN` 已被 `clear_document_context` 清空。

## 问题描述

```bash
$ v-browser snapshot
@e1 [button] Sign in
@e2 [textbox] Email

$ v-browser open https://different.com   # 此时 axref store 被清空
$ v-browser click "@e1"
Error: click failed for selector @e1: 
  dom: element not found: @e1; 
  mouse: unknown ref @e1: run `v-browser snapshot` first
```

错误信息说"run snapshot first"，但用户**确实**刚 snapshot 过；只是中间导航了。同 tab 导航时 `@e1` 这种短引用没法恢复。

## 建议方案

把"stale reference"作为独立的错误码：

```
ERROR:STALE_REF:@e1 was captured for URL <old URL> before navigation to <new URL>; 
  run `v-browser snapshot` to refresh refs.
```

或者更简单——只在 `resolve_axref` 失败时把当前 URL 附上：

```v
fn resolve_axref(mut sess CdpSession, ref string) !ResolvedElement {
    r := axref_get(&sess.axref, ref) or {
        cur_url := eval_scoped_expression(mut sess, 'location.href', false) or { '<unknown>' }
        return error('unknown ref ${ref} (snapshot may be stale for current URL ${cur_url}); run `v-browser snapshot` to refresh')
    }
    ...
}
```

## 验收标准

- [ ] navigate 后 `click @eN` 返回的错误包含当前 URL
- [ ] 错误信息明确"stale snapshot"语义
- [ ] 跟 `error_suggestion` 集成：自动 hint `v-browser snapshot`
- [ ] 单测：mock 多次 snapshot / navigate 序列，验证错误信息

## 备注

如果在多个 tab 切换场景下能保留 `TabContext` 内的 axref 缓存（参见 #9），`@eN` 引用甚至可以在切回原 tab 后继续使用，但那是更大的改造；当前 issue 只解决"错误信息更清楚"。