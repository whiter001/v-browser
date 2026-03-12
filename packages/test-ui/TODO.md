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

- 已通过：open、wait、title、fill、select、check、click、hover、upload、frame、localstorage、sessionstorage、cookies、network requests（通过 eval 触发）
- 仍待确认：dialog。当前在 Chrome + debugger/extension 这条链路里，点击按钮和直接 eval 都没有让 `Page.handleJavaScriptDialog` 看到可处理的 JS dialog，更像运行环境限制，不是 fixture 靶点缺失
