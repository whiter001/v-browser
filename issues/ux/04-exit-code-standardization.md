# [UX] 退出码分层（0/1/2/3/4）

> 标签: `ux`, `P2`, `area/cli`, `good-first-issue`
> 工作量: S
> 相关文件:
> - `packages/server/src/main.v:60-78` (`exit(1)` 散落各处)
> - `packages/server/src/main.v:381-385` (`shutdown_server_process` `exit(0)`)

## 背景

当前所有错误统一 `exit(1)`，shell 脚本无法区分：

```bash
v-browser click "#btn" || echo "failed"   # 不知道是网络还是找不到元素
```

## 建议方案

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 通用命令错误（默认） |
| 2 | 断言/校验失败（assert 子命令用） |
| 3 | 超时 |
| 4 | 连接/扩展不可用 |
| 5 | 权限/路径拒绝 |
| 64–78 | 沿用 BSD sysexits.h（EX_USAGE=64, EX_DATAERR=65...） |

实现：

```v
const exit_success = 0
const exit_error = 1
const exit_assertion = 2
const exit_timeout = 3
const exit_not_connected = 4
const exit_permission = 5

fn exit_with_code(code int) {
    if json_output {
        println('{"ok":false,"exitCode":${code}}')
    }
    exit(code)
}
```

## 验收标准

- [ ] 每个 cmd_xxx 错误返回时附带正确 exit code
- [ ] `assert` 失败用 exit code 2
- [ ] `--json` 模式 stdout 输出 `exitCode`
- [ ] 文档：`docs/exit-codes.md` 列出所有码
- [ ] shell 测试：`set -e` + `[[ $? -eq 4 ]]` 可区分"扩展没装"vs"元素找不到"

## 参考

- BSD sysexits.h
- grep exit codes (0/1/2)