# AGENTS.md

## 项目概述

v-browser 是一个基于 V 语言实现的浏览器自动化 CLI，通过本地 daemon + 浏览器扩展接入 Chrome DevTools Protocol，提供适合 AI Agent 和脚本调用的稳定命令面。

### 仓库结构

- `packages/server`: v-browser CLI 与本地 relay server
- `packages/extension`: 浏览器扩展，负责把当前标签页桥接到本地 server
- `packages/test-ui`: 基于 veb 的本地测试台，用于手工验证

## 代码规范

### 格式化要求

**修改代码后必须执行格式化工具：**

- **V 代码（.v 文件）**：运行 `v fmt` 或项目内的 `./fmt.sh`
- **Markdown 文件（.md 文件）**：运行 `oxfmt`

```bash
# 格式化 V 代码
cd packages/server
v fmt .
# 或使用项目脚本
bash ./fmt.sh

# 格式化 Markdown 文件
oxfmt .
```

### 验证约定

- 每次改完代码、准备做功能验证前，优先先重启 `v-browser server`。
- 原因是这个项目里很多改动会落在本地 daemon / relay / 扩展连接链路上，不重启很容易还在跑旧进程，导致验证结果不生效或看起来“没改动”。
- 如果是只改文档、注释或与运行时无关的静态内容，可以不重启；但只要涉及命令行为、连接逻辑、tab 管理、网络保存、扩展桥接等运行时功能，就默认先重启再验证。

### 构建命令

```bash
# 构建 server
cd packages/server
v test ./src
v run ./build.vsh

# 构建 extension
cd packages/extension
npm install
npm run build

# 启动测试前端（可选）
cd packages/test-ui
v run ./src
```

### 测试

```bash
# 运行 server 测试
cd packages/server
v test ./src
```
