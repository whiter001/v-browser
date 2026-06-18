# [Security] Relay 不校验 Origin / Host，存在 DNS rebinding 风险

> 标签: `security`, `P0`, `area/server`, `area/extension`
> 工作量: S
> 相关文件:
> - `packages/server/src/server.v:178-203` (`on_connect` 回调)
> - `packages/extension/src/ui/connect.tsx:58-69` (`runAsync` URL 解析)

## 背景

WebSocket 握手时，浏览器会带 `Origin: chrome-extension://<id>` 头。恶意网站加载的脚本可以创建 `new WebSocket('ws://localhost:47978/?token=...')`，通过 DNS rebinding 让受害者的浏览器解析到一个攻击者控制的 IP，或者反过来——把受害者浏览器作为代理访问 Relay。

## 问题描述

```v
// server.v:178-203
ws.on_connect(fn [mut s] (mut sc websocket.ServerClient) !bool {
    if !validate_extension_token(sc.resource_name, s.token) {
        ...
    }
    ...
})
```

- 只校验 URL query string 里的 token，没看 `sc.headers['Origin']`。
- 即使绑 loopback (`127.0.0.1`)，恶意网页里的 JS 也能 `new WebSocket('ws://127.0.0.1:47978/...')`，浏览器对自家内网不做特殊处理。

## 建议方案

1. **Origin 白名单**：
   ```v
   origin := sc.headers['Origin'] or { '' }
   if !origin.starts_with('chrome-extension://') && origin != 'null' {
       return false
   }
   ```
2. **Host 严格匹配**：`sc.headers['Host']` 必须等于 `127.0.0.1:47978` 或 `[::1]:47978`。
3. **扩展侧加强**：`connect.tsx` 已经有 loopback 检查（`host === '127.0.0.1'`），但**只是字符串校验**，DNS rebinding 可以让 127.0.0.1 解析成外部 IP。需在浏览器端也做 Origin 锁定（Chrome 的 `chrome.webRequest` / 扩展 manifest `content_security_policy`）。

## 验收标准

- [ ] WebSocket 握手时校验 `Origin` 必须是 `chrome-extension://<id>` 或不存在（CLOSE 1008）
- [ ] 文档明确列出允许的 Origin 白名单
- [ ] 测试用例：模拟 Origin=`http://evil.com` 的握手必须被拒
- [ ] 模拟 DNS rebinding 场景（`ws://127.0.0.1.xip.io`）也应被拒

## 参考

- https://github.com/nickthecook/shorts/wiki/WebSocket-Security
- https://blog.mozilla.org/security/2017/10/04/mitigating-rebinding-attacks/