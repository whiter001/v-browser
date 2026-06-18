# [Feature] `record start/stop/replay` 录制与回放

> 标签: `feature`, `P2`, `area/server`, `area/extension`
> 工作量: XL
> 相关文件:
> - `packages/server/src/commands.v:5021-5076` (`cmd_trace` 可作参考)
> - `packages/server/src/cdp_session.v:331-360` (`on_message` 转发)

## 背景

AI Agent 调试关键场景：能把一次操作全过程录像，并导出为可分享文件。Playwright 有 Trace Viewer；v-browser 目前只有 trace/profiler，没有视频流。

## 建议方案

### Recording

```bash
v-browser record start --output ./rec.cast        # 二进制 + 操作日志
v-browser record stop
```

录制内容：
- `Page.startScreencast` 接收 frame（base64 PNG → 可选 opus 视频流）
- 同步记录 `Input.dispatchKeyEvent` / `Input.dispatchMouseEvent` / 网络事件 / console
- 输出格式：自定义二进制（参考 asciinema `.cast`）

### Replay

```bash
v-browser record replay ./rec.cast --speed 2x
v-browser record replay ./rec.cast --from <timestamp> --to <timestamp>
```

实现：
- 终端播放：screencast frame 转 ANSI 半块字符 + 输入事件回放到终端
- 浏览器回放：把 frame 拼成 webm，事件通过 `Input.dispatch*` 重放

## 验收标准

- [ ] 录制 30s 操作生成文件 ≤ 10MB（关键帧 + delta）
- [ ] 回放速度可调（0.5x / 1x / 2x / 4x）
- [ ] 回放时所有动作重新执行（DOM 已变也能尽量恢复）
- [ ] 文档：与 trace / profiler 的区别（录像是"看"，trace 是"分析"）

## 参考

- asciinema: terminal recording
- Playwright Trace Viewer
- Chrome DevTools Recorder