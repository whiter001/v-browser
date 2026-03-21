# X 请求采集与回放设计稿

这份设计稿面向 v-browser 在 X / Twitter 场景下的请求采集、接口归纳和页面内回放能力。目标不是把页面逻辑塞进插件，而是把插件、server、页面脚本拆成清晰的分层，让后续能稳定提炼出接口规则，并在可控范围内回放。

## 目标

1. 在打开页面后，既能通过 CDP 看到真实网络请求，也能在页面上下文里注入脚本，捕获 fetch / XHR 的语义信息。
2. 把请求记录整理成结构化数据，方便分析分页、鉴权、cursor、query 参数和响应字段。
3. 在页面上下文中优先回放接口，请求失败时再回退到 DOM 采集。
4. 保留现有 network tracking / save / route 能力，但让它们退回到“观测、保存、mock”角色，不作为主采集链路。

## 非目标

- 不把大量业务 JS 固化在插件包里。
- 不追求一次性覆盖 X 的所有接口类型。
- 不尝试绕过站点安全策略或做脱离登录态的裸请求直连。

## 设计原则

1. 插件只做执行壳和桥接，不承担复杂业务逻辑。
2. v-browser 负责调度、注入、收集和归档。
3. 页面脚本只做最小采集与回放，不包含站点特定业务编排。
4. 结构化参数优先于大段字符串拼接。
5. 采集优先，回放其次，DOM 兜底最后。

## 总体架构

```text
用户命令
  -> v-browser CLI
    -> server / CdpSession
      -> Runtime.evaluate / Page.addScriptToEvaluateOnNewDocument
      -> 页面内 hook(fetch / XHR)
      -> console / binding 上报事件
      -> TabContext 记录请求与回放模板
      -> network 命令导出、回放、保存
```

### 三层职责

| 层级          | 职责                                                 | 典型能力                          |
| ------------- | ---------------------------------------------------- | --------------------------------- |
| 页面脚本层    | hook fetch / XHR，记录请求与响应摘要，支持回放       | 请求监听、响应摘要、基础重放      |
| server 采集层 | 接收页面事件，合并 CDP 网络事件，存储到 tab 级上下文 | 请求归档、响应体抓取、过滤导出    |
| CLI 调度层    | 发起注入、查询状态、导出记录、执行回放               | `hook start`、`records`、`replay` |

## 现状复用点

现有代码已经具备两块基础能力，可以直接复用：

- `Runtime.evaluate` 驱动的页面上下文执行，见 `packages/server/src/commands.v`。
- `Network.*` 事件跟踪和 `Network.getResponseBody`，见 `packages/server/src/cdp_session.v`。
- `network requests` / `save` / `watch` / `route` 这些命令，见 `packages/server/src/commands.v`。

因此新方案不是重做网络系统，而是在现有能力之上增加“页面内 hook + 结构化归档 + 回放器”。

## 模块划分

### 1. 页面注入脚本

职责：

- hook `window.fetch`
- hook `XMLHttpRequest.prototype.open` / `send`
- 记录请求 URL、method、headers、body、时间戳、来源页面
- 在响应完成后记录 status、response headers、body 摘要
- 以固定前缀输出事件，供后端消费

建议实现方式：

- 持久注入：`Page.addScriptToEvaluateOnNewDocument`
- 当前页补注入：`Runtime.evaluate`
- 输出通道优先用 `console.debug` 加固定前缀，先接入最小闭环

### 2. 采集归档层

职责：

- 从 `Runtime.consoleAPICalled` 或 binding 事件中读取 hook 事件
- 和现有 `Network.requestWillBeSent`、`Network.responseReceived`、`Network.loadingFinished` 合并
- 生成统一的请求记录
- 维护 tab 级顺序和去重

### 3. 回放层

职责：

- 在页面上下文中重放已采集的请求模板
- 默认优先 fetch，必要时回退 XHR
- 允许按规则过滤或修改参数
- 支持将回放结果再次写回采集记录，用于规则校准

## 数据结构

建议在 `CdpSession` 的 tab 上下文中增加与注入和回放相关的状态字段：

```text
TabContext
  - current_frame_selector
  - network_requests
  - network_request_order
  - network_watch
  - hook_state
  - replay_templates
  - capture_sessions
```

### 推荐字段

#### HookState

- `active`: 是否启用页面 hook
- `injected`: 当前 tab 是否已完成注入
- `script_id`: 当前注入脚本版本
- `filter`: 请求过滤规则
- `capture_body`: 是否采集 body
- `capture_response`: 是否采集响应摘要
- `last_injected_at`: 最近一次注入时间

#### RequestRecord

- `request_id`
- `source`：`fetch` / `xhr` / `cdp`
- `tab_id`
- `page_url`
- `method`
- `url`
- `request_headers`
- `request_body`
- `response_status`
- `response_headers`
- `response_body`
- `response_body_truncated`
- `timestamp_start`
- `timestamp_end`
- `cursor_hint`
- `signature`

#### ReplayTemplate

- `template_id`
- `request_signature`
- `method`
- `url_pattern`
- `required_headers`
- `body_template`
- `transform_rules`
- `expected_response_shape`

## 命令设计

建议不要把这套能力塞进现有 `network route`，而是单独增加一个 `inspect` 或 `hook` 子树，职责更清楚。

### 1. `network hook start`

作用：注入页面脚本并开启采集。

参数建议：

- `filter`: 过滤 URL 或关键字
- `captureBody`: 是否记录请求体
- `captureResponse`: 是否记录响应摘要
- `persistent`: 是否使用新文档注入
- `scriptId`: 指定脚本版本

返回：

- 注入是否成功
- 当前 tab 的 hook 状态
- 当前已捕获数量

### 2. `network hook stop`

作用：停止采集，但保留已记录的数据。

### 3. `network hook status`

作用：查看当前 tab 的 hook 状态、注入状态、采集计数、最近注入时间。

### 4. `network hook records`

作用：导出结构化采集结果。

建议支持：

- `filter`
- `limit`
- `format`：`json` / `ndjson`

### 5. `network replay`

作用：在当前页面上下文中回放一条或一组请求。

建议支持：

- `requestId`
- `templateId`
- `overrideHeaders`
- `overrideBody`
- `dryRun`

### 6. 保留现有 `network` 能力的定位

- `requests`: 作为网络观测列表
- `body`: 作为响应体查看
- `save`: 作为响应保存
- `watch`: 作为落盘监控
- `route`: 作为 mock / 屏蔽 / 故障注入

这样职责边界会比较清晰。

## 页面脚本工作流

### 1. 注入阶段

1. 在页面加载前执行持久注入。
2. 在当前页再执行一次补注入，避免只对新页面生效。
3. 注入完成后发出一条 `hook.ready` 事件。

### 2. 采集阶段

1. 页面发起 fetch / XHR。
2. hook 记录 request metadata。
3. 响应返回后记录 status 和摘要。
4. 后端收到事件后写入 tab 级记录。
5. 同时可从 CDP 网络事件里补全真实响应体。

### 3. 归纳阶段

1. 将重复请求按 signature 去重。
2. 提取 cursor、分页参数和鉴权头模式。
3. 按请求链路归成一个 replay template。

### 4. 回放阶段

1. 选定模板或单条记录。
2. 在页面上下文里构造 fetch / XHR。
3. 复用当前页面的 cookies、localStorage、token。
4. 回放结果写回记录，供后续分析。

## 与现有 network route 的关系

`route` 当前更像“控制台”：可以继续保留，用于 mock、abort、故障注入。

新的 hook 采集层更像“仪表盘”：

- 不修改流量
- 只记录和归档
- 必要时补充页面内视角

这两者可以共存，但不应该混成一个命令。

## 分阶段落地

### Phase 1: 最小闭环

- 增加页面注入脚本
- hook fetch / XHR
- 用 console 事件回传
- 在 tab context 里存结构化记录
- 新增 `hook start / stop / status / records`

验收：打开 X 页面后能稳定看到请求列表，并能区分 fetch 与 XHR。

### Phase 2: 回放能力

- 新增 `network replay`
- 支持参数 override
- 支持 dry-run
- 支持回放结果归档

验收：能复用页面登录态重放同一个接口，不需要重复人工操作。

### Phase 3: 规则归纳

- 自动提取分页 cursor、query 模式、鉴权头特征
- 生成 replay template
- 增加导出格式

验收：同一类接口可以从单次采集生成稳定模板。

### Phase 4: 与 DOM 兜底联动

- 如果接口回放失败，回退到 DOM 抽取
- 失败时自动附带请求记录、截图和页面文本

验收：接口变化后仍能完成任务，只是路径会自动降级。

## 风险与约束

1. X 的前端脚本变化快，hook 逻辑要版本化，不能写死在一个脚本里。
2. 只靠 fetch / XHR 不够，某些资源仍要用 CDP 网络事件补全。
3. 全量记录会比较吵，必须支持过滤和采样。
4. 页面上下文回放要尊重同源、CSP 和登录态，不能假设裸请求总是可用。
5. 注入脚本要尽量保持轻量，避免对页面性能造成明显影响。

## 建议的代码落点

### Server 侧

- `packages/server/src/cdp_session.v`
  - 增加 tab 级 hook 状态
  - 维护请求记录和回放模板
  - 接收页面事件并统一归档

- `packages/server/src/commands.v`
  - 增加 `network hook` / `network replay` 命令
  - 保留 `network route` 作为控制类能力

- `packages/server/src/resolver.v`
  - 复用现有 `Runtime.evaluate` / 作用域执行能力
  - 供页面内脚本执行使用

### Extension 侧

- 保留桥接、连接和必要的消息转发
- 不承载复杂采集逻辑

## 结论

这套方案的核心不是“插件里堆很多 JS”，而是：

1. 页面内注入最小 hook。
2. server 负责归档和回放。
3. 插件只保留运行时桥接。
4. CDP 观测、页面 hook、DOM 兜底三路并存。

如果后续要继续做深，下一步最值得实现的是 Phase 1 的最小闭环。
