# [UX] `snapshot --json` 结构化输出

> 标签: `ux`, `P2`, `area/cli`, `good-first-issue`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:1335-1393` (`cmd_snapshot`)
> - `packages/server/src/main.v:808-820` (`parse_cli_to_ipc snapshot`)

## 背景

`snapshot` 默认输出纯文本格式：

```
@e1 [button] Sign in
@e2 [textbox] Email
```

AI Agent 需要自己解析这格式，脆弱且容易因格式微调而崩溃。

## 建议方案

新增 `--json` 输出：

```json
{
  "version": 1,
  "url": "https://example.com/login",
  "title": "Sign in - Example",
  "refs": {
    "@e1": { "role": "button", "name": "Sign in", "selector": "button.submit", "backendNodeId": 123 },
    "@e2": { "role": "textbox", "name": "Email", "selector": "#email" }
  },
  "tree": [
    { "ref": "@e1", "role": "button", "name": "Sign in", "depth": 3, "children": [] }
  ],
  "stats": { "refCount": 24, "truncated": false }
}
```

CLI：

```bash
v-browser snapshot --json | jq '.refs["@e1"].selector'
```

## 验收标准

- [ ] `--json` 输出符合 schema（含 version 字段）
- [ ] `refs` 用 `@eN` 作 key 便于 O(1) 查询
- [ ] `tree` 保留层级结构
- [ ] `--json --maxNodes 5` 在 `stats.truncated=true`
- [ ] docs/snapshot.schema.json 提供 JSON Schema 校验
- [ ] 单测：JSON 输出格式稳定（用 snapshot test）

## 参考

- Playwright ARIA snapshot JSON
- Chrome DevTools Protocol Accessibility 原始 JSON