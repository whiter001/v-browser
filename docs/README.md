# v-browser 文档索引

欢迎使用 v-browser！本文档帮助你快速了解和使用 v-browser 浏览器自动化工具。

## 📚 文档导航

### 新手入门

1. **[最短可执行 SOP](./v-browser-sop.md)** - 快速开始指南，最少命令即可上手
2. **[命令参考文档](./v-browser.md)** - 完整的命令列表和使用说明

### 项目管理

3. **[改进计划](./v-browser-improvement-plan.md)** - 功能和优化待办事项追踪

### 开发指南

4. **[浏览器自动化 skill](../.agents/skills/automate-browser/SKILL.md)** - AI Agent 使用的技能说明

## 🔑 快速链接

| 资源 | 位置 |
|------|------|
| 源代码 | [packages/server](../packages/server/) |
| 浏览器扩展 | [packages/extension](../packages/extension/) |
| 测试 UI | [packages/test-ui](../packages/test-ui/) |
| GitHub 仓库 | <https://github.com/whiter001/v-browser> |

## 🚀 快速开始

```bash
# 1. 构建 server
cd packages/server
v -o ./v-browser ./src

# 2. 构建扩展
cd ../extension
npm install && npm run build

# 3. 连接浏览器
./v-browser connect

# 4. 执行命令
./v-browser open https://example.com
./v-browser snapshot
```

## 📖 推荐阅读顺序

1. **新手**: `v-browser-sop.md` → `v-browser.md`
2. **开发者**: `v-browser.md` → `v-browser-improvement-plan.md`
3. **AI Agent**: `SKILL.md`

## 🔧 常用命令

```bash
# 连接浏览器
v-browser connect

# 打开页面
v-browser open <url>

# 获取快照
v-browser snapshot

# 执行 JS
v-browser eval "document.title"

# 截图（带标注）
v-browser screenshot --annotate

# 网络请求
v-browser network requests
```

## 📝 更新日志

查看 [GitHub Releases](https://github.com/whiter001/v-browser/releases) 了解版本更新。
