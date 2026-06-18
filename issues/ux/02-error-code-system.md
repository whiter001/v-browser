# [UX] 错误码 + 文档链接 + next-step 建议

> 标签: `ux`, `P2`, `area/server`, `area/cli`
> 工作量: M
> 相关文件:
> - `packages/server/src/output.v:104-141` (`error_code`)
> - `packages/server/src/output.v:144-183` (`error_suggestion`)

## 背景

当前错误分类靠 substring 匹配，存在以下问题：
- "not found" 把 `xx.notfound.example.com` 这类 host 也归为 `NOT_FOUND`
- 多个模糊匹配可能互相覆盖
- 用户看不到错误码本身

## 建议方案

### 错误码规范化

```v
enum VBrowserError {
    unknown_command
    invalid_argument
    not_found
    not_connected
    auth_failed
    timeout
    ambiguous_match
    debugger_conflict
    verify_failed
    startup_failed
    connection_failed
    path_not_allowed
    session_closed
    tab_switched_away
    command_failed
}
```

### 错误输出格式

```
error[NOT_CONNECTED]: no extension connected
  → Run `v-browser connect` after loading the extension
  → Docs: https://v-browser.dev/err/NOT_CONNECTED
```

### 实现

1. 业务命令返回结构化 error：
   ```v
   struct CommandError {
       code    VBrowserError
       message string
       hint    string
       docs    string
   }
   ```
2. `cmd_xxx` 函数从 `string` 改为 `!CommandError`。
3. `print_error` 渲染 `[CODE]: message \n  → hint \n  → Docs: URL`。
4. `--json` 模式输出 `{"ok":false,"error":{"code":"NOT_CONNECTED","message":"...","hint":"...","docs":"..."}}`。

## 验收标准

- [ ] 14 个错误码覆盖现有所有 `ERROR:` 前缀
- [ ] 每个错误码对应一个 docs 页面（`docs/errors/<CODE>.md`）
- [ ] `v-browser --json` 输出包含 code 字段
- [ ] 兼容现有 substring 匹配（渐进式迁移）
- [ ] 单测：每个错误码至少一个用例

## 参考

- HTTP status codes: 标准化错误码
- GitHub API errors: `{message, documentation_url, errors}`