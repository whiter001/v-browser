# [Feature] `v-browser network har` 导出 HAR 1.2

> 标签: `feature`, `P2`, `area/server`, `good-first-issue`
> 工作量: S
> 相关文件:
> - `packages/server/src/commands.v:3111-3300` (`cmd_network`)
> - `packages/server/src/cdp_session.v:1330-1331` (`tracked_network_request_json`)

## 背景

已缓存所有 CDP 网络请求（`TrackedNetworkRequest`）和 hook 记录（`HookRecord`），可以直接导出 HAR。

HAR (HTTP Archive) 1.2 是行业标准格式，Charles / Chrome DevTools / Postman 都支持。

## 建议方案

新增 `network har <path>` 子命令：

```bash
v-browser network har ./out.har
v-browser network har ./out.har --filter api --status 4xx
v-browser network har ./out.har --include-hooks   # 把 hook body 也合并进来
```

输出结构：
```json
{
  "log": {
    "version": "1.2",
    "creator": { "name": "v-browser", "version": "0.1.0" },
    "entries": [
      {
        "startedDateTime": "2026-06-18T10:30:00.000Z",
        "request": { "method": "GET", "url": "...", "headers": [...], "postData": {...} },
        "response": { "status": 200, "headers": [...], "content": { "text": "..." } },
        "cache": {},
        "timings": { "send": 0, "wait": 50, "receive": 20 }
      }
    ]
  }
}
```

## 验收标准

- [ ] 输出文件可被 Chrome DevTools Network 面板导入验证
- [ ] 过滤参数与 `network requests` 一致
- [ ] `--include-hooks` 合并 hook 记录的 requestBody/responseBody
- [ ] 文档：导出后用 Chrome / Charles 打开

## 参考

- HAR Spec: http://www.softwareishard.com/blog/har-12-spec/
- Playwright `page.on('request')` + 自实现 export