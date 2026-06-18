# [UX] `find --list` / `find --debug` 错误信息应提示其他 role 也支持

> 标签: `ux`, `P2`, `area/cli`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:2358-2365` (`cmd_find` debug/list 限制)
> - `packages/server/src/main.v:1038-1113` (`parse_cli_to_ipc` find 分支)

## 背景

`cmd_find` 对 `--debug` / `--list` 模式做了角色限制：

```v
if debug_mode || list_mode {
    if locator != 'text' {
        return 'ERROR:--debug and --list currently support only find text'
    }
    ...
}
```

## 问题描述

```bash
$ v-browser find --role link --name "Learn" --list
Error: --debug and --list currently support only find text
```

实际：
- 内部 `build_semantic_locator_js` 已经支持 `role/text/label/placeholder/alt/title/testid/first/last/nth` 所有 locator
- `--list` 只在 `text` 上有用是过度限制——其他 role 也可以做候选列表

错误信息：
- 没有告诉用户"其他 role 不支持"的原因
- 没有建议"去掉 --list/--debug 试试"
- 跟实际行为（"list 模式只对 text 调试有意义"）脱节

## 建议方案

两条路之一：

**A. 放开限制**：让 `--list` / `--debug` 对所有 locator 工作。复用现有的 `semantic_text_candidates_report` 路径，参数化 locator 类型。

**B. 改进错误信息**：保持限制但说清楚：

```
ERROR:--debug and --list currently support only find text; for other locators, run without --list/--debug.
```

A 更彻底（用户能拿到候选列表做精确选择），B 改动小。建议 A。

## 验收标准

- [ ] `v-browser find --role button --list` 返回 button 候选列表
- [ ] `v-browser find --placeholder "email" --list` 返回 placeholder 候选
- [ ] 单测覆盖：role / placeholder / testid 三种 locator 都能 list
- [ ] docs 更新示例