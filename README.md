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
```

## 测试

- V 单测：在 packages/server 下运行 `v test ./src`
- 扩展构建校验：在 packages/extension 下运行 `npm run build`
- CLI smoke test：在 packages/extension 下运行 `npx playwright test tests/v-browser-cli.spec.ts`

更完整的命令说明见 docs/v-browser.md。
