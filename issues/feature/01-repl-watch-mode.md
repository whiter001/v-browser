# [Feature] `v-browser repl` 长连接 + `--watch` 持续输出

> 标签: `feature`, `P1`, `area/cli`, `good-first-issue`
> 工作量: L
> 相关文件:
> - `packages/server/src/main.v:1519-1574` (`send_ipc_internal`)
> - `packages/server/src/server.v:248-272` (`run_ipc_server`)

## 背景

当前每条 CLI 命令都要：
1. fork `v-browser` 进程（~50ms）
2. 读 IPC port 文件
3. TCP 连接（~5ms）
4. 发送 + 等待响应
5. 关闭

AI Agent 把 CLI 当 LLM tool 时，单条命令 250ms+ 延迟里只有 30ms 是真实工作。

## 建议方案

### `v-browser repl`
启动一个 readline 循环，复用当前 server session：

```
$ v-browser repl
v-browser> snapshot --extra --maxNodes 20
@e1 [button] Sign in
@e2 [textbox] Email
v-browser> click @e1
v-browser> eval document.title
"Sign in - Example"
v-browser> exit
```

实现：
- 新增 `cmd = 'repl'` 分支
- 用 V 标准库的 `readline`（或 `bufio.Scanner`）
- 每行解析为 IPC 请求，复用 `send_ipc_internal` 逻辑（直接调用 server API 而不走 TCP）
- 上下方向键 / Ctrl-R 历史（readline 内置）

### `v-browser --watch <method> --every 2s`
持续输出某个命令的结果，每 N 秒：

```bash
v-browser --watch eval --every 5s 'document.title'
"GitHub - Page A"
"GitHub - Page A"
"GitHub - Page B"  ← 检测到变化
```

### 收益

- REPL 模式：单条命令延迟 **~30ms**（vs 250ms），提升 ~8×
- Watch 模式：替代 `while true; do v-browser ...; sleep 5; done` 的低效脚本

## 验收标准

- [ ] `v-browser repl` 启动后能持续执行命令
- [ ] `--watch` 每 N 秒输出，Ctrl-C 退出
- [ ] readline 历史保存到 `~/.v-browser/repl_history`
- [ ] 文档：README 增加 REPL 使用示例
- [ ] 现有 CLI 命令完全兼容（repl 内部就是循环 parse + send）

## 参考

- Playwright CLI: 没有 REPL，但 Python/JS SDK 有
- iPython / httpie: REPL 设计灵感