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
- [x] **P3-2-Patch** `snapshot` 性能优化：默认极速模式、strings.Builder 优化内存、JS 扫描熔断、maxNodes 参数支持
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

## Phase 7 · 网络资源导出

- [x] **P7-1** 复用 CDP `Network.getResponseBody`，补齐请求响应体的字节级读取能力
- [x] **P7-2** `commands/network.v`：新增 `save`，支持按 `requestId` 将响应体保存到本地路径
- [x] **P7-3** `commands/network.v`：根据 `content-type` / URL / requestId 自动补全默认文件名与扩展名
- [x] **P7-4** `main.v`：CLI 参数解析支持 `v-browser network save <requestId> <path>`
- [x] **P7-5** `network save-all-images`：自动筛选当前页面图片请求并批量导出到目录
- [x] **P7-6** `network watch`：监听页面网络事件并按规则自动转发到 server 落盘
- [x] **P7-7** 文档补充：X / Twitter 图片抓取与保存流程示例

---

## 关键技术决策

| 决策点         | 选择                                                   |
| -------------- | ------------------------------------------------------ |
| CLI↔Server IPC | 本地 TCP + JSON-RPC（sock 文件记录端口）               |
| CDP 响应等待   | `chan` + deadline timeout（默认 30s）                  |
| @eN 引用存储   | server 内存 `map[string]int`（backendNodeId）          |
| auth token     | `~/.v-browser/token` 文件，CLI/server 共享             |
| 全页截图       | `Page.captureScreenshot {captureBeyondViewport: true}` |
| 事件等待       | 订阅 CDP 事件 chan，select + timeout                   |
| 选择器优先级   | `@eN` > CSS/XPath > 语义定位器                         |
| 网络资源导出   | 页面侧抓请求，server 侧按 `requestId` 统一落盘         |

---

## Phase 8 · 实战站点验证与迭代

> 目标：用真实网站和高覆盖 fixture 逐项验证 v-browser 的实际适用性，按失败类型补优化，再回到同一批场景复测，直到常见自动化场景都稳定可用。

### 8.1 站点分层

- [ ] **P8-1** 基础交互站点：`the-internet.herokuapp.com`、`uitestingplayground.com`、`testpages.eviltester.com`、`selenium.dev` 表单页
- [ ] **P8-2** 真实业务站点：GitHub 仓库页、Issues、PR、Actions；X / Twitter 帖子页和个人主页；中文内容站点和文档站点
- [ ] **P8-3** 高风险场景站点：公开表单、iframe / 编辑器 demo、长列表 / 无限滚动页面、电商 demo、公开视频页

### 8.2 能力逐项验证

- [ ] **P8-4** 导航与连接：`connect`、`open`、`status`、`tab`、`window`、重连和错误诊断
- [ ] **P8-5** 定位与点击：`snapshot`、`find`、`click`、`hover`、重复按钮消歧、隐藏元素排除
- [ ] **P8-6** 输入与表单：`fill`、`type`、`keyboard`、`select`、`check`、`uncheck`、受控输入和富文本输入
- [ ] **P8-7** 结构化交互：`frame`、`dialog`、`upload`、`drag`、`scroll`、`scrollintoview`
- [ ] **P8-8** 数据与状态：`get`、`wait`、`cookies`、`storage`、`network requests`、`route`、`save`、`state`
- [ ] **P8-9** 调试闭环：`screenshot`、`console`、`errors`、`trace`、`profiler`、`--json` 输出

### 8.3 逐站执行流程

- [ ] **P8-10** 先跑基础 fixture，确认核心命令无回退，再进入真实站点
- [ ] **P8-11** 每个站点先做只读验证：标题、正文、链接、快照、截图、网络可见性
- [ ] **P8-12** 每个站点再做交互验证：点击、输入、提交、上传、对话框、滚动、iframe
- [ ] **P8-13** 对每个失败点记录症状、复现命令、错误输出、页面状态和修复建议
- [ ] **P8-14** 每修复一类问题，回到同一站点复测，确认不是局部修补

### 8.4 优化闭环

- [ ] **P8-15** 把高频失败归类到连接、定位、输入、异步等待、iframe、dialog、上传、网络、调试九类
- [ ] **P8-16** 为每类失败补最小回归案例，优先放进 `packages/test-ui` 和现有 smoke 脚本
- [ ] **P8-17** 更新错误提示和 JSON 输出，让失败时能直接给出下一步操作建议
- [ ] **P8-18** 复测通过后再扩展站点范围，优先覆盖桌面 Web 的常见交互模式
- [ ] **P8-19** 定期回顾 TODO，删除已被更强回归覆盖的临时检查项，保留长期价值的验证项

### 8.5 执行拆解

- [ ] **P8-20** 先跑 fixture 基线：`open`、`snapshot`、`find`、`click`、`fill`、`upload`、`frame`、`dialog`、`network`
- [ ] **P8-21** 再跑基础站点：表单页、按钮页、列表页、弹窗页、上传页、iframe 页
- [ ] **P8-22** 然后跑真实站点读操作：标题、正文、链接、图片、按钮、导航、分页
- [ ] **P8-23** 接着跑真实站点写操作：登录、搜索、评论、提交表单、上传附件、保存草稿
- [ ] **P8-24** 最后跑高风险站点：动态加载、重复按钮、复杂嵌套、跨区域滚动、长任务等待

### 8.6 单站点验证模板

- [ ] **P8-25** 记录站点名称、URL、登录状态、是否允许公开访问、是否需要已有 cookie
- [ ] **P8-26** 记录读操作结果：`title`、页面正文、关键元素快照、截图、网络请求摘要
- [ ] **P8-27** 记录写操作结果：输入内容、点击结果、提交结果、URL 变化、页面状态变化
- [ ] **P8-28** 记录失败信息：命令、错误码、截图、console、errors、network、复现步骤
- [ ] **P8-29** 记录修复建议：是定位问题、等待问题、输入问题、frame 问题、dialog 问题，还是站点限制
- [ ] **P8-30** 记录是否需要新增 fixture、是否需要新增回归、是否需要更新文档示例

### 8.7 首批执行顺序

- [ ] **P8-31** 先验证 `the-internet.herokuapp.com` 的基础交互链路
- [ ] **P8-32** 再验证 `uitestingplayground.com` 的定位消歧和动态 DOM 场景
- [ ] **P8-33** 再验证 `testpages.eviltester.com` 的 dialog、frame、upload、storage 场景
- [ ] **P8-34** 再验证 `selenium.dev` 表单页的标准输入和提交流程
- [x] **P8-35** 再验证 GitHub 公共页和 X / Twitter 公共页的真实 SPA 场景
- [x] **P8-36** 再验证一个公开表单站点、一个 iframe demo、一个长列表站点、一个电商 demo

### 8.8 实测观察

- [x] **P8-37** X 搜索页上，`find role tab click --name` 可稳定切换 `最新`、`用户` 这类结果分类
- [x] **P8-38** `the-internet.herokuapp.com/add_remove_elements/` 上，`find text "Add Element" click` 添加，`find text "Delete" click --index 0` 删除；动态元素类名 `added-manually`；重复 Delete 按钮需 `--index 0`
- [x] **P8-39** `selenium.dev/selenium/web/web-form.html` 上，`fill`、`select`、`upload` 可稳定驱动文本框、文本域、下拉框和文件输入
- [x] **P8-40** `select` 命令当前按 option `value` 生效，不是按可见文本匹配；例如 `Two` 对应值是 `2`
- [x] **P8-41** 外站导航时的 frame 上下文残留已通过 `open` 导航后清理 `currentFrameSelector` 解决；后续继续观察是否还存在真实的 `session closed` 超时问题
- [x] **P8-42** `uitestingplayground.com/dynamicid`：`find text "Button with Dynamic ID" click` 稳定；`click '.btn-primary'` 稳定（按钮无状态变化故从文本无法观测，但点击无报错）
- [x] **P8-43** `uitestingplayground.com/alerts`：`find text "Alert" click --index 0` + 后台触发 + `dialog accept` 成功关闭弹窗；Confirm 和 Prompt 流程相同
- [x] **P8-44** `testpages.eviltester.com`：Alerts JS (`find text "Show alert box" click` + 后台触发 + `dialog accept`)、 Frames (`frame 'frame[name="top"]'` ✅、`frame 'frame[name="left"]'` ✅、`frame main` ✅)、File Upload (`upload '#fileinput' <path>` ✅，`phase:selected`)、Storage (`storage set/get` ✅) 均验证通过
- [x] **P8-45** GitHub + X.com SPA：`goto` 直接 URL 跳转到 Issues 列表 ✅、`snapshot`/`eval` 正常读取 ✅；X.com 首页加载正常，显示"为你推荐"、"正在关注"等 SPA 内容 ✅；GitHub Issues 面包屑文本不是链接，需用 `goto` 直接 URL
- [x] **P8-46** 表单/iframe/列表/电商：w3schools iframe 演示页 ✅、`frame` 命令因 iframe 无 name 属性无法定位（`<iframe>` 在 AX tree 中可见，但 CSS 属性选择器无法匹配）；Hacker News 长列表 ✅（30 条标题 `document.querySelectorAll(".titleline").length`）；Shopify ✅ 和 Amazon ✅ 首页加载正常

---

## Phase 9 · 高优先级功能补全

### P9-1 · CDP 类型定义（Phase 2 未完成项）

- [ ] **P9-1** `cdp/types.v`：关键域 V struct 定义（Page / Runtime / DOM / Input / Accessibility / Target / Fetch / Network / Storage）
  - 状态：未开始
  - 优先级：P0
  - 验收标准：CDP 协议的主要类型都有对应的 V struct 定义

### P9-2 · 高级截图功能（Phase 5 未完成项）

- [ ] **P9-2** `diff screenshot`：逐像素对比 + 生成差异图
  - 状态：未开始
  - 依赖：需要 stb_image_write C binding 或纯 V 实现
  - 验收标准：可以对比两张截图并生成可视化差异图

- [ ] **P9-3** `diff url`：打开两个 tab 各自 snapshot/screenshot → 对比
  - 状态：未开始
  - 验收标准：可以对比两个 URL 的快照或截图

- [ ] **P9-4** `screenshot --annotate`：截图 + AX tree boundingBox → 叠加编号标签
  - 状态：未开始
  - 依赖：需要 stb_truetype C binding 或纯 V 实现
  - 验收标准：截图上标注可点击元素的编号

---

## Phase 10 · 优化与完善

### P10-1 · 调试可观测性增强

- [ ] **P10-1** 增强 `--json` 输出，让结果结构化包含 `ok`、`error`、`suggestion`、`state`、`hint`
- [ ] **P10-2** 在出错时统一建议用户补充 `screenshot`、`console`、`errors` 和 `network requests` 的信息
- [ ] **P10-3** 为动态页面提供"调试三件套"路径：页面文本、截图、请求日志
- [ ] **P10-4** 对高频错误统一做分类映射，让错误信息更可读

### P10-2 · 回归测试覆盖

- [ ] **P10-5** 把 `packages/test-ui/lab.html` 作为核心 fixture，补全关键场景
- [ ] **P10-6** CLI 层增加 smoke 脚本，覆盖高频链路
- [ ] **P10-7** 对关键命令补最小回归测试
- [ ] **P10-8** 给 smoke 测试统一"通过标准"

### P10-3 · 文档入口优化

- [ ] **P10-9** 统一 SOP、命令参考、技能说明、改进清单的文档串连
- [ ] **P10-10** 新用户能按文档快速上手并找到下一步

---

## Phase 11 · 配置与依赖修复

### P11-1 · 项目配置修复

- [ ] **P11-1** `package.json`：修复 repository URL（当前是占位符 `https://github.com/your-repo/v-browser.git`）
- [ ] **P11-2** `package.json`：补充 license、author 等元数据

### P11-2 · GitHub Actions 升级

- [ ] **P11-3** 升级 Node.js 版本：GitHub Actions 使用的 Node.js 20 将于 2026 年 9 月废弃
  - 建议：设置 `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true` 或升级 action 版本

### P11-3 · 测试补全

- [ ] **P11-4** 决定 `server_test.v` 中被注释测试的命运：删除或实现
- [ ] **P11-5** `packages/extension`：增加单元测试（当前只有构建验证）

---

## 推荐迭代顺序

1. **Phase 9（P9-1 ~ P9-4）**：高优先级功能补全
2. **Phase 10（P10-1 ~ P10-10）**：优化与完善
3. **Phase 11（P11-1 ~ P11-5）**：配置与依赖修复
