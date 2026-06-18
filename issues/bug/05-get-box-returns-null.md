# [Bug] `get box <selector>` 对不存在的元素返回 `'null'` 而非错误

> 标签: `bug`, `P1`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:2010-2053` (`cmd_get`)
> - `packages/server/src/resolver.v:51-79` (`resolve_css`)

## 背景

`cmd_get` 在 `box` 分支直接复用 `build_rect_query_js`，该 JS 内部返回 `null` 表示"元素不存在"。

## 问题描述

```bash
$ v-browser get box "#non-existent"
null
```

期望：返回 `ERROR:element not found: #non-existent`，跟 `cmd_click`、`cmd_is` 行为一致。

实际：返回 `null` 字面量，调用方很难区分"元素存在但 bounding rect 为 0"和"元素根本不存在"。

## 复现步骤

```bash
v-browser open https://example.com
v-browser get box "#nonexistent"
# 实际: null
# 期望: ERROR:element not found: #nonexistent
```

## 建议方案

`cmd_get` 的 `box` 分支单独调用 `resolve_selector`（它会显式 error），失败时把错误返回：

```v
'box' {
    if sel == '' {
        return 'ERROR:missing selector'
    }
    el := resolve_selector(mut sess, sel) or {
        return 'ERROR:${err}'
    }
    return json_str('{"x":${el.x},"y":${el.y},"width":${el.width},"height":${el.height}}')
}
```

或者在 `build_rect_query_js` 返回 null 时由 `cmd_get` 兜底：

```v
'box' {
    js := build_rect_query_js(mut sess, sel)
    resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
    result_obj := cdp_extract_obj_key(resp.result, '"result":')
    value_obj := cdp_extract_obj_key(result_obj, '"value":')
    if value_obj == '' || value_obj == 'null' {
        return 'ERROR:element not found: ${sel}'
    }
    return json_str(value_obj)
}
```

## 验收标准

- [ ] `v-browser get box "#nonexistent"` 返回 `ERROR:element not found: #nonexistent`
- [ ] `v-browser get box "#existing"` 返回 `{"x":..,"y":..,"width":..,"height":..}`
- [ ] 跟 `cmd_click` 等的错误格式保持一致
- [ ] 单测覆盖：存在元素 / 不存在元素两条路径