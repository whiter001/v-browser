# v-browser 命令参考文档

`v-browser` 是一个面向 AI Agent 的浏览器自动化 CLI 工具，基于 vlang 实现, 配合extension使用。

## 安装与启动

```bash
# 构建 CLI
cd packages/server
v test ./src
v -o ./v-browser ./src

# 构建扩展
cd ../extension
npm install
npm run build
```

自动后台拉起 `v-browser server`（如有需要）。现在优先使用 `pueue add`。如果环境里没有 `pueue`，也可以手动运行 `v-browser server`（通常不需要）。

在 Windows 上，`v-browser connect` 会通过系统默认关联或 `V_BROWSER_BROWSER_APP` 指定的浏览器可执行文件打开扩展连接页；如果默认浏览器不是 Chromium 内核，建议显式设置 `V_BROWSER_BROWSER_APP`。

然后在 Chrome / Chromium / Edge 中以开发者模式加载 packages/extension/dist。首次使用前，建议先打开扩展的状态页确认 token 已生成。

## 配置项说明

`v-browser` 使用环境变量做运行时配置。下面列出项目里目前实际使用到的配置项、默认值和示例。

| 变量名                   | 是否必需 | 默认值                                                | 说明                                                                                |
| ------------------------ | -------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `V_BROWSER_EXTENSION_ID` | 建议设置 | 从 `${HOME}/.v-browser/extension_id` 读取（若已同步） | 扩展 ID。`connect` 时若未连接扩展，会用它拼出 `chrome-extension://.../connect.html` |
| `V_BROWSER_BROWSER_APP`  | 可选     | 空                                                    | 指定打开连接页的浏览器。Windows 下建议填浏览器可执行文件路径；macOS 下可填应用名    |
| `V_BROWSER_HOME`         | 可选     | 当前用户 Home 目录                                    | `v-browser` 的状态目录根路径                                                        |
| `V_BROWSER_RELAY_PORT`   | 可选     | `47978`                                               | WebSocket relay 端口                                                                |
| `V_BROWSER_IPC_PORT`     | 可选     | `47979`                                               | 本地 IPC 端口                                                                       |

### 状态文件位置

当未设置 `V_BROWSER_HOME` 时，以下文件默认写入用户主目录下的 `.v-browser`：

- `~/.v-browser/token`：CLI 与扩展握手 token
- `~/.v-browser/extension_id`：最近一次同步/记录的扩展 ID
- `~/.v-browser/server.sock`：当前 IPC 端口记录文件
- `~/.v-browser/server.log`：server 日志
- `~/.v-browser/server.task`：后台任务标记

### 全局配置文件

除 `V_BROWSER_HOME` 外，`v-browser` 还支持从全局配置文件读取运行时配置，路径固定为 `~/.config/v-browser/config`。

- 文件格式：每行 `key=value`
- 支持 `#` 注释
- 优先级：环境变量 > 全局配置文件
- `V_BROWSER_HOME` 仅支持通过环境变量设置，不从该文件读取

示例：

```dotenv
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

### `.env.example` 示例

仓库根目录包含一个可复制的模板：

```dotenv
V_BROWSER_EXTENSION_ID=your-extension-id
V_BROWSER_BROWSER_APP=path-to-your-browser
V_BROWSER_HOME=
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

> 注意：`v-browser` 不会自动加载 `.env`。如需使用，请在启动前由 shell、任务系统或你自己的脚本负责导入。

如果你使用的是 Windows + Edge，本地 `.env` 可以参考：

```dotenv
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
V_BROWSER_HOME=
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

### 示例：Windows PowerShell

```powershell
$env:V_BROWSER_EXTENSION_ID = 'eefgklfpdnjodmmjefedjfnflacaimmj'
$env:V_BROWSER_BROWSER_APP = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
./v-browser.exe connect
```

### 示例：macOS

```bash
export V_BROWSER_EXTENSION_ID="abcdefghijklmnopabcdefghijklmnop"
export V_BROWSER_BROWSER_APP="Microsoft Edge"
./v-browser connect
```

### 示例：隔离测试目录

```bash
export V_BROWSER_HOME="$PWD/.local"
export V_BROWSER_RELAY_PORT=48078
export V_BROWSER_IPC_PORT=48079
./v-browser server
```

连接时 CLI 会自动尝试拉起扩展连接页：

```bash
cd packages/server
./v-browser connect --extension-id eefgklfpdnjodmmjefedjfnflacaimmj
```

---

## 快速开始

```bash
v-browser connect
v-browser open example.com
v-browser snapshot                    # 获取带引用符的无障碍树
v-browser click @e2                   # 通过快照引用符点击
v-browser fill @e3 "test@example.com" # 通过引用符填充
v-browser get text @e1                # 通过引用符获取文本
v-browser screenshot page.png
v-browser close
```

---

## 核心命令

| 命令                                   | 说明                                               |
| -------------------------------------- | -------------------------------------------------- |
| `v-browser open <url>`                 | 导航到 URL（别名: goto, navigate）                 |
| `v-browser click <sel>`                | 点击元素（`--new-tab` 在新标签页打开）             |
| `v-browser dblclick <sel>`             | 双击元素                                           |
| `v-browser download <sel> <path>`      | 点击元素并等待下载完成                             |
| `v-browser focus <sel>`                | 聚焦元素                                           |
| `v-browser type <sel> <text>`          | 输入文本到元素                                     |
| `v-browser fill <sel> <text>`          | 清空并填充                                         |
| `v-browser press <key>`                | 按键（Enter, Tab, Control+a）（别名: key）         |
| `v-browser keyboard type <text>`       | 模拟真实按键输入（无选择器，当前焦点）             |
| `v-browser keyboard inserttext <text>` | 插入文本（无按键事件）                             |
| `v-browser keydown <key>`              | 按住按键                                           |
| `v-browser keyup <key>`                | 释放按键                                           |
| `v-browser hover <sel>`                | 悬停元素                                           |
| `v-browser select <sel> <val>`         | 选择下拉选项                                       |
| `v-browser check <sel>`                | 勾选复选框                                         |
| `v-browser uncheck <sel>`              | 取消勾选复选框                                     |
| `v-browser scroll <dir> [px]`          | 滚动（up/down/left/right，`--selector <sel>`）     |
| `v-browser scrollintoview <sel>`       | 滚动元素到视图（别名: scrollinto）                 |
| `v-browser drag <src> <tgt>`           | 拖放                                               |
| `v-browser upload <sel> <files>`       | 上传文件                                           |
| `v-browser screenshot [path]`          | 截图（`--full` 完整页面，无路径则保存到临时目录）  |
| `v-browser screenshot --annotate`      | 带编号元素标签的标注截图                           |
| `v-browser pdf <path>`                 | 保存为 PDF                                         |
| `v-browser snapshot`                   | 获取带引用符的无障碍树（推荐 AI 使用）             |
| `v-browser eval <js>`                  | 执行 JavaScript（`-b` base64，`--stdin` 管道输入） |
| `v-browser connect`                    | 自动打开扩展连接页并 attach 当前页面               |
| `v-browser close`                      | 关闭浏览器（别名: quit, exit）                     |
| `v-browser --json ...`                 | 以统一 JSON 包装输出结果或错误                     |

---

## 剪贴板操作

v-browser 没有直接的剪贴板命令，但可以通过 `eval` + `press` 组合实现复制粘贴功能。

### 复制内容到剪贴板

```bash
# 将指定文本写入剪贴板
v-browser eval "navigator.clipboard.writeText('要复制的内容')"

# 从页面元素获取内容并复制
v-browser eval "navigator.clipboard.writeText(document.querySelector('.content').innerText)"
```

### 从剪贴板粘贴

```bash
# 先聚焦目标输入框
v-browser focus "textareaSelector"

# 模拟 Ctrl+V / Cmd+V 粘贴
v-browser press "Control+v"    # Linux/Windows
v-browser press "Meta+v"       # macOS
```

### 跨页面复制粘贴示例

```bash
# 1. 在源页面获取内容并复制到剪贴板
v-browser open "https://example.com/source"
v-browser eval "navigator.clipboard.writeText(document.querySelector('.content').innerText)"

# 2. 切换到目标页面并粘贴
v-browser open "https://example.com/editor"
v-browser focus "textarea"
v-browser press "Meta+v"
```

### 相关命令

- `v-browser eval <js>` - 执行 JavaScript，可用于访问 `navigator.clipboard`
- `v-browser press <key>` - 模拟按键组合
- `v-browser keyboard type <text>` - 模拟真实按键输入
- `v-browser tab` - 标签页操作（切换标签页）

---

## 获取信息

```bash
v-browser get text <sel>          # 获取文本内容
v-browser get html <sel>          # 获取 innerHTML
v-browser get value <sel>         # 获取输入值
v-browser get attr <sel> <attr>   # 获取属性
v-browser get title               # 获取页面标题
v-browser get url                 # 获取当前 URL
v-browser get count <sel>         # 计数匹配元素
v-browser get box <sel>           # 获取边界框
v-browser get styles <sel>        # 获取计算样式
```

---

## 检查状态

```bash
v-browser is visible <sel>        # 检查是否可见
v-browser is enabled <sel>       # 检查是否可用
v-browser is checked <sel>       # 检查是否已勾选
```

---

## 查找元素（语义定位器）

```bash
v-browser find role <role> <action> [value]       # 按 role / 隐式角色
v-browser find text <text> <action>               # 按文本内容
v-browser find label <label> <action> [value]     # 按 label 文本关联控件
v-browser find placeholder <ph> <action> [value]  # 按 placeholder
v-browser find alt <text> <action>                # 按 alt 文本
v-browser find title <text> <action>              # 按 title 属性
v-browser find testid <id> <action> [value]       # 按 data-testid
v-browser find first <sel> <action> [value]       # 第一个匹配
v-browser find last <sel> <action> [value]        # 最后一个匹配
v-browser find nth <n> <sel> <action> [value]     # 第 n 个匹配（从 0 开始）
```

**支持的 Actions:** `click`, `fill`, `type`, `hover`, `focus`, `check`, `uncheck`, `text`

**选项:**

- `--name <name>` - 按可访问名称过滤角色
- `--exact` - 要求精确文本匹配

**示例:**

```bash
v-browser find role button click --name "Submit"
v-browser find text "Sign In" click
v-browser find label "Email" fill "test@test.com"
v-browser find alt "Hero banner" click
v-browser find first ".item" click
v-browser find nth 2 "a" text
```

---

## 等待

```bash
v-browser wait <selector>         # 等待元素可见
v-browser wait <ms>               # 等待时间（毫秒）
v-browser wait --text "Welcome"   # 等待文本出现
v-browser wait --url "**/dash"    # 等待 URL 匹配
v-browser wait --load networkidle  # 等待加载状态
v-browser wait --fn "window.ready === true"  # 等待 JS 条件
v-browser wait --download ./file.zip --timeout 30000  # 等待下载完成并保存到指定路径
```

**加载状态:** `load`, `domcontentloaded`, `networkidle`

---

## 鼠标控制

```bash
v-browser mouse move <x> <y>      # 移动鼠标
v-browser mouse down [button]     # 按下按钮 (left/right/middle)
v-browser mouse up [button]       # 释放按钮
v-browser mouse wheel <dy> [dx]   # 滚动滚轮
```

---

## 浏览器设置

当前 `set device` 内置这些预设：`iPhone 14`、`iPhone 14 Pro`、`Pixel 7`、`iPad mini`。

```bash
v-browser set viewport <w> <h> [scale]  # 设置视口大小 (scale 为视网膜缩放，如 2)
v-browser set device <name>       # 模拟设备（如 "iPhone 14"）
v-browser set geo <lat> <lng>     # 设置地理位置
v-browser set offline [on|off]    # 切换离线模式
v-browser set headers <json>      # 设置额外 HTTP 头
v-browser set credentials <u> <p> # HTTP 基本认证
v-browser set media [dark|light]  # 模拟颜色方案
```

---

## Cookies 和存储

```bash
# Cookies
v-browser cookies                 # 获取所有 cookies
v-browser cookies set <name> <val> # 设置 cookie
v-browser cookies clear          # 清除 cookies

# LocalStorage
v-browser storage local          # 获取所有 localStorage
v-browser storage local <key>    # 获取特定 key
v-browser storage local set <k> <v>  # 设置值
v-browser storage local clear    # 清除所有

# SessionStorage
v-browser storage session        # 同上
```

---

## 网络

当前 `network route` / `unroute` / `network requests` 已可用；请求状态码依赖浏览器返回的 `Network.responseReceived` / `Network.responseReceivedExtraInfo`，因此少数请求可能只显示基础信息。

```bash
v-browser network route <url>              # 拦截请求
v-browser network route <url> --abort      # 阻止请求
v-browser network route <url> --body <json> # 模拟响应
v-browser network unroute [url]           # 移除路由
v-browser network requests                 # 查看跟踪的请求
v-browser network requests --filter api    # 过滤请求
```

---

## 标签页和窗口

```bash
v-browser tab                     # 列出标签页
v-browser tab new [url]          # 新建标签页（可选带 URL）
v-browser tab switch <id>        # 切换到指定 tab id
v-browser tab close <id>         # 关闭指定 tab id
v-browser window new [url]       # 新建窗口并切换到该窗口的首个标签页
```

---

## 框架

当前 `frame` 已支持同源 iframe / `srcdoc` 场景；跨域 iframe 仍未支持。

```bash
v-browser frame <sel>            # 切换到 iframe
v-browser frame main             # 返回主框架
```

---

## 对话框

```bash
v-browser dialog accept [text]   # 接受（可选提示文本）
v-browser dialog dismiss          # 关闭
```

---

## 差异对比

```bash
# 快照对比
v-browser diff snapshot                              # 当前 vs 上次快照
v-browser diff snapshot --baseline before.txt       # 当前 vs 保存的快照文件
v-browser diff snapshot --selector "#main" --compact # 局部快照对比

# 截图对比
v-browser diff screenshot --baseline before.png       # 基线截图视觉对比
v-browser diff screenshot --baseline b.png -o d.png  # 保存差异图像到自定义路径
v-browser diff screenshot --baseline b.png -t 0.2     # 调整颜色阈值 (0-1)

# URL 对比
v-browser diff url https://v1.com https://v2.com      # 比较两个 URL（快照对比）
v-browser diff url https://v1.com https://v2.com --screenshot  # 同时视觉对比
v-browser diff url https://v1.com https://v2.com --wait-until networkidle  # 自定义等待策略
v-browser diff url https://v1.com https://v2.com --selector "#main"  # 限定元素范围
```

---

## 调试

`trace stop` 现在会把 CDP trace 流真正写到文件；`console`、`errors`、`highlight`、`profiler` 保持可用。

```bash
v-browser trace start [path]       # 开始录制 trace
v-browser trace stop [path]        # 停止并保存 trace
v-browser profiler start           # 开始 Chrome DevTools 性能分析
v-browser profiler stop [path]    # 停止并保存性能文件 (.json)
v-browser console                  # 查看控制台消息
v-browser console --clear         # 清除控制台
v-browser errors                   # 查看页面错误（未捕获的 JS 异常）
v-browser errors --clear          # 清除错误
v-browser highlight <sel>         # 高亮元素
```

## JSON 输出

```bash
v-browser --json status
v-browser --json get title
v-browser --json find text "Submit" click
```

输出格式当前统一为：

- 成功：`{"ok":true,"result":...}`
- 失败：`{"ok":false,"error":{"code":"...","message":"..."}}`

当前错误码已覆盖常见场景，例如 `INVALID_ARGUMENT`、`NOT_FOUND`、`NOT_CONNECTED`、`TIMEOUT`、`COMMAND_FAILED`。

## 状态管理

```bash
v-browser state save <path>        # 保存认证状态
v-browser state load <path>       # 加载认证状态
v-browser state list              # 列出保存的状态文件
v-browser state show <file>       # 显示状态摘要
v-browser state rename <old> <new> # 重命名状态文件
```

---

## 传统选择器

也支持传统 CSS/XPath 选择器：

```bash
v-browser click "#submit"
v-browser fill "#email" "test@example.com"
v-browser find role button click --name "Submit"
```

---

## 选择器引用符说明

使用 `snapshot` 命令获取页面无障碍树后，元素会显示引用符（如 `@e1`, `@e2`），可直接用于后续命令：

```bash
v-browser snapshot              # 获取快照
v-browser click @e2            # 点击引用符指向的元素
v-browser fill @e3 "text"      # 填充引用符指向的输入框
```

---

> 参考项目:
> [agent-browser](https://github.com/vercel-labs/agent-browser)
> [playwright-mcp](https://github.com/microsoft/playwright-mcp)
