# [Feature] 接受 stdin JSON-lines 批量命令

> 标签: `feature`, `P1`, `area/cli`, `area/server`
> 工作量: L
> 相关文件:
> - `packages/server/src/server.v:248-305` (`run_ipc_server`)
> - `packages/server/src/main.v:30-118` (`main`)

## 背景

批量操作场景：
- 100 次 `click` + 100 次 `eval`，当前需要 200 次 fork+IPC。
- 一次 IPC ~5–10ms，200 次 = 1–2s 纯 IPC 开销。

## 建议方案

新增 `v-browser script` 子命令，stdin 读 JSON lines，每行一个命令：

```bash
cat <<EOF | v-browser script
{"method":"open","params":{"url":"https://example.com"}}
{"method":"snapshot","params":{"maxNodes":10}}
{"method":"click","params":{"selector":"@e1"}}
EOF
```

server 端：
- 新增 `script` 路由
- 在 `handle_ipc_client` 内 for-loop 读多行
- 每条请求独立 dispatch，但**复用同一 session**（无需 re-attach）

响应也以 JSON lines 输出，client 按行读。

### 变体：`v-browser script --file script.jsonl`

## 验收标准

- [ ] 100 条命令批量执行总延迟 < 3s（含实际 CDP 操作）
- [ ] 单条命令失败不影响后续（错误单独打印）
- [ ] 支持 `--stop-on-error` 提前终止
- [ ] 文档：示例展示批量上传 + 验证场景
- [ ] 单测：mock server 接收 N 条 JSON lines，验证 N 次 dispatch

## 参考

- jq: JSON pipeline
- curl --data-binary @-: 多 URL 批量