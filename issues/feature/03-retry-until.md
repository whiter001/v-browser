# [Feature] 所有动作支持 `--retry` / `--until`

> 标签: `feature`, `P1`, `area/cli`, `good-first-issue`
> 工作量: M
> 相关文件:
> - `packages/server/src/main.v:718-1508` (`parse_cli_to_ipc` 全部分支)
> - `packages/server/src/commands.v` 各 cmd_ 实现

## 背景

目前只有 `wait` 命令支持等待条件，其他动作（`click`、`fill`、`eval`）执行后立即返回，调用方必须自己包 `wait + retry` 循环。

```bash
# 当前模式
v-browser click "#submit"
v-browser wait --url "*/success"
# 重试
v-browser click "#submit"  # 失败的话
```

## 建议方案

为所有动作加 `--retry N --interval 200ms`：

```bash
v-browser click "#submit" --retry 5 --interval 200ms \
    --until "#success-message:visible"
```

实现：
- 在 `dispatch_command` 顶层包一层 retry 装饰器
- retry 每次重新 dispatch 直到成功或次数用完
- `--until` 接受 selector / url / text / fn，与 wait 一致

## 验收标准

- [ ] `click/fill/eval/upload/select` 都接受 `--retry N --interval ms`
- [ ] `--until` 复用 `wait` 的所有条件
- [ ] retry 用尽返回最后一次的错误
- [ ] 单测：mock 一个命令第 2 次才成功，验证 retry 正确
- [ ] 文档：README 增加常见 retry 模式示例

## 参考

- Playwright `expect(locator).toHaveText()` 自动 retry
- Selenium `WebDriverWait`