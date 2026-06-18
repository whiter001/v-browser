# v-browser Issues 总索引

> 本目录收录从代码审查中拆分出来的可执行 issue 草稿，便于直接 `gh issue create --body-file` 上传到 GitHub。

## 标签约定

| 标签 | 含义 |
|---|---|
| `security` | 安全相关，需立刻修 |
| `bug` | 行为缺陷或崩溃风险 |
| `performance` | 性能优化 |
| `feature` | 新功能 |
| `ux` | 易用性 / CLI 体验 |
| `cleanup` | 代码质量、技术债 |
| `good-first-issue` | 适合新人上手 |
| `help-wanted` | 欢迎外部贡献 |
| `area/server` | 涉及 V 服务端 |
| `area/extension` | 涉及浏览器扩展 |
| `area/test-ui` | 涉及测试台 |
| `area/cli` | 涉及 CLI 解析 |
| `area/docs` | 仅涉及文档 |

## 优先级

- **P0** — 立刻修（安全 / 严重 bug / 数据丢失风险）
- **P1** — 本迭代必须修
- **P2** — 下迭代清理
- **P3** — 长期 / nice-to-have

## 工作量

- **S** ≤ 2h
- **M** ≤ 0.5d
- **L** ≤ 2d
- **XL** > 2d

---

## 清单（按优先级倒序）

### P0 — Security (5)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [security/01-token-generation.md](security/01-token-generation.md) | 连接 token 使用弱哈希生成，可被秒级暴力破解 | S | [#25](https://github.com/whiter001/v-browser/issues/25) |
| [security/02-relay-bind-all-interfaces.md](security/02-relay-bind-all-interfaces.md) | WebSocket Relay 默认监听所有网卡，攻击面扩大 | S | [#26](https://github.com/whiter001/v-browser/issues/26) |
| [security/03-relay-missing-origin-check.md](security/03-relay-missing-origin-check.md) | Relay 不校验 Origin/Host，DNS rebinding 可绕过 | S | [#27](https://github.com/whiter001/v-browser/issues/27) |
| [security/04-cmd-swallow-timeout.md](security/04-cmd-swallow-timeout.md) | `cmd_open`/`wait_load` 等 select 分支吞掉超时 | S | [#28](https://github.com/whiter001/v-browser/issues/28) |
| [security/05-path-traversal.md](security/05-path-traversal.md) | screenshot/pdf/upload 接受任意文件路径，无沙箱 | M | [#29](https://github.com/whiter001/v-browser/issues/29) |

### P0 — Bug (4)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [bug/01-cmd-click-error-swallowed.md](bug/01-cmd-click-error-swallowed.md) | `cmd_click/dblclick/hover` 内层 fallback 报错被外层吞掉 | S | [#8](https://github.com/whiter001/v-browser/issues/8) |
| [bug/02-pending-leak-tab-switch.md](bug/02-pending-leak-tab-switch.md) | tab 切换不清空 `pending`，旧请求可能投递到错误 tab | M | [#9](https://github.com/whiter001/v-browser/issues/9) |
| [bug/03-event-subscribe-race.md](bug/03-event-subscribe-race.md) | `subscribe` 前已触发的事件会通过新 channel 立刻投递 | M | [#10](https://github.com/whiter001/v-browser/issues/10) |
| [bug/04-route-goroutine-leak.md](bug/04-route-goroutine-leak.md) | `network route` 启动的 goroutine 缺少兜底退出 | M | [#11](https://github.com/whiter001/v-browser/issues/11) |

### P1 — Performance (5)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [performance/01-eval-base64-overhead.md](performance/01-eval-base64-overhead.md) | 每次 `eval` 都做 base64+TextDecoder round-trip | S | [#21](https://github.com/whiter001/v-browser/issues/21) |
| [performance/02-click-triple-resolve.md](performance/02-click-triple-resolve.md) | `click` 重复 resolve 元素坐标 2~3 次 | S | [#22](https://github.com/whiter001/v-browser/issues/22) |
| [performance/03-network-spawn-storm.md](performance/03-network-spawn-storm.md) | `Network.loadingFinished` 每个请求都 spawn 协程 | M | [#23](https://github.com/whiter001/v-browser/issues/23) |
| [performance/04-snapshot-incremental.md](performance/04-snapshot-incremental.md) | `snapshot` 每次全量重算，可增量缓存 | M | [#24](https://github.com/whiter001/v-browser/issues/24) |
| [performance/05-cdp-msg-json-decode.md](performance/05-cdp-msg-json-decode.md) | CDP 消息字段解析用 substring 扫描 | M | [#35](https://github.com/whiter001/v-browser/issues/35) |

### P1 — Feature (8)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [feature/01-repl-watch-mode.md](feature/01-repl-watch-mode.md) | `v-browser repl` / `--watch` 长连接模式 | L | [#13](https://github.com/whiter001/v-browser/issues/13) |
| [feature/02-script-batch-mode.md](feature/02-script-batch-mode.md) | 接受 stdin JSON-lines 批量命令 | L | [#14](https://github.com/whiter001/v-browser/issues/14) |
| [feature/03-retry-until.md](feature/03-retry-until.md) | 所有动作支持 `--retry` / `--until` | M | [#15](https://github.com/whiter001/v-browser/issues/15) |
| [feature/04-session-preset.md](feature/04-session-preset.md) | `v-browser session start --preset` 配置即代码 | M | [#16](https://github.com/whiter001/v-browser/issues/16) |
| [feature/05-assert-subcommand.md](feature/05-assert-subcommand.md) | `v-browser assert` 子命令统一断言 + 退出码 | M | [#17](https://github.com/whiter001/v-browser/issues/17) |
| [feature/06-har-export.md](feature/06-har-export.md) | `network har` 导出 HAR 1.2 | S | [#18](https://github.com/whiter001/v-browser/issues/18) |
| [feature/07-screencast-record.md](feature/07-screencast-record.md) | `record start/stop/replay` 录制与回放 | XL | [#19](https://github.com/whiter001/v-browser/issues/19) |
| [feature/08-named-session.md](feature/08-named-session.md) | `session create/use` 支持多 tab 并行 | XL | [#20](https://github.com/whiter001/v-browser/issues/20) |

### P2 — UX (5)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [ux/01-doctor-command.md](ux/01-doctor-command.md) | `v-browser --doctor` 一键自检 | M | [#30](https://github.com/whiter001/v-browser/issues/30) |
| [ux/02-error-code-system.md](ux/02-error-code-system.md) | 错误码 + 文档链接 + next-step 建议 | M | [#31](https://github.com/whiter001/v-browser/issues/31) |
| [ux/03-snapshot-json-output.md](ux/03-snapshot-json-output.md) | `snapshot --json` 结构化输出 | S | [#32](https://github.com/whiter001/v-browser/issues/32) |
| [ux/04-exit-code-standardization.md](ux/04-exit-code-standardization.md) | 退出码分层（0/1/2/3/4） | S | [#33](https://github.com/whiter001/v-browser/issues/33) |
| [ux/05-shell-completion.md](ux/05-shell-completion.md) | `v-browser completion bash/zsh/fish` | M | [#34](https://github.com/whiter001/v-browser/issues/34) |

### P3 — Cleanup (1)

| 文件 | 标题 | 工作量 | 状态 |
|---|---|---|---|
| [cleanup/01-style-and-doc.md](cleanup/01-style-and-doc.md) | L1-L20 风格/注释/死代码集中清理 | M | [#12](https://github.com/whiter001/v-browser/issues/12) |

---

## 一键创建到 GitHub

```bash
# 需要先 gh auth login
gh issue create \
  --label "security,P0,area/server" \
  --title "$(awk -F: '/^# /{print $2; exit}' issues/security/01-token-generation.md | xargs)" \
  --body-file issues/security/01-token-generation.md

# 或者用脚本批量上传（见 scripts/upload-issues.sh）
```

## 维护建议

1. 每个 issue 完成时同步更新 `INDEX.md` 中的状态列。
2. P0 项每周 review；P1 每月 review；P2/P3 每季度整理一次。
3. `area/*` 标签分配到对应 milestone，便于按区域看进度。