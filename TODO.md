# v-browser 实施 TODO

> 目标：用 V 语言实现 v-browser-server（中继服务）和 v-browser CLI，配合现有浏览器扩展，通过 CDP 完整实现所有浏览器自动化命令。

---

## 架构概览

```text
v-browser CLI (V)
    │  Unix socket JSON-RPC  (~/.v-browser/server.sock)
    ▼
v-browser-server (V daemon)
    │  WebSocket (127.0.0.1:47978，扩展现有协议不变)
    ▼
Chrome Extension (TS，现有代码微调)
    │  chrome.debugger API
    ▼
Chrome Tab (CDP 1.3)
```

---

## Phase 0 · 扩展侧适配

- [x] **P0-1** `manifest.json` 添加 `"scripting"` 权限
- [x] **P0-2** 确认 `connect.tsx` token 自动接受逻辑（URL 参数 `?token=` 匹配 localStorage 时无需手动点击）
- [x] **P0-3** token 文件机制：server 启动时生成/读取 `~/.v-browser/token`，并在打开 connect.html 时注入 URL

---

## Phase 1 · Server 骨架（管道打通）

- [x] **P1-1** 建立 `packages/server/` V 项目结构（`v.mod` + 目录骨架）
- [x] **P1-2** `server.v`：WebSocket server 监听 `127.0.0.1:47978`，接受扩展连接，验证 auth token
- [x] **P1-3** `cdp/session.v`：CDP 命令发送器（原子 id 计数、`send_command` 阻塞等待响应、事件分发 chan）
- [x] **P1-4** `ipc.v`：CLI↔Server JSON-RPC 通道（当前为本地 TCP + sock 文件记录端口，非 Unix socket）
- [x] **P1-5** `main.v`：CLI 入口，检测服务可用性，不可用则自动启动 daemon；`v-browser server` 前台启动命令
- [x] **P1-6** 验收：`v-browser connect` 成功 attach，`v-browser eval "document.title"` 返回标题

---

## Phase 2 · CDP 核心层

- [ ] **P2-1** `cdp/types.v`：关键域 V struct 定义（Page / Runtime / DOM / Input / Accessibility / Target / Fetch / Network / Storage）
- [x] **P2-2** `cdp/events.v`：事件总线，按 method 分发到订阅 chan（已覆盖当前实现所需事件）
- [x] **P2-3** `selectors/axref.v`：`@eN` ↔ `backendNodeId` 映射表（server 内存，跨命令保持）
- [x] **P2-4** `selectors/resolver.v`：统一选择器解析（@eN → CSS/XPath → 语义，输出坐标 + backendNodeId）

---

## Phase 3 · 核心命令

- [x] **P3-1** `commands/navigate.v`：`open`、`close`、`tab list/new/switch/close`、`window new`
- [x] **P3-2** `commands/page.v`：`screenshot`（当前支持 `--full`，`--annotate` 仍单列在 P6-1）、`pdf`、`snapshot`（AX tree + @eN 生成）、`eval`
- [x] **P3-3** `commands/input.v`：`click`、`dblclick`、`fill`、`type`、`keyboard type/inserttext`、`press`/`keydown`/`keyup`、`hover`、`scroll`/`scrollintoview`、`drag`、`upload`、`select`、`check`/`uncheck`、`focus`
- [x] **P3-4** 验收：`docs/v-browser.md` 快速开始主路径命令已可用

---

## Phase 4 · 扩展命令

- [x] **P4-1** `commands/query.v`：`get text/html/value/attr/title/url/count/box/styles`、`is visible/enabled/checked`
- [x] **P4-2** `commands/wait.v`：`wait <sel>`、`wait <ms>`、`wait --text`、`wait --url`、`wait --load`、`wait --fn`
- [x] **P4-3** `find role/text/label/placeholder/alt/title/testid/first/last/nth`：语义定位器与 positional CLI 语法已补齐
- [x] **P4-4** `commands/storage.v`：`cookies`（get/set/clear）、`storage local/session`（get/set/clear）
- [x] **P4-5** 鼠标控制：`mouse move/down/up/wheel`
- [x] **P4-6** 对话框：`dialog accept/dismiss`
- [x] **P4-7** 框架：`frame <sel>`、`frame main`（当前支持同源 iframe / `srcdoc` 场景）

---

## Phase 5 · 高级功能

- [x] **P5-1** `commands/network.v`：`route`（Fetch.enable + requestPaused）、`route --abort`、`route --body`、`unroute`、`network requests`（请求日志缓存 + `--filter`）
- [x] **P5-2** `commands/debug.v`：`trace start/stop`、`profiler start/stop`、`console`（get/clear）、`errors`（get/clear）、`highlight`
- [x] **P5-3** 浏览器设置：`set viewport/device/geo/offline/headers/credentials/media`
- [x] **P5-4** `diff snapshot`：连续两次 snapshot 文本对比（文本 diff 输出）
- [ ] **P5-5** `diff screenshot`：逐像素对比 + 生成差异图（stb_image_write C binding）
- [ ] **P5-6** `diff url`：打开两个 tab 各自 snapshot/screenshot → 对比
- [x] **P5-7** `state save/load/list/show/rename`：认证状态（cookies + localStorage）序列化到文件

---

## Phase 6 · 收尾

- [ ] **P6-1** `screenshot --annotate`：截图 + AX tree boundingBox → 叠加编号标签（stb_truetype C binding）
- [x] **P6-2** `output.v`：统一结果格式化（`--json` 输出模式、错误码规范）
- [x] **P6-3** E2E 集成测试（基于 Playwright 驱动 v-browser CLI）
- [x] **P6-4** 更新 `docs/v-browser.md` / `README.md`，补充安装、构建、连接与测试说明

---

## 关键技术决策

| 决策点 | 选择 |
| ------ | ---- |
| CLI↔Server IPC | 本地 TCP + JSON-RPC（sock 文件记录端口） |
| CDP 响应等待 | `chan` + deadline timeout（默认 30s） |
| @eN 引用存储 | server 内存 `map[string]int`（backendNodeId） |
| auth token | `~/.v-browser/token` 文件，CLI/server 共享 |
| 全页截图 | `Page.captureScreenshot {captureBeyondViewport: true}` |
| 事件等待 | 订阅 CDP 事件 chan，select + timeout |
| 选择器优先级 | `@eN` > CSS/XPath > 语义定位器 |
