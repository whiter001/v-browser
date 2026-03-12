# test-ui fixture plan

- [x] 提供独立的 fixture 页面，和仪表盘职责分离
- [x] 覆盖 click、dblclick、hover、focus、fill、type、select、check、uncheck 所需靶点
- [x] 覆盖 wait、scroll、drag、upload、dialog、frame 所需靶点
- [x] 覆盖 get/is/find/testid/title/alt/placeholder 等定位与查询场景
- [x] 覆盖 localStorage、sessionStorage、cookie、network requests 所需靶点
- [x] 将首页默认 open URL 指向 fixture 页面
- [x] 构建 test-ui 并做基础手工验证
- [ ] 用 v-browser 对关键能力逐项验证

## 验证观察

- 已通过：open、wait、title、fill、select、check、localstorage、sessionstorage、cookies、network requests（通过 eval 触发）
- 待确认：click、hover、upload、dialog、frame 内 DOM 读取，这一轮表现更像 v-browser 命令行为问题，不是 fixture 缺少靶点
