// commands.v — 所有 CLI 命令实现
// dispatch_command 由 server.v 的 IPC dispatch 调用
module main

import os
import time
import encoding.base64
import strings

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
		'clipboard' { cmd_clipboard(mut sess, params) }
		'state' { cmd_state(mut sess, params) }
		else { 'ERROR:unknown command: ${method}' }
	}
}

fn cmd_not_impl(name string) string {
	return 'ERROR:command ${name} not yet implemented'
}

// ─── eval ───────────────────────────────────────────────────
fn cmd_eval(mut sess CdpSession, params string) string {
	read_error := cdp_extract_str(params, 'readError')
	if read_error != '' {
		return 'ERROR:${read_error}'
	}
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

// Short-timeout (3 s) variant for use during dialog-triggering actions to avoid
// blocking the whole CLI when the CDP session is frozen by a synchronous alert/prompt.
fn eval_scoped_expression_short(mut sess CdpSession, expr string) !string {
	encoded_expr := base64.encode_str(expr)
	scoped_expr := build_scoped_runtime_js(&sess, 'var raw=window.atob(${js_str(encoded_expr)}); var bytes=Uint8Array.from(raw, function(ch){ return ch.charCodeAt(0); }); return window.eval(new TextDecoder().decode(bytes));')
	p := '{"expression":${json_str(scoped_expr)},"returnByValue":true,"awaitPromise":false}'
	resp := sess.send_command_to('Runtime.evaluate', p, '', 3 * time.second)!
	result := cdp_extract_obj_key(resp.result, '"result":')
	return cdp_extract_value_from_result(result)
}

// Run element action with a short (3 s) timeout — used when the action may
// trigger a blocking dialog so we do not want to wait the full CDP timeout.
fn run_element_action_short(mut sess CdpSession, sel string, body string) ! {
	query := if sel.starts_with('//') || sel.starts_with('(//') {
		'var el=doc.evaluate(${js_str(sel)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;'
	} else {
		'var el=doc.querySelector(${js_str(sel)});'
	}
	js := if sess.current_frame_selector == '' {
		'(function(){ var frame=null; var doc=document; var win=window; ${query} if(el === null) return false; ${body} })()'
	} else {
		frame_sel := js_str(sess.current_frame_selector)
		'(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; ${query} if(el === null) return false; ${body} })()'
	}
	result := eval_scoped_expression_short(mut sess, js)!
	ok := result == 'true'
	if !ok {
		return error('element not found: ${sel}')
	}
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
	// Build a self-contained page script so selector lookup and event dispatch run in the same DOM scope.
	query := if sel.starts_with('//') || sel.starts_with('(//') {
		'var el=doc.evaluate(${js_str(sel)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;'
	} else {
		'var el=doc.querySelector(${js_str(sel)});'
	}
	js := if sess.current_frame_selector == '' {
		'(function(){ var frame=null; var doc=document; var win=window; ${query} if(el === null) return false; ${body} })()'
	} else {
		frame_sel := js_str(sess.current_frame_selector)
		'(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; ${query} if(el === null) return false; ${body} })()'
	}
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
	return 'el.focus(); function setValue(target, value) { var proto = Object.getPrototypeOf(target); var desc = Object.getOwnPropertyDescriptor(proto, "value") || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value") || Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value"); if (desc && desc.set) { desc.set.call(target, value); } else { target.value = value; } } if ("value" in el) { setValue(el, ""); el.dispatchEvent(new Event("input", { bubbles: true })); setValue(el, ${value_js}); el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } if (el.isContentEditable) { el.textContent = ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } return false;'
}

fn parse_verify_settings(params string, default_timeout time.Duration) (bool, time.Duration) {
	verify := cdp_extract_str(params, 'verify') == 'true'
	verify_timeout_ms := cdp_extract_int(params, '"verifyTimeout":')
	if verify_timeout_ms <= 0 {
		return verify, default_timeout
	}
	return verify, time.millisecond * verify_timeout_ms
}

fn read_element_text_or_value(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(&sess, sel, 'if(!el) return null; if ("value" in el) return el.value; return el.textContent || "";')
	return eval_scoped_expression(mut sess, js, false)
}

fn wait_for_element_text_or_value(mut sess CdpSession, sel string, expected string, timeout time.Duration) ! {
	deadline := time.now().add(timeout)
	poll_interval := verification_poll_interval(timeout)
	settle_interval := verification_settle_interval(timeout)
	mut last_current := ''
	for time.now() < deadline {
		current := read_element_text_or_value(mut sess, sel) or { '' }
		last_current = current
		if current == expected {
			time.sleep(settle_interval)
			stable := read_element_text_or_value(mut sess, sel) or { '' }
			if stable == expected {
				return
			}
			last_current = stable
		}
		time.sleep(poll_interval)
	}
	return error('verification failed: expected ${expected}, got ${last_current}')
}

fn read_file_input_names(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(&sess, sel, 'if(!el) return null; if (!el.files) return ""; return Array.from(el.files).map(function(file) { return file.name; }).join("\n");')
	return eval_scoped_expression(mut sess, js, false)
}

fn read_preview_text(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(&sess, sel, 'if(!el) return null; return (el.innerText || el.textContent || el.value || "").trim();')
	return eval_scoped_expression(mut sess, js, false)
}

fn wait_for_file_input_names(mut sess CdpSession, sel string, expected_names []string, timeout time.Duration) ! {
	expected := expected_names.map(os.file_name(it)).join('\n')
	deadline := time.now().add(timeout)
	poll_interval := verification_poll_interval(timeout)
	settle_interval := verification_settle_interval(timeout)
	mut last_current := ''
	for time.now() < deadline {
		current := read_file_input_names(mut sess, sel) or { '' }
		last_current = current
		if current == expected {
			time.sleep(settle_interval)
			stable := read_file_input_names(mut sess, sel) or { '' }
			if stable == expected {
				return
			}
			last_current = stable
		}
		time.sleep(poll_interval)
	}
	return error('verification failed: expected ${expected}, got ${last_current}')
}

fn wait_for_upload_preview(mut sess CdpSession, preview_selector string, expected_names []string, timeout time.Duration) ! {
	if preview_selector.trim_space() == '' {
		return error('missing preview selector')
	}
	expected := expected_names.map(os.file_name(it)).join(', ')
	deadline := time.now().add(timeout)
	poll_interval := verification_poll_interval(timeout)
	settle_interval := verification_settle_interval(timeout)
	mut last_current := ''
	for time.now() < deadline {
		current := read_preview_text(mut sess, preview_selector) or { '' }
		last_current = current
		if current.contains(expected) {
			time.sleep(settle_interval)
			stable := read_preview_text(mut sess, preview_selector) or { '' }
			if stable.contains(expected) {
				return
			}
			last_current = stable
		}
		time.sleep(poll_interval)
	}
	return error('verification failed: preview selector ${preview_selector} did not show ${expected}; got ${last_current}')
}

fn verification_poll_interval(timeout time.Duration) time.Duration {
	if timeout <= 500 * time.millisecond {
		return 50 * time.millisecond
	}
	if timeout <= 2 * time.second {
		return 75 * time.millisecond
	}
	if timeout <= 10 * time.second {
		return 100 * time.millisecond
	}
	return 200 * time.millisecond
}

fn verification_settle_interval(timeout time.Duration) time.Duration {
	if timeout <= 500 * time.millisecond {
		return 50 * time.millisecond
	}
	if timeout <= 2 * time.second {
		return 75 * time.millisecond
	}
	return 150 * time.millisecond
}

fn upload_result_json(files []string, phase string, preview_selector string) string {
	files_json := '[' + files.map(json_str(os.file_name(it))).join(',') + ']'
	mut p := '{"phase":${json_str(phase)},"files":${files_json}}'
	if preview_selector.trim_space() != '' {
		p = '{"phase":${json_str(phase)},"files":${files_json},"previewSelector":${json_str(preview_selector)}}'
	}
	return p
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
	clear_document_context(mut sess)
	// 订阅 loadEventFired
	load_ch := sess.subscribe('Page.loadEventFired')
	defer { sess.unsubscribe('Page.loadEventFired', load_ch) }

	sess.send_command('Page.navigate', '{"url":${json_str(url)}}') or { return 'ERROR:${err}' }
	// 等待页面加载完成（最多 30s）
	select {
		_ := <-load_ch {}
		30 * time.second {}
	}
	clear_document_context(mut sess)
	return json_str('navigated to ${url}')
}

fn clear_document_context(mut sess CdpSession) {
	// Navigation must drop any stale frame or AX state so the next page starts from the main document.
	sess.current_frame_selector = ''
	axref_clear(mut sess.axref)
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
	annotate := cdp_extract_bool(params, 'annotate')
	mut max_labels := cdp_extract_int(params, 'maxLabels')
	if max_labels == 0 {
		max_labels = 20
	}

	if annotate {
		return cmd_screenshot_annotate(mut sess, params, path, fmt, full, max_labels)
	}

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

	out_path := if path != '' {
		path
	} else {
		os.join_path(os.temp_dir(), 'screenshot_${time.now().unix_milli()}.${fmt}')
	}
	raw_bytes := base64.decode(data)
	os.write_file_array(out_path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
	return json_str(out_path)
}

fn cmd_screenshot_annotate(mut sess CdpSession, params string, path string, fmt string, full bool, max_labels int) string {
	js := build_screenshot_annotate_js(full, max_labels)
	result := eval_scoped_expression(mut sess, js, true) or { return 'ERROR:${err}' }
	ok := cdp_extract_obj_key(result, '"ok":')
	if ok != 'true' {
		err_msg := cdp_extract_str(result, 'error')
		return 'ERROR:${err_msg}'
	}
	annotated_b64 := cdp_extract_str(result, 'data')
	if annotated_b64 == '' {
		return 'ERROR:no annotated screenshot data returned'
	}

	out_path := if path != '' {
		path
	} else {
		os.join_path(os.temp_dir(), 'screenshot_annotated_${time.now().unix_milli()}.${fmt}')
	}
	raw_bytes := base64.decode(annotated_b64)
	os.write_file_array(out_path, raw_bytes) or { return 'ERROR:write failed: ${err}' }

	mut json_out := '{"path":${json_str(out_path)}'
	labels_count := cdp_extract_int(result, '"labelsCount":')
	if labels_count > 0 {
		labels_json := cdp_extract_obj_key(result, '"labels":')
		json_out += ',"labelsCount":${labels_count},"labels":${labels_json}'
	}
	json_out += '}'
	return json_out
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

fn build_screenshot_annotate_js(full bool, max_labels int) string {
	full_js := if full { 'true' } else { 'false' }
	return '((function(){
var interactiveRoles = ["button","link","textbox","checkbox","radio","combobox","listbox","menuitem","menuitemcheckbox","menuitemradio","option","searchbox","slider","spinbutton","switch","tab","treeitem","heading","image"];
var nodes = [];
try {
var tree = (function(){ var cb; var promise = new Promise(function(r){cb=r;}); chrome.runtime.sendMessage({type:"getAXTree"},function(resp){cb(resp);}); return promise; })();
var counter = 1;
for (var i = 0; i < tree.length && counter <= ${max_labels}; i++) {
var node = tree[i];
var role = node.role && node.role.value ? node.role.value : "";
if (interactiveRoles.indexOf(role) === -1) continue;
var name = node.name && node.name.value ? node.name.value : "";
var bnid = node.backendDOMNodeId || 0;
if (bnid === 0) continue;
var js = "(function(){var el=null;try{el=window.domAccessHelper.querySelectorByBackendNodeId(" + bnid + ");}catch(e){}if(!el)return null;var r=el.getBoundingClientRect();if(r.width<=0||r.height<=0)return null;var frame=null;try{var iframes=document.querySelectorAll(\"iframe\");for(var fi=0;fi<iframes.length;fi++){var fr=iframes[fi].getBoundingClientRect();if(r.x>=fr.x&&r.x<fr.x+fr.width&&r.y>=fr.y&&r.y<fr.y+fr.height){frame=iframes[fi];break;}}}catch(e){}if(frame){return{x:fr.x+r.x+r.width/2,y:fr.y+r.y+r.height/2,width:r.width,height:r.height};}return{x:r.x+r.width/2,y:r.y+r.height/2,width:r.width,height:r.height};})()";
var rect = null;
try{rect=eval(js);}catch(e){}
if (!rect) continue;
nodes.push({num:counter,role:role,name:name.substring(0,50),x:rect.x,y:rect.y,width:rect.width,height:rect.height});
counter++;
}
} catch(e) { return JSON.stringify({ok:false,error:"failed to get AX tree: "+e.message}); }
if (nodes.length === 0) { return JSON.stringify({ok:false,error:"no interactive elements found"}); }
var resp = (function(){ var cb; var promise = new Promise(function(r){cb=r;}); chrome.runtime.sendMessage({type:"captureScreenshot",params:{format:"png",captureBeyondViewport:${full_js}}},function(r){cb(r);}); return promise; })();
var img = new Image();
img.src = "data:image/png;base64," + resp.data;
var canvas = document.createElement("canvas");
canvas.width = img.width;
canvas.height = img.height;
var ctx = canvas.getContext("2d");
ctx.drawImage(img,0,0);
ctx.strokeStyle = "#ff0000";
ctx.lineWidth = 2;
for (var i = 0; i < nodes.length; i++) {
var n = nodes[i];
var scaleX = img.width / window.innerWidth;
var scaleY = img.height / window.innerHeight;
var x = n.x * scaleX;
var y = n.y * scaleY;
var w = n.width * scaleX;
var h = n.height * scaleY;
ctx.strokeRect(x - w/2, y - h/2, w, h);
var fontSize = Math.max(14, Math.min(24, Math.floor(Math.min(w, h) * 0.4)));
ctx.fillStyle = "#ff0000";
ctx.fillRect(x + w/2 - 4, y - h/2 - fontSize - 4, fontSize + 8, fontSize + 8);
ctx.fillStyle = "#ffffff";
ctx.font = "bold " + fontSize + "px monospace";
ctx.textAlign = "center";
ctx.textBaseline = "middle";
ctx.fillText(n.num.toString(), x + w/2, y - h/2 - fontSize/2);
}
var outData = canvas.toDataURL("image/png").split(",")[1];
return JSON.stringify({ok:true,data:outData,labelsCount:nodes.length,labels:nodes});
})())'
}

fn screenshot_diff_js(baseline_b64 string, baseline_mime string, current_b64 string, threshold f64, include_diff bool) string {
	include_diff_js := if include_diff { 'true' } else { 'false' }
	return '(async function(){\n' +
		'  var baselineSrc = "data:${baseline_mime};base64,${baseline_b64}";\n' +
		'  var currentSrc = "data:image/png;base64,${current_b64}";\n' +
		'  function load(src){ return new Promise(function(resolve,reject){ var img=new Image(); img.onload=function(){ resolve(img); }; img.onerror=function(){ reject(new Error("image decode failed")); }; img.src=src; }); }\n' +
		'  var images = await Promise.all([load(baselineSrc), load(currentSrc)]);\n' +
		'  var a = images[0];\n' + '  var b = images[1];\n' +
		'  var w = Math.min(a.naturalWidth, b.naturalWidth);\n' +
		'  var h = Math.min(a.naturalHeight, b.naturalHeight);\n' +
		'  if (w <= 0 || h <= 0) { return { ok:false, error:"dimension mismatch", width:b.naturalWidth, height:b.naturalHeight }; }\n' +
		'  var c1 = document.createElement("canvas"); c1.width = w; c1.height = h;\n' +
		'  var c2 = document.createElement("canvas"); c2.width = w; c2.height = h;\n' +
		'  var diffCanvas = document.createElement("canvas"); diffCanvas.width = w; diffCanvas.height = h;\n' +
		'  var x1 = c1.getContext("2d"); var x2 = c2.getContext("2d"); var xd = diffCanvas.getContext("2d");\n' +
		'  x1.drawImage(a, 0, 0, w, h, 0, 0, w, h); x2.drawImage(b, 0, 0, w, h, 0, 0, w, h);\n' +
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
		'    } else {\n' +
		'      var avg = Math.round((d2.data[i] +
		d2.data[i+1] +
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
const snapshot_interactive_roles = ['button', 'link', 'textbox', 'checkbox', 'radio', 'combobox',
	'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'searchbox', 'slider',
	'spinbutton', 'switch', 'tab', 'treeitem', 'heading', 'image', 'banner', 'navigation', 'region',
	'main', 'form', 'search', 'dialog', 'alert', 'alertdialog', 'complementary', 'contentinfo',
	'definition', 'directory', 'document', 'feed', 'figure', 'log', 'marquee', 'math', 'note',
	'progressbar', 'status', 'table', 'term', 'timer', 'tooltip', 'tree']

// parse_json_string_array 解析简单的 JSON 字符串数组 ["a","b"]
fn parse_json_string_array(json string) []string {
	mut result := []string{}
	if !json.starts_with('[') {
		return result
	}
	mut i := 1
	for i < json.len {
		if json[i] == `"` {
			j := json.index_after('"', i + 1) or { break }
			result << json[i + 1..j]
			i = j + 1
		} else {
			i++
		}
	}
	return result
}

// get_backend_node_id_for_selector 通过 CSS 选择器获取元素的 backendNodeId
fn get_backend_node_id_for_selector(mut sess CdpSession, sel string) !int {
	doc_resp := sess.send_command('DOM.getDocument', '{"depth":0}')!
	root_node_id := cdp_extract_int(doc_resp.result, '"nodeId":')
	if root_node_id == 0 {
		return error('could not get document root')
	}
	qs_resp := sess.send_command('DOM.querySelector', '{"nodeId":${root_node_id},"selector":${json_str(sel)}}')!
	target_node_id := cdp_extract_int(qs_resp.result, '"nodeId":')
	if target_node_id == 0 {
		return error('selector not found: ${sel}')
	}
	desc_resp := sess.send_command('DOM.describeNode', '{"nodeId":${target_node_id}}')!
	bnid := cdp_extract_int(desc_resp.result, '"backendNodeId":')
	return bnid
}

// collect_ax_subtree_bnids 从 AX tree JSON 中收集属于给定 backendNodeId 子树的所有 backendDOMNodeId
fn collect_ax_subtree_bnids(nodes_json string, target_bnid int) map[int]bool {
	mut node_bnid := map[string]int{}
	mut node_children := map[string][]string{}
	mut root_ax_id := ''
	mut pos := 1
	mut safety := 0
	for pos < nodes_json.len - 1 {
		if nodes_json[pos] == `{` {
			node_str := cdp_balanced(nodes_json[pos..])
			ax_id := cdp_extract_str(node_str, 'nodeId')
			bnid := cdp_extract_int(node_str, '"backendDOMNodeId":')
			child_ids_json := cdp_extract_obj_key(node_str, '"childIds":')
			if ax_id != '' {
				node_bnid[ax_id] = bnid
				node_children[ax_id] = parse_json_string_array(child_ids_json)
				if bnid == target_bnid {
					root_ax_id = ax_id
				}
			}
			pos += node_str.len
		} else {
			pos++
		}
		safety++
		if safety > 10000 {
			break
		}
	}
	if root_ax_id == '' {
		return map[int]bool{}
	}
	mut allowed := map[int]bool{}
	mut queue := [root_ax_id]
	for queue.len > 0 {
		cur_id := queue[0]
		queue = unsafe { queue[1..] }
		if bnid := node_bnid[cur_id] {
			if bnid > 0 {
				allowed[bnid] = true
			}
		}
		if children := node_children[cur_id] {
			for child_id in children {
				queue << child_id
			}
		}
	}
	return allowed
}

fn cmd_snapshot(mut sess CdpSession, params string) string {
	// 解析参数
	raw := cdp_extract_bool(params, 'raw')
	// 默认只输出 AX Tree；--extra / --interactive 会额外触发 cursor-interactive 补全扫描。
	extra := cdp_extract_bool(params, 'extra') || cdp_extract_bool(params, 'interactive')
	// maxNodes 限制的是最终返回的引用总数，AX Tree 和补全共用同一预算。
	max_nodes := cdp_extract_int(params, 'maxNodes')
	// --selector 限剑对指定元素子树进行快照
	filter_selector := cdp_extract_str(params, 'selector')

	resp := sess.send_command('Accessibility.getFullAXTree', '{}') or { return 'ERROR:${err}' }
	nodes_json := cdp_extract_obj_key(resp.result, '"nodes":')
	if nodes_json == '' {
		return 'ERROR:no AX tree returned'
	}

	// 如果指定了 selector，先获取目标元素的 backendNodeId，再收集子树节点 ID
	mut filter_bnids := map[int]bool{}
	if filter_selector != '' {
		target_bnid := get_backend_node_id_for_selector(mut sess, filter_selector) or {
			return 'ERROR:${err}'
		}
		filter_bnids = collect_ax_subtree_bnids(nodes_json, target_bnid)
		if filter_bnids.len == 0 {
			return 'ERROR:selector matched no accessible nodes: ${filter_selector}'
		}
	}

	axref_clear(mut sess.axref)
	mut out := strings.new_builder(4096)
	out.write_string('= Accessibility Snapshot =\n')
	ax_out, next_counter := render_ax_tree(nodes_json, 1, mut sess.axref, extra, max_nodes,
		filter_bnids)
	out.write_string(ax_out)

	// extra 模式下才会在 AX Tree 之外附加 cursor-interactive 补全。
	if extra && filter_selector == '' {
		remaining := if max_nodes > 0 { max_nodes - (next_counter - 1) } else { 0 }
		if max_nodes == 0 || remaining > 0 {
			cursor_limit := if max_nodes > 0 { remaining } else { 0 }
			cursor_out := render_cursor_interactive_snapshot(mut sess, next_counter, mut
				sess.axref, cursor_limit) or { '' }
			if cursor_out != '' {
				if !ax_out.ends_with('\n') {
					out.write_string('\n')
				}
				out.write_string('# Cursor-interactive elements:\n')
				out.write_string(cursor_out)
			}
		}
	}

	final_out := out.str()
	// raw 模式返回未编码的纯文本
	if raw {
		return final_out
	}
	return json_str(final_out)
}

fn render_ax_tree(nodes_json string, start_counter int, mut store AxRefStore, include_extra bool,
	max_nodes int, filter_bnids map[int]bool) (string, int) {
	mut out := strings.new_builder(4096)
	mut counter := start_counter
	mut pos := 1 // skip opening '['
	mut i := 0 // 安全计数器，防止解析过大的树时无限循环

	for pos < nodes_json.len - 1 {
		if nodes_json[pos] == `{` {
			if max_nodes > 0 && counter - start_counter >= max_nodes {
				break
			}
			node_str := cdp_balanced(nodes_json[pos..])
			role := ax_prop(node_str, 'role')
			name := ax_prop(node_str, 'name')
			bnid := cdp_extract_int(node_str, '"backendDOMNodeId":')

			// 如果指定了 selector 过滤，跳过不属于子树的节点
			if filter_bnids.len > 0 && (bnid == 0 || filter_bnids[bnid] == false) {
				pos += node_str.len
				i++
				if i > 10000 {
					break
				}
				continue
			}

			// extra 模式只保留明确可交互的角色；默认模式则保留更多可读节点。
			should_include := if include_extra {
				role != '' && role in snapshot_interactive_roles
			} else {
				role != '' && role != 'none' && role != 'generic'
			}

			// 只有满足条件的节点才分配引用并写入输出。
			if should_include {
				ref_key := '@e${counter}'
				counter++
				out.write_string('${ref_key} [${role}] ${name}\n')
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
	return out.str(), counter
}

fn build_cursor_interactive_snapshot_js(sess &CdpSession, candidate_limit int) string {
	limit := if candidate_limit > 0 { candidate_limit } else { 1000 }
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
		// 优化：不再使用 querySelectorAll("*")，仅扫描明确的可交互元素或有交互意图的属性
		var selector = [
			"a", "button", "input", "select", "textarea", "details", "summary",
			"[onclick]", "[role]", "[tabindex]", "[contenteditable]",
			"area", "label"
		].join(",");
		var candidates = doc.querySelectorAll(selector);
		
		// 默认只处理前 1000 个候选；如果 snapshot 传入了 maxNodes，则继续收紧扫描上限。
		var count = Math.min(candidates.length, ${limit});
		for (var i = 0; i < count; i++) {
			var el = candidates[i];
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

fn render_cursor_interactive_snapshot(mut sess CdpSession, start_counter int, mut store AxRefStore,
	max_nodes int) !string {
	js := build_cursor_interactive_snapshot_js(&sess, max_nodes)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return error('cursor scan failed: ${err}')
	}
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	raw_lines := cdp_extract_value_from_result(result_obj)
	if raw_lines == '' || raw_lines == 'null' {
		return ''
	}
	mut out := strings.new_builder(4096)
	mut counter := start_counter
	for line in raw_lines.split('\n') {
		// maxNodes 是全局输出预算，这里沿用剩余额度继续截断。
		if max_nodes > 0 && counter - start_counter >= max_nodes {
			break
		}
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
		out.write_string('${ref_key} [${resolved_role}] ${text}')
		if hints != '' {
			out.write_string(' (${hints})')
		}
		out.write_string('\n')
		axref_set(mut store, ref_key, AxRef{
			selector: selector
			role:     resolved_role
			name:     text
		})
	}
	return out.str()
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
	// Prefer the in-page JS click path: it is the most faithful to the page's
	// own event handling and works for the fixture buttons that update state.
	// If the DOM click cannot be resolved, fall back to CDP mouse input.
	run_element_action(mut sess, sel, build_click_action_body()) or {
		pointer_action_for_selector(mut sess, sel, 'click') or { return 'ERROR:${err}' }
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
	focus_selector(mut sess, sel) or { return 'ERROR:${err}' }
	return 'null'
}

fn focus_selector(mut sess CdpSession, sel string) ! {
	el := resolve_selector(mut sess, sel)!
	sess.send_command('DOM.focus', '{"backendNodeId":${el.backend_node_id}}') or {
		// fallback: Runtime.evaluate
		js := build_element_scope_js(&sess, sel, 'el?.focus(); return true;')
		if !evaluate_bool_js(mut sess, js)! {
			return error('element not found: ${sel}')
		}
	}
}

// ─── fill ───────────────────────────────────────────────────
fn cmd_fill(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	if sess.current_frame_selector != '' {
		fill_via_keyboard(mut sess, sel, text) or { return 'ERROR:${err}' }
	} else {
		run_element_action(mut sess, sel, build_fill_action_body(text)) or {
			fill_via_keyboard(mut sess, sel, text) or { return 'ERROR:${err}' }
		}
	}
	verify, verify_timeout := parse_verify_settings(params, 1500 * time.millisecond)
	if verify {
		wait_for_element_text_or_value(mut sess, sel, text, verify_timeout) or {
			return 'ERROR:${err}'
		}
	}
	return 'null'
}

fn fill_via_keyboard(mut sess CdpSession, sel string, text string) ! {
	// Frame inputs are more reliable with native key events than DOM value assignment in this stack.
	focus_selector(mut sess, sel)!
	$if macos {
		dispatch_key(mut sess, 'Meta+a', 'keyDown', '')!
		dispatch_key(mut sess, 'Meta+a', 'keyUp', '')!
	} $else {
		dispatch_key(mut sess, 'Control+a', 'keyDown', '')!
		dispatch_key(mut sess, 'Control+a', 'keyUp', '')!
	}
	dispatch_key(mut sess, 'Backspace', 'keyDown', '')!
	dispatch_key(mut sess, 'Backspace', 'keyUp', '')!
	type_text_like_playwright(mut sess, text)!
}

// ─── type ───────────────────────────────────────────────────
fn cmd_type_text(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	focus_selector(mut sess, sel) or { return 'ERROR:${err}' }
	type_text_like_playwright(mut sess, text) or { return 'ERROR:${err}' }
	verify, verify_timeout := parse_verify_settings(params, 1500 * time.millisecond)
	if verify {
		wait_for_element_text_or_value(mut sess, sel, text, verify_timeout) or {
			return 'ERROR:${err}'
		}
	}
	return 'null'
}

// ─── keyboard ───────────────────────────────────────────────
fn cmd_keyboard(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	text := cdp_extract_str(params, 'text')
	return match action {
		'type', 'inserttext' {
			if action == 'type' {
				type_text_like_playwright(mut sess, text) or { return 'ERROR:${err}' }
			} else {
				sess.send_command('Input.insertText', '{"text":${json_str(text)}}') or {
					return 'ERROR:${err}'
				}
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
	dispatch_key(mut sess, key, 'keyDown', '') or { return 'ERROR:${err}' }
	dispatch_key(mut sess, key, 'keyUp', '') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keydown(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' {
		return 'ERROR:missing key'
	}
	dispatch_key(mut sess, key, 'keyDown', '') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keyup(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' {
		return 'ERROR:missing key'
	}
	dispatch_key(mut sess, key, 'keyUp', '') or { return 'ERROR:${err}' }
	return 'null'
}

fn dispatch_key(mut sess CdpSession, key string, typ string, text string) ! {
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
	mut payload := '{"type":"${typ}","key":${json_str(actual_key)},"modifiers":${modifiers}'
	if typ == 'keyDown' && text != '' {
		payload += ',"text":${json_str(text)},"unmodifiedText":${json_str(text)}'
	}
	payload += '}'
	sess.send_command('Input.dispatchKeyEvent', payload)!
}

fn type_text_like_playwright(mut sess CdpSession, text string) ! {
	for ch in text.runes() {
		ch_text := ch.str()
		match ch {
			`\n` {
				dispatch_key(mut sess, 'Enter', 'keyDown', '\n')!
				dispatch_key(mut sess, 'Enter', 'keyUp', '')!
			}
			`\r` {
				continue
			}
			`\t` {
				dispatch_key(mut sess, 'Tab', 'keyDown', '\t')!
				dispatch_key(mut sess, 'Tab', 'keyUp', '')!
			}
			else {
				// ASCII printable chars use real key events
				if ch_text.len == 1 && ch_text[0] >= 32 && ch_text[0] < 127 {
					key_name := if ch_text == ' ' { 'Space' } else { ch_text }
					dispatch_key(mut sess, key_name, 'keyDown', ch_text)!
					dispatch_key(mut sess, key_name, 'keyUp', '')!
				} else {
					// Non-ASCII (e.g., Chinese) use insertText for better compatibility
					sess.send_command('Input.insertText', '{"text":${json_str(ch_text)}}')!
				}
			}
		}
	}
}

// ─── select ─────────────────────────────────────────────────
fn cmd_select(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	value := cdp_extract_str(params, 'value')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	js := build_element_scope_js(&sess, sel, 'if(!el) return false; el.value=${js_str(value)}; el.dispatchEvent(new Event("input",{bubbles:true})); el.dispatchEvent(new Event("change",{bubbles:true})); return true;')
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
	wait_preview := cdp_extract_str(params, 'waitPreview') == 'true'
	preview_selector := cdp_extract_str(params, 'previewSelector')
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
	verify, verify_timeout := parse_verify_settings(params, 1500 * time.millisecond)
	if verify {
		wait_for_file_input_names(mut sess, sel, files, verify_timeout) or { return 'ERROR:${err}' }
	}
	if wait_preview {
		if preview_selector.trim_space() == '' {
			return 'ERROR:missing preview selector'
		}
		wait_for_upload_preview(mut sess, preview_selector, files, verify_timeout) or {
			return 'ERROR:${err}'
		}
		return upload_result_json(files, 'previewed', preview_selector)
	}
	if preview_selector.trim_space() != '' {
		return upload_result_json(files, 'selected', preview_selector)
	}
	return upload_result_json(files, 'selected', '')
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
		// visible：排除 visibility:hidden、display:none、opacity:0 以及零尺寸元素
		'visible' {
			build_element_scope_js(&sess, sel, "if(!el) return false; var r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false; var s=getComputedStyle(el); return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';")
		}
		'enabled' {
			build_element_scope_js(&sess, sel, 'return !el?.disabled;')
		}
		'checked' {
			build_element_scope_js(&sess, sel, 'return !!el?.checked;')
		}
		// disabled
		'disabled' {
			build_element_scope_js(&sess, sel, 'return !!el?.disabled;')
		}
		// focused：是否是当前获得焦点的元素
		'focused' {
			build_element_scope_js(&sess, sel, 'return el === doc.activeElement;')
		}
		// selected：option 被选中 或 aria-selected=true
		'selected' {
			build_element_scope_js(&sess, sel, "return el?.selected === true || el?.getAttribute('aria-selected') === 'true';")
		}
		// editable：可编辑（非只读、非禁用)
		'editable' {
			build_element_scope_js(&sess, sel, "if(!el) return false; if(el.disabled) return false; if(el.readOnly) return false; return el.isContentEditable || 'value' in el;")
		}
		// expanded：aria-expanded=true
		'expanded' {
			build_element_scope_js(&sess, sel, "return el?.getAttribute('aria-expanded') === 'true';")
		}
		else {
			return 'ERROR:unknown state: ${state}'
		}
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
	// wait --stable
	stable := cdp_extract_str(params, 'stable')
	if stable != '' {
		stable_timeout := if timeout_ms > 0 {
			timeout_ms * time.millisecond
		} else {
			30 * time.second
		}
		return wait_stable(mut sess, stable, stable_timeout)
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

// wait_stable 连续两次读取内容相同则认为元素内容已稳定
fn wait_stable(mut sess CdpSession, sel string, timeout time.Duration) string {
	deadline := time.now().add(timeout)
	poll_interval := 300 * time.millisecond
	settled_threshold := 2 // 连续相同次数
	js := build_element_scope_js(&sess, sel, "if(!el) return null; return el.innerText||el.value||'';")
	mut last_val := ''
	mut stable_count := 0
	for time.now() < deadline {
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
			break
		}
		result := cdp_extract_obj_key(resp.result, '"result":')
		cur_val := cdp_extract_value_from_result(result)
		if cur_val == 'null' || cur_val == '' {
			time.sleep(poll_interval)
			continue
		}
		if cur_val == last_val {
			stable_count++
			if stable_count >= settled_threshold {
				return 'null'
			}
		} else {
			last_val = cur_val
			stable_count = 1
		}
		time.sleep(poll_interval)
	}
	return 'ERROR:timeout waiting for ${sel} to stabilize'
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
	if locator == 'text' && index < 0 {
		report := semantic_text_candidates_report(mut sess, query, exact, index, 5, 'list')
		count := cdp_extract_int(report, '"count":')
		if count > 1 {
			return 'ERROR:ambiguous text match: ${query}. Use --index to select a candidate, or run find --list / --debug to review candidates.'
		}
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
		function isVisible(el) {
			if (!el) return false;
			var tag = (el.tagName || "").toLowerCase();
			if (tag !== "summary" && el.closest("details:not([open])")) return false;
			var style = win.getComputedStyle(el);
			if (style.visibility === "hidden" || style.display === "none") return false;
			return !!(el.getClientRects && el.getClientRects().length);
		}
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
		}).sort(function(a, b) {
			return Number(isVisible(b)) - Number(isVisible(a));
		}).map(function(el, idx) {
			var item = inspectCandidate(el, idx);
			if (item) item.visible = isVisible(el);
			return item;
		}).filter(Boolean);
		var total = candidates.length;
		var hint = total === 0 ? "未找到候选" : (total === 1 ? "仅 1 个候选" : "有 " + total + " 个候选，请使用 --index 选择具体项，或用 --name 缩小范围");
		var report = { count: total, selectedIndex: ${selected_index_js}, hint: hint, mode: ${mode_js} };
		if (${mode_js} === "debug") {
			report.candidates = candidates.slice(0, ${limit_js});
		} else {
			report.candidates = candidates;
		}
		return JSON.stringify(report, null, 2);
	')
}

fn build_semantic_locator_js(sess &CdpSession, locator string, query string, exact bool, name_filter string, index int) string {
	query_js := js_str(query)
	name_js := js_str(name_filter)
	index_js := '${index}'
	exact_js := if exact { 'true' } else { 'false' }
	locator_body := match locator {
		'role' {
			'var pool=Array.from(doc.querySelectorAll(roleSelector(${query_js}))); var visibleMatches=pool.filter(el=>isVisible(el)&&roleOf(el)===${query_js}&&matchesName(el, ${name_js}, ${exact_js})); elements=(visibleMatches.length?visibleMatches:pool.filter(el=>roleOf(el)===${query_js}&&matchesName(el, ${name_js}, ${exact_js})));'
		}
		'text' {
			'var actionablePool=Array.from(doc.querySelectorAll(actionableSelector())); var visibleActionableMatches=actionablePool.filter(el=>isVisible(el)&&isActionable(el)&&matchesText(candidateText(el), ${query_js}, ${exact_js})).filter(el=>!hasMatchingDescendant(el, ${query_js}, ${exact_js})); var actionableMatches=(visibleActionableMatches.length?visibleActionableMatches:actionablePool.filter(el=>isActionable(el)&&matchesText(candidateText(el), ${query_js}, ${exact_js})).filter(el=>!hasMatchingDescendant(el, ${query_js}, ${exact_js}))); elements=(actionableMatches.length?actionableMatches:Array.from(doc.querySelectorAll("*")).filter(el=>isVisible(el)&&matchesText(candidateText(el), ${query_js}, ${exact_js})).filter(el=>!hasMatchingDescendant(el, ${query_js}, ${exact_js})).map(el=>closestActionable(el, ${query_js}, ${exact_js})).filter(Boolean)).filter((el, idx, arr)=>arr.indexOf(el)===idx);'
		}
		'label' {
			'var labels=Array.from(doc.querySelectorAll("label")); var visibleControls=labels.map(label=>{ if(!matchesText(label.innerText||label.textContent||"", ${query_js}, ${exact_js})) return null; var control=label.control || label.querySelector("input, textarea, select, button"); return control && isVisible(control) ? control : null; }).filter(Boolean); elements=(visibleControls.length?visibleControls:labels.map(label=>{ if(!matchesText(label.innerText||label.textContent||"", ${query_js}, ${exact_js})) return null; return label.control || label.querySelector("input, textarea, select, button"); }).filter(Boolean));'
		}
		'placeholder' {
			'var all=Array.from(doc.querySelectorAll("[placeholder]")); var visibleMatches=all.filter(el=>isVisible(el)&&matchesText(el.getAttribute("placeholder")||"", ${query_js}, ${exact_js})); elements=(visibleMatches.length?visibleMatches:all.filter(el=>matchesText(el.getAttribute("placeholder")||"", ${query_js}, ${exact_js})));'
		}
		'alt' {
			'var all=Array.from(doc.querySelectorAll("[alt]")); var visibleMatches=all.filter(el=>isVisible(el)&&matchesText(el.getAttribute("alt")||"", ${query_js}, ${exact_js})); elements=(visibleMatches.length?visibleMatches:all.filter(el=>matchesText(el.getAttribute("alt")||"", ${query_js}, ${exact_js})));'
		}
		'title' {
			'var all=Array.from(doc.querySelectorAll("[title]")); var visibleMatches=all.filter(el=>isVisible(el)&&matchesText(el.getAttribute("title")||"", ${query_js}, ${exact_js})); elements=(visibleMatches.length?visibleMatches:all.filter(el=>matchesText(el.getAttribute("title")||"", ${query_js}, ${exact_js})));'
		}
		'testid' {
			'var all=Array.from(doc.querySelectorAll("[data-testid]")); var visibleMatches=all.filter(el=>isVisible(el)&&matchesText(el.getAttribute("data-testid")||"", ${query_js}, ${exact_js})); elements=(visibleMatches.length?visibleMatches:all.filter(el=>matchesText(el.getAttribute("data-testid")||"", ${query_js}, ${exact_js})));'
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
		'nth' {
			'return elements.length > ${index_js} ? elements[${index_js}] : null;'
		}
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
		function isVisible(el) {
			if (!el) return false;
			var tag = (el.tagName || "").toLowerCase();
			if (tag !== "summary" && el.closest("details:not([open])")) return false;
			var style = win.getComputedStyle(el);
			if (style.visibility === "hidden" || style.display === "none") return false;
			return !!(el.getClientRects && el.getClientRects().length);
		}
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
		function actionableSelector() {
			return "a[href], button, summary, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=checkbox], [role=radio], [role=switch], [role=tab], [role=menuitem], [role=option], [data-testid], [aria-controls], [aria-haspopup]";
		}
		function roleSelector(role) {
			switch (String(role || "").toLowerCase()) {
				case "button": return "button, summary, [role=button], input[type=button], input[type=submit], input[type=reset]";
				case "link": return "a[href], [role=link]";
				case "checkbox": return "input[type=checkbox], [role=checkbox]";
				case "radio": return "input[type=radio], [role=radio]";
				case "textbox": return "textarea, input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not([type=button]):not([type=submit]):not([type=reset]), [role=textbox]";
				case "combobox": return "select, [role=combobox]";
				case "option": return "option, [role=option]";
				case "tab": return "[role=tab]";
				case "menuitem": return "[role=menuitem], [role=menuitemcheckbox], [role=menuitemradio]";
				default: return "*";
			}
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
			sess.save_current_tab_context()
			resp := sess.send_bridge_command('createTab', '{"url":${json_str(if url != '' {
				url
			} else {
				'about:blank'
			})}}') or { return 'ERROR:${err}' }
			sess.activate_tab_context_from_result(resp.result) or { return 'ERROR:${err}' }
			return resp.result
		}
		'switch' {
			tab_id := cdp_extract_int(params, '"tabId":')
			window_id := cdp_extract_int(params, '"windowId":')
			if tab_id == 0 {
				return 'ERROR:missing tabId'
			}
			sess.save_current_tab_context()
			resp := sess.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}') or {
				return 'ERROR:${err}'
			}
			sess.activate_tab_context_from_result(resp.result) or { return 'ERROR:${err}' }
			return resp.result
		}
		'close' {
			tab_id := cdp_extract_int(params, '"tabId":')
			if tab_id == 0 {
				return 'ERROR:missing tabId'
			}
			if sess.current_tab_id == tab_id {
				sess.save_current_tab_context()
			}
			resp := sess.send_bridge_command('closeTab', '{"tabId":${tab_id}}') or {
				return 'ERROR:${err}'
			}
			sess.tab_contexts_mu.@lock()
			sess.tab_contexts.delete(tab_id)
			sess.tab_contexts_mu.unlock()
			if sess.current_tab_id == tab_id {
				sess.current_tab_id = 0
				sess.page_mu.@lock()
				sess.page_enabled = false
				sess.page_mu.unlock()
				sess.network_mu.@lock()
				sess.network_enabled = false
				sess.network_mu.unlock()
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
			sess.save_current_tab_context()
			resp := sess.send_bridge_command('createWindow', '{"url":${json_str(if url != '' {
				url
			} else {
				'about:blank'
			})}}') or { return 'ERROR:${err}' }
			sess.activate_tab_context_from_result(resp.result) or { return 'ERROR:${err}' }
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
		'body' {
			request_id := cdp_extract_str(params, 'requestId')
			if request_id == '' {
				return 'ERROR:missing requestId'
			}
			body := sess.get_response_body(request_id) or { return 'ERROR:${err}' }
			return json_str(body)
		}
		'save' {
			request_id := cdp_extract_str(params, 'requestId')
			if request_id == '' {
				return 'ERROR:missing requestId'
			}
			target_path := cdp_extract_str(params, 'path')
			out_path, mime_type := save_network_response(mut sess, request_id, target_path) or {
				return 'ERROR:${err}'
			}
			return '{"ok":true,"requestId":${json_str(request_id)},"path":${json_str(out_path)},"mimeType":${json_str(mime_type)}}'
		}
		'save-images' {
			target_dir := cdp_extract_str(params, 'path')
			if target_dir == '' {
				return 'ERROR:missing path'
			}
			filter := cdp_extract_str(params, 'filter')
			paths, count := save_network_images(mut sess, target_dir, filter) or {
				return 'ERROR:${err}'
			}
			mut items := []string{}
			for path in paths {
				items << json_str(path)
			}
			return '{"ok":true,"count":${count},"paths":[${items.join(',')}]} '
		}
		'watch' {
			subaction := cdp_extract_str(params, 'subaction')
			match subaction {
				'', 'start' {
					target_dir := cdp_extract_str(params, 'path')
					filter := cdp_extract_str(params, 'filter')
					if target_dir == '' {
						return 'ERROR:missing path'
					}
					return start_network_watch(mut sess, target_dir, filter) or {
						return 'ERROR:${err}'
					}
				}
				'stop' {
					return stop_network_watch(mut sess)
				}
				'status' {
					return network_watch_status_json(mut sess)
				}
				else {
					return 'ERROR:unknown network watch subaction: ${subaction}'
				}
			}
		}
		'headers' {
			request_id := cdp_extract_str(params, 'requestId')
			if request_id == '' {
				return 'ERROR:missing requestId'
			}
			headers := sess.get_response_headers(request_id) or { return 'ERROR:${err}' }
			return json_str(headers)
		}
		'route' {
			url := cdp_extract_str(params, 'url')
			abort := cdp_extract_str(params, 'abort') == 'true'
			body := cdp_extract_str(params, 'body')
			// 如果已存在 route，先停止旧 goroutine 并取消订阅
			if sess.has_route {
				sess.route_stop_ch <- true
				sess.unsubscribe('Fetch.requestPaused', sess.route_ch)
				sess.has_route = false
			}
			// 启用 Fetch 拦截
			sess.send_command('Fetch.enable', '{"patterns":[{"urlPattern":${json_str(url)}}]}') or {
				return 'ERROR:${err}'
			}
			// 订阅 Fetch.requestPaused 事件并处理
			ch := sess.subscribe('Fetch.requestPaused')
			stop_ch := chan bool{cap: 1}
			sess.route_ch = ch
			sess.route_stop_ch = stop_ch
			sess.has_route = true
			spawn fn [mut sess, ch, stop_ch, abort, body] () {
				for {
					select {
						evt := <-ch {
							request_id := cdp_extract_str(evt.params, 'requestId')
							if request_id == '' {
								continue
							}
							if abort {
								sess.send_command('Fetch.failRequest', '{"requestId":${json_str(request_id)},"errorReason":"Aborted"}') or {}
							} else if body != '' {
								sess.send_command('Fetch.fulfillRequest', '{"requestId":${json_str(request_id)},"responseCode":200,"body":${json_str(base64.encode_str(body))}}') or {}
							} else {
								sess.send_command('Fetch.continueRequest', '{"requestId":${json_str(request_id)}}') or {}
							}
						}
						_ := <-stop_ch {
							break
						}
					}
				}
			}()
			return 'null'
		}
		'hook' {
			subaction := cdp_extract_str(params, 'subaction')
			match subaction {
				'', 'start' {
					return start_network_hook(mut sess, params) or { return 'ERROR:${err}' }
				}
				'stop' {
					return stop_network_hook(mut sess)
				}
				'status' {
					return network_hook_status_json(mut sess)
				}
				'records' {
					return network_hook_records_json(mut sess, params) or { return 'ERROR:${err}' }
				}
				'summary' {
					return network_hook_summary_json(mut sess, params) or { return 'ERROR:${err}' }
				}
				'templates' {
					return network_hook_templates_json(mut sess, params) or {
						return 'ERROR:${err}'
					}
				}
				'replay' {
					return network_hook_replay_json(mut sess, params) or { return 'ERROR:${err}' }
				}
				else {
					return 'ERROR:unknown network hook subaction: ${subaction}'
				}
			}
		}
		'unroute' {
			// 停止 route goroutine 并取消订阅
			if sess.has_route {
				sess.route_stop_ch <- true
				sess.unsubscribe('Fetch.requestPaused', sess.route_ch)
				sess.has_route = false
			}
			sess.send_command('Fetch.disable', '{}') or { return 'ERROR:${err}' }
			return 'null'
		}
		else {
			return 'ERROR:unknown network action: ${action}'
		}
	}
}

fn start_network_hook(mut sess CdpSession, params string) !string {
	filter := cdp_extract_str(params, 'filter')
	capture_body := cdp_extract_str(params, 'captureBody') == 'true'
	capture_response := cdp_extract_str(params, 'captureResponse') == 'true'
	persistent := cdp_extract_str(params, 'persistent') != 'false'
	clear := cdp_extract_str(params, 'clear') != 'false'
	mut script_id := cdp_extract_str(params, 'scriptId')
	if script_id == '' {
		script_id = 'hook-v1'
	}
	install_network_hook(mut sess, script_id, persistent)!
	if clear {
		clear_network_hook_records(mut sess)
	}
	activate_js := 'window.__vBrowserHookConfig = window.__vBrowserHookConfig || {}; try { if (window.localStorage) { window.localStorage.setItem("__vBrowserHookActive", "true"); } } catch (err) {} try { if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookActive", "true"); } } catch (err) {} window.__vBrowserHookConfig.active = true; window.__vBrowserHookConfig.filter = ${json_str(filter)}; window.__vBrowserHookConfig.captureBody = ${capture_body}; window.__vBrowserHookConfig.captureResponse = ${capture_response}; window.__vBrowserHookConfig.scriptId = ${json_str(script_id)}; window.__vBrowserHookState = window.__vBrowserHookState || { events: [], nextId: 0 }; if (${clear}) { window.__vBrowserHookState.events = []; window.__vBrowserHookState.nextId = 0; } window.__vBrowserHookInstalled = true; "ok"'
	eval_scoped_expression(mut sess, activate_js, false)!
	sess.hook_mu.@lock()
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_state.script_id = script_id
	sess.hook_state.script_version = 2
	sess.hook_state.filter = filter
	sess.hook_state.capture_body = capture_body
	sess.hook_state.capture_response = capture_response
	sess.hook_state.last_injected_at = time.now().unix_milli().str()
	if clear {
		sess.hook_state.last_synced_index = 0
		sess.hook_state.record_count = 0
	}
	sess.hook_mu.unlock()
	return network_hook_status_json(mut sess)
}

fn stop_network_hook(mut sess CdpSession) string {
	stop_js := 'window.__vBrowserHookConfig = window.__vBrowserHookConfig || {}; try { if (window.localStorage) { window.localStorage.setItem("__vBrowserHookActive", "false"); } } catch (err) {} try { if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookActive", "false"); } } catch (err) {} window.__vBrowserHookConfig.active = false; window.__vBrowserHookInstalled = true; "ok"'
	eval_scoped_expression(mut sess, stop_js, false) or {}
	sess.hook_mu.@lock()
	sess.hook_state.active = false
	sess.hook_mu.unlock()
	return network_hook_status_json(mut sess)
}

fn network_hook_status_json(mut sess CdpSession) string {
	sync_network_hook_records(mut sess) or {}
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	return network_hook_status_json_from_state(sess.hook_state)
}

fn network_hook_status_json_from_state(state HookState) string {
	return '{"active":${state.active},"injected":${state.injected},"scriptId":${json_str(state.script_id)},"scriptVersion":${state.script_version},"filter":${json_str(state.filter)},"captureBody":${state.capture_body},"captureResponse":${state.capture_response},"lastInjectedAt":${json_str(state.last_injected_at)},"lastSyncedIndex":${state.last_synced_index},"recordCount":${state.record_count}}'
}

fn network_hook_records_json(mut sess CdpSession, params string) !string {
	sync_network_hook_records(mut sess) or { return error(err.msg()) }
	filter := cdp_extract_str(params, 'filter').to_lower()
	limit := cdp_extract_str(params, 'limit').int()
	format := cdp_extract_str(params, 'format').to_lower()
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	mut items := []string{}
	for record_id in sess.hook_record_order {
		record := sess.hook_records[record_id] or { continue }
		view := hook_record_view_from_raw(record)
		if filter != '' && !hook_record_matches_filter(view, filter) {
			continue
		}
		if format == 'raw' {
			items << record.raw_json
		} else {
			items << hook_record_view_json(view)
		}
		if limit > 0 && items.len >= limit {
			break
		}
	}
	return '[' + items.join(',') + ']'
}

fn network_hook_summary_json(mut sess CdpSession, params string) !string {
	sync_network_hook_records(mut sess) or { return error(err.msg()) }
	filter := cdp_extract_str(params, 'filter').to_lower()
	limit := cdp_extract_str(params, 'limit').int()
	return hook_summary_json_from_session(mut sess, filter, limit)
}

fn network_hook_templates_json(mut sess CdpSession, params string) !string {
	sync_network_hook_records(mut sess) or { return error(err.msg()) }
	filter := cdp_extract_str(params, 'filter').to_lower()
	limit := cdp_extract_str(params, 'limit').int()
	return hook_templates_json_from_session(mut sess, filter, limit)
}

fn network_hook_replay_json(mut sess CdpSession, params string) !string {
	sync_network_hook_records(mut sess) or { return error(err.msg()) }
	record_id := cdp_extract_str(params, 'recordId')
	if record_id == '' {
		return error('missing recordId')
	}
	override_method := cdp_extract_str(params, 'method')
	override_body := cdp_extract_str(params, 'body')
	mut override_headers := cdp_extract_str(params, 'overrideHeaders')
	dry_run := cdp_extract_str(params, 'dryRun') == 'true'
	record := sess.hook_records[record_id] or {
		return error('hook record not found: ${record_id}')
	}
	method := if override_method != '' {
		override_method
	} else {
		cdp_extract_str(record.raw_json, 'method')
	}
	url := network_hook_replay_url_from_params(params, record)
	body := if override_body != '' {
		override_body
	} else {
		cdp_extract_str(record.raw_json, 'requestBody')
	}
	mut request_headers := cdp_extract_obj(record.raw_json, 'requestHeaders')
	if request_headers == '' {
		request_headers = '{}'
	}
	if override_headers == '' {
		override_headers = '{}'
	}
	if method == '' || url == '' {
		return error('replay record is missing method or url')
	}
	if dry_run {
		return '{"ok":true,"dryRun":true,"recordId":${json_str(record_id)},"method":${json_str(method)},"url":${json_str(url)},"body":${json_str(body)},"requestHeaders":${request_headers},"overrideHeaders":${json_str(override_headers)}}'
	}
	replay_js := build_network_replay_js(method, url, body, request_headers, override_headers)
	raw := eval_scoped_expression(mut sess, replay_js, true) or { return error(err.msg()) }
	// If replay returned a fallback, persist fallbackText into the stored record
	// so it shows up in subsequent records/summary exports.
	if raw.contains('"fallback"') {
		fb := cdp_extract_obj(raw, 'fallback')
		if fb != '' {
			fb_text := cdp_extract_str(fb, 'text')
			if fb_text != '' {
				sess.hook_mu.@lock()
				if record_id in sess.hook_records {
					sess.hook_records[record_id] = HookRecord{
						record_id:     record_id
						raw_json:      sess.hook_records[record_id].raw_json
						fallback_text: fb_text
					}
				}
				sess.hook_mu.unlock()
			}
		}
	}
	return raw
}

fn network_hook_replay_url_from_params(params string, record HookRecord) string {
	override_url := cdp_extract_str(params, 'overrideUrl')
	if override_url != '' {
		return override_url
	}
	legacy_url := cdp_extract_str(params, 'url')
	if legacy_url != '' {
		return legacy_url
	}
	return cdp_extract_str(record.raw_json, 'url')
}

fn hook_record_view_from_raw(record HookRecord) RequestRecord {
	raw := record.raw_json
	request_headers := hook_extract_json_object(raw, 'requestHeaders')
	response_headers := hook_extract_json_object(raw, 'responseHeaders')
	request_body := cdp_extract_str(raw, 'requestBody')
	response_body := cdp_extract_str(raw, 'responseBody')
	url := cdp_extract_str(raw, 'url')
	fallback_text := if record.fallback_text != '' {
		record.fallback_text
	} else {
		cdp_extract_str(raw, 'fallbackText')
	}
	return RequestRecord{
		record_id:        record.record_id
		source:           hook_extract_string(raw, 'source', 'unknown')
		phase:            hook_extract_string(raw, 'phase', '')
		page_url:         cdp_extract_str(raw, 'pageUrl')
		method:           hook_extract_string(raw, 'method', 'GET')
		url:              url
		signature:        hook_record_signature(raw)
		cursor_hint:      hook_record_cursor_hint(raw)
		request_headers:  if request_headers == '' { '{}' } else { request_headers }
		request_body:     request_body
		response_status:  cdp_extract_int(raw, 'status')
		status_text:      cdp_extract_str(raw, 'statusText')
		response_url:     cdp_extract_str(raw, 'responseUrl')
		response_ok:      cdp_extract_bool(raw, 'responseOk')
		response_type:    cdp_extract_str(raw, 'responseType')
		ready_state:      cdp_extract_int(raw, 'readyState')
		with_credentials: cdp_extract_bool(raw, 'withCredentials')
		response_headers: if response_headers == '' { '{}' } else { response_headers }
		response_body:    response_body
		error_text:       cdp_extract_str(raw, 'errorText')
		timestamp:        cdp_extract_int(raw, 'timestamp')
		fallback_text:    fallback_text
	}
}

fn hook_record_view_json(view RequestRecord) string {
	return '{"recordId":${json_str(view.record_id)},"source":${json_str(view.source)},"phase":${json_str(view.phase)},"pageUrl":${json_str(view.page_url)},"method":${json_str(view.method)},"url":${json_str(view.url)},"signature":${json_str(view.signature)},"cursorHint":${json_str(view.cursor_hint)},"requestHeaders":${view.request_headers},"requestBody":${json_str(view.request_body)},"responseStatus":${view.response_status},"statusText":${json_str(view.status_text)},"responseUrl":${json_str(view.response_url)},"responseOk":${view.response_ok},"responseType":${json_str(view.response_type)},"readyState":${view.ready_state},"withCredentials":${view.with_credentials},"responseHeaders":${view.response_headers},"responseBody":${json_str(view.response_body)},"errorText":${json_str(view.error_text)},"timestamp":${view.timestamp},"fallbackText":${json_str(view.fallback_text)}}'
}

fn hook_record_matches_filter(view RequestRecord, filter string) bool {
	if filter == '' {
		return true
	}
	haystack := '${view.record_id} ${view.source} ${view.phase} ${view.page_url} ${view.method} ${view.url} ${view.signature} ${view.cursor_hint} ${view.request_body} ${view.response_body} ${view.status_text} ${view.response_url} ${view.error_text} ${view.fallback_text}'.to_lower()
	return haystack.contains(filter)
}

fn hook_summary_json_from_session(mut sess CdpSession, filter string, limit int) string {
	mut method_counts := map[string]int{}
	mut signature_counts := map[string]int{}
	mut signature_order := []string{}
	mut signature_record_ids := map[string][]string{}
	mut signature_cursor_hints := map[string][]string{}
	mut signature_samples := map[string]string{}
	mut signature_methods := map[string]string{}
	mut signature_url_patterns := map[string]string{}
	mut signature_body_templates := map[string]string{}
	mut signature_required_headers := map[string]string{}
	mut signature_transform_rules := map[string]string{}
	mut signature_expected_shapes := map[string]string{}
	mut cursor_counts := map[string]int{}
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	for record_id in sess.hook_record_order {
		record := sess.hook_records[record_id] or { continue }
		view := hook_record_view_from_raw(record)
		if filter != '' && !hook_record_matches_filter(view, filter) {
			continue
		}
		method_key := if view.method == '' { 'GET' } else { view.method }
		method_counts[method_key] = method_counts[method_key] + 1
		signature_key := if view.signature == '' {
			'${method_key} ${view.url}'
		} else {
			view.signature
		}
		if signature_key !in signature_counts {
			signature_order << signature_key
			signature_samples[signature_key] = hook_record_view_json(view)
			signature_record_ids[signature_key] = []string{}
			signature_cursor_hints[signature_key] = []string{}
			signature_methods[signature_key] = method_key
			signature_url_patterns[signature_key] = hook_normalize_signature_url(view.url)
			signature_body_templates[signature_key] = hook_request_body_signature(view.request_body)
			signature_required_headers[signature_key] = hook_required_headers_json(view.request_headers)
			signature_transform_rules[signature_key] = hook_transform_rules_json(view)
			signature_expected_shapes[signature_key] = hook_expected_shape_json(view)
		}
		signature_counts[signature_key] = signature_counts[signature_key] + 1
		signature_record_ids[signature_key] << view.record_id
		if view.cursor_hint != '' {
			cursor_counts[view.cursor_hint] = cursor_counts[view.cursor_hint] + 1
			if view.cursor_hint !in signature_cursor_hints[signature_key]
				&& signature_cursor_hints[signature_key].len < 5 {
				signature_cursor_hints[signature_key] << view.cursor_hint
			}
		}
	}
	mut method_items := []string{}
	mut method_keys := method_counts.keys()
	method_keys.sort()
	for key in method_keys {
		method_items << '"${json_object_key(key)}":${method_counts[key]}'
	}
	mut cursor_items := []string{}
	mut cursor_keys := cursor_counts.keys()
	cursor_keys.sort()
	for key in cursor_keys {
		cursor_items << '{"hint":${json_str(key)},"count":${cursor_counts[key]}}'
	}
	mut groups := []string{}
	for signature_key in signature_order {
		count := signature_counts[signature_key]
		if limit > 0 && groups.len >= limit {
			break
		}
		record_ids := signature_record_ids[signature_key] or { []string{} }
		hints := signature_cursor_hints[signature_key] or { []string{} }
		mut record_id_items := []string{}
		for record_id in record_ids {
			record_id_items << json_str(record_id)
		}
		mut hint_items := []string{}
		for hint in hints {
			hint_items << json_str(hint)
		}
		groups << '{"signature":${json_str(signature_key)},"count":${count},"recordIds":[${record_id_items.join(',')}],"cursorHints":[${hint_items.join(',')}],"sample":${signature_samples[signature_key] or {
			'{}'
		}}}'
	}
	mut templates := []string{}
	for signature_key in signature_order {
		if limit > 0 && templates.len >= limit {
			break
		}
		templates << hook_template_json(hook_template_from_signature(signature_key, signature_methods[signature_key] or {
			'GET'
		}, signature_url_patterns[signature_key] or { '' }, signature_required_headers[signature_key] or {
			'[]'
		}, signature_body_templates[signature_key] or { '' }, signature_transform_rules[signature_key] or {
			'[]'
		}, signature_expected_shapes[signature_key] or { '{}' }, signature_record_ids[signature_key] or {
			[]string{}
		}, signature_samples[signature_key] or { '{}' }))
	}
	return '{"totalRecords":${sess.hook_record_order.len},"uniqueSignatures":${signature_counts.len},"methodCounts":{${method_items.join(',')}},"cursorHints":[${cursor_items.join(',')}],"groups":[${groups.join(',')}],"templates":[${templates.join(',')}]}'
}

fn hook_templates_json_from_session(mut sess CdpSession, filter string, limit int) string {
	summary := hook_summary_json_from_session(mut sess, filter, limit)
	return cdp_extract_obj(summary, 'templates')
}

fn hook_record_signature(raw string) string {
	method := hook_extract_string(raw, 'method', 'GET')
	url := cdp_extract_str(raw, 'url')
	return '${method} ${hook_normalize_signature_url(url)} ${hook_request_body_signature(cdp_extract_str(raw,
		'requestBody'))}'
}

fn hook_record_cursor_hint(raw string) string {
	url := cdp_extract_str(raw, 'url')
	body := cdp_extract_str(raw, 'requestBody')
	keys := ['cursor', 'cursorToken', 'cursor_token', 'paginationToken', 'pagination_token',
		'nextCursor', 'next_cursor', 'max_id', 'since_id']
	for key in keys {
		mut hint := hook_extract_query_value(url, key)
		if hint != '' {
			return '${key}=${hint}'
		}
		hint = hook_extract_query_value(body, key)
		if hint != '' {
			return '${key}=${hint}'
		}
		hint = cdp_extract_str(body, key)
		if hint != '' {
			return '${key}=${hint}'
		}
	}
	return ''
}

fn hook_extract_string(raw string, key string, fallback string) string {
	value := cdp_extract_str(raw, key)
	if value != '' {
		return value
	}
	return fallback
}

fn hook_extract_json_object(raw string, key string) string {
	value := cdp_extract_obj(raw, key)
	if value != '' {
		return value
	}
	return '{}'
}

fn hook_extract_query_value(text string, key string) string {
	if text == '' {
		return ''
	}
	search := '${key}='
	idx := text.index(search) or { return '' }
	rest := text[idx + search.len..]
	end := rest.index('&') or { rest.len }
	value := rest[..end].trim_space()
	if value == '' {
		return ''
	}
	return value.trim('"')
}

fn json_object_key(key string) string {
	quoted := json_str(key)
	if quoted.len >= 2 {
		return quoted[1..quoted.len - 1]
	}
	return quoted
}

fn hook_normalize_signature_url(url string) string {
	if url == '' {
		return ''
	}
	mut base := url
	if hash_index := base.index('#') {
		base = base[..hash_index]
	}
	mut query_keys := []string{}
	if question_index := base.index('?') {
		query := base[question_index + 1..]
		base = base[..question_index]
		for part in query.split('&') {
			if part.trim_space() == '' {
				continue
			}
			key := part.all_before('=').trim_space()
			if key != '' && key !in query_keys {
				query_keys << key
			}
		}
	}
	if query_keys.len == 0 {
		return base
	}
	return '${base}?keys=${query_keys.join(',')}'
}

fn hook_request_body_signature(body string) string {
	if body == '' {
		return ''
	}
	trimmed := body.trim_space()
	if trimmed.len <= 120 {
		return trimmed
	}
	return trimmed[..120]
}

fn hook_required_headers_json(headers_json string) string {
	keys := hook_json_object_keys(headers_json)
	mut items := []string{}
	for key in keys {
		items << json_str(key)
	}
	return '[' + items.join(',') + ']'
}

fn hook_transform_rules_json(view RequestRecord) string {
	rules := [
		'"captureBody":${view.request_body != ''}',
		'"captureResponse":${view.response_body != ''}',
		'"hasCursorHint":${view.cursor_hint != ''}',
		'"method":"${json_object_key(view.method)}"',
	]
	return '[' + rules.join(',') + ']'
}

fn hook_expected_shape_json(view RequestRecord) string {
	return '{"status":${view.response_status},"responseOk":${view.response_ok},"responseType":${json_str(view.response_type)},"statusText":${json_str(view.status_text)}}'
}

fn hook_template_from_signature(signature string, method string, url_pattern string, required_headers string, body_template string, transform_rules string, expected_response_shape string, record_ids []string, sample string) ReplayTemplate {
	first_record_id := if record_ids.len > 0 { record_ids[0] } else { '' }
	return ReplayTemplate{
		template_id:             'tpl-${hook_safe_id_component(signature)}'
		request_signature:       signature
		method:                  method
		url_pattern:             url_pattern
		required_headers:        required_headers
		body_template:           body_template
		transform_rules:         transform_rules
		expected_response_shape: expected_response_shape
		sample_record_id:        first_record_id
	}
}

fn hook_template_json(template ReplayTemplate) string {
	return '{"templateId":${json_str(template.template_id)},"requestSignature":${json_str(template.request_signature)},"method":${json_str(template.method)},"urlPattern":${json_str(template.url_pattern)},"requiredHeaders":${template.required_headers},"bodyTemplate":${json_str(template.body_template)},"transformRules":${template.transform_rules},"expectedResponseShape":${template.expected_response_shape},"sampleRecordId":${json_str(template.sample_record_id)}}'
}

fn hook_json_object_keys(raw string) []string {
	trimmed := raw.trim_space()
	if trimmed == '' || trimmed == '{}' {
		return []string{}
	}
	mut keys := []string{}
	mut depth := 0
	mut in_string := false
	mut escaped := false
	mut collecting_key := false
	mut expecting_key := true
	mut current_key := ''
	for c in trimmed {
		if in_string {
			if escaped {
				escaped = false
				if collecting_key {
					current_key += c.ascii_str()
				}
				continue
			}
			if c == `\\` {
				escaped = true
				if collecting_key {
					current_key += c.ascii_str()
				}
				continue
			}
			if c == `"` {
				in_string = false
				if collecting_key && current_key != '' {
					keys << current_key
				}
				collecting_key = false
				continue
			}
			if collecting_key {
				current_key += c.ascii_str()
			}
			continue
		}
		if c == `"` {
			in_string = true
			collecting_key = depth == 1 && expecting_key
			if collecting_key {
				current_key = ''
			}
			continue
		}
		if c == `{` {
			depth++
			expecting_key = true
			continue
		}
		if c == `}` {
			if depth > 0 {
				depth--
			}
			expecting_key = false
			continue
		}
		if c == `:` && depth == 1 {
			expecting_key = false
			continue
		}
		if c == `,` && depth == 1 {
			expecting_key = true
			continue
		}
	}
	return keys
}

fn hook_safe_id_component(value string) string {
	if value == '' {
		return 'empty'
	}
	mut out := value.to_lower()
	replacements := [
		['://', '-'],
		[' ', '-'],
		['/', '-'],
		['?', '-'],
		['&', '-'],
		['=', '-'],
		[':', '-'],
		['"', ''],
		['\\', '-'],
		['{', '-'],
		['}', '-'],
		['[', '-'],
		[']', '-'],
		['(', '-'],
		[')', '-'],
	]
	for pair in replacements {
		out = out.replace(pair[0], pair[1])
	}
	for out.contains('--') {
		out = out.replace('--', '-')
	}
	return out.trim('-')
}

fn install_network_hook(mut sess CdpSession, script_id string, persistent bool) !string {
	bootstrap_js := network_hook_bootstrap_js()
	if persistent {
		sess.hook_mu.@lock()
		should_install := !sess.hook_state.injected || sess.hook_state.script_id != script_id
			|| sess.hook_state.script_version != 2
		sess.hook_mu.unlock()
		if should_install {
			sess.send_command('Page.addScriptToEvaluateOnNewDocument', '{"source":${json_str(bootstrap_js)}}')!
			sess.hook_mu.@lock()
			sess.hook_state.injected = true
			sess.hook_state.script_id = script_id
			sess.hook_state.script_version = 2
			sess.hook_mu.unlock()
		}
	}
	eval_scoped_expression(mut sess, bootstrap_js, false)!
	return 'ok'
}

fn clear_network_hook_records(mut sess CdpSession) {
	sess.hook_mu.@lock()
	sess.hook_records = map[string]HookRecord{}
	sess.hook_record_order = []string{}
	sess.hook_state.last_synced_index = 0
	sess.hook_state.record_count = 0
	sess.hook_mu.unlock()
}

fn sync_network_hook_records(mut sess CdpSession) !int {
	sess.hook_mu.@lock()
	last_synced_index := sess.hook_state.last_synced_index
	sess.hook_mu.unlock()
	read_js := 'JSON.stringify(window.__vBrowserHookState && window.__vBrowserHookState.events ? window.__vBrowserHookState.events.slice(${last_synced_index}) : [])'
	raw := eval_scoped_expression(mut sess, read_js, false) or { return error(err.msg()) }
	trimmed := raw.trim_space()
	if trimmed == '' || trimmed == 'null' || trimmed == 'undefined' || trimmed == '[]' {
		return 0
	}
	items := split_json_array_objects(trimmed)
	if items.len == 0 {
		return 0
	}
	mut added := 0
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	for item in items {
		record_id := cdp_extract_str(item, 'recordId')
		if record_id == '' {
			continue
		}
		if record_id in sess.hook_records {
			continue
		}
		sess.hook_records[record_id] = HookRecord{
			record_id: record_id
			raw_json:  item
		}
		sess.hook_record_order << record_id
		added++
	}
	sess.hook_state.last_synced_index += items.len
	sess.hook_state.record_count = sess.hook_record_order.len
	return added
}

fn network_hook_bootstrap_js() string {
	return [
		'(function() {',
		'  var SCRIPT_VERSION = 2;',
		'  var cfg = window.__vBrowserHookConfig = window.__vBrowserHookConfig || {};',
		'  function readPersistedActive() {',
		'    try {',
		'      var value = window.localStorage && window.localStorage.getItem("__vBrowserHookActive");',
		'      if (value === "true") { return true; }',
		'      if (value === "false") { return false; }',
		'      value = window.sessionStorage && window.sessionStorage.getItem("__vBrowserHookActive");',
		'      if (value === "true") { return true; }',
		'      if (value === "false") { return false; }',
		'    } catch (err) {}',
		'    return null;',
		'  }',
		'  var persistedActive = readPersistedActive();',
		'  if (persistedActive !== null) { cfg.active = persistedActive; }',
		'  var state = window.__vBrowserHookState = window.__vBrowserHookState || { events: [], nextId: 0 };',
		'  if (window.__vBrowserHookInstalled && window.__vBrowserHookVersion === SCRIPT_VERSION) { return "ok"; }',
		'  window.__vBrowserHookVersion = SCRIPT_VERSION;',
		'  function truncateText(value, limit) {',
		'    var text = String(value == null ? "" : value);',
		'    if (!limit || text.length <= limit) { return text; }',
		'    return text.slice(0, limit) + "...";',
		'  }',
		'  function toPlainHeaders(headers) {',
		'    var out = {};',
		'    if (!headers) { return out; }',
		'    try {',
		'      if (typeof Headers !== "undefined" && headers instanceof Headers) {',
		'        headers.forEach(function(value, key) { out[String(key)] = String(value); });',
		'        return out;',
		'      }',
		'      if (Array.isArray(headers)) {',
		'        headers.forEach(function(item) {',
		'          if (Array.isArray(item) && item.length >= 2) { out[String(item[0])] = String(item[1]); }',
		'        });',
		'        return out;',
		'      }',
		'      if (typeof headers === "object") {',
		'        Object.keys(headers).forEach(function(key) {',
		'          var value = headers[key];',
		'          if (value != null) { out[String(key)] = String(value); }',
		'        });',
		'      }',
		'    } catch (err) {}',
		'    return out;',
		'  }',
		'  function normalizeBody(body) {',
		'    if (body == null) { return ""; }',
		'    if (typeof body === "string") { return body; }',
		'    if (typeof URLSearchParams !== "undefined" && body instanceof URLSearchParams) { return body.toString(); }',
		'    if (typeof FormData !== "undefined" && body instanceof FormData) {',
		'      var items = [];',
		'      body.forEach(function(value, key) { items.push([String(key), String(value)]); });',
		'      return JSON.stringify(items);',
		'    }',
		'    if (typeof body === "number" || typeof body === "boolean") { return String(body); }',
		'    if (typeof body === "object") {',
		'      if (typeof body.byteLength === "number") { return "[binary:" + body.byteLength + "]"; }',
		'      try { return JSON.stringify(body); } catch (err) { return String(body); }',
		'    }',
		'    return String(body);',
		'  }',
		'  function shouldCapture(method, url) {',
		'    var filter = String(cfg.filter || "");',
		'    if (!filter) { return true; }',
		'    var haystack = String(method || "") + " " + String(url || "");',
		'    return haystack.toLowerCase().indexOf(filter.toLowerCase()) >= 0;',
		'  }',
		'  function pushRecord(record) {',
		'    record.recordId = String(++state.nextId);',
		'    record.scriptId = String(cfg.scriptId || "");',
		'    record.pageUrl = String(location.href || "");',
		'    record.timestamp = Date.now();',
		'    state.events.push(record);',
		'    if (state.events.length > 1000) { state.events.splice(0, state.events.length - 1000); }',
		'  }',
		'  var nativeToStringMap = window.__vBrowserHookNativeToStringMap = window.__vBrowserHookNativeToStringMap || (typeof WeakMap !== "undefined" ? new WeakMap() : null);',
		'  function nativeCodeString(name) {',
		'    return "function " + String(name || "") + "() { [native code] }";',
		'  }',
		'  function registerNativeLike(fn, name, length) {',
		'    if (!fn) { return; }',
		'    try {',
		'      if (nativeToStringMap) { nativeToStringMap.set(fn, nativeCodeString(name)); }',
		'    } catch (err) {}',
		'    try {',
		'      if (name) { Object.defineProperty(fn, "name", { value: String(name), configurable: true }); }',
		'    } catch (err) {}',
		'    try {',
		'      if (length != null) { Object.defineProperty(fn, "length", { value: Number(length), configurable: true }); }',
		'    } catch (err) {}',
		'  }',
		'  var originalFunctionToString = Function.prototype.toString;',
		'  if (!Function.prototype.__vBrowserHookToStringPatched) {',
		'    var patchedFunctionToString = function() {',
		'      try {',
		'        if (nativeToStringMap && nativeToStringMap.has(this)) { return nativeToStringMap.get(this); }',
		'      } catch (err) {}',
		'      return originalFunctionToString.apply(this, arguments);',
		'    };',
		'    try {',
		'      Object.defineProperty(Function.prototype, "toString", { value: patchedFunctionToString, configurable: true, writable: true });',
		'    } catch (err) {',
		'      Function.prototype.toString = patchedFunctionToString;',
		'    }',
		'    try {',
		'      Object.defineProperty(Function.prototype, "__vBrowserHookToStringPatched", { value: true, configurable: true });',
		'    } catch (err) {',
		'      Function.prototype.__vBrowserHookToStringPatched = true;',
		'    }',
		'  }',
		'  function captureFetchRequest(input, init) {',
		'    var method = "GET";',
		'    var url = "";',
		'    var headers = {};',
		'    var body = "";',
		'    var mode = "";',
		'    var credentials = "";',
		'    var cache = "";',
		'    var redirect = "";',
		'    var referrer = "";',
		'    var referrerPolicy = "";',
		'    var integrity = "";',
		'    var keepalive = "";',
		'    var priority = "";',
		'    try {',
		'      if (typeof input === "string") {',
		'        url = input;',
		'      } else if (input && typeof input.url === "string") {',
		'        url = input.url;',
		'        method = input.method || method;',
		'        headers = toPlainHeaders(input.headers);',
		'        body = normalizeBody(input.body);',
		'        mode = input.mode || mode;',
		'        credentials = input.credentials || credentials;',
		'        cache = input.cache || cache;',
		'        redirect = input.redirect || redirect;',
		'        referrer = input.referrer || referrer;',
		'        referrerPolicy = input.referrerPolicy || referrerPolicy;',
		'        integrity = input.integrity || integrity;',
		'        keepalive = input.keepalive != null ? String(input.keepalive) : keepalive;',
		'        priority = input.priority || priority;',
		'      }',
		'      if (init) {',
		'        if (init.method) { method = init.method; }',
		'        if (init.headers) {',
		'          var initHeaders = toPlainHeaders(init.headers);',
		'          Object.keys(initHeaders).forEach(function(key) { headers[key] = initHeaders[key]; });',
		'        }',
		'        if (init.body !== undefined) { body = normalizeBody(init.body); }',
		'        if (init.mode) { mode = init.mode; }',
		'        if (init.credentials) { credentials = init.credentials; }',
		'        if (init.cache) { cache = init.cache; }',
		'        if (init.redirect) { redirect = init.redirect; }',
		'        if (init.referrer !== undefined) { referrer = String(init.referrer); }',
		'        if (init.referrerPolicy) { referrerPolicy = init.referrerPolicy; }',
		'        if (init.integrity) { integrity = init.integrity; }',
		'        if (init.keepalive != null) { keepalive = String(init.keepalive); }',
		'        if (init.priority) { priority = init.priority; }',
		'      }',
		'    } catch (err) {}',
		'    return { method: String(method || "GET"), url: String(url || ""), headers: headers, body: body, mode: String(mode || ""), credentials: String(credentials || ""), cache: String(cache || ""), redirect: String(redirect || ""), referrer: String(referrer || ""), referrerPolicy: String(referrerPolicy || ""), integrity: String(integrity || ""), keepalive: String(keepalive || ""), priority: String(priority || "") };',
		'  }',
		'  function captureFetchResult(meta, response, error, responseBody) {',
		'    pushRecord({',
		'      source: "fetch",',
		'      phase: error ? "error" : "complete",',
		'      method: meta.method,',
		'      url: meta.url,',
		'      status: response ? Number(response.status || 0) : 0,',
		'      statusText: response ? String(response.statusText || "") : "",',
		'      responseUrl: response ? String(response.url || "") : "",',
		'      responseOk: response ? Boolean(response.ok) : false,',
		'      requestHeaders: meta.headers,',
		'      requestBody: meta.body,',
		'      requestMode: meta.mode,',
		'      requestCredentials: meta.credentials,',
		'      requestCache: meta.cache,',
		'      requestRedirect: meta.redirect,',
		'      requestReferrer: meta.referrer,',
		'      requestReferrerPolicy: meta.referrerPolicy,',
		'      requestIntegrity: meta.integrity,',
		'      requestKeepalive: meta.keepalive,',
		'      requestPriority: meta.priority,',
		'      signature: [String(meta.method || "GET"), String(meta.url || ""), String(meta.body || "").slice(0, 120)].join(" "),',
		'      responseBody: responseBody ? truncateText(responseBody, 4000) : "",',
		'      responseHeaders: typeof response.headers === "object" && response.headers ? toPlainHeaders(response.headers) : {},',
		'      errorText: error ? truncateText(error, 2000) : ""',
		'    });',
		'  }',
		'  function captureXhrResult(meta, xhr, errorText) {',
		'    var responseBody = "";',
		'    if (cfg.captureResponse) {',
		'      try { responseBody = String(xhr.responseText == null ? "" : xhr.responseText); } catch (err) {}',
		'    }',
		'    function parseXhrHeaders(raw) {',
		'      var out = {};',
		'      if (!raw) { return out; }',
		'      var lines = String(raw).split("\\n");',
		'      for (var i = 0; i < lines.length; i++) {',
		'        var line = lines[i];',
		'        var idx = line.indexOf(":");',
		'        if (idx > 0) {',
		'          var key = line.slice(0, idx).trim();',
		'          var val = line.slice(idx + 1).trim();',
		'          if (key) { out[key] = val; }',
		'        }',
		'      }',
		'      return out;',
		'    }',
		'    pushRecord({',
		'      source: "xhr",',
		'      phase: errorText ? "error" : "complete",',
		'      method: meta.method,',
		'      url: meta.url,',
		'      status: Number(xhr.status || 0),',
		'      statusText: String(xhr.statusText || ""),',
		'      responseUrl: String(xhr.responseURL || ""),',
		'      responseOk: xhr.status >= 200 && xhr.status < 300,',
		'      responseType: String(xhr.responseType || ""),',
		'      readyState: Number(xhr.readyState || 0),',
		'      withCredentials: Boolean(xhr.withCredentials),',
		'      requestHeaders: meta.headers,',
		'      requestBody: meta.body,',
		'      responseBody: responseBody ? truncateText(responseBody, 4000) : "",',
		'      responseHeaders: parseXhrHeaders(xhr.getAllResponseHeaders ? xhr.getAllResponseHeaders() : ""),',
		'      errorText: errorText ? truncateText(errorText, 2000) : ""',
		'    });',
		'  }',
		'  function captureFetchResponse(meta, response, onDone, onError) {',
		'    if (!cfg.captureResponse || !response || typeof response.clone !== "function") {',
		'      onDone("");',
		'      return;',
		'    }',
		'    try {',
		'      response.clone().text().then(function(text) {',
		'        onDone(String(text == null ? "" : text));',
		'      }, function() {',
		'        onDone("");',
		'      });',
		'    } catch (err) {',
		'      onError(err);',
		'    }',
		'  }',
		'  var originalFetch = window.fetch;',
		'  if (typeof originalFetch === "function" && !originalFetch.__vBrowserHookWrapped) {',
		'    var fetchWrapper = function(input, init) {',
		'      if (!cfg.active) { return originalFetch.apply(this, arguments); }',
		'      var meta = captureFetchRequest(input, init);',
		'      if (!shouldCapture(meta.method, meta.url)) { return originalFetch.apply(this, arguments); }',
		'      try {',
		'        return originalFetch.apply(this, arguments).then(function(response) {',
		'          return new Promise(function(resolve) {',
		'            captureFetchResponse(meta, response, function(responseBody) {',
		'              captureFetchResult(meta, response, null, responseBody);',
		'              resolve(response);',
		'            }, function() {',
		'              captureFetchResult(meta, response, null, "");',
		'              resolve(response);',
		'            });',
		'          });',
		'        }, function(error) {',
		'          captureFetchResult(meta, null, error, "");',
		'          throw error;',
		'        });',
		'      } catch (error) {',
		'        captureFetchResult(meta, null, error, "");',
		'        throw error;',
		'      }',
		'    };',
		'    fetchWrapper.__vBrowserHookWrapped = true;',
		'    registerNativeLike(fetchWrapper, "fetch", 2);',
		'    window.fetch = fetchWrapper;',
		'  }',
		'  var XHR = window.XMLHttpRequest;',
		'  if (XHR && XHR.prototype && !XHR.prototype.__vBrowserHookWrapped) {',
		'    var originalOpen = XHR.prototype.open;',
		'    var originalSend = XHR.prototype.send;',
		'    var originalSetRequestHeader = XHR.prototype.setRequestHeader;',
		'    XHR.prototype.open = function(method, url, async, user, password) {',
		'      this.__vBrowserHookMeta = { method: String(method || "GET"), url: String(url || ""), headers: {}, body: "" };',
		'      return originalOpen.apply(this, arguments);',
		'    };',
		'    registerNativeLike(XHR.prototype.open, "open", 5);',
		'    XHR.prototype.setRequestHeader = function(name, value) {',
		'      if (this.__vBrowserHookMeta) { this.__vBrowserHookMeta.headers[String(name)] = String(value); }',
		'      return originalSetRequestHeader.apply(this, arguments);',
		'    };',
		'    registerNativeLike(XHR.prototype.setRequestHeader, "setRequestHeader", 2);',
		'    XHR.prototype.send = function(body) {',
		'      var xhr = this;',
		'      var meta = xhr.__vBrowserHookMeta || { method: "GET", url: "", headers: {}, body: "" };',
		'      meta.body = normalizeBody(body);',
		'      if (cfg.active && shouldCapture(meta.method, meta.url)) {',
		'        var finalized = false;',
		'        var finalize = function(errorText) {',
		'          if (finalized) { return; }',
		'          finalized = true;',
		'          captureXhrResult(meta, xhr, errorText);',
		'        };',
		'        xhr.addEventListener("loadend", function() { finalize(""); }, { once: true });',
		'        xhr.addEventListener("error", function() { finalize("xhr error"); }, { once: true });',
		'        xhr.addEventListener("abort", function() { finalize("xhr abort"); }, { once: true });',
		'        xhr.addEventListener("timeout", function() { finalize("xhr timeout"); }, { once: true });',
		'      }',
		'      return originalSend.apply(this, arguments);',
		'    };',
		'    registerNativeLike(XHR.prototype.send, "send", 1);',
		'    XHR.prototype.__vBrowserHookWrapped = true;',
		'  }',
		'  window.__vBrowserHookInstalled = true;',
		'  return "ok";',
		'})()',
	].join('\n')
}

fn build_network_replay_js(method string, url string, body string, headers string, override_headers string) string {
	method_js := js_str(method)
	url_js := js_str(url)
	body_js := js_str(body)
	headers_js := if headers.trim_space() != '' { headers } else { '{}' }
	override_headers_js := if override_headers.trim_space() != '' { override_headers } else { '{}' }
	return [
		'(async function(){',
		'  function mergeHeaders(baseHeaders, overrideHeaders) {',
		'    var out = {};',
		'    Object.keys(baseHeaders || {}).forEach(function(key) { out[String(key)] = String(baseHeaders[key]); });',
		'    Object.keys(overrideHeaders || {}).forEach(function(key) { out[String(key)] = String(overrideHeaders[key]); });',
		'    return out;',
		'  }',
		'  function captureDomFallback(reason, responseStatus) {',
		'    var text = "";',
		'    var title = "";',
		'    try {',
		'      text = String((document.body && document.body.innerText) || (document.documentElement && document.documentElement.innerText) || "");',
		'      title = String(document.title || "");',
		'    } catch (err) {}',
		'    if (text.length > 4000) { text = text.slice(0, 4000); }',
		'    return { kind: "dom", reason: String(reason || ""), status: Number(responseStatus || 0), title: title, pageUrl: String(location.href || ""), text: text };',
		'  }',
		'  var headers = mergeHeaders(' + headers_js + ', ' + override_headers_js + ');',
		'  var init = { method: ' + method_js + ', credentials: "include" };',
		'  if (Object.keys(headers).length > 0) { init.headers = headers; }',
		'  if (' + method_js + ' !== "GET" && ' + method_js + ' !== "HEAD" && ' + body_js +
			' !== "") { init.body = ' + body_js + '; }',
		'  try {',
		'    var response = await fetch(' + url_js + ', init);',
		'    var text = "";',
		'    try { text = await response.text(); } catch (err) { text = ""; }',
		'    if (!response.ok) {',
			'      return JSON.stringify({ ok: false, replayKind: "dom-fallback", reason: "http-status", method: ' +
			method_js + ', url: ' + url_js +
			', status: response.status, statusText: response.statusText, responseUrl: response.url || ' +
			url_js +
			', requestHeaders: headers, responseBody: text.slice(0, 4000), fallback: captureDomFallback("http-status", response.status) });',
		'    }',
		'    return JSON.stringify({ ok: true, replayKind: "fetch", method: ' + method_js +
			', url: ' + url_js +
			', status: response.status, statusText: response.statusText, responseUrl: response.url || ' +
			url_js + ', requestHeaders: headers, body: text.slice(0, 4000) });',
		'  } catch (error) {',
			'    return JSON.stringify({ ok: false, replayKind: "dom-fallback", reason: String(error && error.message ? error.message : error), method: ' +
			method_js + ', url: ' + url_js + ', status: 0, statusText: "", responseUrl: ' + url_js +
			', requestHeaders: headers, responseBody: "", fallback: captureDomFallback(String(error && error.message ? error.message : error), 0) });',
		'  }',
		'})()',
	].join('\n')
}

fn save_network_response(mut sess CdpSession, request_id string, target_path string) !(string, string) {
	sess.enable_network_tracking()!
	entry := sess.network_requests[request_id] or {
		return error('request not found: ${request_id}')
	}
	body := sess.get_response_body_bytes(request_id)!
	mime_type := network_response_mime_type(entry)
	out_path := resolve_network_save_path(target_path, request_id, entry.url, mime_type)
	parent_dir := os.dir(out_path)
	if parent_dir != '' {
		os.mkdir_all(parent_dir)!
	}
	os.write_file_array(out_path, body)!
	return out_path, mime_type
}

fn save_network_images(mut sess CdpSession, target_dir string, filter string) !([]string, int) {
	sess.enable_network_tracking()!
	os.mkdir_all(target_dir)!
	needle := filter.trim_space().to_lower()
	primary_urls := collect_page_primary_image_urls(mut sess) or { []string{} }
	mut primary_url_set := map[string]bool{}
	for url in primary_urls {
		primary_url_set[url] = true
	}
	mut saved_paths := []string{}
	if primary_url_set.len == 0 {
		return saved_paths, 0
	}
	for request_id in sess.network_request_order {
		entry := sess.network_requests[request_id] or { continue }
		if needle != '' {
			haystack := '${entry.method} ${entry.url} ${entry.resource_type} ${entry.status_text} ${entry.error_text}'.to_lower()
			if !haystack.contains(needle) {
				continue
			}
		}
		if entry.url !in primary_url_set {
			continue
		}
		seq := saved_paths.len + 1
		output_name := network_image_output_name(seq, entry)
		out_path, _ := save_network_response(mut sess, request_id, os.join_path(target_dir,
			output_name)) or { continue }
		saved_paths << out_path
	}
	return saved_paths, saved_paths.len
}

fn start_network_watch(mut sess CdpSession, target_dir string, filter string) !string {
	if target_dir.trim_space() == '' {
		return error('missing path')
	}
	sess.enable_network_tracking()!
	os.mkdir_all(target_dir)!
	needle := filter.trim_space().to_lower()
	primary_urls := collect_page_primary_image_urls(mut sess) or { []string{} }
	mut candidate_urls := []string{}
	for url in primary_urls {
		if needle != '' && !url.to_lower().contains(needle) {
			continue
		}
		if url !in candidate_urls {
			candidate_urls << url
		}
	}
	sess.network_watch_mu.@lock()
	sess.network_watch.active = true
	sess.network_watch.target_dir = target_dir
	sess.network_watch.filter = filter
	sess.network_watch.candidate_urls = map[string]bool{}
	sess.network_watch.saved_request_ids = map[string]bool{}
	sess.network_watch.next_index = 0
	for url in candidate_urls {
		sess.network_watch.candidate_urls[url] = true
	}
	target_count := sess.network_watch.candidate_urls.len
	sess.network_watch_mu.unlock()
	sync_network_watch_existing_requests(mut sess)
	return '{"ok":true,"active":true,"targetDir":${json_str(target_dir)},"filter":${json_str(filter)},"candidateCount":${target_count}}'
}

fn stop_network_watch(mut sess CdpSession) string {
	sess.network_watch_mu.@lock()
	active := sess.network_watch.active
	target_dir := sess.network_watch.target_dir
	filter := sess.network_watch.filter
	candidate_count := sess.network_watch.candidate_urls.len
	saved_count := sess.network_watch.saved_request_ids.len
	sess.network_watch.active = false
	sess.network_watch.target_dir = ''
	sess.network_watch.filter = ''
	sess.network_watch.candidate_urls = map[string]bool{}
	sess.network_watch.saved_request_ids = map[string]bool{}
	sess.network_watch.next_index = 0
	sess.network_watch_mu.unlock()
	return '{"ok":true,"active":${active},"targetDir":${json_str(target_dir)},"filter":${json_str(filter)},"candidateCount":${candidate_count},"savedCount":${saved_count}}'
}

fn network_watch_status_json(mut sess CdpSession) string {
	sess.network_watch_mu.@lock()
	defer { sess.network_watch_mu.unlock() }
	return '{"active":${sess.network_watch.active},"targetDir":${json_str(sess.network_watch.target_dir)},"filter":${json_str(sess.network_watch.filter)},"candidateCount":${sess.network_watch.candidate_urls.len},"savedCount":${sess.network_watch.saved_request_ids.len},"nextIndex":${sess.network_watch.next_index}}'
}

fn sync_network_watch_existing_requests(mut sess CdpSession) {
	sess.network_watch_mu.@lock()
	if !sess.network_watch.active {
		sess.network_watch_mu.unlock()
		return
	}
	mut request_ids := []string{}
	mut paths := []string{}
	for request_id in sess.network_request_order {
		entry := sess.network_requests[request_id] or { continue }
		if !entry.finished {
			continue
		}
		if entry.url !in sess.network_watch.candidate_urls {
			continue
		}
		if request_id in sess.network_watch.saved_request_ids {
			continue
		}
		sess.network_watch.next_index++
		seq := sess.network_watch.next_index
		paths << os.join_path(sess.network_watch.target_dir, network_image_output_name(seq,
			entry))
		sess.network_watch.saved_request_ids[request_id] = true
		request_ids << request_id
	}
	sess.network_watch_mu.unlock()
	for i, request_id in request_ids {
		path := paths[i]
		spawn fn [mut sess, request_id, path] () {
			if err := save_network_response_with_retry(mut sess, request_id, path, 3,
				150 * time.millisecond)
			{
				eprintln('[network watch] sync save failed for ${request_id}: ${err}')
			}
		}()
	}
}

fn handle_network_watch_loading_finished(mut sess CdpSession, request_id string) {
	sess.network_watch_mu.@lock()
	if !sess.network_watch.active {
		sess.network_watch_mu.unlock()
		return
	}
	entry := sess.network_requests[request_id] or {
		sess.network_watch_mu.unlock()
		return
	}
	if entry.url !in sess.network_watch.candidate_urls {
		sess.network_watch_mu.unlock()
		return
	}
	if request_id in sess.network_watch.saved_request_ids {
		sess.network_watch_mu.unlock()
		return
	}
	sess.network_watch.next_index++
	seq := sess.network_watch.next_index
	target_dir := sess.network_watch.target_dir
	sess.network_watch.saved_request_ids[request_id] = true
	sess.network_watch_mu.unlock()
	output_name := network_image_output_name(seq, entry)
	path := os.join_path(target_dir, output_name)
	if err := save_network_response_with_retry(mut sess, request_id, path, 3, 150 * time.millisecond) {
		eprintln('[network watch] save failed for ${request_id}: ${err}')
	}
}

fn save_network_response_with_retry(mut sess CdpSession, request_id string, target_path string, attempts int, delay time.Duration) !string {
	mut last_err := ''
	for attempt in 0 .. attempts {
		out_path, _ := save_network_response(mut sess, request_id, target_path) or {
			last_err = err.msg()
			if attempt + 1 < attempts {
				time.sleep(delay)
				continue
			}
			return error(last_err)
		}
		return out_path
	}
	return error(if last_err != '' { last_err } else { 'save failed' })
}

fn collect_page_primary_image_urls(mut sess CdpSession) ![]string {
	js := build_page_primary_image_urls_js(&sess)
	raw := eval_scoped_expression(mut sess, js, true)!
	if raw == '' || raw == 'null' || raw == '[]' {
		return []string{}
	}
	mut urls := []string{}
	trimmed := raw.trim_space()
	if trimmed.starts_with('[') && trimmed.ends_with(']') {
		for item in trimmed[1..trimmed.len - 1].split(',') {
			url := decode_json_string_literal(item.trim_space())
			if url != '' && url !in urls {
				urls << url
			}
		}
	}
	return urls
}

fn build_page_primary_image_urls_js(sess &CdpSession) string {
	return build_document_scope_js(sess, '
		function normalizeUrl(src) {
			try { return new URL(src, doc.baseURI).href; } catch (e) { return ""; }
		}
		function isVisible(el) {
			if (!el) return false;
			var r = el.getBoundingClientRect();
			var style = win.getComputedStyle(el);
			return r.width > 0 && r.height > 0 && style.visibility !== "hidden" && style.display !== "none";
		}
		function imageArea(img) {
			var r = img.getBoundingClientRect();
			return r.width * r.height;
		}
		var containers = Array.from(doc.querySelectorAll("article, figure, main, [role=article], [data-testid=tweet]"));
		if (!containers.length) containers = [doc.body];
		var best = null;
		for (var i = 0; i < containers.length; i++) {
			var root = containers[i];
			var images = Array.from(root.querySelectorAll("img")).filter(isVisible);
			var mediaImages = images.filter(function(img) { return imageArea(img) >= 40000; });
			if (!mediaImages.length) continue;
			var area = mediaImages.reduce(function(sum, img) { return sum + imageArea(img); }, 0);
			var textLen = String(root.innerText || "").trim().length;
			var score = area + Math.min(textLen, 4000);
			if (!best || score > best.score) {
				best = { score: score, mediaImages: mediaImages };
			}
		}
		if (!best) return "[]";
		var urls = [];
		var seen = {};
		best.mediaImages.forEach(function(img) {
			var src = normalizeUrl(img.currentSrc || img.src || "");
			if (!src || seen[src]) return;
			seen[src] = true;
			urls.push(src);
		});
		return JSON.stringify(urls);
	')
}

fn network_image_output_name(index int, entry TrackedNetworkRequest) string {
	mut base := network_url_filename(entry.url)
	if base == '' {
		base = entry.request_id
	}
	mime_type := network_response_mime_type(entry)
	if file_extension(base) == '' {
		base += network_file_extension(mime_type, entry.url)
	}
	return '${index:02d}-${base}'
}

fn resolve_network_save_path(target_path string, request_id string, url string, mime_type string) string {
	mut base_path := target_path.trim_space()
	if base_path == '' {
		base_path = os.join_path(os.temp_dir(), network_default_filename(request_id, url,
			mime_type))
		return base_path
	}
	if base_path.ends_with('/') || base_path.ends_with('\\') {
		return os.join_path(base_path, network_default_filename(request_id, url, mime_type))
	}
	if os.exists(base_path) && os.is_dir(base_path) {
		return os.join_path(base_path, network_default_filename(request_id, url, mime_type))
	}
	if file_extension(base_path) == '' {
		return base_path + network_file_extension(mime_type, url)
	}
	return base_path
}

fn network_default_filename(request_id string, url string, mime_type string) string {
	mut name := network_url_filename(url)
	if name == '' {
		name = request_id
	}
	if file_extension(name) == '' {
		name += network_file_extension(mime_type, url)
	}
	return name
}

fn file_extension(path string) string {
	mut name := path
	if idx := name.last_index('/') {
		name = name[idx + 1..]
	}
	if idx := name.last_index('\\') {
		name = name[idx + 1..]
	}
	if idx := name.last_index('.') {
		if idx > 0 && idx < name.len - 1 {
			return name[idx..]
		}
	}
	return ''
}

fn network_url_filename(url string) string {
	mut cleaned := url
	if idx := cleaned.index('?') {
		cleaned = cleaned[..idx]
	}
	if idx := cleaned.index('#') {
		cleaned = cleaned[..idx]
	}
	if idx := cleaned.last_index('/') {
		return cleaned[idx + 1..]
	}
	return ''
}

fn network_file_extension(mime_type string, url string) string {
	if mime_type != '' {
		match mime_type.to_lower() {
			'image/jpeg', 'image/jpg' { return '.jpg' }
			'image/gif' { return '.gif' }
			'image/webp' { return '.webp' }
			'image/bmp' { return '.bmp' }
			'image/png' { return '.png' }
			'text/html' { return '.html' }
			'application/json' { return '.json' }
			'video/mp4' { return '.mp4' }
			else {}
		}
	}
	if query_image_format_extension(url) != '' {
		return query_image_format_extension(url)
	}
	if url.to_lower().contains('.jpg') || url.to_lower().contains('.jpeg') {
		return '.jpg'
	}
	if url.to_lower().contains('.gif') {
		return '.gif'
	}
	if url.to_lower().contains('.webp') {
		return '.webp'
	}
	if url.to_lower().contains('.bmp') {
		return '.bmp'
	}
	return '.bin'
}

fn query_image_format_extension(url string) string {
	mut query := url
	if idx := query.index('?') {
		query = query[idx + 1..]
	} else {
		return ''
	}
	for pair in query.split('&') {
		if pair.starts_with('format=') {
			format := pair[7..].to_lower()
			return match format {
				'jpg', 'jpeg' { '.jpg' }
				'png' { '.png' }
				'gif' { '.gif' }
				'webp' { '.webp' }
				'bmp' { '.bmp' }
				else { '' }
			}
		}
	}
	return ''
}

fn network_response_mime_type(entry TrackedNetworkRequest) string {
	mut mime_type := cdp_extract_str(entry.response_headers, 'content-type')
	if mime_type == '' {
		mime_type = cdp_extract_str(entry.response_headers, 'Content-Type')
	}
	if mime_type == '' {
		if entry.url.to_lower().contains('.jpg') || entry.url.to_lower().contains('.jpeg') {
			return 'image/jpeg'
		}
		if entry.url.to_lower().contains('.gif') {
			return 'image/gif'
		}
		if entry.url.to_lower().contains('.webp') {
			return 'image/webp'
		}
		if entry.url.to_lower().contains('.png') {
			return 'image/png'
		}
		return 'application/octet-stream'
	}
	if idx := mime_type.index(';') {
		return mime_type[..idx].trim_space()
	}
	return mime_type.trim_space()
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
		'wait' {
			// Wait for a dialog to appear (up to timeout ms, default 5000).
			timeout_ms := cdp_extract_int(params, '"timeout":')
			mut timeout := if timeout_ms > 0 { time.millisecond * time.Duration(timeout_ms) } else { 5 * time.second }
			sess.enable_page_events() or { return 'ERROR:${err}' }
			deadline := time.now().add(timeout)
			for time.now() < deadline {
				for ev in sess.dialog_events {
					if ev.contains('javascriptDialogOpening') {
						return 'true'
					}
				}
				time.sleep(50 * time.millisecond)
			}
			return 'false'
		}
		else {
			return 'ERROR:unknown dialog action: ${action}'
		}
	}
	return 'null'
}

fn handle_dialog_with_retry(mut sess CdpSession, params string) ! {
	mut last_err := ''
	// First, poll for a dialog-opening event (up to 3 s).  When the trigger
	// click is dispatched via CDP Input.dispatchMouseEvent the CDP message
	// returns immediately, so the browser receives the click and shows the
	// dialog in its own event loop — we just need to wait for the
	// Page.javascriptDialogOpening event to arrive before we call
	// Page.handleJavaScriptDialog, otherwise it fails with "No dialog is showing".
	mut event_deadline := time.now().add(3 * time.second)
	for time.now() < event_deadline {
		if sess.dialog_events.len > 0 {
			for ev in sess.dialog_events {
				if ev.contains('javascriptDialogOpening') {
					event_deadline = time.now() // dialog is open, stop waiting
					break
				}
			}
		}
		time.sleep(50 * time.millisecond)
	}
	for i := 0; i < 30; i++ {
		sess.send_command('Page.handleJavaScriptDialog', params) or {
			last_err = err.msg()
			if last_err.contains('No dialog is showing') {
				time.sleep(200 * time.millisecond)
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

// ─── clipboard ─────────────────────────────────────────────
// clipboard read image  — read image from system clipboard and save to a temp file
// clipboard write image <path> — write a local image file to the system clipboard
fn cmd_clipboard(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	kind := cdp_extract_str(params, 'kind')
	clipboard_kind := if kind != '' { kind } else { 'image' }
	match action {
		'read', 'r' {
			if clipboard_kind != 'image' {
				return 'ERROR:clipboard read only supports image'
			}
			ensure_clipboard_permissions(mut sess)
			raw := eval_scoped_expression(mut sess, build_clipboard_read_image_js(), true) or {
				return 'ERROR:${err}'
			}
			if raw == '' {
				return 'ERROR:no image found in clipboard'
			}
			parts := raw.split('\t')
			if parts.len != 2 {
				return 'ERROR:unexpected clipboard image payload'
			}
			mime_type := parts[0].trim_space()
			data := parts[1].trim_space()
			if mime_type == '' || data == '' {
				return 'ERROR:no image found in clipboard'
			}
			raw_bytes := base64.decode(data)
			ext := clipboard_image_extension(mime_type)
			out_path := os.join_path(os.temp_dir(), 'v-browser-clipboard-${time.now().unix_milli()}.${ext}')
			os.write_file_array(out_path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
			return '{"ok":true,"path":${json_str(out_path)},"mimeType":${json_str(mime_type)}}'
		}
		'write', 'w' {
			if clipboard_kind != 'image' {
				return 'ERROR:clipboard write only supports image'
			}
			path := cdp_extract_str(params, 'path')
			if path == '' {
				return 'ERROR:clipboard write requires --path'
			}
			img_bytes := os.read_bytes(path) or { return 'ERROR:failed to read ${path}: ${err}' }
			mime_type := image_mime_type(path)
			js := build_clipboard_write_image_js(mime_type, base64.encode(img_bytes))
			ensure_clipboard_permissions(mut sess)
			val := eval_scoped_expression(mut sess, js, true) or { return 'ERROR:${err}' }
			if val == '' || val == 'undefined' || val == 'ok' {
				return '{"ok":true,"mimeType":${json_str(mime_type)}}'
			}
			return '{"ok":true,"mimeType":${json_str(mime_type)}}'
		}
		else {
			return 'ERROR:clipboard action must be "read" or "write"'
		}
	}
}

fn image_mime_type(path string) string {
	lowered := path.to_lower()
	if lowered.ends_with('.png') {
		return 'image/png'
	}
	if lowered.ends_with('.jpg') || lowered.ends_with('.jpeg') {
		return 'image/jpeg'
	}
	if lowered.ends_with('.gif') {
		return 'image/gif'
	}
	if lowered.ends_with('.webp') {
		return 'image/webp'
	}
	if lowered.ends_with('.bmp') {
		return 'image/bmp'
	}
	return 'image/png'
}

fn clipboard_image_extension(mime_type string) string {
	match mime_type.to_lower() {
		'image/jpeg', 'image/jpg' { return 'jpg' }
		'image/gif' { return 'gif' }
		'image/webp' { return 'webp' }
		'image/bmp' { return 'bmp' }
		else { return 'png' }
	}
}

fn build_clipboard_read_image_js() string {
	return '(async function(){ const items = await navigator.clipboard.read(); for (const item of items) { for (const type of item.types) { if (type.startsWith("image/")) { const blob = await item.getType(type); const bytes = new Uint8Array(await blob.arrayBuffer()); let binary = ""; for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); } return type + "\t" + btoa(binary); } } } return ""; })()'
}

fn build_clipboard_write_image_js(mime_type string, img_b64 string) string {
	mime_js := js_str(mime_type)
	data_js := js_str(img_b64)
	return '(async function(){ const binary = atob(${data_js}); const bytes = Uint8Array.from(binary, function(ch){ return ch.charCodeAt(0); }); const blob = new Blob([bytes], { type: ${mime_js} }); await navigator.clipboard.write([new ClipboardItem({ ${mime_js}: blob })]); return "ok"; })()'
}

fn ensure_clipboard_permissions(mut sess CdpSession) {
	sess.send_command('Browser.setPermission', '{"permission":{"name":"clipboardReadWrite"},"setting":"granted"}') or {}
	sess.send_command('Browser.setPermission', '{"permission":{"name":"clipboardSanitizedWrite"},"setting":"granted"}') or {}
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
