# [UX] `v-browser --doctor` 一键自检

> 标签: `ux`, `P2`, `area/cli`, `good-first-issue`
> 工作量: M
> 相关文件:
> - `packages/server/src/server.v:248-272` (`run_ipc_server`)
> - `packages/server/src/main.v:249-273` (`ensure_server_running`)

## 背景

新用户报错时最大的痛点：不知道是 server 没启、token 不对、扩展没装、还是 tab 选错。

错误信息散落各处（"no extension connected"、"cdp session is closed"），缺乏统一诊断入口。

## 建议方案

新增 `v-browser doctor`（或 `--doctor` flag），逐项检查：

```
$ v-browser doctor
✓ CLI version 0.1.0
✗ Server not running
   → Run: v-browser server start
   → Or:  v-browser connect  (auto-start)
✓ IPC port 47979 listening
✗ Token file missing
   → Run: v-browser connect  (auto-create)
✓ Extension ID recorded: eefgklfpdnjodmmjefedjfnflacaimmj
✗ Extension not connected
   → Open Chrome with extension loaded, then visit:
     chrome-extension://eefgklfpdnjodmmjefedjfnflacaimmj/connect.html
✓ Tab attached (windowId=1234, tabId=5678)
✓ Page enabled (Network + DOM)
```

检查项：
1. CLI 版本
2. server 进程 + 版本
3. IPC 端口可达
4. token 文件存在
5. extension ID 已记录
6. extension 已连接
7. CDP session attached 到某 tab
8. `Page.enable` / `Network.enable` 已下发
9. 最近一次 CDP 命令 < 5s 内成功

## 验收标准

- [ ] 每项输出 ✓ / ✗ + 修复建议
- [ ] `--json` 输出结构化报告
- [ ] 非交互环境可用 `v-browser doctor --no-color`
- [ ] 集成进 `v-browser --help` 输出
- [ ] 单测：mock server/extension 各种状态

## 参考

- `flutter doctor`
- `brew doctor`