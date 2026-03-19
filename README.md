# v-browser

v-browser 是一个基于 V 语言实现的浏览器自动化 CLI。它通过本地 daemon + 浏览器扩展接入 Chrome DevTools Protocol，目标是提供一套适合 AI Agent 和脚本调用的稳定命令面。

## 仓库结构

- packages/server: v-browser CLI 与本地 relay server
- packages/extension: 浏览器扩展，负责把当前标签页桥接到本地 server
- packages/test-ui: 基于 veb 的本地测试台，用于手工验证 server / extension / CLI 链路
- docs/v-browser.md: 命令参考与使用说明

## 本地开发

1. 构建 server

```bash
cd packages/server
v test ./src
v run ./build.vsh
sh ./fmt.sh
```

1. 构建 extension

```bash
cd packages/extension
npm install
npm run build
```

1. 启动测试前端（可选，用于手工测试）

```bash
cd packages/test-ui
v run ./src
```

然后打开 <http://127.0.0.1:48280> 。首页是控制面板，可以查看 token、已同步的 extension id、server 日志，并触发 build / connect / open / eval / snapshot / tab list / 自定义命令。

用于 v-browser 功能验证的被测页面在 <http://127.0.0.1:48280/lab.html> 。这个 fixture lab 提供表单、等待态、拖拽、上传、对话框、同源 iframe、storage 和 network 请求靶点，适合手工调试和后续 CLI/E2E 测试复用。

1. 在 Chromium / Chrome 中加载 packages/extension/dist 作为解压扩展

1. 连接并验证

```bash
cd packages/server
./v-browser connect
./v-browser tab list
./v-browser tab new https://example.com
./v-browser open https://example.com
./v-browser snapshot
./v-browser eval document.title
printf 'document.location.href\n' | ./v-browser --json eval --stdin
```

### 执行较长的 JavaScript

当表达式比较长、包含引号、换行，或者你想避免 shell 续行把终端卡在“等待输入”状态时，优先使用文件或标准输入，而不是把整段 JS 直接塞进命令行。

```bash
# 方式 1：从文件执行
cat > /tmp/vbrowser-example.js <<'EOF'
Array.from(document.querySelectorAll('button'))
  .map((el) => (el.innerText || '').trim())
  .filter(Boolean)
EOF
./v-browser --json eval --file /tmp/vbrowser-example.js

# 方式 2：通过标准输入执行
cat /tmp/vbrowser-example.js | ./v-browser --json eval --stdin

# 方式 3：base64 传入，适合脚本程序生成命令时避免引号转义
./v-browser eval --base64 "ZG9jdW1lbnQudGl0bGU="
```

## 网络资源导出

v-browser 现在支持直接把网络响应体保存到本地，适合 X / Twitter 这类图片页的自动化导出：

```bash
./v-browser network requests --filter image
./v-browser network body <requestId>
./v-browser network save <requestId> ./downloads/image.jpg
./v-browser network save-images ./downloads/x-post
./v-browser network watch start ./downloads/watch
./v-browser network watch status
./v-browser network watch stop
```

其中 `network save-images` 会优先筛选帖子主图请求，并自动过滤头像、emoji 和视频缩略图。
`network watch` 会持续监听当前页面的网络事件，适合页面主图在后续滚动或动态加载后再发起请求的场景。

## 项目配置

`v-browser` 目前主要通过环境变量配置运行行为。CLI/Server 本身不会自动读取根目录 `.env`，但你可以把它当成团队共享的配置模板，再按自己的 shell 手动加载。

### 必要配置

- `V_BROWSER_EXTENSION_ID`
  - 用途：告诉 `v-browser connect` 要打开哪个浏览器扩展。
  - 来源：浏览器扩展详情页中的扩展 ID，或扩展状态页同步到本地后的 `~/.v-browser/extension_id`。
  - 示例：`eefgklfpdnjodmmjefedjfnflacaimmj`

### 常用可选配置

- `V_BROWSER_BROWSER_APP`
  - 用途：显式指定要用哪个 Chromium 内核浏览器打开扩展连接页。
  - 适用场景：Windows 默认浏览器不是 Edge/Chrome，或机器上装了多个浏览器。
- `V_BROWSER_HOME`
  - 用途：指定 `v-browser` 的状态目录根路径。
  - 默认值：当前用户 Home 目录。
  - 影响文件：`${V_BROWSER_HOME}/.v-browser/token`、`${V_BROWSER_HOME}/.v-browser/extension_id`、`${V_BROWSER_HOME}/.v-browser/server.log` 等。
- `V_BROWSER_RELAY_PORT`
  - 用途：覆盖 WebSocket relay 端口。
  - 默认值：`47978`
- `V_BROWSER_IPC_PORT`
  - 用途：覆盖本地 IPC 端口。
  - 默认值：`47979`

### `.env` 示例

仓库根目录已提供 `.env.example` 模板，你可以复制为 `.env` 后按需修改：

```bash
# Windows PowerShell
Copy-Item .env.example .env

# macOS / Linux
cp .env.example .env
```

模板内容如下：

```dotenv
V_BROWSER_EXTENSION_ID=your-extension-id
V_BROWSER_BROWSER_APP=path-to-your-browser
V_BROWSER_HOME=
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

> **注意**：`v-browser` 不会自动加载 `.env` 文件。如需使用，请按下方"设置环境变量"章节的方法配置。

### 全局配置文件（推荐）

v-browser 支持从全局配置文件读取配置，推荐使用此方式：

- **配置路径**：`~/.config/v-browser/config`（即 `C:\Users\<用户名>\.config\v-browser\config`）
- **文件格式**：每行 `key=value`，支持 `#` 注释

**示例配置**：

```dotenv
# v-browser 全局配置
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe

# 可选配置
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

**优先级**：环境变量 > 全局配置文件

`V_BROWSER_HOME` 不从全局配置文件读取；如需修改状态目录，请通过环境变量单独设置。

### 设置环境变量

#### Windows PowerShell（当前会话有效）

```powershell
$env:V_BROWSER_EXTENSION_ID = "eefgklfpdnjodmmjefedjfnflacaimmj"
$env:V_BROWSER_BROWSER_APP = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
```

#### Windows PowerShell（永久生效）

```powershell
[Environment]::SetEnvironmentVariable("V_BROWSER_EXTENSION_ID", "eefgklfpdnjodmmjefedjfnflacaimmj", "User")
[Environment]::SetEnvironmentVariable("V_BROWSER_BROWSER_APP", "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", "User")
```

设置后需要**重启终端**使环境变量生效。

#### macOS / Linux（设置环境变量）

```bash
export V_BROWSER_EXTENSION_ID="eefgklfpdnjodmmjefedjfnflacaimmj"
export V_BROWSER_BROWSER_APP="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
```

#### 永久生效（macOS / Linux）

```bash
# 添加到 ~/.zshrc 或 ~/.bashrc
echo 'export V_BROWSER_EXTENSION_ID="eefgklfpdnjodmmjefedjfnflacaimmj"' >> ~/.zshrc
echo 'export V_BROWSER_BROWSER_APP="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"' >> ~/.zshrc
source ~/.zshrc
```

如果是你当前这台 Windows + Edge 机器，本地 `.env` 可以写成：

```dotenv
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
V_BROWSER_HOME=
V_BROWSER_RELAY_PORT=47978
V_BROWSER_IPC_PORT=47979
```

### 在不同系统中使用配置

#### Windows PowerShell

```powershell
$env:V_BROWSER_EXTENSION_ID = 'eefgklfpdnjodmmjefedjfnflacaimmj'
$env:V_BROWSER_BROWSER_APP = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
./packages/server/v-browser.exe connect
```

#### macOS / Linux

```bash
export V_BROWSER_EXTENSION_ID="your-extension-id"
export V_BROWSER_BROWSER_APP="/Applications/Google Chrome.app"
./packages/server/v-browser connect
```

### 推荐配置组合

#### 1. Windows + Edge

```dotenv
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
```

#### 2. 隔离测试环境

```dotenv
V_BROWSER_HOME=D:\work\github\v-browser\.local
V_BROWSER_RELAY_PORT=48078
V_BROWSER_IPC_PORT=48079
```

这样可以避免和你平时使用的浏览器状态目录互相“踩脚趾”。

## 测试

- V 单测：在 packages/server 下运行 `v test ./src`
- 扩展构建校验：在 packages/extension 下运行 `npm run build`
- CLI smoke test：运行 `sh packages/test-ui/smoke-cli.sh`

更完整的命令说明见 docs/v-browser.md。
