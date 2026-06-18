# [Perf] CDP 消息字段解析用 substring 扫描

> 标签: `performance`, `P1`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/cdp_session.v:1459-1611` (`cdp_extract_*`)
> - `packages/server/src/cdp_session.v:1444-1457` (`cdp_parse_message`)

## 背景

```v
fn cdp_extract_int(s string, key string) int {
    idx := s.index(key) or { return 0 }
    ...
}

fn cdp_extract_str(s string, key string) string {
    search := '"${key}":'
    idx := s.index(search) or { return '' }
    ...
}
```

每个字段调用一次 `index` 扫描整条 JSON 字符串。

## 问题描述

`ProtocolResponse.result` 在 hook/snapshot/network 中频繁访问，每条消息平均 5–10 次字段提取。

- `cdp_extract_str` 用 `cdp_balanced` 配对括号，单次 100–500ns
- 网络事件密集场景（> 1k/s）时 CPU 100% 吃满

## 量化收益

- 单次消息解析 **3–5×** 提速
- 高频场景下 CPU 占用降一半

## 建议方案

把 `ProtocolResponse.result` 一次性 decode 到 `map[string]json.Any`，后续字段 O(1) 取：

```v
import x.json2 as json

struct ParsedResponse {
    raw     string
    decoded map[string]json.Any  // 缓存
}

fn (p ParsedResponse) get_int(key string) int { ... }
fn (p ParsedResponse) get_str(key string) string { ... }
```

只在第一次访问时 decode。

## 验收标准

- [ ] benchmark：解析 100 条典型 CDP 响应，验证 ≥ 3× 提速
- [ ] 不破坏现有 cdp_extract_* 调用方（提供兼容层）
- [ ] 内存：避免缓存全部消息，只缓存最近 N 条
- [ ] 单测：保留现有 1844 行测试的覆盖