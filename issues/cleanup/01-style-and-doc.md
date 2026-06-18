# [Cleanup] L1-L20 风格/注释/死代码集中清理

> 标签: `cleanup`, `P3`, `good-first-issue`, `help-wanted`
> 工作量: M

## 范围

从代码审查中识别的风格/可读性问题，集中在一个 PR 里清理：

| # | 文件:行 | 描述 |
|---|---|---|
| L1 | `server.v:425` | 弱 token 的 TODO 注释替换为 issue 链接 |
| L2 | `ipc.v:34-73` | `ipc_decode_request` 手写 JSON 解析器换成 `x.json2` |
| L3 | `resolver.v:175-184` | `cdp_extract_float` 不识别科学计数法 |
| L4 | `commands.v:1487` | `cmd_get styles` 的 JS 写法 `el?JSON.stringify(...)` 错把 `?` 放在表达式前 |
| L5 | `commands.v:1487` | `exec_semantic_action` 部分 action 不消费 `value` 但仍透传 |
| L6 | `commands.v:2963` | `cmd_cookies` 帮助里说支持 `delete`，但实际未实现 |
| L7 | `cdp_session.v:1618-1631` | `json_str` 控制字符过滤改为 `\u00XX` 转义 |
| L8 | `commands.v:2962` | `cmd_cookies` setCookie 失败无细分错误 |
| L9 | `commands.v:3168` | `network watch` / `network hook` 子命令命名重叠 |
| L10 | `commands.v:3479` | `apply_hook_js_to_default_contexts` 串行可并发 |
| L11 | `commands.v:1701-1716` | `cmd_fill` frame 内分支错误信息不直观 |
| L12 | `server.v:179-203` | `ws.on_message_ref` 用 `unsafe voidptr(&s)` 与 `client_ptr` 风格不一致 |
| L13 | `commands.v:1289` | route spawn 闭包过大 |
| L14 | `commands.v:1150` | `screenshot_diff_js` 80 行内嵌 JS 没拆出来 |
| L15 | `extension/relayConnection.ts:341` | `_sendMessage` 非 OPEN 时静默丢错误 |
| L16 | `extension/background.ts:294-315` | `_onTabActivated` `for` 内 `return` 易误判 |
| L17 | `extension/connect.tsx:99` | `newTab` 模式下没有明确的"关闭连接"路径 |
| L18 | `extension/authToken.tsx:114-126` | `String.fromCharCode.apply` 大数组爆栈 |
| L19 | `test-ui/main.v:160-188` | `api_run` 直接 `os.execute` 子命令，沙箱外执行 |
| L20 | 全局 | CI 加 `v fmt --check` + `oxfmt --check` 校验 |

## 验收标准

- [ ] 所有 L 项修复
- [ ] 现有 1844 行 server_test.v 全部通过
- [ ] CI 加格式化校验
- [ ] 文档：CHANGELOG 记录本批清理

## 执行建议

- 按文件分批提交，每批 3–5 个 L 项
- 单独 PR 减少 review 负担
- 与功能 PR 解耦