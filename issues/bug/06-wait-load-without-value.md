# [Bug] `v-browser wait --load` 不带值时返回 `unknown load state: true`

> 标签: `bug`, `P2`, `area/cli`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/main.v:726-753` (CLI flag 解析)
> - `packages/server/src/main.v:1019-1020` (`wait --load` 分支)
> - `packages/server/src/commands.v:2195-2198` (`cmd_wait --load` 分发)
> - `packages/server/src/commands.v:2218-2223` (`wait_load` 状态匹配)

## 背景

CLI flag 解析的通用规则是：`--flag` 不带值时，flag 被设为字符串 `'true'`。

```v
if arg.starts_with('--') {
    key := arg[2..]
    if i + 1 < args.len && !args[i + 1].starts_with('--') {
        flags[key] = args[i + 1]
        i += 2
    } else {
        flags[key] = 'true'   // ← 通用默认
        i++
    }
}
```

## 问题描述

`v-browser wait --load`（不带值）的预期行为是"等待页面 load 事件"。但实际：

```bash
$ v-browser wait --load
Error: unknown load state: true
```

跟踪路径：
1. CLI parser: `flags['load'] = 'true'`
2. `parse_cli_to_ipc('wait', ...)` 把 `flags['load']` 直接放进 IPC params：`{"load":"true"}`
3. server `cmd_wait` 提取 `load="true"`，传给 `wait_load(mut sess, "true")`
4. `wait_load` 的 `match state` 没有 `true` 分支 → 返回 `unknown load state: true`

用户必须**显式写** `--load load`：

```bash
$ v-browser wait --load load   # 才能工作
```

但 help 文档（`cli_usage_lines`）示例是 `v-browser wait --load`：

```
'  v-browser wait <ms|sel>       等待 (毫秒 / 选择器 / --load / --url / --text / --fn / --download)'
```

读 help 会以为 `--load` 是个独立 flag，但实际上必须传值。

## 复现步骤

```bash
v-browser connect
v-browser open https://example.com
v-browser wait --load          # 实际：错误信息
v-browser wait --load load     # 正确行为：等 load 事件
```

## 同类问题

类似 flag 也受影响，但行为可能是预期的：

| Flag | 不带值的语义 | 当前行为 | 是否 bug |
|---|---|---|---|
| `--load` | 等待 load | `unknown load state: true` | ❌ bug |
| `--stable` | 等待内容稳定 | 行为待验证 | 待确认 |
| `--download` | 等待任意下载 | 走 `download_path == 'true'` 分支，当作"任意下载" | 看起来是 by design |
| `--url` | 等待 URL | 必传值 | OK |
| `--text` | 等待文本 | 必传值 | OK |

## 建议方案

**方案 A（推荐）**：server 端 `cmd_wait --load` 把 `load == 'true'` 当作 `load == 'load'`：

```v
load := cdp_extract_str(params, 'load')
if load != '' {
    state := if load == 'true' { 'load' } else { load }
    return wait_load(mut sess, state)
}
```

类似处理 `--stable`、`--download` 等。

**方案 B**：CLI parser 对特殊 flag（`--load`）不设 `'true'`，而是设默认字符串 `'load'`，并在 IPC 中不带引号序列化。但这会破坏通用 flag 解析的统一性。

**方案 C**：CLI parser 引入"无值 flag"概念（仅作 presence check），但 V 的 flag map 是 `map[string]string`，改起来成本高。

选 A。改动小，向后兼容。

## 验收标准

- [ ] `v-browser wait --load` 返回正确结果（不报错）
- [ ] `v-browser wait --load load` 仍然工作
- [ ] `v-browser wait --load domcontentloaded` 仍然工作
- [ ] `v-browser wait --load networkidle` 仍然工作
- [ ] 单测覆盖：4 种 state 值 + 'true' 别名
- [ ] help 文案保持 `v-browser wait --load` 的简洁示例

## 备注

这是 E2E 测试 #8/#9/#10 修复时顺手发现的 bug，不属于那三个修复的范围。修复时建议同时检查 `--stable` 和 `--download` 是否也有类似的"无值 flag 默认值"问题。