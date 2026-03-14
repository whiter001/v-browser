// commands.v — 所有 CLI 命令实现
// dispatch_command 由 server.v 的 IPC dispatch 调用
module main

import os
import time
import encoding.base64

struct DevicePreset {
	name       string
	width      int
	height     int
	scale      f64
	mobile     bool
	has_touch  bool
	user_agent string
}

struct DownloadEventState {
mut:
	guid               string
	suggested_filename string
	url                string
	file_path          string
	state              string
}

struct ScreenshotDiffResult {
	ok             bool
	error          string
	width          int
	height         int
	changed_pixels int
	total_pixels   int
	ratio          f64
	diff_data      string
}

// dispatch_command 命令路由
fn dispatch_command(mut sess CdpSession, method string, params string) string {
	return match method {
		'eval' { cmd_eval(mut sess, params) }
		'open', 'goto', 'navigate' { cmd_open(mut sess, params) }
		'close', 'quit', 'exit' { cmd_close(mut sess) }
		'screenshot' { cmd_screenshot(mut sess, params) }
		'snapshot' { cmd_snapshot(mut sess, params) }
		'pdf' { cmd_pdf(mut sess, params) }
		'click' { cmd_click(mut sess, params) }
		'dblclick' { cmd_dblclick(mut sess, params) }
		'download' { cmd_download(mut sess, params) }
		'fill' { cmd_fill(mut sess, params) }
		'type' { cmd_type_text(mut sess, params) }
		'press', 'key' { cmd_press(mut sess, params) }
		'keydown' { cmd_keydown(mut sess, params) }
		'keyup' { cmd_keyup(mut sess, params) }
		'hover' { cmd_hover(mut sess, params) }
		'focus' { cmd_focus(mut sess, params) }
		'select' { cmd_select(mut sess, params) }
		'check' { cmd_check(mut sess, params) }
		'uncheck' { cmd_uncheck(mut sess, params) }
		'scroll' { cmd_scroll(mut sess, params) }
		'scrollintoview', 'scrollinto' { cmd_scrollintoview(mut sess, params) }
		'drag' { cmd_drag(mut sess, params) }
		'upload' { cmd_upload(mut sess, params) }
		'get' { cmd_get(mut sess, params) }
		'is' { cmd_is(mut sess, params) }
		'wait' { cmd_wait(mut sess, params) }
		'find' { cmd_find(mut sess, params) }
		'tab' { cmd_tab(mut sess, params) }
		'window' { cmd_window(mut sess, params) }
		'keyboard' { cmd_keyboard(mut sess, params) }
		'mouse' { cmd_mouse(mut sess, params) }
		'cookies' { cmd_cookies(mut sess, params) }
		'storage' { cmd_storage(mut sess, params) }
		'network' { cmd_network(mut sess, params) }
		'frame' { cmd_frame(mut sess, params) }
		'dialog' { cmd_dialog(mut sess, params) }
		'highlight' { cmd_highlight(mut sess, params) }
		'console' { cmd_console(mut sess, params) }
		'errors' { cmd_errors(mut sess, params) }
		'trace' { cmd_trace(mut sess, params) }
		'profiler' { cmd_profiler(mut sess, params) }
		'set' { cmd_set(mut sess, params) }
		'diff' { cmd_diff(mut sess, params) }
		'state' { cmd_state(mut sess, params) }
		else { 'ERROR:unknown command: ${method}' }
	}
}

fn cmd_not_impl(name string) string {
	return 'ERROR:command ${name} not yet implemented'
}

// ─── eval ───────────────────────────────────────────────────
fn cmd_eval(mut sess CdpSession, params string) string {
	expr := cdp_extract_str(params, 'expression')
	if expr == '' {
		return 'ERROR:missing expression'
	}
	await_promise := cdp_extract_str(params, 'awaitPromise') == 'true'
	as_b64 := cdp_extract_str(params, 'base64') == 'true'
	actual_expr := if as_b64 {
		decoded := base64.decode_str(expr)
		decoded
	} else {
		expr
	}
	val := eval_scoped_expression(mut sess, actual_expr, await_promise) or { return 'ERROR:${err}' }
	return json_str(val)
}

fn build_scoped_runtime_js(sess &CdpSession, body string) string {
	if sess.current_frame_selector == '' {
		return '(function(document, window){ ${body} })(document, window)'
	}
	frame_sel := js_str(sess.current_frame_selector)
	return '(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; return (function(document, window){ ${body} })(doc, win); })()'
}

fn evaluate_bool_js(mut sess CdpSession, js string) !bool {
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	result := cdp_extract_obj_key(resp.result, '"result":')
	val := cdp_extract_value_from_result(result)
	return val == 'true'
}

fn eval_scoped_expression(mut sess CdpSession, expr string, await_promise bool) !string {
	encoded_expr := base64.encode_str(expr)
	scoped_expr := build_scoped_runtime_js(&sess, 'var raw=window.atob(${js_str(encoded_expr)}); var bytes=Uint8Array.from(raw, function(ch){ return ch.charCodeAt(0); }); return window.eval(new TextDecoder().decode(bytes));')
	p := '{"expression":${json_str(scoped_expr)},"returnByValue":true,"awaitPromise":${await_promise}}'
	resp := sess.send_command('Runtime.evaluate', p)!
	result := cdp_extract_obj_key(resp.result, '"result":')
	return cdp_extract_value_from_result(result)
}

fn resolve_object_id_by_selector(mut sess CdpSession, sel string) !string {
	js := build_scoped_runtime_js(&sess, 'return document.querySelector(${js_str(sel)});')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}')!
	object_id := cdp_extract_str(resp.result, 'objectId')
	if object_id == '' {
		return error('element not found: ${sel}')
	}
	return object_id
}

fn run_element_action(mut sess CdpSession, sel string, body string) ! {
	js := build_element_scope_js(&sess, sel, 'if(el === null) return false; ${body}')
	result := eval_scoped_expression(mut sess, js, false)!
	ok := result == 'true'
	if !ok {
		return error('element not found: ${sel}')
	}
}

fn build_action_point_query_js(sess &CdpSession, locator_js string) string {
	return build_document_scope_js(sess, '
			var el = (${locator_js});
			if (!el) return null;
			el.scrollIntoView({ block: "center", inline: "center" });
			var style = win.getComputedStyle(el);
			if (style.visibility === "hidden" || style.display === "none" || style.pointerEvents === "none") return null;
			if ("disabled" in el && el.disabled) return null;
			var r = el.getBoundingClientRect();
			if (r.width <= 0 || r.height <= 0) return null;
			if (frame) {
				var fr = frame.getBoundingClientRect();
				return { x: fr.x + r.x + r.width / 2, y: fr.y + r.y + r.height / 2, width: r.width, height: r.height };
			}
			return { x: r.x + r.width / 2, y: r.y + r.height / 2, width: r.width, height: r.height };
		')
}

fn resolve_action_point_by_js(mut sess CdpSession, locator_js string) !ResolvedElement {
	js := build_action_point_query_js(&sess, locator_js)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('element not actionable')
	}
	return ResolvedElement{
		x:      cdp_extract_float(value_obj, 'x')
		y:      cdp_extract_float(value_obj, 'y')
		width:  cdp_extract_float(value_obj, 'width')
		height: cdp_extract_float(value_obj, 'height')
	}
}

fn scroll_resolved_element_into_view(mut sess CdpSession, sel string, el ResolvedElement) ! {
	if el.backend_node_id > 0 {
		sess.send_command('DOM.scrollIntoViewIfNeeded', '{"backendNodeId":${el.backend_node_id}}')!
		return
	}
	js := build_element_scope_js(&sess, sel, 'if(!el) return false; el.scrollIntoView({block:"center",inline:"center"}); return true;')
	if !evaluate_bool_js(mut sess, js)! {
		return error('element not found: ${sel}')
	}
}

fn pointer_move(mut sess CdpSession, x f64, y f64) ! {
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseMoved","x":${x},"y":${y},"button":"none"}')!
}

fn pointer_hover(mut sess CdpSession, x f64, y f64) ! {
	pointer_move(mut sess, x, y)!
}

fn pointer_click(mut sess CdpSession, x f64, y f64, click_count int) ! {
	pointer_move(mut sess, x, y)!
	for index := 1; index <= click_count; index++ {
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mousePressed","x":${x},"y":${y},"button":"left","clickCount":${index}}')!
		time.sleep(20 * time.millisecond)
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${x},"y":${y},"button":"left","clickCount":${index}}')!
		if index < click_count {
			time.sleep(40 * time.millisecond)
		}
	}
}

fn pointer_action_for_selector(mut sess CdpSession, sel string, action string) ! {
	mut el := resolve_selector(mut sess, sel)!
	scroll_resolved_element_into_view(mut sess, sel, el)!
	el = resolve_selector(mut sess, sel) or { el }
	match action {
		'click' { pointer_click(mut sess, el.x, el.y, 1)! }
		'dblclick' { pointer_click(mut sess, el.x, el.y, 2)! }
		'hover' { pointer_hover(mut sess, el.x, el.y)! }
		else { return error('unknown pointer action: ${action}') }
	}
}

fn pointer_action_for_locator_js(mut sess CdpSession, locator_js string, action string) ! {
	el := resolve_action_point_by_js(mut sess, locator_js)!
	match action {
		'click' { pointer_click(mut sess, el.x, el.y, 1)! }
		'hover' { pointer_hover(mut sess, el.x, el.y)! }
		else { return error('unknown pointer action: ${action}') }
	}
}

fn build_click_action_body() string {
	return 'if(typeof el.click === "function") { el.click(); return true; } el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: win })); return true;'
}

fn build_dblclick_action_body() string {
	return 'if(typeof el.click === "function") { el.click(); el.click(); } el.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true, view: win, detail: 2 })); return true;'
}

fn build_hover_action_body() string {
	return 'var events=["pointerover","mouseover","pointerenter","mouseenter","mousemove"]; for (var i=0;i<events.length;i++) { var name=events[i]; el.dispatchEvent(new MouseEvent(name, { bubbles: name !== "mouseenter" && name !== "pointerenter", cancelable: true, view: window })); } return true;'
}

fn build_fill_action_body(text string) string {
	value_js := js_str(text)
	return 'el.focus(); if ("value" in el) { el.value = ""; el.dispatchEvent(new Event("input", { bubbles: true })); el.value = ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } if (el.isContentEditable) { el.textContent = ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); return true; } return false;'
}

fn build_type_action_body(text string) string {
	value_js := js_str(text)
	return 'el.focus(); if ("value" in el) { var current = el.value || ""; el.value = current + ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } if (el.isContentEditable) { el.textContent = (el.textContent || "") + ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); return true; } return false;'
}

fn build_toggle_action_body(checked bool) string {
	checked_js := if checked { 'true' } else { 'false' }
	return 'if(!("checked" in el)) return false; el.focus(); el.checked = ${checked_js}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;'
}

fn cdp_extract_value_from_result(result_obj string) string {
	t := cdp_extract_str(result_obj, 'type')
	match t {
		'string' {
			return cdp_extract_str(result_obj, 'value')
		}
		'number' {
			return cdp_extract_obj_key(result_obj, '"value":')
		}
		'boolean' {
			return cdp_extract_obj_key(result_obj, '"value":')
		}
		'undefined' {
			return 'undefined'
		}
		'object' {
			sub_type := cdp_extract_str(result_obj, 'subtype')
			if sub_type == 'null' {
				return 'null'
			}
			v := cdp_extract_obj_key(result_obj, '"value":')
			return if v != '' { v } else { result_obj }
		}
		else {
			return result_obj
		}
	}
}

// ─── open / navigate ────────────────────────────────────────
fn cmd_open(mut sess CdpSession, params string) string {
	url := cdp_extract_str(params, 'url')
	if url == '' {
		return 'ERROR:missing url'
	}
	// 订阅 loadEventFired
	load_ch := sess.subscribe('Page.loadEventFired')
	defer { sess.unsubscribe('Page.loadEventFired', load_ch) }

	sess.send_command('Page.navigate', '{"url":${json_str(url)}}') or { return 'ERROR:${err}' }
	// 等待页面加载完成（最多 30s）
	select {
		_ := <-load_ch {}
		30 * time.second {}
	}
	return json_str('navigated to ${url}')
}

// ─── close ──────────────────────────────────────────────────
fn cmd_close(mut sess CdpSession) string {
	sess.send_command('Target.closeTarget', '{}') or {}
	sess.close()
	return 'null'
}

// ─── screenshot ─────────────────────────────────────────────
fn cmd_screenshot(mut sess CdpSession, params string) string {
	path := cdp_extract_str(params, 'path')
	full := cdp_extract_str(params, 'full') == 'true'
	format := cdp_extract_str(params, 'format')
	fmt := if format != '' { format } else { 'png' }
	quality := cdp_extract_int(params, '"quality":')

	mut p := '{"format":"${fmt}","captureBeyondViewport":${full}'
	if quality > 0 {
		p += ',"quality":${quality}'
	}
	p += '}'

	resp := sess.send_command('Page.captureScreenshot', p) or { return 'ERROR:${err}' }
	data := cdp_extract_str(resp.result, 'data')
	if data == '' {
		return 'ERROR:no screenshot data returned'
	}

	// 决定保存路径
	out_path := if path != '' {
		path
	} else {
		os.join_path(os.temp_dir(), 'screenshot_${time.now().unix_milli()}.${fmt}')
	}
	raw_bytes := base64.decode(data)
	os.write_file_array(out_path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
	return json_str(out_path)
}

fn capture_screenshot_base64(mut sess CdpSession, format string, full bool, selector string) !string {
	mut p := '{"format":"${format}"'
	if selector != '' {
		mut el := resolve_selector(mut sess, selector)!
		scroll_resolved_element_into_view(mut sess, selector, el)!
		el = resolve_selector(mut sess, selector) or { el }
		clip_x := el.x - el.width / 2
		clip_y := el.y - el.height / 2
		p += ',"clip":{"x":${clip_x},"y":${clip_y},"width":${el.width},"height":${el.height},"scale":1}'
		p += ',"captureBeyondViewport":true'
	} else {
		p += ',"captureBeyondViewport":${full}'
	}
	p += '}'
	resp := sess.send_command('Page.captureScreenshot', p)!
	data := cdp_extract_str(resp.result, 'data')
	if data == '' {
		return error('no screenshot data returned')
	}
	return data
}

fn ensure_download_behavior(mut sess CdpSession, download_dir string) !string {
	os.mkdir_all(download_dir)!
	browser_params := '{"behavior":"allow","downloadPath":${json_str(download_dir)},"eventsEnabled":true}'
	sess.send_command('Browser.setDownloadBehavior', browser_params) or {
		sess.send_command('Page.setDownloadBehavior', '{"behavior":"allow","downloadPath":${json_str(download_dir)}}') or {
			install_dom_download_capture(mut sess)!
			return 'dom'
		}
		return 'native'
	}
	return 'native'
}

fn unique_download_dir() string {
	return os.join_path(os.temp_dir(), 'v_browser_download_${time.now().unix_milli()}')
}

fn apply_click_for_download(mut sess CdpSession, sel string) ! {
	run_element_action(mut sess, sel, build_click_action_body()) or {
		pointer_action_for_selector(mut sess, sel, 'click')!
		return
	}
}

fn update_download_event_state(mut state DownloadEventState, evt ProtocolResponse) bool {
	guid := cdp_extract_str(evt.params, 'guid')
	if guid != '' && state.guid != '' && guid != state.guid {
		return false
	}
	if guid != '' {
		state.guid = guid
	}
	suggested := cdp_extract_str(evt.params, 'suggestedFilename')
	if suggested != '' {
		state.suggested_filename = suggested
	}
	url := cdp_extract_str(evt.params, 'url')
	if url != '' {
		state.url = url
	}
	file_path := cdp_extract_str(evt.params, 'filePath')
	if file_path != '' {
		state.file_path = file_path
	}
	event_state := cdp_extract_str(evt.params, 'state')
	if event_state != '' {
		state.state = event_state
	}
	return true
}

fn resolve_downloaded_file_path(download_dir string, state DownloadEventState) !string {
	if state.file_path != '' && os.exists(state.file_path) {
		return state.file_path
	}
	mut candidates := []string{}
	if state.suggested_filename != '' {
		candidates << os.join_path(download_dir, state.suggested_filename)
	}
	if state.guid != '' {
		candidates << os.join_path(download_dir, state.guid)
	}
	for candidate in candidates {
		if os.exists(candidate) {
			return candidate
		}
	}
	entries := os.ls(download_dir) or { []string{} }
	if entries.len == 1 {
		return os.join_path(download_dir, entries[0])
	}
	if entries.len > 1 && state.suggested_filename != '' {
		for entry in entries {
			if entry.starts_with(state.suggested_filename) {
				return os.join_path(download_dir, entry)
			}
		}
	}
	return error('download completed but file was not found in ${download_dir}')
}

fn detect_completed_download_in_dir(download_dir string) string {
	entries := os.ls(download_dir) or { return '' }
	for entry in entries {
		if entry.ends_with('.crdownload') || entry.ends_with('.tmp') {
			continue
		}
		path := os.join_path(download_dir, entry)
		if os.is_file(path) {
			return path
		}
	}
	return ''
}

fn install_dom_download_capture(mut sess CdpSession) ! {
	js := build_document_scope_js(&sess, '
		if (win.__vBrowserDownloadCaptureInstalled) return true;
		win.__vBrowserDownloadCaptureInstalled = true;
		win.__vBrowserDownloadQueue = win.__vBrowserDownloadQueue || [];
		function queueAnchorDownload(anchor) {
			if (!anchor) return;
			var href = anchor.href || anchor.getAttribute("href");
			if (!href) return;
			var url = new URL(href, doc.baseURI).href;
			var filename = anchor.getAttribute("download") || url.split("/").pop() || "download";
			fetch(url, { credentials: "include" })
				.then(function(response) {
					if (!response.ok) throw new Error("HTTP " + response.status);
					return response.arrayBuffer();
				})
				.then(function(buffer) {
					var bytes = new Uint8Array(buffer);
					var chunks = [];
					for (var i = 0; i < bytes.length; i += 0x8000) {
						chunks.push(String.fromCharCode.apply(null, Array.from(bytes.slice(i, i + 0x8000))));
					}
					win.__vBrowserDownloadQueue.push({ ok: true, url: url, filename: filename, data: btoa(chunks.join("")) });
				})
				.catch(function(err) {
					win.__vBrowserDownloadQueue.push({ ok: false, url: url, filename: filename, error: String(err) });
				});
		}
		if (!win.__vBrowserOriginalAnchorClick && win.HTMLAnchorElement && win.HTMLAnchorElement.prototype) {
			win.__vBrowserOriginalAnchorClick = win.HTMLAnchorElement.prototype.click;
			win.HTMLAnchorElement.prototype.click = function() {
				if (this && this.getAttribute && this.hasAttribute("download")) {
					queueAnchorDownload(this);
					return;
				}
				return win.__vBrowserOriginalAnchorClick.call(this);
			};
		}
		doc.addEventListener("click", function(event) {
			var target = event.target;
			if (!target || !target.closest) return;
			var anchor = target.closest("a[download]");
			if (!anchor) return;
			event.preventDefault();
			queueAnchorDownload(anchor);
		}, true);
		return true;
	')
	eval_scoped_expression(mut sess, js, false)!
}

fn pull_dom_download_capture(mut sess CdpSession) !string {
	js := build_document_scope_js(&sess, 'var queue = win.__vBrowserDownloadQueue || []; if (queue.length === 0) return null; return JSON.stringify(queue.shift());')
	return eval_scoped_expression(mut sess, js, false)!
}

fn write_dom_download_result(raw string, target_path string) !string {
	if raw == '' || raw == 'null' {
		return error('no DOM download payload available')
	}
	mut payload := raw.trim_space()
	if payload.contains('\\"') {
		payload = payload.replace('\\"', '"').replace('\\\\', '\\')
	}
	ok := cdp_extract_obj_key(payload, '"ok":') == 'true'
	if !ok {
		message := cdp_extract_str(payload, 'error')
		return error(if message != '' { message } else { 'download payload reported failure' })
	}
	filename := cdp_extract_str(payload, 'filename')
	data := cdp_extract_str(payload, 'data')
	if data == '' {
		return error('download payload missing data')
	}
	out_path := if target_path != '' {
		target_path
	} else {
		os.join_path(os.temp_dir(), if filename != '' { filename } else { 'download.bin' })
	}
	parent_dir := os.dir(out_path)
	if parent_dir != '' {
		os.mkdir_all(parent_dir)!
	}
	os.write_file_array(out_path, base64.decode(data))!
	return out_path
}

fn fetch_download_via_dom(mut sess CdpSession, sel string, target_path string) !string {
	js := build_element_scope_js(&sess, sel, '
		if (!el) return JSON.stringify({ ok: false, error: "element not found" });
		var href = el.href || el.getAttribute("href");
		if (!href) return JSON.stringify({ ok: false, error: "element has no href" });
		var url = new URL(href, doc.baseURI).href;
		var filename = el.getAttribute("download") || url.split("/").pop() || "download";
		return fetch(url, { credentials: "include" })
			.then(function(response) {
				if (!response.ok) throw new Error("HTTP " + response.status);
				return response.arrayBuffer();
			})
			.then(function(buffer) {
				var bytes = new Uint8Array(buffer);
				var chunks = [];
				for (var i = 0; i < bytes.length; i += 0x8000) {
					chunks.push(String.fromCharCode.apply(null, Array.from(bytes.slice(i, i + 0x8000))));
				}
				return JSON.stringify({ ok: true, url: url, filename: filename, data: btoa(chunks.join("")) });
			})
			.catch(function(err) {
				return JSON.stringify({ ok: false, url: url, filename: filename, error: String(err) });
			});
	')
	raw := eval_scoped_expression(mut sess, js, true)!
	return write_dom_download_result(raw, target_path)
}

fn wait_for_dom_download(mut sess CdpSession, target_path string, timeout time.Duration) !string {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		raw := pull_dom_download_capture(mut sess) or { '' }
		if raw != '' && raw != 'null' {
			return write_dom_download_result(raw, target_path)!
		}
		time.sleep(200 * time.millisecond)
	}
	return error('timeout waiting for download')
}

fn finalize_download_path(source_path string, target_path string) !string {
	if target_path == '' {
		return source_path
	}
	if source_path == target_path {
		return source_path
	}
	parent_dir := os.dir(target_path)
	if parent_dir != '' {
		os.mkdir_all(parent_dir)!
	}
	if os.exists(target_path) {
		os.rm(target_path)!
	}
	os.mv(source_path, target_path)!
	return target_path
}

fn wait_for_download(mut sess CdpSession, download_dir string, target_path string, timeout time.Duration) !string {
	begin_browser := sess.subscribe('Browser.downloadWillBegin')
	begin_page := sess.subscribe('Page.downloadWillBegin')
	progress_browser := sess.subscribe('Browser.downloadProgress')
	progress_page := sess.subscribe('Page.downloadProgress')
	defer {
		sess.unsubscribe('Browser.downloadWillBegin', begin_browser)
		sess.unsubscribe('Page.downloadWillBegin', begin_page)
		sess.unsubscribe('Browser.downloadProgress', progress_browser)
		sess.unsubscribe('Page.downloadProgress', progress_page)
	}

	mut state := DownloadEventState{}
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		select {
			evt := <-begin_browser {
				update_download_event_state(mut state, evt)
			}
			evt := <-begin_page {
				update_download_event_state(mut state, evt)
			}
			evt := <-progress_browser {
				if !update_download_event_state(mut state, evt) {
					continue
				}
				if state.state == 'completed' {
					resolved := resolve_downloaded_file_path(download_dir, state)!
					return finalize_download_path(resolved, target_path)!
				}
				if state.state == 'canceled' {
					return error('download canceled')
				}
			}
			evt := <-progress_page {
				if !update_download_event_state(mut state, evt) {
					continue
				}
				if state.state == 'completed' {
					resolved := resolve_downloaded_file_path(download_dir, state)!
					return finalize_download_path(resolved, target_path)!
				}
				if state.state == 'canceled' {
					return error('download canceled')
				}
			}
			250 * time.millisecond {}
		}
		fallback_path := detect_completed_download_in_dir(download_dir)
		if fallback_path != '' {
			return finalize_download_path(fallback_path, target_path)!
		}
	}
	return error('timeout waiting for download')
}

fn build_dom_snapshot_js(sess &CdpSession, selector string, compact bool, max_depth int) string {
	selector_expr := if selector == '' {
		'doc.body || doc.documentElement'
	} else if selector.starts_with('//') || selector.starts_with('(//') {
		'doc.evaluate(${js_str(selector)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue'
	} else {
		'doc.querySelector(${js_str(selector)})'
	}
	compact_js := if compact { 'true' } else { 'false' }
	depth_limit := if max_depth > 0 { max_depth } else { 8 }
	return build_document_scope_js(sess, '
		var root = ${selector_expr};
		if (!root) return "";
		function normalizeText(value) {
			return String(value || "").replace(/\\s+/g, " ").trim();
		}
		function describe(el, depth) {
			var tag = (el.tagName || "node").toLowerCase();
			var label = tag;
			if (!${compact_js}) {
				if (el.id) label += "#" + el.id;
				var cls = Array.from(el.classList || []).filter(Boolean).slice(0, 2);
				if (cls.length) label += "." + cls.join(".");
			}
			var role = normalizeText(el.getAttribute && el.getAttribute("role"));
			var text = normalizeText(el.getAttribute && (el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("placeholder") || el.getAttribute("value")) || "");
			if (!text && el.children.length === 0) {
				text = normalizeText(el.textContent || "");
			}
			if (text.length > 80) text = text.slice(0, 77) + "...";
			var line = "  ".repeat(depth) + label;
			if (role) line += " [" + role + "]";
			if (text) line += " " + JSON.stringify(text);
			return line;
		}
		var lines = [];
		function visit(node, depth) {
			if (!node || depth > ${depth_limit}) return;
			if (node.nodeType !== Node.ELEMENT_NODE) return;
			lines.push(describe(node, depth));
			for (var i = 0; i < node.children.length; i++) visit(node.children[i], depth + 1);
		}
		visit(root, 0);
		return lines.join("\\n");
	')
}

fn capture_dom_snapshot(mut sess CdpSession, selector string, compact bool, max_depth int) !string {
	js := build_dom_snapshot_js(&sess, selector, compact, max_depth)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	result := cdp_extract_obj_key(resp.result, '"result":')
	return cdp_extract_value_from_result(result)
}

fn wait_for_navigation_state(mut sess CdpSession, state string) ! {
	match state {
		'', 'load' {
			ch := sess.subscribe('Page.loadEventFired')
			defer { sess.unsubscribe('Page.loadEventFired', ch) }
			select {
				_ := <-ch {}
				30 * time.second {
					return error('timeout waiting for load')
				}
			}
		}
		'domcontentloaded' {
			ch := sess.subscribe('Page.domContentEventFired')
			defer { sess.unsubscribe('Page.domContentEventFired', ch) }
			select {
				_ := <-ch {}
				30 * time.second {
					return error('timeout waiting for domcontentloaded')
				}
			}
		}
		'networkidle' {
			ch := sess.subscribe('Page.lifecycleEvent')
			defer { sess.unsubscribe('Page.lifecycleEvent', ch) }
			for {
				select {
					evt := <-ch {
						if cdp_extract_str(evt.params, 'name') == 'networkIdle' {
							return
						}
					}
					30 * time.second {
						return error('timeout waiting for networkidle')
					}
				}
			}
		}
		else {
			return error('unknown waitUntil state: ${state}')
		}
	}
}

fn navigate_and_wait(mut sess CdpSession, url string, state string) ! {
	mut event := 'Page.loadEventFired'
	if state == 'domcontentloaded' {
		event = 'Page.domContentEventFired'
	} else if state == 'networkidle' {
		event = 'Page.lifecycleEvent'
	}
	ch := sess.subscribe(event)
	defer { sess.unsubscribe(event, ch) }
	sess.send_command('Page.navigate', '{"url":${json_str(url)}}')!
	if state == 'networkidle' {
		for {
			select {
				evt := <-ch {
					if cdp_extract_str(evt.params, 'name') == 'networkIdle' {
						return
					}
				}
				30 * time.second {
					return error('timeout waiting for networkidle')
				}
			}
		}
	}
	select {
		_ := <-ch {}
		30 * time.second {
			return error('timeout waiting for ${state}')
		}
	}
}

fn baseline_mime_type(path string) string {
	lower := path.to_lower()
	if lower.ends_with('.jpg') || lower.ends_with('.jpeg') {
		return 'image/jpeg'
	}
	return 'image/png'
}

fn screenshot_diff_js(baseline_b64 string, baseline_mime string, current_b64 string, threshold f64, include_diff bool) string {
	include_diff_js := if include_diff { 'true' } else { 'false' }
	return '(async function(){\n' +
		'  var baselineSrc = "data:${baseline_mime};base64,${baseline_b64}";\n' +
		'  var currentSrc = "data:image/png;base64,${current_b64}";\n' +
		'  function load(src){ return new Promise(function(resolve,reject){ var img=new Image(); img.onload=function(){ resolve(img); }; img.onerror=function(){ reject(new Error("image decode failed")); }; img.src=src; }); }\n' +
		'  var images = await Promise.all([load(baselineSrc), load(currentSrc)]);\n' +
		'  var a = images[0];\n' + '  var b = images[1];\n' +
		'  if (a.naturalWidth !== b.naturalWidth || a.naturalHeight !== b.naturalHeight) { return { ok:false, error:"dimension mismatch", width:b.naturalWidth, height:b.naturalHeight }; }\n' +
		'  var w = a.naturalWidth;\n' + '  var h = a.naturalHeight;\n' +
		'  var c1 = document.createElement("canvas"); c1.width = w; c1.height = h;\n' +
		'  var c2 = document.createElement("canvas"); c2.width = w; c2.height = h;\n' +
		'  var diffCanvas = document.createElement("canvas"); diffCanvas.width = w; diffCanvas.height = h;\n' +
		'  var x1 = c1.getContext("2d"); var x2 = c2.getContext("2d"); var xd = diffCanvas.getContext("2d");\n' +
		'  x1.drawImage(a, 0, 0); x2.drawImage(b, 0, 0);\n' +
		'  var d1 = x1.getImageData(0, 0, w, h);\n' + '  var d2 = x2.getImageData(0, 0, w, h);\n' +
		'  var diff = xd.createImageData(w, h);\n' + '  var changed = 0;\n' +
		'  var limit = Math.round(${threshold} * 255);\n' +
		'  for (var i = 0; i < d1.data.length; i += 4) {\n' +
		'    var dr = Math.abs(d1.data[i] - d2.data[i]);\n' +
		'    var dg = Math.abs(d1.data[i+1] - d2.data[i+1]);\n' +
		'    var db = Math.abs(d1.data[i+2] - d2.data[i+2]);\n' +
		'    var da = Math.abs(d1.data[i+3] - d2.data[i+3]);\n' +
		'    var changedPx = Math.max(dr, dg, db, da) > limit;\n' + '    if (changedPx) {\n' +
		'      changed++;\n' +
		'      diff.data[i] = 255; diff.data[i+1] = 0; diff.data[i+2] = 0; diff.data[i+3] = 255;\n' +
		'    } else {\n' + '      var avg = Math.round((d2.data[i] + d2.data[i+1] +
		d2.data[i+2]) / 3);\n' +
		'      diff.data[i] = avg; diff.data[i+1] = avg; diff.data[i+2] = avg; diff.data[i+3] = 96;\n' +
		'    }\n' + '  }\n' + '  xd.putImageData(diff, 0, 0);\n' +
		'  return { ok:true, width:w, height:h, changedPixels:changed, totalPixels:w*h, ratio:(w*h?changed/(w*h):0), diffData:${include_diff_js} ? diffCanvas.toDataURL("image/png").split(",")[1] : "" };\n' +
		'})()'
}

fn run_screenshot_diff(mut sess CdpSession, baseline_b64 string, baseline_mime string, current_b64 string, threshold f64, output_path string) !ScreenshotDiffResult {
	js := screenshot_diff_js(baseline_b64, baseline_mime, current_b64, threshold, output_path != '')
	result := eval_scoped_expression(mut sess, js, true)!
	ok := cdp_extract_obj_key(result, '"ok":') == 'true'
	if !ok {
		return ScreenshotDiffResult{
			ok:    false
			error: cdp_extract_str(result, 'error')
		}
	}
	diff_data := cdp_extract_str(result, 'diffData')
	if output_path != '' && diff_data != '' {
		os.mkdir_all(os.dir(output_path)) or {}
		os.write_file_array(output_path, base64.decode(diff_data))!
	}
	return ScreenshotDiffResult{
		ok:             true
		width:          cdp_extract_int(result, '"width":')
		height:         cdp_extract_int(result, '"height":')
		changed_pixels: cdp_extract_int(result, '"changedPixels":')
		total_pixels:   cdp_extract_int(result, '"totalPixels":')
		ratio:          cdp_extract_float(result, 'ratio')
		diff_data:      diff_data
	}
}

// ─── pdf ────────────────────────────────────────────────────
fn cmd_pdf(mut sess CdpSession, params string) string {
	path := cdp_extract_str(params, 'path')
	if path == '' {
		return 'ERROR:missing path'
	}
	resp := sess.send_command('Page.printToPDF', '{"printBackground":true}') or {
		return 'ERROR:${err}'
	}
	data := cdp_extract_str(resp.result, 'data')
	if data == '' {
		return 'ERROR:no pdf data'
	}
	raw_bytes := base64.decode(data)
	os.write_file_array(path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
	return json_str(path)
}

// ─── snapshot ───────────────────────────────────────────────

// 可交互角色列表
const snapshot_interactive_roles = ['button', 'link', 'textbox', 'checkbox', 'radio',
	'combobox', 'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
	'searchbox', 'slider', 'spinbutton', 'switch', 'tab', 'treeitem', 'heading', 'image',
	'banner', 'navigation', 'region', 'main', 'form', 'search', 'dialog', 'alert',
	'alertdialog', 'complementary', 'contentinfo', 'definition', 'directory', 'document',
	'feed', 'figure', 'log', 'marquee', 'math', 'note', 'progressbar', 'status', 'table',
	'term', 'timer', 'tooltip', 'tree']

fn cmd_snapshot(mut sess CdpSession, params string) string {
	// 解析参数
	raw := cdp_extract_bool(params, 'raw')
	interactive := cdp_extract_bool(params, 'interactive')

	resp := sess.send_command('Accessibility.getFullAXTree', '{}') or { return 'ERROR:${err}' }
	nodes_json := cdp_extract_obj_key(resp.result, '"nodes":')
	if nodes_json == '' {
		return 'ERROR:no AX tree returned'
	}

	axref_clear(mut sess.axref)
	mut out := '= Accessibility Snapshot =\n'
	ax_out, next_counter := render_ax_tree(nodes_json, 1, mut sess.axref, interactive)
	out += ax_out
	
	// 只有在非 interactive 模式下才添加 cursor-interactive 元素
	if !interactive {
		cursor_out := render_cursor_interactive_snapshot(mut sess, next_counter, mut sess.axref) or {
			''
		}
		if cursor_out != '' {
			if ax_out != '' && !ax_out.ends_with('\n') {
				out += '\n'
			}
			out += '# Cursor-interactive elements:\n'
			out += cursor_out
		}
	}

	// raw 模式返回未编码的纯文本
	if raw {
		return out
	}
	return json_str(out)
}

fn render_ax_tree(nodes_json string, start_counter int, mut store AxRefStore, interactive bool) (string, int) {
	mut out := ''
	mut counter := start_counter
	mut pos := 1 // skip opening '['
	mut i := 0 // 安全计数器，防止解析过大的树时无限循环

	for pos < nodes_json.len - 1 {
		if nodes_json[pos] == `{` {
			node_str := cdp_balanced(nodes_json[pos..])
			role := ax_prop(node_str, 'role')
			name := ax_prop(node_str, 'name')
			bnid := cdp_extract_int(node_str, '"backendDOMNodeId":')
			
			// interactive 模式下只保留可交互角色
			// 非 interactive 模式下过滤 none 和 generic
			should_include := if interactive {
				role != '' && role in snapshot_interactive_roles
			} else {
				role != '' && role != 'none' && role != 'generic'
			}
			
			// 只有满足条件的才输出
			if should_include {
				ref_key := '@e${counter}'
				counter++
				out += '${ref_key} [${role}] ${name}\n'
				if bnid > 0 {
					axref_set(mut store, ref_key, AxRef{
						backend_node_id: bnid
						role:            role
						name:            name
					})
				}
			}
			pos += node_str.len
		} else {
			pos++
		}
		i++
		if i > 10000 {
			break
		}
		// 安全上限
	}
	return out, counter
}

fn build_cursor_interactive_snapshot_js(sess &CdpSession) string {
	return build_document_scope_js(sess, '
		var interactiveRoles = new Set([
			"button", "link", "textbox", "checkbox", "radio", "combobox", "listbox",
			"menuitem", "menuitemcheckbox", "menuitemradio", "option", "searchbox",
			"slider", "spinbutton", "switch", "tab", "treeitem"
		]);
		var interactiveTags = new Set(["a", "button", "input", "select", "textarea", "details", "summary"]);
		function normalizeText(value) {
			return String(value || "").replace(/\\s+/g, " ").trim();
		}
		function buildSelector(el) {
			var testId = el.getAttribute("data-testid");
			if (testId) return "[data-testid=" + JSON.stringify(testId) + "]";
			if (el.id) return "#" + CSS.escape(el.id);
			var path = [];
			var current = el;
			while (current && current !== doc.body) {
				var sel = current.tagName.toLowerCase();
				var classes = Array.from(current.classList || []).filter(function(name) { return String(name || "").trim() !== ""; });
				if (classes.length > 0) sel += "." + CSS.escape(classes[0]);
				var parent = current.parentElement;
				if (parent) {
					var siblings = Array.from(parent.children);
					var matching = siblings.filter(function(node) {
						if (node.tagName !== current.tagName) return false;
						if (classes.length > 0 && !node.classList.contains(classes[0])) return false;
						return true;
					});
					if (matching.length > 1) {
						sel += ":nth-of-type(" + (matching.indexOf(current) + 1) + ")";
					}
				}
				path.unshift(sel);
				current = current.parentElement;
				try {
					var candidate = path.join(" > ");
					if (doc.querySelectorAll(candidate).length === 1) break;
				} catch (e) {}
				if (path.length >= 8) break;
			}
			return path.join(" > ");
		}
		var seen = new Set();
		var results = [];
		var all = doc.querySelectorAll("*");
		for (var i = 0; i < all.length; i++) {
			var el = all[i];
			var tag = (el.tagName || "").toLowerCase();
			if (interactiveTags.has(tag)) continue;
			var role = normalizeText(el.getAttribute("role"));
			if (role && interactiveRoles.has(role.toLowerCase())) continue;
			var style = win.getComputedStyle(el);
			var hasCursorPointer = style.cursor === "pointer";
			var hasOnClick = el.hasAttribute("onclick") || typeof el.onclick === "function";
			var tabIndex = el.getAttribute("tabindex");
			var hasTabIndex = tabIndex !== null && tabIndex !== "-1";
			if (!hasCursorPointer && !hasOnClick && !hasTabIndex) continue;
			if (hasCursorPointer && !hasOnClick && !hasTabIndex) {
				var parentEl = el.parentElement;
				if (parentEl && win.getComputedStyle(parentEl).cursor === "pointer") continue;
			}
			if (style.visibility === "hidden" || style.display === "none" || style.pointerEvents === "none") continue;
			var rect = el.getBoundingClientRect();
			if (rect.width <= 0 || rect.height <= 0) continue;
			var text = normalizeText(el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title") || "");
			if (!text) continue;
			var selector = buildSelector(el);
			if (!selector || seen.has(selector)) continue;
			seen.add(selector);
			var hints = [];
			if (hasCursorPointer) hints.push("cursor:pointer");
			if (hasOnClick) hints.push("onclick");
			if (hasTabIndex) hints.push("tabindex");
			results.push({ selector: selector, text: text.slice(0, 120), role: hasCursorPointer || hasOnClick ? "clickable" : "focusable", hints: hints.join(", ") });
		}
		return results.map(function(item) {
			return [item.selector, item.text.replace(/[\t\n\r]+/g, " "), item.role, item.hints.replace(/[\t\n\r]+/g, " ")].join("\t");
		}).join("\n");
	')
}

fn render_cursor_interactive_snapshot(mut sess CdpSession, start_counter int, mut store AxRefStore) !string {
	js := build_cursor_interactive_snapshot_js(&sess)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	raw_lines := cdp_extract_value_from_result(result_obj)
	if raw_lines == '' || raw_lines == 'null' {
		return ''
	}
	mut out := ''
	mut counter := start_counter
	for line in raw_lines.split('\n') {
		parts := line.split('\t')
		if parts.len < 3 {
			continue
		}
		selector := parts[0].trim_space()
		text := parts[1].trim_space()
		role := parts[2].trim_space()
		hints := if parts.len > 3 { parts[3].trim_space() } else { '' }
		if selector == '' || text == '' {
			continue
		}
		ref_key := '@e${counter}'
		counter++
		resolved_role := if role != '' { role } else { 'clickable' }
		out += '${ref_key} [${resolved_role}] ${text}'
		if hints != '' {
			out += ' (${hints})'
		}
		out += '\n'
		axref_set(mut store, ref_key, AxRef{
			selector: selector
			role:     resolved_role
			name:     text
		})
	}
	return out
}

fn ax_prop(node_str string, prop string) string {
	// AX node 属性如 "role":{"type":"role","value":"button"}
	search := '"${prop}":'
	idx := node_str.index(search) or { return '' }
	val_obj := cdp_extract_value(node_str[idx + search.len..].trim_left(' '))
	if val_obj.starts_with('{') {
		return cdp_extract_str(val_obj, 'value')
	}
	return val_obj.trim('"')
}

// ─── click ──────────────────────────────────────────────────
fn cmd_click(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_click_action_body()) or {
		pointer_action_for_selector(mut sess, sel, 'click') or { return 'ERROR:${err}' }
		return 'null'
	}
	return 'null'
}

fn cmd_dblclick(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_dblclick_action_body()) or {
		pointer_action_for_selector(mut sess, sel, 'dblclick') or { return 'ERROR:${err}' }
		return 'null'
	}
	return 'null'
}

fn cmd_download(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	path := cdp_extract_str(params, 'path')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	if path == '' {
		return 'ERROR:missing path'
	}
	download_dir := unique_download_dir()
	mode := ensure_download_behavior(mut sess, download_dir) or { return 'ERROR:${err}' }
	final_path := if mode == 'dom' {
		fetch_download_via_dom(mut sess, sel, path) or { return 'ERROR:${err}' }
	} else {
		apply_click_for_download(mut sess, sel) or { return 'ERROR:${err}' }
		wait_for_download(mut sess, download_dir, path, 60 * time.second) or {
			return 'ERROR:${err}'
		}
	}
	return '{"path":${json_str(final_path)}}'
}

fn mouse_click(mut sess CdpSession, x f64, y f64) ! {
	pointer_click(mut sess, x, y, 1)!
}

// ─── hover ──────────────────────────────────────────────────
fn cmd_hover(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_hover_action_body()) or {
		pointer_action_for_selector(mut sess, sel, 'hover') or { return 'ERROR:${err}' }
		return 'null'
	}
	return 'null'
}

// ─── focus ──────────────────────────────────────────────────
fn cmd_focus(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	el := resolve_selector(mut sess, sel) or { return 'ERROR:${err}' }
	sess.send_command('DOM.focus', '{"backendNodeId":${el.backend_node_id}}') or {
		// fallback: Runtime.evaluate
		js := build_element_scope_js(&sess, sel, 'el?.focus()')
		sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {}
	}
	return 'null'
}

// ─── fill ───────────────────────────────────────────────────
fn cmd_fill(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_fill_action_body(text)) or { return 'ERROR:${err}' }
	return 'null'
}

// ─── type ───────────────────────────────────────────────────
fn cmd_type_text(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_type_action_body(text)) or { return 'ERROR:${err}' }
	return 'null'
}

// ─── keyboard ───────────────────────────────────────────────
fn cmd_keyboard(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	text := cdp_extract_str(params, 'text')
	return match action {
		'type', 'inserttext' {
			sess.send_command('Input.insertText', '{"text":${json_str(text)}}') or {
				return 'ERROR:${err}'
			}
			'null'
		}
		else {
			'ERROR:unknown keyboard action: ${action}'
		}
	}
}

// ─── press / keydown / keyup ─────────────────────────────────
fn cmd_press(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' {
		return 'ERROR:missing key'
	}
	dispatch_key(mut sess, key, 'keyDown') or { return 'ERROR:${err}' }
	dispatch_key(mut sess, key, 'keyUp') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keydown(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' {
		return 'ERROR:missing key'
	}
	dispatch_key(mut sess, key, 'keyDown') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keyup(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' {
		return 'ERROR:missing key'
	}
	dispatch_key(mut sess, key, 'keyUp') or { return 'ERROR:${err}' }
	return 'null'
}

fn dispatch_key(mut sess CdpSession, key string, typ string) ! {
	// 解析 Control+a 等组合键
	parts := key.split('+')
	mut modifiers := 0
	mut actual_key := key
	if parts.len > 1 {
		actual_key = parts.last()
		for mod in parts[..parts.len - 1] {
			modifiers |= match mod.to_lower() {
				'alt' { 1 }
				'control', 'ctrl' { 4 }
				'meta', 'command' { 8 }
				'shift' { 2 }
				else { 0 }
			}
		}
	}
	sess.send_command('Input.dispatchKeyEvent', '{"type":"${typ}","key":"${actual_key}","modifiers":${modifiers}}')!
}

// ─── select ─────────────────────────────────────────────────
fn cmd_select(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	value := cdp_extract_str(params, 'value')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	js := build_element_scope_js(&sess, sel, 'if(!el) return false; el.value=${js_str(value)}; el.dispatchEvent(new Event("change",{bubbles:true})); return true;')
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// ─── check / uncheck ────────────────────────────────────────
fn cmd_check(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_toggle_action_body(true)) or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_uncheck(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action(mut sess, sel, build_toggle_action_body(false)) or { return 'ERROR:${err}' }
	return 'null'
}

// ─── scroll ─────────────────────────────────────────────────
fn cmd_scroll(mut sess CdpSession, params string) string {
	direction := cdp_extract_str(params, 'direction')
	px_str := cdp_extract_obj_key(params, '"px":')
	px := if px_str != '' { px_str.int() } else { 300 }

	mut dx := 0
	mut dy := 0
	match direction {
		'up' { dy = -px }
		'down' { dy = px }
		'left' { dx = -px }
		'right' { dx = px }
		else { return 'ERROR:unknown direction: ${direction}' }
	}

	sel := cdp_extract_str(params, 'selector')
	if sel != '' {
		el := resolve_selector(mut sess, sel) or { return 'ERROR:${err}' }
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseWheel","x":${el.x},"y":${el.y},"deltaX":${dx},"deltaY":${dy}}') or {
			return 'ERROR:${err}'
		}
	} else {
		js := build_document_scope_js(&sess, 'win.scrollBy(${dx}, ${dy}); return true;')
		sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
			return 'ERROR:${err}'
		}
	}
	return 'null'
}

fn cmd_scrollintoview(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	js := build_element_scope_js(&sess, sel, "el?.scrollIntoView({block:'center',inline:'center'})")
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// ─── drag ───────────────────────────────────────────────────
fn cmd_drag(mut sess CdpSession, params string) string {
	src := cdp_extract_str(params, 'source')
	tgt := cdp_extract_str(params, 'target')
	if src == '' || tgt == '' {
		return 'ERROR:missing source or target'
	}
	src_el := resolve_selector(mut sess, src) or { return 'ERROR:src: ${err}' }
	tgt_el := resolve_selector(mut sess, tgt) or { return 'ERROR:tgt: ${err}' }

	// mousePressed → mouseMoved (steps) → mouseReleased
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mousePressed","x":${src_el.x},"y":${src_el.y},"button":"left","clickCount":1}') or {}
	// 分 10 步移动
	for step in 1 .. 11 {
		t := f64(step) / 10.0
		mx := src_el.x + (tgt_el.x - src_el.x) * t
		my := src_el.y + (tgt_el.y - src_el.y) * t
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseMoved","x":${mx},"y":${my},"button":"left"}') or {}
		time.sleep(10 * time.millisecond)
	}
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${tgt_el.x},"y":${tgt_el.y},"button":"left"}') or {}
	return 'null'
}

// ─── upload ─────────────────────────────────────────────────
fn cmd_upload(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	files_str := cdp_extract_str(params, 'files')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	files := files_str.split(',').map(it.trim_space()).filter(it != '')
	if files.len == 0 {
		return 'ERROR:no files specified'
	}
	files_json := '[' + files.map(json_str(it)).join(',') + ']'
	object_id := resolve_object_id_by_selector(mut sess, sel) or { return 'ERROR:${err}' }
	sess.send_command('DOM.setFileInputFiles', '{"objectId":${json_str(object_id)},"files":${files_json}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// ─── get ────────────────────────────────────────────────────
fn cmd_get(mut sess CdpSession, params string) string {
	prop := cdp_extract_str(params, 'property')
	sel := cdp_extract_str(params, 'selector')

	js := match prop {
		'text' {
			build_element_scope_js(&sess, sel, 'return el?.textContent;')
		}
		'html' {
			build_element_scope_js(&sess, sel, 'return el?.innerHTML;')
		}
		'value' {
			build_element_scope_js(&sess, sel, 'return el?.value;')
		}
		'title' {
			'document.title'
		}
		'url' {
			'window.location.href'
		}
		'count' {
			build_elements_scope_js(&sess, sel, 'return els.length;')
		}
		'attr' {
			attr := cdp_extract_str(params, 'attr')
			build_element_scope_js(&sess, sel, 'return el?.getAttribute(${js_str(attr)});')
		}
		'box' {
			build_rect_query_js(&sess, sel)
		}
		'styles' {
			build_element_scope_js(&sess, sel, 'return el?JSON.stringify(Object.fromEntries(Object.entries(getComputedStyle(el)))):null;')
		}
		else {
			return 'ERROR:unknown property: ${prop}'
		}
	}

	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	return json_str(cdp_extract_value_from_result(result))
}

// ─── is ─────────────────────────────────────────────────────
fn cmd_is(mut sess CdpSession, params string) string {
	state := cdp_extract_str(params, 'state')
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}

	js := match state {
		'visible' { build_element_scope_js(&sess, sel, "if(!el) return false; var r=el.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(el).visibility!=='hidden'&&getComputedStyle(el).display!=='none';") }
		'enabled' { build_element_scope_js(&sess, sel, 'return !el?.disabled;') }
		'checked' { build_element_scope_js(&sess, sel, 'return !!el?.checked;') }
		else { return 'ERROR:unknown state: ${state}' }
	}

	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	val := cdp_extract_obj_key(result, '"value":')
	return val
}

// ─── wait ───────────────────────────────────────────────────
fn cmd_wait(mut sess CdpSession, params string) string {
	// wait <ms>
	ms_str := cdp_extract_obj_key(params, '"ms":')
	if ms_str != '' && ms_str != 'null' {
		ms := ms_str.int()
		time.sleep(ms * time.millisecond)
		return 'null'
	}
	// wait --download
	download_path := cdp_extract_str(params, 'download')
	timeout_ms := cdp_extract_int(params, '"timeout":')
	if download_path != '' || timeout_ms > 0 {
		download_dir := unique_download_dir()
		timeout := if timeout_ms > 0 { timeout_ms } else { 30000 }
		mode := ensure_download_behavior(mut sess, download_dir) or { return 'ERROR:${err}' }
		final_path := if mode == 'dom' {
			wait_for_dom_download(mut sess, download_path, timeout * time.millisecond) or {
				return 'ERROR:${err}'
			}
		} else {
			wait_for_download(mut sess, download_dir, download_path, timeout * time.millisecond) or {
				return 'ERROR:${err}'
			}
		}
		return json_str(final_path)
	}
	// wait --load
	load := cdp_extract_str(params, 'load')
	if load != '' {
		return wait_load(mut sess, load)
	}
	// wait --url
	url_pat := cdp_extract_str(params, 'url')
	if url_pat != '' {
		return wait_url(mut sess, url_pat)
	}
	// wait --text
	text := cdp_extract_str(params, 'text')
	if text != '' {
		return wait_text(mut sess, text)
	}
	// wait --fn
	fn_expr := cdp_extract_str(params, 'fn')
	if fn_expr != '' {
		return wait_fn(mut sess, fn_expr)
	}
	// wait <selector>
	sel := cdp_extract_str(params, 'selector')
	if sel != '' {
		return wait_selector(mut sess, sel)
	}
	return 'ERROR:missing wait condition'
}

fn wait_load(mut sess CdpSession, state string) string {
	event := match state {
		'load' {
			'Page.loadEventFired'
		}
		'domcontentloaded' {
			'Page.domContentEventFired'
		}
		'networkidle' {
			// 监听 Page.lifecycleEvent name=networkIdle
			ch := sess.subscribe('Page.lifecycleEvent')
			defer { sess.unsubscribe('Page.lifecycleEvent', ch) }
			for {
				select {
					evt := <-ch {
						name := cdp_extract_str(evt.params, 'name')
						if name == 'networkIdle' {
							break
						}
					}
					30 * time.second {
						return 'ERROR:timeout waiting for networkidle'
					}
				}
			}
			return 'null'
		}
		else {
			return 'ERROR:unknown load state: ${state}'
		}
	}
	ch := sess.subscribe(event)
	defer { sess.unsubscribe(event, ch) }
	select {
		_ := <-ch {}
		30 * time.second {
			return 'ERROR:timeout waiting for ${state}'
		}
	}
	return 'null'
}

fn wait_url(mut sess CdpSession, pattern string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		resp := sess.send_command('Runtime.evaluate', '{"expression":"window.location.href","returnByValue":true}') or {
			break
		}
		result := cdp_extract_obj_key(resp.result, '"result":')
		url := cdp_extract_value_from_result(result)
		if glob_match(pattern, url) {
			return 'null'
		}
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for url ${pattern}'
}

fn wait_text(mut sess CdpSession, text string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		js := build_document_scope_js(&sess, 'return doc.body?.innerText;')
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
			break
		}
		result := cdp_extract_obj_key(resp.result, '"result":')
		body := cdp_extract_value_from_result(result)
		if body.contains(text) {
			return 'null'
		}
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for text "${text}"'
}

fn wait_fn(mut sess CdpSession, expr string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(expr)},"returnByValue":true}') or {
			break
		}
		result := cdp_extract_obj_key(resp.result, '"result":')
		val := cdp_extract_value_from_result(result)
		if val == 'true' {
			return 'null'
		}
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for fn condition'
}

fn wait_selector(mut sess CdpSession, sel string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		js := build_element_scope_js(&sess, sel, 'if(!el) return false; var r=el.getBoundingClientRect(); return r.width>0&&r.height>0;')
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
			break
		}
		result := cdp_extract_obj_key(resp.result, '"result":')
		if cdp_extract_value_from_result(result) == 'true' {
			return 'null'
		}
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for selector ${sel}'
}

// ─── find（语义定位器）──────────────────────────────────────
fn cmd_find(mut sess CdpSession, params string) string {
	locator := cdp_extract_str(params, 'locator')
	query := cdp_extract_str(params, 'query')
	action := cdp_extract_str(params, 'action')
	value := cdp_extract_str(params, 'value')
	exact := cdp_extract_str(params, 'exact') == 'true'
	name_filter := cdp_extract_str(params, 'name')
	index_str := cdp_extract_str(params, 'index')
	index := if index_str != '' { index_str.int() } else { -1 }
	debug_mode := cdp_extract_str(params, 'debug') == 'true'
	list_mode := cdp_extract_str(params, 'list') == 'true'

	if locator == '' {
		return 'ERROR:missing locator'
	}
	if query == '' && locator !in ['first', 'last'] {
		return 'ERROR:missing semantic query'
	}
	if debug_mode && list_mode {
		return 'ERROR:--debug and --list cannot be used together'
	}
	if debug_mode || list_mode {
		if locator != 'text' {
			return 'ERROR:--debug and --list currently support only find text'
		}
		mode := if debug_mode { 'debug' } else { 'list' }
		limit := if debug_mode { 5 } else { 0 }
		return semantic_text_candidates_report(mut sess, query, exact, index, limit, mode)
	}
	js := build_semantic_locator_js(&sess, locator, query, exact, name_filter, index)
	return exec_semantic_action(mut sess, js, locator, action, value)
}

fn semantic_text_candidates_report(mut sess CdpSession, query string, exact bool, selected_index int, limit int, mode string) string {
	js := build_semantic_text_report_js(&sess, query, exact, selected_index, limit, mode)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	value := cdp_extract_value_from_result(result)
	if value == 'null' || value == 'undefined' {
		return '未找到候选'
	}
	return value
}

fn build_semantic_text_report_js(sess &CdpSession, query string, exact bool, selected_index int, limit int, mode string) string {
	query_js := js_str(query)
	selected_index_js := '${selected_index}'
	limit_js := '${limit}'
	mode_js := js_str(mode)
	exact_js := if exact { 'true' } else { 'false' }
	return build_document_scope_js(sess, '
		function normalizeText(value) { return String(value || "").replace(/\\s+/g, " ").trim(); }
		function matchesText(actual, expected, exactMatch) {
			var left = normalizeText(actual);
			var right = normalizeText(expected);
			if (!right) return false;
			return exactMatch ? left === right : left.toLowerCase().includes(right.toLowerCase());
		}
		function isActionable(el) {
			if (!el) return false;
			var tag = (el.tagName || "").toLowerCase();
			if (["a", "button", "summary", "option"].includes(tag)) return true;
			if (tag === "input") return (el.getAttribute("type") || "text").toLowerCase() !== "hidden";
			if (["textarea", "select"].includes(tag)) return true;
			var role = (el.getAttribute("role") || "").toLowerCase();
			if (["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "option"].includes(role)) return true;
			if (typeof el.onclick === "function") return true;
			if (el.hasAttribute("href") || el.hasAttribute("data-testid") || el.hasAttribute("aria-controls") || el.hasAttribute("aria-haspopup")) return true;
			if (typeof el.tabIndex === "number" && el.tabIndex >= 0) return true;
			return false;
		}
		function candidateText(el) {
			return normalizeText(el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt") || "");
		}
		function matchesText(actual, expected, exactMatch) {
			var left = normalizeText(actual);
			var right = normalizeText(expected);
			if (!right) return false;
			return exactMatch ? left === right : left.toLowerCase().includes(right.toLowerCase());
		}
		function roleOf(el) {
			if (!el) return "";
			var explicit = el.getAttribute("role");
			if (explicit) return explicit;
			var tag = (el.tagName || "").toLowerCase();
			if (tag === "button") return "button";
			if (tag === "a" && el.hasAttribute("href")) return "link";
			if (tag === "img") return "img";
			if (tag === "select") return "combobox";
			if (tag === "textarea") return "textbox";
			if (tag === "input") {
				var type = (el.getAttribute("type") || "text").toLowerCase();
				if (type === "checkbox") return "checkbox";
				if (type === "radio") return "radio";
				if (["button", "submit", "reset"].includes(type)) return "button";
				return "textbox";
			}
			return "";
		}
		function selectorPart(el) {
			var tag = (el.tagName || "div").toLowerCase();
			if (el.id) return tag + "#" + el.id;
			var part = tag;
			var classNames = Array.from(el.classList || []).slice(0, 2);
			if (classNames.length) part += "." + classNames.join(".");
			var parent = el.parentElement;
			if (!parent) return part;
			var siblings = Array.from(parent.children).filter(function(child) {
				return (child.tagName || "").toLowerCase() === tag;
			});
			if (siblings.length > 1) part += ":nth-of-type(" + (siblings.indexOf(el) + 1) + ")";
			return part;
		}
		function selectorOf(el) {
			if (!el) return "";
			var parts = [];
			var current = el;
			var depth = 0;
			while (current && current.nodeType === 1 && current !== doc.body && depth < 3) {
				var tag = (current.tagName || "div").toLowerCase();
				var ident = current.id ? (tag + "#" + current.id) : tag;
				parts.unshift(ident);
				if (current.id) break;
				current = current.parentElement;
				depth += 1;
			}
			return parts.join(" > ");
		}
		function describeNode(el) {
			if (!el) return "-";
			var tag = (el.tagName || "node").toLowerCase();
			var id = el.id ? "#" + el.id : "";
			var classes = Array.from(el.classList || []).slice(0, 2);
			var classPart = classes.length ? "." + classes.join(".") : "";
			var role = roleOf(el);
			var extras = [];
			if (role) extras.push("role=" + role);
			if (el.hasAttribute("href")) extras.push("href=" + el.getAttribute("href"));
			return "<" + tag + id + classPart + (extras.length ? " " + extras.join(" ") : "") + ">";
		}
		function inspectCandidate(target, idx) {
			if (!target || !isActionable(target)) return null;
			return {
				index: idx,
				selected: idx === ${selected_index_js},
				matchText: candidateText(target),
				sourceNode: describeNode(target),
				targetNode: describeNode(target),
				text: candidateText(target),
				href: target.getAttribute("href") || "",
				role: roleOf(target),
				selector: selectorOf(target)
			};
		}
		var expected = ${query_js};
		var exactMatch = ${exact_js};
		var candidates = Array.from(doc.querySelectorAll("a[href], button, summary, [role=button], [role=link]")).filter(function(el) {
			if (!isActionable(el)) return false;
			return matchesText(candidateText(el), expected, exactMatch);
		}).map(function(el, idx) {
			return inspectCandidate(el, idx);
		}).filter(Boolean);
		if (${mode_js} === "debug") {
			return JSON.stringify(candidates.slice(0, ${limit_js}), null, 2);
		}
		return JSON.stringify(candidates, null, 2);
	')
}

fn build_semantic_locator_js(sess &CdpSession, locator string, query string, exact bool, name_filter string, index int) string {
	query_js := js_str(query)
	name_js := js_str(name_filter)
	index_js := '${index}'
	exact_js := if exact { 'true' } else { 'false' }
	locator_body := match locator {
		'role' {
			'var all=Array.from(doc.querySelectorAll("*")); elements=all.filter(el=>roleOf(el)===${query_js}&&matchesName(el, ${name_js}, ${exact_js}));'
		}
		'text' {
			'var all=Array.from(doc.querySelectorAll("*")); var actionableMatches=all.filter(el=>isActionable(el)&&matchesText(candidateText(el), ${query_js}, ${exact_js})).filter(el=>!hasMatchingDescendant(el, ${query_js}, ${exact_js})); elements=(actionableMatches.length?actionableMatches:all.filter(el=>matchesText(candidateText(el), ${query_js}, ${exact_js})).filter(el=>!hasMatchingDescendant(el, ${query_js}, ${exact_js})).map(el=>closestActionable(el, ${query_js}, ${exact_js}))).filter(Boolean).filter((el, idx, arr)=>arr.indexOf(el)===idx);'
		}
		'label' {
			'var labels=Array.from(doc.querySelectorAll("label")); elements=labels.map(label=>{ if(!matchesText(label.innerText||label.textContent||"", ${query_js}, ${exact_js})) return null; return label.control || label.querySelector("input, textarea, select, button"); }).filter(Boolean);'
		}
		'placeholder' {
			'var all=Array.from(doc.querySelectorAll("[placeholder]")); elements=all.filter(el=>matchesText(el.getAttribute("placeholder")||"", ${query_js}, ${exact_js}));'
		}
		'alt' {
			'var all=Array.from(doc.querySelectorAll("[alt]")); elements=all.filter(el=>matchesText(el.getAttribute("alt")||"", ${query_js}, ${exact_js}));'
		}
		'title' {
			'var all=Array.from(doc.querySelectorAll("[title]")); elements=all.filter(el=>matchesText(el.getAttribute("title")||"", ${query_js}, ${exact_js}));'
		}
		'testid' {
			'var all=Array.from(doc.querySelectorAll("[data-testid]")); elements=all.filter(el=>matchesText(el.getAttribute("data-testid")||"", ${query_js}, ${exact_js}));'
		}
		'first', 'last', 'nth' {
			'elements=Array.from(doc.querySelectorAll(${query_js}));'
		}
		else {
			'elements=[];'
		}
	}
	selection_body := match locator {
		'last' {
			if index >= 0 {
				'return elements.length > ${index_js} ? elements[${index_js}] : null;'
			} else {
				'return elements.length ? elements[elements.length - 1] : null;'
			}
		}
		'nth' { 'return elements.length > ${index_js} ? elements[${index_js}] : null;' }
		else {
			if index >= 0 {
				'return elements.length > ${index_js} ? elements[${index_js}] : null;'
			} else {
				'return elements.length ? elements[0] : null;'
			}
		}
	}
	return build_document_scope_js(sess, '
		function normalizeText(value) { return String(value || "").replace(/\\s+/g, " ").trim(); }
		function candidateText(el) {
			return normalizeText(el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("alt") || "");
		}
		function isActionable(el) {
			if (!el) return false;
			var tag = (el.tagName || "").toLowerCase();
			if (["a", "button", "summary", "option"].includes(tag)) return true;
			if (tag === "input") return (el.getAttribute("type") || "text").toLowerCase() !== "hidden";
			if (["textarea", "select"].includes(tag)) return true;
			var role = (el.getAttribute("role") || "").toLowerCase();
			if (["button", "link", "checkbox", "radio", "switch", "tab", "menuitem", "option"].includes(role)) return true;
			if (typeof el.onclick === "function") return true;
			if (el.hasAttribute("href") || el.hasAttribute("data-testid") || el.hasAttribute("aria-controls") || el.hasAttribute("aria-haspopup")) return true;
			if (typeof el.tabIndex === "number" && el.tabIndex >= 0) return true;
			return false;
		}
		function hasMatchingDescendant(el, expected, exactMatch) {
			var descendants = Array.from(el.querySelectorAll("*"));
			return descendants.some(function(child) {
				return matchesText(candidateText(child), expected, exactMatch);
			});
		}
		function closestActionable(el, expected, exactMatch) {
			var current = el;
			while (current && current !== doc.body) {
				if (isActionable(current)) return current;
				current = current.parentElement;
			}
			var descendants = Array.from(el.querySelectorAll("*"));
			for (var i = 0; i < descendants.length; i++) {
				var candidate = descendants[i];
				if (!isActionable(candidate)) continue;
				if (matchesText(candidateText(candidate), expected, exactMatch)) return candidate;
			}
			for (var j = 0; j < descendants.length; j++) {
				if (isActionable(descendants[j])) return descendants[j];
			}
			return el;
		}
		function matchesText(actual, expected, exactMatch) {
			var left = normalizeText(actual);
			var right = normalizeText(expected);
			if (!right)
				return false;
			return exactMatch ? left === right : left.toLowerCase().includes(right.toLowerCase());
		}
		function accessibleName(el) {
			return normalizeText(el.getAttribute("aria-label") || el.innerText || el.textContent || el.value || el.getAttribute("alt") || el.getAttribute("title") || "");
		}
		function matchesName(el, expected, exactMatch) {
			if (!expected)
				return true;
			return matchesText(accessibleName(el), expected, exactMatch);
		}
		function roleOf(el) {
			var explicit = el.getAttribute("role");
			if (explicit)
				return explicit;
			var tag = (el.tagName || "").toLowerCase();
			if (tag === "button") return "button";
			if (tag === "a" && el.hasAttribute("href")) return "link";
			if (tag === "img") return "img";
			if (tag === "select") return "combobox";
			if (tag === "textarea") return "textbox";
			if (tag === "input") {
				var type = (el.getAttribute("type") || "text").toLowerCase();
				if (type === "checkbox") return "checkbox";
				if (type === "radio") return "radio";
				if (["button", "submit", "reset"].includes(type)) return "button";
				return "textbox";
			}
			return "";
		}
		var elements = [];
		${locator_body}
		${selection_body}
	')
}

fn exec_semantic_action(mut sess CdpSession, locator_js string, locator string, action string, value string) string {
	match action {
		'click' {
			return semantic_mouse_action(mut sess, locator_js, 'click', locator)
		}
		'hover' {
			return semantic_mouse_action(mut sess, locator_js, 'hover', locator)
		}
		'fill' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; el.focus?.(); if ("value" in el) el.value = ${js_str(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'type' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; el.focus?.(); if ("value" in el) el.value = String(el.value || "") + ${js_str(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'text' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; return el.innerText || el.textContent || "";')
			return evaluate_semantic_result(mut sess, js, locator, true)
		}
		'focus' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; el.focus?.(); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'check' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; if ("checked" in el) el.checked = true; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'uncheck' {
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return null; if ("checked" in el) el.checked = false; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		else {
			return 'ERROR:unknown action: ${action}'
		}
	}
}

fn semantic_mouse_action(mut sess CdpSession, locator_js string, action string, locator string) string {
	if action in ['click', 'hover'] {
		pointer_action_for_locator_js(mut sess, locator_js, action) or {
			body := match action {
				'click' { build_click_action_body() }
				'hover' { build_hover_action_body() }
				else { return 'ERROR:unknown action: ${action}' }
			}
			js := build_semantic_action_js(&sess, locator_js, 'if (!el) return false; el.scrollIntoView({block:"center",inline:"center"}); ${body}')
			ok := eval_scoped_expression(mut sess, js, false) or {
				return 'ERROR:${err}'
			}
			if ok != 'true' {
				return 'ERROR:element not found: ${locator}'
			}
			return 'null'
		}
		return 'null'
	}
	body := match action {
		'click' { build_click_action_body() }
		'hover' { build_hover_action_body() }
		else { return 'ERROR:unknown action: ${action}' }
	}
	js := build_semantic_action_js(&sess, locator_js, 'if (!el) return false; el.scrollIntoView({block:"center",inline:"center"}); ${body}')
	ok := eval_scoped_expression(mut sess, js, false) or {
		pointer_action_for_locator_js(mut sess, locator_js, action) or { return 'ERROR:${err}' }
		return 'null'
	}
	if ok != 'true' {
		pointer_action_for_locator_js(mut sess, locator_js, action) or {
			return 'ERROR:element not found: ${locator}'
		}
		return 'null'
	}
	return 'null'
}

fn build_semantic_action_js(sess &CdpSession, locator_js string, body string) string {
	return build_document_scope_js(sess, 'var el = (${locator_js}); ${body}')
}

fn evaluate_semantic_result(mut sess CdpSession, js string, locator string, return_value bool) string {
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return 'ERROR:element not found: ${locator}'
	}
	if return_value {
		return json_str(cdp_extract_value_from_result(result))
	}
	return 'null'
}

fn apply_action(mut sess CdpSession, el ResolvedElement, sel string, action string, value string) string {
	match action {
		'click' {
			run_element_action(mut sess, sel, build_click_action_body()) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'fill' {
			run_element_action(mut sess, sel, build_fill_action_body(value)) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'type' {
			run_element_action(mut sess, sel, build_type_action_body(value)) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'hover' {
			run_element_action(mut sess, sel, build_hover_action_body()) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'text' {
			js := build_element_scope_js(&sess, sel, 'return el?.textContent;')
			resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
				return 'ERROR:${err}'
			}
			result := cdp_extract_obj_key(resp.result, '"result":')
			return json_str(cdp_extract_value_from_result(result))
		}
		'focus' {
			sess.send_command('DOM.focus', '{"backendNodeId":${el.backend_node_id}}') or {}
			return 'null'
		}
		'check' {
			run_element_action(mut sess, sel, build_toggle_action_body(true)) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'uncheck' {
			run_element_action(mut sess, sel, build_toggle_action_body(false)) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		else {
			return 'ERROR:unknown action: ${action}'
		}
	}
}

// ─── tab ────────────────────────────────────────────────────
fn cmd_tab(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'list' {
			resp := sess.send_bridge_command('listTabs', '{}') or { return 'ERROR:${err}' }
			return resp.result
		}
		'new' {
			url := cdp_extract_str(params, 'url')
			resp := sess.send_bridge_command('createTab', '{"url":${json_str(if url != '' {
				url
			} else {
				'about:blank'
			})}}') or { return 'ERROR:${err}' }
			axref_clear(mut sess.axref)
			sess.current_frame_selector = ''
			sess.enable_network_tracking() or {}
			return resp.result
		}
		'switch' {
			tab_id := cdp_extract_int(params, '"tabId":')
			window_id := cdp_extract_int(params, '"windowId":')
			if tab_id == 0 {
				return 'ERROR:missing tabId'
			}
			resp := sess.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}') or {
				return 'ERROR:${err}'
			}
			axref_clear(mut sess.axref)
			sess.current_frame_selector = ''
			sess.enable_network_tracking() or {}
			return resp.result
		}
		'close' {
			tab_id := cdp_extract_int(params, '"tabId":')
			if tab_id == 0 {
				return 'ERROR:missing tabId'
			}
			resp := sess.send_bridge_command('closeTab', '{"tabId":${tab_id}}') or {
				return 'ERROR:${err}'
			}
			return resp.result
		}
		else {
			return 'ERROR:unknown tab action: ${action}'
		}
	}
}

fn cmd_window(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'new' {
			url := cdp_extract_str(params, 'url')
			resp := sess.send_bridge_command('createWindow', '{"url":${json_str(if url != '' {
				url
			} else {
				'about:blank'
			})}}') or { return 'ERROR:${err}' }
			axref_clear(mut sess.axref)
			sess.current_frame_selector = ''
			sess.enable_network_tracking() or {}
			return resp.result
		}
		else {
			return 'ERROR:unknown window action: ${action}'
		}
	}
}

// ─── mouse ──────────────────────────────────────────────────
fn cmd_mouse(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	x := cdp_extract_float(params, 'x')
	y := cdp_extract_float(params, 'y')
	button := cdp_extract_str(params, 'button')
	btn := if button != '' { button } else { 'left' }

	match action {
		'move' {
			sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseMoved","x":${x},"y":${y}}') or {
				return 'ERROR:${err}'
			}
		}
		'down' {
			sess.send_command('Input.dispatchMouseEvent', '{"type":"mousePressed","x":${x},"y":${y},"button":"${btn}","clickCount":1}') or {
				return 'ERROR:${err}'
			}
		}
		'up' {
			sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${x},"y":${y},"button":"${btn}"}') or {
				return 'ERROR:${err}'
			}
		}
		'wheel' {
			dy := cdp_extract_float(params, 'dy')
			dx := cdp_extract_float(params, 'dx')
			sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseWheel","x":${x},"y":${y},"deltaX":${dx},"deltaY":${dy}}') or {
				return 'ERROR:${err}'
			}
		}
		else {
			return 'ERROR:unknown mouse action: ${action}'
		}
	}
	return 'null'
}

// ─── cookies ────────────────────────────────────────────────
fn cmd_cookies(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'', 'get' {
			resp := sess.send_command('Network.getCookies', '{}') or { return 'ERROR:${err}' }
			cookies_json := cdp_extract_obj_key(resp.result, '"cookies":')
			return format_cookies_expires(cookies_json)
		}
		'set' {
			name := cdp_extract_str(params, 'name')
			value := cdp_extract_str(params, 'value')
			domain := cdp_extract_str(params, 'domain')
			sess.send_command('Network.setCookie', '{"name":${json_str(name)},"value":${json_str(value)},"domain":${json_str(domain)}}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'clear' {
			sess.send_command('Network.clearBrowserCookies', '{}') or { return 'ERROR:${err}' }
			return 'null'
		}
		else {
			return 'ERROR:unknown cookies action: ${action}'
		}
	}
}

// format_cookies_expires 将 Unix 时间戳转换为人类可读格式
fn format_cookies_expires(cookies_json string) string {
	mut result := cookies_json

	// 1. 替换 session cookie (-1 或 -1.0)
	result = result.replace('"expires":-1,', '"expires":"session",')
	result = result.replace('"expires":-1}', '"expires":"session"}')
	result = result.replace('"expires":-1.0,', '"expires":"session",')
	result = result.replace('"expires":-1.0}', '"expires":"session"}')

	// 2. 处理时间戳 - 循环直到没有变化
	for {
		mut found := false

		mut search_pos := 0
		for search_pos < result.len - 15 {
			idx := result.index_after('"expires":', search_pos) or { break }

			rest := result[idx + 10..]
			if rest.len < 10 {
				break
			}

			// 跳过已转换的
			if rest.starts_with('"session"') || (rest.len >= 2 && rest[0] == `"` && rest[1] == `2`) {
				search_pos = idx + 10
				continue
			}

			// 提取时间戳
			mut ts := ''
			for i := 0; i < rest.len && i < 20; i++ {
				c := rest[i]
				if c >= `0` && c <= `9` {
					ts += c.ascii_str()
				} else if c == `.` && ts.len >= 10 {
					ts += '.'
				} else {
					break
				}
			}

			if ts.len < 10 {
				search_pos = idx + 10
				continue
			}

			ts_int := ts.int()
			if ts_int < 1000000000 || ts_int > 2000000000 {
				search_pos = idx + 10
				continue
			}

			ts_end := idx + 10 + ts.len
			if ts_end >= result.len || (result[ts_end] != `,` && result[ts_end] != `}`) {
				search_pos = idx + 10
				continue
			}

			exp_time := time.unix(ts_int)
			exp_str := '${exp_time.year}-${int(exp_time.month):02}-${exp_time.day:02} ${exp_time.hour:02}:${exp_time.minute:02}'

			old := '"expires":${ts}'
			result = result.replace(old, '"expires":"${exp_str}"')
			found = true
			break
		}

		if !found {
			break
		}
	}

	return result
}

// ─── storage ────────────────────────────────────────────────
fn cmd_storage(mut sess CdpSession, params string) string {
	storage_type := cdp_extract_str(params, 'type') // 'local' or 'session'
	action := cdp_extract_str(params, 'action') // 'get', 'set', 'clear'
	key := cdp_extract_str(params, 'key')
	value := cdp_extract_str(params, 'value')

	store := if storage_type == 'session' { 'sessionStorage' } else { 'localStorage' }

	js := match action {
		'', 'get' {
			if key != '' {
				'${store}.getItem(${js_str(key)})'
			} else {
				'JSON.stringify(Object.fromEntries(Object.keys(${store}).map(k=>[k,${store}.getItem(k)])))'
			}
		}
		'set' {
			'${store}.setItem(${js_str(key)},${js_str(value)})'
		}
		'clear' {
			'${store}.clear()'
		}
		else {
			return 'ERROR:unknown storage action: ${action}'
		}
	}

	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	return json_str(cdp_extract_value_from_result(result))
}

// ─── network ────────────────────────────────────────────────
fn cmd_network(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'requests' {
			filter := cdp_extract_str(params, 'filter')
			sess.enable_network_tracking() or { return 'ERROR:${err}' }
			return sess.network_requests_json(filter)
		}
		'route' {
			url := cdp_extract_str(params, 'url')
			abort := cdp_extract_str(params, 'abort') == 'true'
			body := cdp_extract_str(params, 'body')
			// 启用 Fetch 拦截
			sess.send_command('Fetch.enable', '{"patterns":[{"urlPattern":${json_str(url)}}]}') or {
				return 'ERROR:${err}'
			}
			// 订阅 Fetch.requestPaused 事件并处理
			ch := sess.subscribe('Fetch.requestPaused')
			spawn fn [mut sess, ch, abort, body] () {
				for {
					select {
						evt := <-ch {
							request_id := cdp_extract_str(evt.params, 'requestId')
							if request_id == '' {
								break
							}
							if abort {
								sess.send_command('Fetch.failRequest', '{"requestId":${json_str(request_id)},"errorReason":"Aborted"}') or {}
							} else if body != '' {
								sess.send_command('Fetch.fulfillRequest', '{"requestId":${json_str(request_id)},"responseCode":200,"body":${json_str(base64.encode_str(body))}}') or {}
							} else {
								sess.send_command('Fetch.continueRequest', '{"requestId":${json_str(request_id)}}') or {}
							}
						}
						else {
							break
						}
					}
				}
			}()
			return 'null'
		}
		'unroute' {
			sess.send_command('Fetch.disable', '{}') or { return 'ERROR:${err}' }
			return 'null'
		}
		else {
			return 'ERROR:unknown network action: ${action}'
		}
	}
}

// ─── frame ──────────────────────────────────────────────────
fn cmd_frame(mut sess CdpSession, params string) string {
	selector := cdp_extract_str(params, 'selector')
	if selector == '' || selector == 'main' {
		sess.current_frame_selector = ''
		axref_clear(mut sess.axref)
		return json_str('main')
	}
	if axref_is_ref(selector) {
		return 'ERROR:frame switching currently requires a CSS or XPath selector'
	}
	js := build_document_scope_js(&sess, 'var frameEl=document.querySelector(${js_str(selector)}); if(!frameEl) return "missing"; try { return frameEl.contentDocument ? "ok" : "unavailable"; } catch (e) { return "cross-origin"; }')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	status := cdp_extract_value_from_result(result)
	if status != 'ok' {
		return 'ERROR:cannot switch frame ${selector}: ${status}'
	}
	sess.current_frame_selector = selector
	axref_clear(mut sess.axref)
	return json_str(selector)
}

// ─── dialog ─────────────────────────────────────────────────
fn cmd_dialog(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	text := cdp_extract_str(params, 'text')
	match action {
		'events' {
			sess.enable_page_events() or { return 'ERROR:${err}' }
			if sess.dialog_events.len == 0 {
				return '[]'
			}
			return '[' + sess.dialog_events.map(it).join(',') + ']'
		}
		'clear' {
			sess.dialog_events.clear()
			return 'null'
		}
		'accept' {
			sess.enable_page_events() or { return 'ERROR:${err}' }
			handle_dialog_with_retry(mut sess, '{"accept":true,"promptText":${json_str(text)}}') or {
				return 'ERROR:${err}'
			}
		}
		'dismiss' {
			sess.enable_page_events() or { return 'ERROR:${err}' }
			handle_dialog_with_retry(mut sess, '{"accept":false}') or { return 'ERROR:${err}' }
		}
		else {
			return 'ERROR:unknown dialog action: ${action}'
		}
	}
	return 'null'
}

fn handle_dialog_with_retry(mut sess CdpSession, params string) ! {
	mut last_err := ''
	for _ in 0 .. 10 {
		sess.send_command('Page.handleJavaScriptDialog', params) or {
			last_err = err.msg()
			if last_err.contains('No dialog is showing') {
				time.sleep(100 * time.millisecond)
				continue
			}
			return error(last_err)
		}
		return
	}
	return error(last_err)
}

// ─── highlight ──────────────────────────────────────────────
fn cmd_highlight(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	js := build_element_scope_js(&sess, sel, "if(!el) return; var old=el.style.outline; el.style.outline='3px solid #FF0080'; setTimeout(()=>el.style.outline=old,2000);")
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// ─── console / errors ───────────────────────────────────────
fn cmd_console(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	if action == 'clear' {
		sess.console_msgs.clear()
		return 'null'
	}
	if sess.console_msgs.len == 0 {
		return '[]'
	}
	out := '[' + sess.console_msgs.map(it).join(',') + ']'
	return out
}

fn cmd_errors(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	if action == 'clear' {
		sess.page_errors.clear()
		return 'null'
	}
	if sess.page_errors.len == 0 {
		return '[]'
	}
	return '[' + sess.page_errors.map(it).join(',') + ']'
}

// ─── trace ──────────────────────────────────────────────────
fn cmd_trace(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	path := cdp_extract_str(params, 'path')
	match action {
		'start' {
			categories := 'devtools.timeline,v8.execute,disabled-by-default-devtools.screenshot'
			sess.send_command('Tracing.start', '{"transferMode":"ReturnAsStream","categories":${json_str(categories)}}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'stop' {
			out_path := if path != '' {
				path
			} else {
				os.join_path(os.temp_dir(), 'trace_${time.now().unix_milli()}.json')
			}
			ch := sess.subscribe('Tracing.tracingComplete')
			defer { sess.unsubscribe('Tracing.tracingComplete', ch) }
			sess.send_command('Tracing.end', '{}') or { return 'ERROR:${err}' }
			select {
				evt := <-ch {
					stream := cdp_extract_str(evt.params, 'stream')
					if stream == '' {
						return 'ERROR:trace stream missing'
					}
					content := read_protocol_stream(mut sess, stream) or { return 'ERROR:${err}' }
					os.write_file(out_path, content) or { return 'ERROR:write failed: ${err}' }
				}
				30 * time.second {
					return 'ERROR:timeout waiting for trace data'
				}
			}
			return json_str(out_path)
		}
		else {
			return 'ERROR:unknown trace action: ${action}'
		}
	}
}

// ─── profiler ───────────────────────────────────────────────
fn cmd_profiler(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	path := cdp_extract_str(params, 'path')
	match action {
		'start' {
			sess.send_command('Profiler.enable', '{}') or { return 'ERROR:${err}' }
			sess.send_command('Profiler.start', '{}') or { return 'ERROR:${err}' }
			return 'null'
		}
		'stop' {
			resp := sess.send_command('Profiler.stop', '{}') or { return 'ERROR:${err}' }
			out_path := if path != '' {
				path
			} else {
				os.join_path(os.temp_dir(), 'profile_${time.now().unix_milli()}.json')
			}
			profile := cdp_extract_obj_key(resp.result, '"profile":')
			os.write_file(out_path, profile) or { return 'ERROR:write failed: ${err}' }
			return json_str(out_path)
		}
		else {
			return 'ERROR:unknown profiler action: ${action}'
		}
	}
}

// ─── set ────────────────────────────────────────────────────
fn cmd_set(mut sess CdpSession, params string) string {
	prop := cdp_extract_str(params, 'property')
	match prop {
		'viewport' {
			w := cdp_extract_int(params, '"width":')
			h := cdp_extract_int(params, '"height":')
			scale_str := cdp_extract_obj_key(params, '"scale":')
			scale := if scale_str != '' { scale_str.f64() } else { 1.0 }
			apply_device_preset(mut sess, DevicePreset{
				name:       'custom viewport'
				width:      w
				height:     h
				scale:      scale
				mobile:     false
				has_touch:  false
				user_agent: ''
			}) or { return 'ERROR:${err}' }
			return 'null'
		}
		'device' {
			name := cdp_extract_str(params, 'value')
			preset := resolve_device_preset(name) or { return 'ERROR:${err}' }
			apply_device_preset(mut sess, preset) or { return 'ERROR:${err}' }
			return 'null'
		}
		'geo' {
			lat := cdp_extract_float(params, 'lat')
			lng := cdp_extract_float(params, 'lng')
			sess.send_command('Emulation.setGeolocationOverride', '{"latitude":${lat},"longitude":${lng},"accuracy":1}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'offline' {
			offline := cdp_extract_str(params, 'value') != 'off'
			latency := if offline { 0 } else { 0 }
			download := if offline { 0 } else { -1 }
			upload := if offline { 0 } else { -1 }
			sess.send_command('Network.emulateNetworkConditions', '{"offline":${offline},"latency":${latency},"downloadThroughput":${download},"uploadThroughput":${upload}}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'headers' {
			headers := cdp_extract_obj_key(params, '"headers":')
			sess.send_command('Network.setExtraHTTPHeaders', '{"headers":${headers}}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'credentials' {
			user := cdp_extract_str(params, 'username')
			pass := cdp_extract_str(params, 'password')
			// Credentials via Network.setExtraHTTPHeaders with Authorization header
			encoded := base64.encode_str('${user}:${pass}')
			headers := '{"Authorization":"Basic ${encoded}"}'
			sess.send_command('Network.setExtraHTTPHeaders', '{"headers":${headers}}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'media' {
			scheme := cdp_extract_str(params, 'value')
			sess.send_command('Emulation.setEmulatedMedia', '{"features":[{"name":"prefers-color-scheme","value":"${scheme}"}]}') or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		else {
			return 'ERROR:unknown set property: ${prop}'
		}
	}
}

fn resolve_device_preset(name string) !DevicePreset {
	normalized := name.to_lower().trim_space()
	return match normalized {
		'iphone 14' {
			DevicePreset{
				name:       'iPhone 14'
				width:      390
				height:     844
				scale:      3.0
				mobile:     true
				has_touch:  true
				user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'
			}
		}
		'iphone 14 pro' {
			DevicePreset{
				name:       'iPhone 14 Pro'
				width:      393
				height:     852
				scale:      3.0
				mobile:     true
				has_touch:  true
				user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'
			}
		}
		'pixel 7' {
			DevicePreset{
				name:       'Pixel 7'
				width:      412
				height:     915
				scale:      2.625
				mobile:     true
				has_touch:  true
				user_agent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36'
			}
		}
		'ipad mini' {
			DevicePreset{
				name:       'iPad mini'
				width:      768
				height:     1024
				scale:      2.0
				mobile:     true
				has_touch:  true
				user_agent: 'Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1'
			}
		}
		else {
			return error('unknown device preset: ${name}')
		}
	}
}

fn apply_device_preset(mut sess CdpSession, preset DevicePreset) ! {
	sess.send_command('Emulation.setDeviceMetricsOverride', '{"width":${preset.width},"height":${preset.height},"deviceScaleFactor":${preset.scale},"mobile":${preset.mobile}}')!
	sess.send_command('Emulation.setTouchEmulationEnabled', '{"enabled":${preset.has_touch},"maxTouchPoints":${if preset.has_touch {
		5
	} else {
		1
	}}}') or {}
	if preset.user_agent != '' {
		sess.send_command('Emulation.setUserAgentOverride', '{"userAgent":${json_str(preset.user_agent)}}')!
	}
}

fn read_protocol_stream(mut sess CdpSession, stream string) !string {
	mut out := ''
	for {
		resp := sess.send_command('IO.read', '{"handle":${json_str(stream)}}')!
		data := cdp_extract_str(resp.result, 'data')
		out += data
		eof := cdp_extract_obj_key(resp.result, '"eof":') == 'true'
		if eof {
			break
		}
	}
	sess.send_command('IO.close', '{"handle":${json_str(stream)}}') or {}
	return out
}

// ─── diff ───────────────────────────────────────────────────
fn cmd_diff(mut sess CdpSession, params string) string {
	dtype := cdp_extract_str(params, 'type')
	match dtype {
		'snapshot' {
			current := cmd_snapshot(mut sess, '{}').trim('"')
			baseline_path := cdp_extract_str(params, 'baseline')
			if baseline_path != '' {
				baseline := os.read_file(baseline_path) or {
					return 'ERROR:cannot read baseline: ${err}'
				}
				diff := text_diff(baseline, current)
				return '{"diff":${json_str(diff)},"current":${json_str(current)}}'
			}
			return json_str(current)
		}
		'screenshot' {
			baseline_path := cdp_extract_str(params, 'baseline')
			if baseline_path == '' {
				return 'ERROR:missing baseline'
			}
			baseline_bytes := os.read_bytes(baseline_path) or {
				return 'ERROR:cannot read baseline: ${err}'
			}
			selector := cdp_extract_str(params, 'selector')
			full := cdp_extract_str(params, 'full') == 'true'
			threshold_obj := cdp_extract_obj_key(params, '"threshold":')
			threshold := if threshold_obj != '' { threshold_obj.f64() } else { 0.1 }
			output_path := cdp_extract_str(params, 'output')
			current_b64 := capture_screenshot_base64(mut sess, 'png', full, selector) or {
				return 'ERROR:${err}'
			}
			result := run_screenshot_diff(mut sess, base64.encode(baseline_bytes), baseline_mime_type(baseline_path),
				current_b64, threshold, output_path) or { return 'ERROR:${err}' }
			if !result.ok {
				return 'ERROR:${result.error}'
			}
			return '{"width":${result.width},"height":${result.height},"changedPixels":${result.changed_pixels},"totalPixels":${result.total_pixels},"ratio":${result.ratio},"output":${json_str(output_path)}}'
		}
		'url' {
			url1 := cdp_extract_str(params, 'url1')
			url2 := cdp_extract_str(params, 'url2')
			if url1 == '' || url2 == '' {
				return 'ERROR:diff url requires url1 and url2'
			}
			wait_until := cdp_extract_str(params, 'waitUntil')
			with_screenshot := cdp_extract_str(params, 'screenshot') == 'true'
			full := cdp_extract_str(params, 'full') == 'true'

			navigate_and_wait(mut sess, url1, wait_until) or { return 'ERROR:${err}' }
			snapshot1 := cmd_snapshot(mut sess, '{}').trim('"')
			mut screenshot1_b64 := ''
			if with_screenshot {
				screenshot1_b64 = capture_screenshot_base64(mut sess, 'png', full, '') or {
					return 'ERROR:${err}'
				}
			}

			navigate_and_wait(mut sess, url2, wait_until) or { return 'ERROR:${err}' }
			snapshot2 := cmd_snapshot(mut sess, '{}').trim('"')
			snapshot_diff := text_diff(snapshot1, snapshot2)
			mut result := '{"url1":${json_str(url1)},"url2":${json_str(url2)},"snapshot":{"diff":${json_str(snapshot_diff)},"before":${json_str(snapshot1)},"after":${json_str(snapshot2)}}'
			if with_screenshot {
				screenshot2_b64 := capture_screenshot_base64(mut sess, 'png', full, '') or {
					return 'ERROR:${err}'
				}
				screenshot_result := run_screenshot_diff(mut sess, screenshot1_b64, 'image/png',
					screenshot2_b64, 0.1, '') or { return 'ERROR:${err}' }
				if !screenshot_result.ok {
					return 'ERROR:${screenshot_result.error}'
				}
				result += ',"screenshot":{"width":${screenshot_result.width},"height":${screenshot_result.height},"changedPixels":${screenshot_result.changed_pixels},"totalPixels":${screenshot_result.total_pixels},"ratio":${screenshot_result.ratio}}'
			}
			result += '}'
			return result
		}
		else {
			return 'ERROR:unknown diff type: ${dtype}'
		}
	}
}

// ─── state ──────────────────────────────────────────────────
fn cmd_state(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	path := cdp_extract_str(params, 'path')
	state_dir := os.join_path(os.home_dir(), '.v-browser', 'states')
	os.mkdir_all(state_dir) or {}

	match action {
		'save' {
			if path == '' {
				return 'ERROR:missing path'
			}
			// 获取 cookies
			cookie_resp := sess.send_command('Network.getCookies', '{}') or {
				return 'ERROR:${err}'
			}
			cookies := cdp_extract_obj_key(cookie_resp.result, '"cookies":')
			// 获取 localStorage
			ls_js := 'JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k=>[k,localStorage.getItem(k)])))'
			ls_resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(ls_js)},"returnByValue":true}') or {
				ProtocolResponse{}
			}
			ls_result := cdp_extract_obj_key(ls_resp.result, '"result":')
			local_storage := cdp_extract_value_from_result(ls_result)
			state := '{"cookies":${cookies},"localStorage":${json_str(local_storage)}}'
			out_path := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			os.write_file(out_path, state) or { return 'ERROR:${err}' }
			return json_str(out_path)
		}
		'load' {
			file := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			content := os.read_file(file) or { return 'ERROR:cannot read state: ${err}' }
			cookies_json := cdp_extract_obj_key(content, '"cookies":')
			local_storage_json := cdp_extract_str(content, 'localStorage')
			if cookies_json != '' && cookies_json != '[]' {
				sess.send_command('Network.setCookies', '{"cookies":${cookies_json}}') or {}
			}
			if local_storage_json != '' {
				restore_js := build_storage_restore_script('localStorage', local_storage_json)
				sess.send_command('Runtime.evaluate', '{"expression":${json_str(restore_js)}}') or {}
			}
			return 'null'
		}
		'list' {
			files := os.ls(state_dir) or { return '[]' }
			return '[' + files.map(json_str(it)).join(',') + ']'
		}
		'show' {
			file := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			content := os.read_file(file) or { return 'ERROR:cannot read state: ${err}' }
			return json_str(content)
		}
		'rename' {
			new_path := cdp_extract_str(params, 'newPath')
			old := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			new := if os.is_abs_path(new_path) {
				new_path
			} else {
				os.join_path(state_dir, new_path)
			}
			os.mv(old, new) or { return 'ERROR:${err}' }
			return 'null'
		}
		else {
			return 'ERROR:unknown state action: ${action}'
		}
	}
}

// ─── 帮助函数 ────────────────────────────────────────────────

// glob_match 简单通配符匹配（支持 * 和 **）
fn glob_match(pattern string, s string) bool {
	if pattern == '*' || pattern == '**' {
		return true
	}
	if !pattern.contains('*') {
		return s == pattern
	}
	// 简单实现：将 ** 和 * 替换为正则等价处理
	parts := pattern.split('*')
	mut pos := 0
	for i, part in parts {
		if part == '' {
			continue
		}
		idx := s.index_after_(part, pos)
		if idx < 0 {
			return false
		}
		if i == 0 && idx != 0 {
			return false
		}
		// 开头不匹配
		pos = idx + part.len
	}
	if !pattern.ends_with('*') && pos != s.len {
		return s.ends_with(parts.last())
	}
	return true
}

// xpath_str XPath 字符串字面量
fn xpath_str(s string) string {
	if !s.contains("'") {
		return "'${s}'"
	}
	return 'concat("${s.replace('"', '","\'","')}")'
}

// css_attr_val CSS 属性值（用引号包裹）
fn css_attr_val(s string) string {
	return '"${s.replace('\\', '\\\\').replace('"', '\\"')}"'
}

fn build_storage_restore_script(store_name string, payload_json string) string {
	return '(function(){ try { var data=JSON.parse(${js_str(payload_json)}); ${store_name}.clear(); for (var key in data) { if (Object.prototype.hasOwnProperty.call(data, key)) { ${store_name}.setItem(key, data[key]); } } return true; } catch (e) { return String(e); } })()'
}

// text_diff 简单文本差异（逐行比较）
fn text_diff(a string, b string) string {
	a_lines := a.split_into_lines()
	b_lines := b.split_into_lines()
	mut out := ''
	mut ai := 0
	mut bi := 0
	for ai < a_lines.len || bi < b_lines.len {
		if ai >= a_lines.len {
			out += '+ ${b_lines[bi]}\n'
			bi++
		} else if bi >= b_lines.len {
			out += '- ${a_lines[ai]}\n'
			ai++
		} else if a_lines[ai] == b_lines[bi] {
			ai++
			bi++
		} else {
			out += '- ${a_lines[ai]}\n'
			out += '+ ${b_lines[bi]}\n'
			ai++
			bi++
		}
	}
	return if out == '' { '(no changes)' } else { out }
}
