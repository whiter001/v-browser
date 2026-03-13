---
name: v-browser
description: 面向 AI Agent 的浏览器自动化 CLI 工具，基于 V 语言和 Chrome DevTools Protocol (CDP)。
---

# v-browser 使用指南

## 前提条件

```bash
# 构建 CLI
cd packages/server
v test ./src
v -o ./v-browser ./src

# 构建扩展
cd packages/extension
npm install
npm run build
```

## 快速开始

1. **连接浏览器**：`v-browser connect`（自动启动 server + 打开扩展连接页）

---

## 常用命令

| 命令                          | 说明                                               |
| ----------------------------- | -------------------------------------------------- |
| `v-browser connect`           | 自动打开扩展连接页并 attach 当前页面               |
| `v-browser open <url>`        | 导航到 URL                                         |
| `v-browser snapshot`          | 获取无障碍树（`--raw` 返回原始文本，适合 AI 处理） |
| `v-browser click <sel>`       | 点击元素                                           |
| `v-browser fill <sel> <text>` | 清空并填充输入框                                   |
| `v-browser get text <sel>`    | 获取文本内容（**需要 selector**）                  |
| `v-browser screenshot [path]` | 截图                                               |
| `v-browser close`             | 关闭浏览器                                         |

---

### ⚠️ 常见问题

| 问题                      | 原因                                           | 解决方案                             |
| ------------------------- | ---------------------------------------------- | ------------------------------------ |
| `get text` 报 SyntaxError | 未提供 selector，生成 `querySelector("")` 无效 | 使用 `v-browser get text <selector>` |
| `snapshot` 超时           | 大型 SPA 无障碍树太庞大                        | 使用 `v-browser eval` 获取内容       |
| `Not connected`           | 未连接浏览器                                   | 运行 `v-browser connect`             |

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
v-browser mouse up [button]           # 释放按钮
v-browser mouse wheel <dy> [dx]      # 滚动滚轮
```

### 获取元素信息

```bash
v-browser get text <sel>             # 获取文本内容
v-browser get html <sel>             # 获取 innerHTML
v-browser get value <sel>            # 获取输入值
v-browser get attr <sel> <attr>       # 获取属性
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
v-browser wait <selector>             # 等待元素可见
v-browser wait <ms>                   # 等待时间（毫秒）
v-browser wait --text "Welcome"       # 等待文本出现
v-browser wait --url "**/dash"        # 等待 URL 匹配
v-browser wait --load networkidle     # 等待加载状态
v-browser wait --fn "window.ready"    # 等待 JS 条件
v-browser wait --download <path>      # 等待下载完成（--timeout 超时时间）
```

**加载状态:** `load`, `domcontentloaded`, `networkidle`

---

## 截图与视觉输出

```bash
v-browser screenshot [path]          # 截图（--full 完整页面）
v-browser screenshot --annotate       # 带编号标注
v-browser pdf <path>                 # 保存为 PDF
```

---

## 差异对比

```bash
v-browser diff snapshot                              # 当前 vs 上次快照
v-browser diff snapshot --baseline before.txt       # 当前 vs 快照文件
v-browser diff screenshot --baseline before.png     # 截图对比
v-browser diff url <url1> <url2>                    # URL 对比
```

---

## 浏览器设置

```bash
v-browser set viewport <w> <h> [scale]    # 视口大小
v-browser set device <name>               # 模拟设备
v-browser set geo <lat> <lng>             # 地理位置
v-browser set offline [on|off]            # 离线模式
v-browser set headers <json>               # HTTP 头
v-browser set credentials <u> <p>          # HTTP 基本认证
v-browser set media [dark|light]           # 颜色方案
```

---

## 网络控制

```bash
v-browser network route <url>             # 拦截请求
v-browser network route <url> --abort    # 阻止请求
v-browser network unroute [url]           # 移除路由
v-browser network requests               # 查看请求
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
v-browser cookies                      # 获取 cookies
v-browser cookies set <name> <val>    # 设置 cookie
v-browser cookies clear               # 清除 cookies

v-browser storage local                # localStorage
v-browser storage local <key>         # 获取 key
v-browser storage local set <k> <v>   # 设置值
v-browser storage local clear         # 清除
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
v-browser dialog accept [text]
v-browser dialog dismiss
```

---

## 调试工具

```bash
v-browser trace start [path]           # 录制 trace
v-browser trace stop [path]           # 停止并保存
v-browser profiler start               # 性能分析
v-browser profiler stop [path]        # 停止并保存
v-browser console                     # 控制台消息
v-browser errors                      # 页面错误
v-browser highlight <sel>            # 高亮元素
```

---

## 状态管理

```bash
v-browser state save <path>
v-browser state load <path>
v-browser state list
```

---

## JavaScript 执行

```bash
v-browser eval <js>
v-browser eval <js> -b                 # base64 编码
v-browser eval --stdin                 # 从管道读取
```

---

## JSON 输出

```bash
v-browser --json status
v-browser --json get title
```

---

## 选择器引用符

```bash
v-browser snapshot              # 获取快照（元素显示 @e1, @e2）
v-browser click @e2             # 使用引用符
v-browser fill @e3 "text"
```

---

## 传统选择器

```bash
v-browser click "#submit"
v-browser fill "#email" "test@example.com"
```
