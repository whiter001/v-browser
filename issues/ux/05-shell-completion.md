# [UX] `v-browser completion bash/zsh/fish` 自动补全脚本

> 标签: `ux`, `P2`, `area/cli`, `help-wanted`
> 工作量: M
> 相关文件:
> - 新增 `packages/server/src/completion.v`
> - `packages/server/src/cli_help.v:4-135` (`cli_usage_lines`)

## 背景

CLI 命令已经接近 100 个，但用户记不住 flag 和子命令。每次都 `v-browser --help` 太繁琐。

## 建议方案

新增 `completion` 子命令，为各 shell 输出补全脚本：

```bash
v-browser completion bash > /etc/bash_completion.d/v-browser
v-browser completion zsh > "${fpath[1]}/_v-browser"
v-browser completion fish > ~/.config/fish/completions/v-browser.fish
v-browser completion powershell > v-browser.ps1
```

实现要点：
- 静态补全：命令、子命令、通用 flag（`--json`, `--raw`, `--selector`...）
- 动态补全：
  - `--tab-id` / `--window-id` 从 `tab list` 读取
  - `--extension-id` 从本地配置读取
  - `--url` 历史 from `~/.v-browser/url_history`

## 验收标准

- [ ] bash/zsh/fish 三套补全脚本可用
- [ ] 动态补全 `v-browser tab <TAB>` 显示 list/new/switch/close
- [ ] 动态补全 `v-browser --tab-id <TAB>` 显示当前所有 tab
- [ ] README 增加安装补全的一行命令
- [ ] CI 校验补全脚本能 source 不报错

## 参考

- kubectl completion
- docker completion