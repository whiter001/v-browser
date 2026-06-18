# [Security] 连接 token 使用弱哈希生成，可被秒级暴力破解

> 标签: `security`, `P0`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/server.v:415-434` (`load_or_create_token`)
> - `packages/server/src/server.v:444-447` (`validate_extension_token`)

## 背景

v-browser 在启动 WebSocket Relay 之前会调用 `load_or_create_token` 生成一个 16 字节十六进制 token，扩展连接时把它放在 URL query string (`?token=...`) 中传给 Relay。Relay 通过 `validate_extension_token` 做相等比较后放行。

## 问题描述

```v
// server.v:425-431
now := time.now().unix_milli()
raw := '${now}-${os.getpid()}-vbrowser'
mut h := u64(0)
for b in raw.bytes() {
    h = h * 31 + u64(b)
}
token := h.hex()
```

- `raw` 的熵完全来自 `time.unix_milli()` + `os.getpid()`，攻击者拿到自己的时间/PID 后即可预测。
- 自定义 `h * 31 + b` 哈希没有 secret，可逆推原始字符串。
- 注释 `// 简易伪随机 token（生产可换 crypto random）` 表明作者已知问题但未修。
- `validate_extension_token` 用 `==` 直接比较 token，存在时序攻击面（V 字符串比较是否 constant-time 未确认）。

## 复现步骤

1. 拿到任意一次 `v-browser status` 输出的 token（用户在 bug 报告里随手贴的概率不低）。
2. 用同一时段的 `time + PID + 'vbrowser'` 字典循环 2^16 ≈ 65536 次（PID 通常 < 65535），几秒内命中。

## 建议方案

1. **生成**：用 `crypto.rand_bytes(32)` 取 32 字节随机；或 `time.now().unix_nano()` 拼 `secure_rand`。
2. **比较**：用 `secrets.compare_digest(token, expected)`（V 标准库暂无，自写 `compare_constant_time` 也可）。
3. **持久化**：保持现状 `~/.v-browser/token`，但加 `0600` 文件权限（`os.chmod`）。
4. **轮转**：每次 `v-browser server restart` 重新生成；老 token 自动失效。

## 验收标准

- [ ] `load_or_create_token` 调用 `crypto.rand_bytes` 或 OS 级 `/dev/urandom`
- [ ] token 长度 ≥ 32 字节（≥ 256 bit 熵）
- [ ] 比较走 constant-time 函数
- [ ] token 文件权限 `0600`
- [ ] 单元测试：连续生成两个 token 至少有一个比特位不同

## 参考

- OWASP: https://cheatsheetseries.owasp.org/cheatsheets/Cryptographic_Storage_Cheat_Sheet.html
- CVE 案例：CWE-330 (Use of Insufficiently Random Values)