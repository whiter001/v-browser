# [Perf] `snapshot` 每次全量重算，可增量缓存

> 标签: `performance`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/commands.v:1335-1393` (`cmd_snapshot`)
> - `packages/server/src/commands.v:1395-1453` (`render_ax_tree`)
> - `packages/server/src/commands.v:1455-1545` (`build_cursor_interactive_snapshot_js`)

## 背景

`snapshot` 流程：
1. `Accessibility.getFullAXTree` — 拉整个 AX tree（大页面 5MB+）
2. `render_ax_tree` — 手写 `cdp_balanced` 逐字符解析每个 node
3. （可选）`render_cursor_interactive_snapshot` — `querySelectorAll` 全文档扫描

`i > 10000` 静默退出，可能漏节点。

## 问题描述

AI Agent 经常 1 秒调多次 `snapshot`（比如观察交互前后 DOM 变化），每次都拉全量 + 全量解析。

- 单次 snapshot 平均 200–500ms（大页面 1s+）
- 重复 snapshot 99% 内容相同

## 量化收益

重复 snapshot 提速 ~10×（缓存命中后 < 30ms）。

## 建议方案

1. **服务端 hash 缓存**：
   ```v
   struct SnapshotCache {
       url_hash  string
       ax_hash   string  // Accessibility.getFullAXTree 结果的 xxhash
       ref_hash  string  // cursor scan 结果 hash
       expires   time.Time
       output    string
   }
   ```
2. **`--snapshot-cache-ttl 5s`** flag。
3. **增量 mode**：`--snapshot --diff <baseline>` 只输出新增/移除的 `@eN` 引用。
4. **提前终止**：安全计数器改成"软上限 + 警告"，不要静默截断。

## 验收标准

- [ ] 重复 snapshot（同 URL 5s 内）命中缓存，p99 < 30ms
- [ ] 缓存命中时返回 `cache-hit: true` 元数据
- [ ] 文档说明 `--no-cache` 强制绕过
- [ ] `--snapshot --diff` 输出实际 diff（line-based）