# [Feature] `v-browser assert` 子命令统一断言 + 退出码

> 标签: `feature`, `P1`, `area/cli`
> 工作量: M
> 相关文件:
> - 新增 `packages/server/src/commands/assert.v`
> - `packages/server/src/main.v:718+` (parse_cli_to_ipc)

## 背景

当前要做断言需要 `is visible + && exit` 多步组合，脚本层很难写：

```bash
v-browser is visible "#modal" || { echo "modal not visible"; exit 1; }
v-browser get text "#modal" | grep -q "success" || exit 1
```

## 建议方案

统一 `assert` 子命令：

```bash
v-browser assert visible "#modal"                  # 元素可见
v-browser assert hidden "#loading-spinner"         # 元素不可见
v-browser assert checked "#agree-checkbox"         # 已勾选
v-browser assert text "#status" "Order confirmed"  # 文本匹配
v-browser assert url "*/orders/123"                # URL glob
v-browser assert count ".item" 10                  # 元素数量
v-browser assert eval 'window.app.ready === true'  # JS 表达式
v-browser assert response "api/users" 200          # 网络响应
```

退出码：
- 0 — 断言通过
- 2 — 断言失败（区别于命令错误 1）
- 3 — 超时

带 `--timeout 5s` / `--retry 3`。

## 验收标准

- [ ] 所有上述断言类型实现
- [ ] 失败时退出码 2，超时退出码 3
- [ ] `--diff` 输出实际值与期望值差异（JSON）
- [ ] 文档：CI 集成示例
- [ ] 单测：覆盖每种断言的成功/失败路径

## 参考

- Playwright `expect()` API
- Cypress `cy.should()`