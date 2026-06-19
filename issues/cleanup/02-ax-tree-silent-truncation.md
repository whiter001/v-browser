# [Cleanup] `render_ax_tree` 在 10000 节点静默截断，无任何提示

> 标签: `cleanup`, `P2`, `bug`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:1395-1453` (`render_ax_tree`)
> - `packages/server/src/commands.v:1335-1393` (`cmd_snapshot`)

## 背景

`render_ax_tree` 用手写括号配对解析 CDP 返回的 AX tree JSON 字符串。每个 node 用 `cdp_balanced` 截取。

## 问题描述

```v
fn render_ax_tree(nodes_json string, start_counter int, mut store AxRefStore, include_extra bool,
    max_nodes int, filter_bnids map[int]bool) (string, int) {
    mut out := strings.new_builder(4096)
    mut counter := start_counter
    mut pos := 1
    mut i := 0  // 安全计数器

    for pos < nodes_json.len - 1 {
        if nodes_json[pos] == `{` {
            if max_nodes > 0 && counter - start_counter >= max_nodes {
                break
            }
            ...
            i++
            if i > 10000 {       // ← 10000 次迭代后静默退出
                break
            }
        }
        ...
    }
    return out.str(), counter
}
```

10000 次迭代就退出，但**调用方完全不知道**——`cmd_snapshot` 仍然返回 `out.str()`，看起来好像处理完了所有节点。

## 影响

- 大型 SPA（电商、dashboard）AX tree 经常超过 5000+ 节点
- 用户看到的 snapshot 是**不完整**的，但没有任何错误提示
- 后续 `click @eN` 用 snapshot 没收录到的引用，会报"unknown ref"（#38 的部分成因）

## 建议方案

**方案 A**：去掉 10000 静默截断，改用合理默认值 + 警告：
```v
const ax_tree_parse_safety_limit = 1_000_000  // 1M 次足够任何合理 AX tree

if i > ax_tree_parse_safety_limit {
    srv_log_err('AX tree parse hit safety limit at ${i}; tree is unusually large')
    break
}
```

如果真到了 100M 次还在迭代，说明 JSON 格式坏了 — 那才是真正的安全限制。

**方案 B**：先一次扫描估算 node 数量，超过 `max_nodes` 时直接退出并报告：
```v
total_nodes := estimate_node_count(nodes_json)  // O(N) 字符扫描
if total_nodes > 10000 {
    return '{"truncated":true,"totalNodes":${total_nodes},"rendered":${max_nodes}}'
}
```

## 验收标准

- [ ] 10000 静默截断去掉（或者改成显式 truncation 提示）
- [ ] snapshot 输出在截断时包含 `truncated: true` 字段
- [ ] 加 `srv_log_err` 警告便于运维发现
- [ ] 单测：构造 15000 个 node 的 AX tree，验证截断提示输出
- [ ] 帮助用户避免 silent data loss（这条 issue 的根本目标）

## 备注

这是个**正确性 + 性能**混合问题：
- 性能角度：限制解析时间有道理
- 正确性角度：silent truncation 隐藏 bug，让用户误以为拿到了完整快照

单独 PR 修复即可。关联 issue：#24 (snapshot incremental), #38 (stale ref error)