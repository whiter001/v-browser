# [Feature] `v-browser session start --preset` 配置即代码

> 标签: `feature`, `P1`, `area/cli`, `area/server`
> 工作量: M
> 相关文件:
> - `packages/server/src/commands.v:5109-5273` (`cmd_set`)
> - 新增 `packages/server/src/commands/session_preset.v`

## 背景

重复场景（如"以某个 user 登录态访问 GitHub"）当前要 5+ 条命令组合：

```bash
v-browser cookies set --name token --value xxx --domain .github.com
v-browser set headers '{"X-Debug":"1"}'
v-browser set viewport --width 1440 --height 900
v-browser storage set --key theme --value dark
v-browser open https://github.com
```

## 建议方案

JSON preset 文件 + 一键应用：

```json
{
  "name": "github-debug",
  "viewport": { "width": 1440, "height": 900 },
  "cookies": [
    { "name": "token", "value": "xxx", "domain": ".github.com" }
  ],
  "headers": { "X-Debug": "1" },
  "storage": {
    "local": { "theme": "dark" }
  },
  "extraHeaders": {
    "*": { "X-Forwarded-For": "127.0.0.1" }
  },
  "url": "https://github.com"
}
```

CLI：

```bash
v-browser session start --preset ./github.json
v-browser session start --preset github-debug  # 从 ~/.v-browser/presets/ 加载
```

## 验收标准

- [ ] preset 文件支持 cookies/headers/storage/viewport/url/geo
- [ ] preset 存储位置：`~/.v-browser/presets/` + `./.v-browser/presets/`
- [ ] `v-browser session list` 列出已加载 preset
- [ ] preset 可嵌套引用：`{"extends": "github-base", ...}`
- [ ] 文档：完整 preset schema 定义

## 参考

- Playwright Projects: 复用登录态
- Postman Environments: 配置即代码