# v-browser 最短可执行 SOP

这份 SOP 面向日常浏览器自动化，目标是少走弯路、减少误点、提高可复现性。

## 1. 连接

```bash
cd packages/server
./v-browser connect
```

先确认连接状态和当前页面。

```bash
./v-browser status
./v-browser get url
./v-browser get title
```

如果 `connect` 因为错误的 `chrome-extension://` 页面失败，先切到普通网页标签页，再重试连接。

## 2. 导航和读页面

```bash
./v-browser open https://x.com
./v-browser --json eval 'document.body.innerText'
./v-browser eval 'document.querySelector("h1")?.innerText'
```

动态页面优先用 `eval`，不要只依赖静态快照。

## 3. 操作元素

优先按语义定位，再按可见性和上下文确认。

```bash
./v-browser find text "发帖" click
./v-browser find role button click --name "保存"
./v-browser find label "Email" fill "test@example.com"
```

对于富文本或 React 页面，优先使用 `fill`、`type`、`keyboard type` 等真实输入方式，而不是直接改 DOM 属性。

## 4. X / Twitter 转帖 SOP

1. 打开目标推文。
2. 点击转帖按钮。
3. 选择“引用”。
4. 填写文案。
5. 上传图片。
6. 如有替代文本要求，进入媒体编辑器，填写 alt 文本并保存。
7. 检查是否仍停留在 `compose/post` 或 `compose/post/media`。
8. 只在确认按钮状态正确后提交。
9. 提交后再次核对 URL 或页面状态，确认真的发出去了。

### 容易踩坑的点

- `tweetButton` 才是最终提交按钮，`tweetButtonInline` 往往只是回复按钮。
- 图片替代文本要通过编辑器真实保存，不能只改图片 DOM 的 `alt`。
- 如果页面一直提示图片没有描述，优先回到媒体编辑层检查是否真的保存成功。

## 5. 结果验证

```bash
./v-browser get url
./v-browser eval 'document.body.innerText.slice(0,1200)'
./v-browser eval 'Array.from(document.querySelectorAll("img")).map(img => img.alt)'
```

至少确认一项：页面跳转、成功提示、发布内容出现、或按钮状态发生变化。
