---
name: v-browser
description: v-browser 是一个面向 AI Agent 的浏览器自动化 CLI 工具，基于 V 语言实现，通过 Chrome DevTools Protocol (CDP) 控制浏览器。当用户想要进行浏览器自动化操作时使用此 skill。
---

# v-browser 使用指南

v-browser 是一个面向 AI Agent 的浏览器自动化 CLI 工具，基于 V 语言实现，通过 Chrome DevTools Protocol (CDP) 控制浏览器。配合 Chrome 扩展使用。

## 前提条件

### 1. 构建 CLI

```bash
cd packages/server
v test ./src
v -o ./v-browser ./src
```

### 2. 构建扩展

```bash
cd packages/extension
npm install
npm run build
```

### 3. 启动方式

- **自动启动**（推荐）：CLI 会自动在后台拉起 `v-browser server`，优先使用 `pueue add`
- **手动启动**：如果没有 `pueue`，可以手动运行：

```bash
cd packages/server
./v-browser server
```

### 4. 加载扩展

在 Chrome / Chromium / Edge 中以开发者模式加载 `packages/extension/dist`。首次使用前，建议先打开扩展的状态页确认 token 已生成。

### 5. 连接浏览器

```bash
cd packages/server
./v-browser connect
```

在 Windows 上，`v-browser connect` 会通过系统默认关联或 `V_BROWSER_BROWSER_APP` 指定的浏览器可执行文件打开扩展连接页。

---

## 常用命令速查

| 命令 | 说明 |
|------|------|
| `v-browser connect` | 自动打开扩展连接页并 attach 当前页面 |
| `v-browser open <url>` | 导航到 URL |
| `v-browser snapshot` | 获取带引用符的无障碍树（推荐 AI 使用） |
| `v-browser click <sel>` | 点击元素 |
| `v-browser fill <sel> <text>` | 清空并填充输入框 |
| `v-browser get text <sel>` | 获取文本内容 |
| `v-browser screenshot [path]` | 截图 |
| `v-browser close` | 关闭浏览器 |

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
v-browser type <sel> <text>          # 输入文本（追加）
v-browser fill <sel> <text>          # 清空并填充
v-browser press <key>                # 按键（Enter, Tab, Control+a 等）
v-browser select <sel> <val>         # 选择下拉选项
v-browser check <sel>                # 勾选复选框
v-browser uncheck <sel>              # 取消勾选
v-browser scroll <dir> [px]         # 滚动（up/down/left/right）
v-browser scrollintoview <sel>       # 滚动元素到视图
v-browser drag <src> <tgt>           # 拖放
v-browser upload <sel> <files>      # 文件上传
```

### 键盘模拟

```bash
v-browser keyboard type <text>       # 模拟真实按键输入（无选择器，当前焦点）
v-browser keyboard inserttext <text> # 插入文本（无按键事件）
v-browser keydown <key>              # 按住按键
v-browser keyup <key>                # 释放按键
```

### 获取元素信息

```bash
v-browser get text <sel>             # 获取文本内容
v-browser get html <sel>             # 获取 innerHTML
v-browser get value <sel>            # 获取输入值
v-browser get attr <sel> <attr>      # 获取属性
v-browser get count <sel>            # 计数匹配元素
v-browser get box <sel>               # 获取边界框
v-browser get styles <sel>           # 获取计算样式
```

### 检查元素状态

```bash
v-browser is visible <sel>           # 检查是否可见
v-browser is enabled <sel>           # 检查是否可用
v-browser is checked <sel>           # 检查是否已勾选
```

---

## 语义定位器（推荐）

v-browser 支持语义定位器，AI 交互推荐使用这种方式：

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

**支持的 Actions:** `click`, `fill`, `type`, `hover`, `focus`, `check`, `uncheck`, `text`

**示例:**

```bash
v-browser find role button click --name "Submit"
v-browser find text "Sign In" click
v-browser find label "Email" fill "test@test.com"
v-browser find alt "Hero banner" click
```

---

## 等待条件

```bash
v-browser wait <selector>             # 等待元素可见
v-browser wait <ms>                  # 等待时间（毫秒）
v-browser wait --text "Welcome"      # 等待文本出现
v-browser wait --url "**/dash"       # 等待 URL 匹配
v-browser wait --load networkidle    # 等待加载状态
v-browser wait --fn "window.ready"   # 等待 JS 条件
v-browser wait --download <path>     # 等待下载完成并保存
```

**加载状态:** `load`, `domcontentloaded`, `networkidle`

---

## 截图与视觉输出

```bash
v-browser screenshot [path]          # 截图（--full 完整页面）
v-browser screenshot --annotate       # 带编号元素标签的标注截图
v-browser pdf <path>                 # 保存为 PDF
```

---

## 差异对比

```bash
# 快照对比
v-browser diff snapshot                              # 当前 vs 上次快照
v-browser diff snapshot --baseline before.txt       # 当前 vs 保存的快照文件
v-browser diff snapshot --selector "#main" --compact # 局部快照对比

# 截图对比
v-browser diff screenshot --baseline before.png     # 基线截图视觉对比
v-browser diff screenshot --baseline b.png -o d.png # 保存差异图像
v-browser diff screenshot --baseline b.png -t 0.2   # 调整颜色阈值

# URL 对比
v-browser diff url <url1> <url2>                   # 比较两个 URL
v-browser diff url <url1> <url2> --screenshot      # 同时视觉对比
v-browser diff url <url1> <url2> --selector "#main" # 限定元素范围
```

---

## 浏览器设置

```bash
v-browser set viewport <w> <h> [scale]    # 设置视口大小
v-browser set device <name>               # 模拟设备（iPhone 14, Pixel 7 等）
v-browser set geo <lat> <lng>            # 设置地理位置
v-browser set offline [on|off]           # 切换离线模式
v-browser set headers <json>              # 设置 HTTP 头
v-browser set credentials <u> <p>        # HTTP 基本认证
v-browser set media [dark|light]         # 模拟颜色方案
```

---

## 网络控制

```bash
v-browser network route <url>             # 拦截请求
v-browser network route <url> --abort    # 阻止请求
v-browser network route <url> --body <json>  # 模拟响应
v-browser network unroute [url]          # 移除路由
v-browser network requests               # 查看跟踪的请求
v-browser network requests --filter api  # 过滤请求
```

---

## 标签页与窗口

```bash
v-browser tab                          # 列出标签页
v-browser tab new [url]               # 新建标签页
v-browser tab switch <id>             # 切换标签页
v-browser tab close <id>              # 关闭标签页
v-browser window new [url]            # 新建窗口
```

---

## Cookies 和存储

```bash
# Cookies
v-browser cookies                      # 获取所有 cookies
v-browser cookies set <name> <val>    # 设置 cookie
v-browser cookies clear               # 清除 cookies

# LocalStorage
v-browser storage local                # 获取所有 localStorage
v-browser storage local <key>         # 获取特定 key
v-browser storage local set <k> <v>   # 设置值
v-browser storage local clear          # 清除

# SessionStorage
v-browser storage session              # 同上
```

---

## 框架 (iframe)

```bash
v-browser frame <sel>                  # 切换到 iframe
v-browser frame main                  # 返回主框架
```

---

## 对话框处理

```bash
v-browser dialog accept [text]         # 接受对话框
v-browser dialog dismiss              # 关闭对话框
```

---

## 调试工具

```bash
v-browser trace start [path]           # 开始录制 trace
v-browser trace stop [path]           # 停止并保存 trace
v-browser profiler start               # 开始性能分析
v-browser profiler stop [path]        # 停止并保存性能文件
v-browser console                     # 查看控制台消息
v-browser console --clear            # 清除控制台
v-browser errors                      # 查看页面错误
v-browser errors --clear             # 清除错误
v-browser highlight <sel>            # 高亮元素
```

---

## 状态管理

```bash
v-browser state save <path>           # 保存认证状态
v-browser state load <path>           # 加载认证状态
v-browser state list                  # 列出保存的状态
v-browser state show <file>           # 显示状态摘要
v-browser state rename <old> <new>    # 重命名状态
```

---

## JavaScript 执行

```bash
v-browser eval <js>                    # 执行 JavaScript
v-browser eval <js> -b                 # 执行 base64 编码的 JS
v-browser eval --stdin                 # 从管道读取 JS
```

---

## JSON 输出

所有命令都支持 `--json` 标志：

```bash
v-browser --json status
v-browser --json get title
v-browser --json find text "Submit" click
```

输出格式：

- 成功：`{"ok":true,"result":...}`
- 失败：`{"ok":false,"error":{"code":"...","message":"..."}}`

---

## 选择器引用符

使用 `snapshot` 命令后，元素会显示引用符（如 `@e1`, `@e2`），可直接用于后续命令：

```bash
v-browser snapshot              # 获取快照
v-browser click @e2             # 点击引用符指向的元素
v-browser fill @e3 "text"       # 填充引用符指向的输入框
```

---

## 传统选择器

也支持 CSS 选择器：

```bash
v-browser click "#submit"
v-browser fill "#email" "test@example.com"
```
