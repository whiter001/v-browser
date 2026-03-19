# 图片剪贴板实验记录

这份记录总结了在 v-browser 里把已展示图片复制到系统剪贴板的几种尝试，以及最后可用的结论。

## 测试对象

- 图片直链：`https://pbs.twimg.com/media/HDwHaSCbQAAMgOb?format=jpg&name=small`
- 页面场景：先在 Edge 里直接打开图片直链，再在页面上下文里测试复制。

## 逐步实验结果

### 1. `document.execCommand('copy')`

- 把图片节点选中后执行 `document.execCommand('copy')`。
- 结果：返回 `false`。
- 结论：这条路不适合做图片复制自动化。

### 2. `navigator.clipboard.write(...)` 直接写图片

- 在前台页面里调用 `navigator.clipboard.write([new ClipboardItem(...)])`。
- 结果：如果页面没有焦点，会报 `NotAllowedError: Document is not focused`。
- 结论：Clipboard API 需要前台焦点和用户激活，不能在后台稳定执行。

### 3. 直接把原图 JPEG 写入剪贴板

- 先用 `fetch(location.href)` 拿到图片 blob。
- 结果：`ClipboardItem` 对 `image/jpeg` 不支持，报 `Type image/jpeg not supported on write`。
- 结论：这条链路不能直接把 JPEG 原样塞进剪贴板。

### 4. 先转成 PNG 再写入剪贴板

- 把原图 blob 先解码，再绘制到 `canvas`，输出为 `image/png`。
- 结果：
  - 小尺寸 PNG 可以成功写入剪贴板。
  - 原图尺寸的 PNG 在这次实验里会失败，报 `DataError: Failed to read or decode ClipboardItemData for type image/png`。
  - 把图片缩小后再写入，成功。

## 当前可行方案

如果目标是“稳定自动化复制图片”，建议用下面这条链路：

1. 在前台、可见、可交互的页面里触发。
2. 通过 `fetch` 拿到图片 bytes。
3. 统一转成 PNG 后再写入剪贴板。
4. 如果原图尺寸太大，先缩放再写入。

## 结论

- `execCommand('copy')` 不适合图片复制。
- `navigator.clipboard.write` 是正确方向，但它要求前台焦点和用户激活。
- 对 X 图片这类场景，最稳的是先转 PNG；如果原尺寸 PNG 写入失败，再降采样后写入。

## 后续实现建议

- 如果要把这个能力放进 v-browser，优先做成一个前台 UI 按钮或扩展页面动作。
- 扩展侧可考虑补 `clipboardWrite` 权限，但权限本身不能替代焦点和用户激活。
- 如果要保留原尺寸且稳定，可能需要另找更底层的实现路径。
