# [Security] WebSocket Relay 默认监听所有网卡

> 标签: `security`, `P0`, `area/server`
> 工作量: S
> 相关文件:
> - `packages/server/src/server.v:175-237` (`run_ws_server`)
> - `packages/server/src/server.v:15-21` (`configured_relay_port`)

## 背景

v-browser 默认在 `0.0.0.0:47978` 上启动 WebSocket Relay，扩展从 `127.0.0.1` 连过来。代码用的是 V 标准库的 `websocket.new_server(.ip, port, ...)`，`.ip` 表示 dual-stack INADDR_ANY。

## 问题描述

```v
// server.v:177
mut ws := websocket.new_server(.ip, relay, '', websocket.ServerOpt{})
```

- 在公司/家庭 NAT 下，局域网其他设备能直接握手这个端口。
- 即使本机启用了 firewall（很多 Windows 默认允许 47978 这样的高位端口），LAN 设备仍可访问。
- 配合 `S3 (origin 检查缺失)` 形成可利用链：恶意网站通过 WebRTC 信令或 DNS rebinding 把浏览器引到 `ws://192.168.x.x:47978`。

## 建议方案

把监听地址强制锁 loopback：

```v
mut listener := net.listen_tcp(.ip, '127.0.0.1:${relay}') or { ... }
ws := websocket.new_server_from_listener(listener, websocket.ServerOpt{})
```

若 V 标准库不直接支持，从现有 `websocket.new_server` 入手时，用底层 `net.Listen` + 自包装。最简方案是新增 `websocket.ServerOpt{ host: '127.0.0.1' }`（如果支持），或在 `on_connect` 拒绝 `peer_addr` 不在 loopback 段的所有连接。

## 验收标准

- [ ] 默认绑定 `127.0.0.1`（IPv4）和 `[::1]`（IPv6 loopback）
- [ ] LAN 设备 `nc -zv <host-ip> 47978` 失败
- [ ] `can_reach_ipc_server` 仍能连到 `127.0.0.1` 上的 relay
- [ ] 通过 `V_BROWSER_RELAY_PORT` 配置不影响 binding 逻辑
- [ ] CI 加 `ss -tlnp | grep 47978` 断言仅 loopback

## 参考

- CWE-1327: Binding to an Unrestricted IP Address
- Mozilla MDN: WebSocket server 安全清单