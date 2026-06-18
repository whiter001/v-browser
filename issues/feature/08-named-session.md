# [Feature] `session create/use` 支持多 tab 并行

> 标签: `feature`, `P2`, `area/server`
> 工作量: XL
> 相关文件:
> - `packages/server/src/server.v:138-154` (`VBrowserServer`)
> - `packages/server/src/cdp_session.v:189-228` (`CdpSession`)

## 背景

当前 `VBrowserServer` 只持有一个 `ext_conn` + 单个 `CdpSession`。多 tab 需要在 `CdpSession` 内通过 `TabContext` 模拟隔离（已经部分实现）。

但 CLI 调用没有"当前 session"概念，每次只能操作默认 tab。

## 建议方案

### Server 端：多 Session

```v
struct VBrowserServer {
    ext_conn ?&ExtensionConn
    ext_mu   sync.Mutex
    sessions map[string]&CdpSession  // name → session
}
```

每个 session 独立 axref / network / hook / console / runtime_context。

### CLI 端：

```bash
v-browser session create dev1 --tab-id 12
v-browser session create dev2 --tab-id 34
v-browser --session dev1 open https://github.com
v-browser --session dev2 open https://example.com
v-browser --session dev1 snapshot
v-browser session list
v-browser session close dev1
```

## 验收标准

- [ ] 多个 session 并行操作不互相干扰（独立 axref / network buffer）
- [ ] 切换 session 是 O(1)
- [ ] server 重启后 session list 持久化到 `~/.v-browser/sessions.json`
- [ ] 单测：两个 session 同时 snapshot，验证 axref 互不污染
- [ ] 文档：多 tab 自动化场景示例

## 参考

- Playwright BrowserContext
- tmux session 命名模型