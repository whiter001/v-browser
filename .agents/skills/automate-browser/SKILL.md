---
name: automate-browser
description: 面向 AI Agent 的浏览器自动化 CLI 工具，适合网页操作、抓取、发布和多标签页调试。
---

# automate-browser 使用指南

## 📑 快速索引

| 场景 | 推荐命令 |
|------|----------|
| **连接浏览器** | `v-browser connect` → `v-browser connect <url>` |
| **页面导航** | `open`, `back`, `forward`, `reload` |
| **元素操作** | `click`, `fill`, `type`, `hover`, `focus` |
| **信息获取** | `snapshot`, `get text`, `get attr`, `screenshot` |
| **等待条件** | `wait selector`, `wait --text`, `wait --url` |
| **文件下载** | `download`, `upload` |
| **多标签页** | `tab list`, `tab new`, `tab switch` |
| **网络调试** | `network requests`, `network hook`, `network inspect` |
| **Server 管理** | `server start`, `server stop`, `server restart` |
| **状态保存** | `state save`, `state load` |

---

## 前提条件

```bash
# 构建 CLI
cd packages/server
v -o ./v-browser ./src


```

## 快速开始

1. **连接浏览器**：`v-browser connect`（自动启动 server + 打开扩展连接页）

### 验证约定

- 如果你刚改了运行时代码、连接逻辑、tab 管理、网络保存或扩展桥接，先重启 `v-browser server` 再验证。
- 这个项目的本地 daemon / relay / 扩展连接链路很容易跑旧进程，不重启会出现"看起来没改动"的假象。
- 只改文档、注释或静态内容时，一般不需要重启。

---

## 常用命令速查

| 命令                          | 说明                                               |
| ----------------------------- | -------------------------------------------------- |
| `v-browser connect`           | 自动打开扩展连接页并 attach 当前页面               |
| `v-browser connect <url>`    | 优先命中已打开且 URL 匹配的标签页                  |
| `v-browser tab list`         | 列出当前标签页，连接前先确认目标页是否已打开       |
| `v-browser open <url>`       | 导航到 URL                                         |
| `v-browser snapshot`         | 获取无障碍树（`--raw` 返回原始文本，适合 AI 处理） |
| `v-browser click <sel>`      | 点击元素                                           |
| `v-browser fill <sel> <text>`| 清空并填充输入框                                   |
| `v-browser get text <sel>`   | 获取文本内容（需要 selector）                      |
| `v-browser screenshot [path]`| 截图                                               |
| `v-browser close`             | 关闭浏览器                                         |
| `v-browser server start`      | 启动本地 daemon                                    |
| `v-browser server stop`       | 停止本地 daemon                                    |
| `v-browser server restart`    | 重启本地 daemon                                    |

---

## 常用工作流

### 工作流 1: 登录并抓取内容

```bash
# 1. 连接浏览器
v-browser connect https://example.com/login

# 2. 填写登录表单
v-browser fill "#username" "user@example.com"
v-browser fill "#password" "password123"
v-browser click "button[type='submit']"

# 3. 等待登录完成
v-browser wait --url "**/dashboard"
v-browser wait --text "Welcome"

# 4. 抓取数据
v-browser snapshot --raw
```

### 工作流 2: 多步骤表单填写

```bash
# 1. 打开表单页面
v-browser open https://example.com/form

# 2. 填写文本输入
v-browser fill "#title" "My Article Title"

# 3. 填写富文本（如果支持）
v-browser eval --expression "document.querySelector('#editor').innerHTML = '<p>Content here</p>'"

# 4. 上传图片
v-browser upload "input[type='file']" "./photo.jpg"
v-browser wait --timeout 5000 "img.preview"

# 5. 提交表单
v-browser click "button[type='submit']"
v-browser wait --text "Success"

# 6. 确认数据
v-browser get text ".result-title"
```

### 工作流 3: 批量下载文件

```bash
# 1. 打开下载列表页
v-browser connect https://example.com/downloads

# 2. 获取所有下载链接
v-browser eval --expression "Array.from(document.querySelectorAll('a.download')).map(a => a.href)" --json

# 3. 循环下载（伪代码示例）
for link in links:
    v-browser download "a[href='${link}']" "./downloads/${filename}"
```

### 工作流 4: 复杂交互操作

```bash
# 场景：拖拽排序
v-browser drag "#item-1" "#item-3"

# 场景：日期选择
v-browser click ".date-picker"
v-browser wait ".calendar"
v-browser click "[data-date='2024-01-15']"

# 场景：级联选择
v-browser click "#country"
v-browser wait "#country option"
v-browser select "#country" "China"
v-browser wait "#province"  # 等待省份下拉加载
v-browser select "#province" "Beijing"
```

---

## 核心命令详解

### 页面导航

```bash
v-browser open <url>                 # 导航到 URL（别名: goto, navigate）
v-browser back                       # 后退
v-browser forward                    # 前进
v-browser reload                     # 刷新
v-browser get url                    # 获取当前 URL
v-browser get title                  # 获取页面标题
```

### 元素交互

```bash
v-browser click <sel>                # 点击元素（--new-tab 在新标签页打开）
v-browser dblclick <sel>             # 双击
v-browser focus <sel>                # 聚焦元素
v-browser hover <sel>                # 悬停
v-browser type <sel> <text>          # 真实按键式追加输入文本
v-browser fill <sel> <text>          # 清空并填充
v-browser press <key>                # 按键
v-browser select <sel> <val>         # 选择下拉选项
v-browser check <sel>                # 勾选复选框
v-browser uncheck <sel>              # 取消勾选
v-browser scroll <dir> [px]          # 滚动
v-browser scrollintoview <sel>       # 滚动元素到视图
v-browser drag <src> <tgt>           # 拖放
v-browser upload <sel> <files>       # 文件上传
v-browser download <sel> <path>      # 点击并等待下载完成
```

### 下载文件和图片

`v-browser download` 适合下载页面上可点击的文件链接、图片链接、附件链接，或者带有可下载目标的元素。使用时要直接传入完整的目标文件路径，而不是只传目录。

```bash
# 下载到指定文件名
v-browser download "#downloadLink" "C:\\Downloads\\photo.jpg"

# 如果目标是图片或文件直链，也可以直接保存为指定文件名
v-browser download "a[href*='image']" "C:\\Downloads\\image.png"
```

- 如果页面元素本身没有 download 属性，但能点开真正的文件地址，通常也可以用 download 保存下来。
- 如果只是普通页面里的图片展示，没有可点击下载入口，先用 v-browser get attr <sel> src 或 v-browser get attr <sel> href 拿到真实地址，再决定是否用 download。
- 对于下载到目录的需求，请在目标路径里带上文件名；当前命令返回的是最终文件路径，不是目录路径。

### 键盘模拟

```bash
v-browser keyboard type <text>       # 模拟按键输入
v-browser keyboard inserttext <text> # 插入文本
v-browser keydown <key>              # 按住按键
v-browser keyup <key>                # 释放按键
```

### 鼠标操作

```bash
v-browser mouse move <x> <y>         # 移动鼠标
v-browser mouse down [button]        # 按下按钮
v-browser mouse up [button]          # 释放按钮
v-browser mouse wheel <dy> [dx]      # 滚动滚轮
```

### 获取元素信息

```bash
v-browser get text <sel>             # 获取文本内容
v-browser get html <sel>             # 获取 innerHTML
v-browser get value <sel>            # 获取输入值
v-browser get attr <sel> <attr>      # 获取属性
v-browser get count <sel>            # 计数匹配元素
v-browser get box <sel>              # 获取边界框
v-browser get styles <sel>           # 获取计算样式
```

### 检查元素状态

```bash
v-browser is visible <sel>
v-browser is enabled <sel>
v-browser is checked <sel>
```

---

## 语义定位器（推荐）

```bash
# 按角色查找
v-browser find role <role> <action> [--name <name>]
# 按文本查找
v-browser find text <text> <action>
# 按 label 关联控件
v-browser find label <label> <action> [value]
# 按 placeholder
v-browser find placeholder <ph> <action> [value]
# 按 alt 文本
v-browser find alt <text> <action>
# 按 title 属性
v-browser find title <text> <action>
# 按 data-testid
v-browser find testid <id> <action> [value]
# 位置限定
v-browser find first <sel> <action> [value]
v-browser find last <sel> <action> [value]
v-browser find nth <n> <sel> <action> [value]
```

**Actions:** `click`, `fill`, `type`, `hover`, `focus`, `check`, `uncheck`, `text`

---

## 等待条件

```bash
v-browser wait <selector>            # 等待元素可见
v-browser wait <ms>                  # 等待时间（毫秒）
v-browser wait --text "Welcome"      # 等待文本出现
v-browser wait --url "**/dash"       # 等待 URL 匹配
v-browser wait --load networkidle     # 等待加载状态
v-browser wait --fn "window.ready"   # 等待 JS 条件
v-browser wait --download <path>     # 等待下载完成（--timeout 超时时间）
```

**加载状态:** `load`, `domcontentloaded`, `networkidle`

---

## 截图与视觉输出

```bash
v-browser screenshot [path]          # 截图（--full 完整页面）
v-browser screenshot --annotate      # 带编号标注
v-browser pdf <path>                 # 保存为 PDF
```

---

## 差异对比

```bash
v-browser diff snapshot                            # 当前 vs 上次快照
v-browser diff snapshot --baseline before.txt      # 当前 vs 快照文件
v-browser diff screenshot --baseline before.png    # 截图对比
v-browser diff url <url1> <url2>                   # URL 对比
```

---

## 浏览器设置

```bash
v-browser set viewport <w> <h> [scale]   # 视口大小
v-browser set device <name>              # 模拟设备
v-browser set geo <lat> <lng>            # 地理位置
v-browser set offline [on|off]           # 离线模式
v-browser set headers <json>             # HTTP 头
v-browser set credentials <u> <p>        # HTTP 基本认证
v-browser set media [dark|light]         # 颜色方案
```

---

## 网络控制

```bash
v-browser network route <url>            # 拦截请求
v-browser network route <url> --abort    # 阻止请求
v-browser network unroute [url]          # 移除路由
v-browser network requests               # 查看请求
```

### 高级网络功能

```bash
# 查看特定域名的请求
v-browser network requests --filter "api.example.com"

# 查看 JSON 响应
v-browser network requests --mime "application/json"

# 保存请求到文件
v-browser network requests --save ./requests.json
```

---

## Server 管理

```bash
v-browser server start               # 启动本地 daemon
v-browser server stop                 # 停止本地 daemon
v-browser server restart              # 重启本地 daemon
v-browser server status               # 查看 daemon 状态
```

> **提示**：改动涉及运行时行为时，需先 `server restart` 再验证。

---

## 标签页与窗口

```bash
v-browser tab                        # 列出标签页
v-browser tab new [url]               # 新建标签页
v-browser tab switch <id>              # 切换标签页
v-browser tab close <id>               # 关闭标签页
v-browser window new [url]             # 新建窗口
```

---

## 网络控制

### 查看网络请求（CDP 层）

CDP 层自动捕获所有网络请求，可直接查看请求列表、响应体、响应头。

```bash
v-browser network requests                  # 查看所有请求
v-browser network requests --limit 50      # 限制返回数量
v-browser network requests --capture-body  # 捕获响应体（自动缓存）
v-browser network requests --filter POST   # 按 HTTP 方法过滤
v-browser network requests --filter api    # 按 URL 关键词过滤
v-browser network requests --domain example.com  # 按域名过滤
v-browser network requests --type XHR       # 按类型过滤 (XHR, Fetch, Document, Script, Stylesheet, Image, Font, ...)
v-browser network requests --mime application/json  # 按 Content-Type 过滤
v-browser network requests --status 200   # 按状态码过滤 (200, 404, 2xx, 4xx, 5xx)
```

### 获取请求详情

```bash
v-browser network body <requestId>     # 获取响应体
v-browser network headers <requestId>  # 获取响应头
v-browser network save <requestId> <path>  # 保存响应体到本地文件
```

### 批量保存

```bash
v-browser network save-images <dir>    # 批量保存页面图片请求到目录
```

### 监听网络请求（CDP 层）

持续监听并保存请求到文件，适合调试一次性请求。

```bash
v-browser network watch start ./requests  # 开始监听，保存到 requests 目录
v-browser network watch start ./requests --filter api  # 只监听匹配的请求
v-browser network watch stop               # 停止监听
v-browser network watch status            # 查看监听状态
```

### XHR/Fetch Hook（应用层）

Hook 在 JavaScript 层面拦截 XHR 和 Fetch 请求，支持捕获请求/响应体、过滤、重放。

```bash
v-browser network hook start                  # 启动 Hook（默认配置）
v-browser network hook start --capture-body   # 捕获请求体
v-browser network hook start --capture-response  # 捕获响应体
v-browser network hook start --filter api     # 只拦截匹配模式的请求
v-browser network hook start --max-body-len 0  # 不限制响应体大小
v-browser network hook start --all-frames      # 包含 iframe 中的请求
v-browser network hook stop                   # 停止 Hook
v-browser network hook status                 # 查看 Hook 状态
```

### 查看 Hook 记录

```bash
v-browser network hook records               # 查看所有 Hook 记录
v-browser network hook records --limit 20    # 限制数量
v-browser network hook records --filter POST # 按 URL/方法过滤
v-browser network hook records --domain api.example.com  # 按域名过滤
v-browser network hook records --type XHR    # 只看 XHR (或 Fetch)
v-browser network hook records --mime application/json  # 按 Content-Type 过滤
v-browser network hook records --status 2xx  # 按状态码过滤
```

### 重放请求

```bash
# 重放原始请求
v-browser network hook replay <record-id>

# 自定义重放参数
v-browser network hook replay <record-id> --method POST --override-url https://new-api.com/endpoint
v-browser network hook replay <record-id> --override-body '{"key":"value"}' --override-headers '{"Authorization":"Bearer xxx"}'
v-browser network hook replay <record-id> --dry-run  # 不实际发送，只预览
```

### 合并查看（Hook + CDP 去重）

```bash
v-browser network inspect               # 合并查看 Hook 和 CDP 记录（自动去重）
v-browser network inspect --limit 20   # 限制数量
v-browser network inspect --filter api  # 按关键词过滤
v-browser network inspect --domain example.com  # 按域名过滤
v-browser network inspect --type XHR    # 按类型过滤
v-browser network inspect --mime application/json  # 按 MIME 类型过滤
v-browser network inspect --status 2xx # 按状态码过滤
```

### CDP 层 vs Hook 层

| 特性 | CDP 层 (`network requests`) | Hook 层 (`network hook`) |
|------|---------------------------|-------------------------|
| 捕获范围 | TCP/HTTP 层，所有资源 | JavaScript 层，只拦截 XHR/Fetch |
| 请求体 | 仅响应体 | 请求体 + 响应体（可选） |
| iframe | 自动包含 | 需要 `--all-frames` |
| 重放 | 不支持 | 支持 |
| 适用场景 | 静态资源、文档请求 | API 调试、请求修改重放 |

### 典型工作流

#### 工作流 1: 抓取 API 响应

```bash
# 1. 打开页面触发 API 请求
v-browser connect https://example.com

# 2. 查看 XHR/Fetch 请求
v-browser network requests --type XHR --mime application/json --limit 20

# 3. 获取具体响应体
v-browser network body <requestId>
```

#### 工作流 2: 调试 API 请求

```bash
# 1. 启动 Hook 并捕获请求体
v-browser network hook start --capture-body --capture-response

# 2. 触发业务操作（如登录、提交表单）
v-browser click "#submit"

# 3. 查看 Hook 记录
v-browser network hook records --type XHR

# 4. 修改参数后重放
v-browser network hook replay <record-id> --override-body '{"email":"test2@example.com"}'
```

#### 工作流 3: 持续监控请求

```bash
# 1. 开始监听并保存到目录
v-browser network watch start ./debug-requests

# 2. 执行操作
v-browser click "#load-more"
v-browser wait --timeout 3000 ".new-item"

# 3. 停止监听并分析
v-browser network watch stop
# 查看 ./debug-requests 目录中的保存文件
```

---

## Cookies 和存储

```bash
v-browser cookies                     # 获取 cookies
v-browser cookies set <name> <val>     # 设置 cookie
v-browser cookies clear                # 清除 cookies

v-browser storage local                # localStorage
v-browser storage local <key>          # 获取 key
v-browser storage local set <k> <v>    # 设置值
v-browser storage local clear          # 清除
```

---

## 框架 (iframe)

```bash
v-browser frame <sel>                 # 切换到 iframe
v-browser frame main                  # 返回主框架
```

---

## 对话框处理

```bash
v-browser dialog accept [text]
v-browser dialog dismiss
```

---

## 剪贴板功能

v-browser 现在支持图片剪贴板命令：

```bash
v-browser clipboard read image
v-browser clipboard write image ./photo.png
```

- `clipboard read image` 会把剪贴板里的第一张图片保存到临时文件，并返回路径和 MIME 类型
- `clipboard write image <path>` 会把本地图片写入系统剪贴板

---

## 状态管理（会话保存与恢复）

### 保存会话状态

```bash
# 保存当前会话的 cookies 和 localStorage
v-browser state save my-session

# 保存到指定路径
v-browser state save /path/to/state.json
```

### 恢复会话状态

```bash
# 从命名的状态恢复
v-browser state load my-session

# 从文件恢复
v-browser state load /path/to/state.json
```

### 列出可用状态

```bash
v-browser state list
```

**使用场景：**
- 登录后保存状态，下次直接恢复无需重新登录
- 跨会话保持用户偏好设置
- 自动化流程中的状态检查点

---

## 性能分析工具

### Trace 追踪

```bash
# 开始追踪（会截取每帧截图）
v-browser trace start

# 执行待测操作
v-browser click "#slow-button"
v-browser wait --text "Loaded"

# 停止追踪并保存
v-browser trace stop
# 输出：/tmp/trace_1234567890.json
```

### CPU 性能分析

```bash
# 开始分析
v-browser profiler start

# 执行操作
v-browser do-something

# 停止并保存
v-browser profiler stop
# 输出：/tmp/profile_1234567890.json
```

**使用场景：**
- 识别页面加载瓶颈
- 分析复杂交互性能
- 优化 JavaScript 执行效率

---

## 调试工具

```bash
v-browser console                     # 查看控制台输出
v-browser errors                      # 查看页面错误
v-browser network requests            # 查看网络请求
```

### 常用调试技巧

#### 1. 查看元素信息
```bash
# 获取元素计算样式
v-browser get styles "#target"

# 获取元素边界框（用于定位）
v-browser get box "#target"
```

#### 2. 执行自定义 JavaScript
```bash
# 简单表达式
v-browser eval --expression "document.title"

# 复杂逻辑
v-browser eval --expression "JSON.stringify(window.performance.timing)"

# 等待 Promise
v-browser eval --awaitPromise --expression "fetch('/api/data').then(r => r.json())"
```

#### 3. 高亮元素
```bash
# 临时高亮元素（2秒）
v-browser highlight "#target"
```

---

## 常用技巧

- `snapshot` 输出里带 `@eN` 的元素引用符，可以直接复用到后续命令
- `eval` 适合处理复杂页面、动态渲染和剪贴板操作
- `--json` 可以让输出更适合机器处理
- 对 X / Twitter 长帖，优先抓 `document.body.innerText` 或 `article` 的正文，再抓 `[data-testid="tweetPhoto"] img` 和 `article img` 的 `src`
- 对 QQ 邮箱记事本这类富文本页，先写标题，再写正文，最后补图片，保存后再读一遍确认标题和图片没有丢

---

## 高级技巧

### 1. 批量操作

```bash
# 批量勾选
for i in 1 2 3 4 5; do
    v-browser click "#checkbox-$i"
done

# 批量下载
v-browser eval --expression "document.querySelectorAll('a.download').forEach(a => a.click())"
```

### 2. 条件执行

```bash
# 检查元素是否存在再操作
if v-browser is visible "#optional-section"; then
    v-browser click "#optional-section"
fi
```

### 3. 滚动加载内容

```bash
# 滚动到页面底部
v-browser scroll down 1000

# 等待新内容加载
v-browser wait --timeout 3000 ".new-item"
```

### 4. 处理动态内容

```bash
# 等待动态元素出现
v-browser wait --timeout 10000 ".dynamically-loaded"

# 等待网络空闲
v-browser wait --load networkidle
```

---

## ⚠️ 常见问题

| 问题                      | 原因                                           | 解决方案                                    |
| ------------------------- | ---------------------------------------------- | ------------------------------------------- |
| `get text` 报 SyntaxError | 未提供 selector，生成 `querySelector("")` 无效 | 使用 `v-browser get text <selector>`        |
| `snapshot` 超时           | 大型 SPA 无障碍树太庞大                        | 使用 `v-browser eval` 获取内容               |
| `Not connected`           | 未连接浏览器                                   | 运行 `v-browser connect`                    |
| 连到旧标签页              | 目标页已打开但 attach 命中了别的 tab           | 先 `v-browser tab list`，再 `connect <url>` |
| 改动不生效                | 运行时改动还在旧 server 上                     | 先 `v-browser server restart`              |
| `upload` 失败            | 文件路径不存在或格式不支持                     | 检查文件路径，或使用 `waitPreview`           |
| `download` 等待超时       | 下载未触发或文件未生成                         | 增加 `--timeout`，或检查元素是否可点击       |

### 错误恢复策略

#### 1. 连接问题
```bash
# 重启 server
v-browser server restart

# 重新连接
v-browser connect <url>
```

#### 2. 元素查找失败
```bash
# 增加等待时间
v-browser wait --timeout 30000 "#lazy-element"

# 使用 eval 直接查找
v-browser eval --expression "document.querySelector('#target')?.click()"
```

#### 3. 网络请求问题
```bash
# 启用网络日志
v-browser network requests

# 检查特定请求
v-browser network requests --filter "api"
```

---

## 多标签页与 URL 命中

- 当你已经打开了目标网页时，优先用 `v-browser connect <url>` 复用现有标签页，不要先 `open` 再 `connect`。
- 连接前如果不确定页面是否已打开，先跑 `v-browser tab list`。
- 如果当前改动涉及运行时行为，而验证结果看起来没变化，优先重启 `v-browser server` 再重新 `connect`。

---

## 命令参数参考

### 全局参数

| 参数              | 说明                     |
| ----------------- | ------------------------ |
| `--json`          | 输出 JSON 格式           |
| `--timeout <ms>`  | 操作超时时间（毫秒）     |
| `--debug`         | 启用调试输出             |

### 常见 selector 类型

- **CSS 选择器**: `#id`, `.class`, `tag`, `tag.class`
- **属性选择器**: `[type="text"]`, `[href*="example"]`
- **组合选择器**: `div > p`, `ul li:first-child`

---

## 最佳实践

### 1. 稳定性优先

```bash
# ✅ 推荐：明确的等待
v-browser click "#submit"
v-browser wait --text "Success"

# ⚠️ 避免：依赖固定延迟
v-browser click "#submit"
v-browser wait 5000  # 硬编码等待
```

### 2. 使用语义定位器

```bash
# ✅ 推荐：语义化
v-browser find role button click --name "Submit"

# ⚠️ 避免：脆弱的 CSS 选择器
v-browser click "#content > form > div:nth-child(3) > button"
```

### 3. 错误处理

```bash
# 检查元素是否存在
if v-browser is visible "#error-message"; then
    echo "Error occurred"
    v-browser get text "#error-message"
fi
```

### 4. 状态管理

```bash
# 定期保存进度
v-browser state save progress-checkpoint

# 失败后恢复
v-browser state load progress-checkpoint
```
