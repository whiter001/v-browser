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

### 并发规范

- **`sync.Mutex` 结构体字段建议在构造函数里显式 `.init()`**。旧版 V 不会自动
  初始化 Mutex 字段（`init_with` 未实现），macOS 上全零 `pthread_mutex_t`
  非法，`pthread_mutex_lock` 静默失败、完全不互斥（Linux 上恰好可用，问题被
  掩盖）。上游已修复：`Mutex` 自带原子 `lazy_init`，零值安全，`init()` 幂等。
  保留显式 `.init()` 仅为兼容旧版 V。参考 `new_cdp_session` / `new_server`
  的写法，根因记录见 `issues/bug/07-sync-mutex-field-uninitialized-macos.md`。
- `sync.RwMutex` 自带 `lazy_init`，一直不受此影响。

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

## 注释规范

生成代码时，只在非显而易见的地方添加注释，重点解释业务意图、为什么选择这种实现、边缘case处理和任何权衡。避免逐行解释简单语句，补足隐藏条件说明就行。使用中文注释
