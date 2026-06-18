# [Security] screenshot/pdf/upload 接受任意文件路径，无沙箱

> 标签: `security`, `P0`, `area/server`, `area/cli`
> 工作量: M
> 相关文件:
> - `packages/server/src/commands.v:583-590` (`cmd_screenshot` 写文件)
> - `packages/server/src/commands.v:1226-1231` (`cmd_pdf` 写文件)
> - `packages/server/src/commands.v:1980-2002` (`cmd_upload` 读 + 写文件)
> - `packages/server/src/commands.v:1977` (`files.split(',')` 直接读)
> - `packages/server/src/main.v:518` 路径构造

## 背景

CLI 接受 `--path` 参数透传给 server，server 直接调用 `os.write_file_array(path, bytes)` / `os.read_file(path)`，没有白名单校验。

## 问题描述

```bash
# 覆写系统关键文件（取决于运行用户权限）
v-browser screenshot --path /etc/cron.d/backdoor --annotate

# 读任意文件
v-browser eval 'await (await fetch("file:///etc/passwd")).text()'
# (fetch 不支持 file://，但 --file 参数会读任意路径)
v-browser eval --file /root/.ssh/id_rsa

# upload 文件路径
v-browser upload --selector "input[type=file]" --files "/root/.ssh/id_rsa,/etc/shadow"
```

虽然 CLI 不直接支持 `cmd_upload --files /etc/shadow`，但内部 `files_str.split(',')` 完全透传给 CDP `DOM.setFileInputFiles`，扩展侧会把任何路径的文件读出来再 base64 发回。

## 建议方案

1. **白名单**：限制 `--path` 必须在 `V_BROWSER_HOME` 或显式 `--allow-path` 列表下。
2. **绝对路径校验**：`os.real_path` 解析后与 `safe_root` 比对。
3. **敏感目录黑名单**：默认拒绝 `/etc`, `/root`, `~/.ssh`, `~/Library/Keychains`, `C:\Windows\System32\config`。
4. **upload 文件大小限制**：单文件 ≤ 100MB（`MAX_UPLOAD_BYTES` 常量）。
5. **扩展侧二次校验**：在 `relayConnection.ts` 收到 `DOM.setFileInputFiles` 时拒绝路径穿越。

## 验收标准

- [ ] `--path /etc/passwd` 被拒，返回明确错误码 `PATH_NOT_ALLOWED`
- [ ] `cmd_upload` 调用前校验每个文件存在且在白名单
- [ ] 新增 `V_BROWSER_SAFE_PATH` 环境变量，CLI 默认 `~/Downloads`
- [ ] 单测：mock 一个 `cmd_upload`，传入 `/etc/shadow` 验证被拒

## 参考

- OWASP Path Traversal: https://owasp.org/www-community/attacks/Path_Traversal
- CWE-22