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

// dispatch_command 命令路由
fn dispatch_command(mut sess CdpSession, method string, params string) string {
	return match method {
		'eval'           { cmd_eval(mut sess, params) }
		'open', 'goto', 'navigate' { cmd_open(mut sess, params) }
		'close', 'quit', 'exit' { cmd_close(mut sess) }
		'screenshot'     { cmd_screenshot(mut sess, params) }
		'snapshot'       { cmd_snapshot(mut sess, params) }
		'pdf'            { cmd_pdf(mut sess, params) }
		'click'          { cmd_click(mut sess, params) }
		'dblclick'       { cmd_dblclick(mut sess, params) }
		'fill'           { cmd_fill(mut sess, params) }
		'type'           { cmd_type_text(mut sess, params) }
		'press', 'key'   { cmd_press(mut sess, params) }
		'keydown'        { cmd_keydown(mut sess, params) }
		'keyup'          { cmd_keyup(mut sess, params) }
		'hover'          { cmd_hover(mut sess, params) }
		'focus'          { cmd_focus(mut sess, params) }
		'select'         { cmd_select(mut sess, params) }
		'check'          { cmd_check(mut sess, params) }
		'uncheck'        { cmd_uncheck(mut sess, params) }
		'scroll'         { cmd_scroll(mut sess, params) }
		'scrollintoview', 'scrollinto' { cmd_scrollintoview(mut sess, params) }
		'drag'           { cmd_drag(mut sess, params) }
		'upload'         { cmd_upload(mut sess, params) }
		'get'            { cmd_get(mut sess, params) }
		'is'             { cmd_is(mut sess, params) }
		'wait'           { cmd_wait(mut sess, params) }
		'find'           { cmd_find(mut sess, params) }
		'tab'            { cmd_tab(mut sess, params) }
		'window'         { cmd_window(mut sess, params) }
		'keyboard'       { cmd_keyboard(mut sess, params) }
		'mouse'          { cmd_mouse(mut sess, params) }
		'cookies'        { cmd_cookies(mut sess, params) }
		'storage'        { cmd_storage(mut sess, params) }
		'network'        { cmd_network(mut sess, params) }
		'frame'          { cmd_frame(mut sess, params) }
		'dialog'         { cmd_dialog(mut sess, params) }
		'highlight'      { cmd_highlight(mut sess, params) }
		'console'        { cmd_console(mut sess, params) }
		'errors'         { cmd_errors(mut sess, params) }
		'trace'          { cmd_trace(mut sess, params) }
		'profiler'       { cmd_profiler(mut sess, params) }
		'set'            { cmd_set(mut sess, params) }
		'diff'           { cmd_diff(mut sess, params) }
		'state'          { cmd_state(mut sess, params) }
		else             { 'ERROR:unknown command: ${method}' }
	}
}

fn cmd_not_impl(name string) string {
	return 'ERROR:command ${name} not yet implemented'
}

// ─── eval ───────────────────────────────────────────────────
fn cmd_eval(mut sess CdpSession, params string) string {
	expr := cdp_extract_str(params, 'expression')
	if expr == '' { return 'ERROR:missing expression' }
	await_promise := cdp_extract_str(params, 'awaitPromise') == 'true'
	as_b64 := cdp_extract_str(params, 'base64') == 'true'
	actual_expr := if as_b64 {
		decoded := base64.decode_str(expr)
		decoded
	} else { expr }
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
	scoped_expr := build_scoped_runtime_js(&sess, 'return window.eval(${js_str(expr)});')
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
	expr := '(function(){ var el=document.querySelector(${js_str(sel)}); if(el === null) return false; ${body} })()'
	ok := eval_scoped_expression(mut sess, expr, false)! == 'true'
	if !ok {
		return error('element not found: ${sel}')
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
		'string'    { return cdp_extract_str(result_obj, 'value') }
		'number'    { return cdp_extract_obj_key(result_obj, '"value":') }
		'boolean'   { return cdp_extract_obj_key(result_obj, '"value":') }
		'undefined' { return 'undefined' }
		'object'    {
			sub_type := cdp_extract_str(result_obj, 'subtype')
			if sub_type == 'null' { return 'null' }
			v := cdp_extract_obj_key(result_obj, '"value":')
			return if v != '' { v } else { result_obj }
		}
		else { return result_obj }
	}
}

// ─── open / navigate ────────────────────────────────────────
fn cmd_open(mut sess CdpSession, params string) string {
	url := cdp_extract_str(params, 'url')
	if url == '' { return 'ERROR:missing url' }
	// 订阅 loadEventFired
	load_ch := sess.subscribe('Page.loadEventFired')
	defer { sess.unsubscribe('Page.loadEventFired', load_ch) }

	sess.send_command('Page.navigate', '{"url":${json_str(url)}}') or {
		return 'ERROR:${err}'
	}
	// 等待页面加载完成（最多 30s）
	select {
		_ := <-load_ch { }
		30 * time.second { }
	}
	return json_str('navigated to ${url}')
}

// ─── close ──────────────────────────────────────────────────
fn cmd_close(mut sess CdpSession) string {
	sess.send_command('Target.closeTarget', '{}') or { }
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
	if quality > 0 { p += ',"quality":${quality}' }
	p += '}'

	resp := sess.send_command('Page.captureScreenshot', p) or { return 'ERROR:${err}' }
	data := cdp_extract_str(resp.result, 'data')
	if data == '' { return 'ERROR:no screenshot data returned' }

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

// ─── pdf ────────────────────────────────────────────────────
fn cmd_pdf(mut sess CdpSession, params string) string {
	path := cdp_extract_str(params, 'path')
	if path == '' { return 'ERROR:missing path' }
	resp := sess.send_command('Page.printToPDF', '{"printBackground":true}') or { return 'ERROR:${err}' }
	data := cdp_extract_str(resp.result, 'data')
	if data == '' { return 'ERROR:no pdf data' }
	raw_bytes := base64.decode(data)
	os.write_file_array(path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
	return json_str(path)
}

// ─── snapshot ───────────────────────────────────────────────
fn cmd_snapshot(mut sess CdpSession, params string) string {
	resp := sess.send_command('Accessibility.getFullAXTree', '{}') or { return 'ERROR:${err}' }
	nodes_json := cdp_extract_obj_key(resp.result, '"nodes":')
	if nodes_json == '' { return 'ERROR:no AX tree returned' }

	axref_clear(mut sess.axref)
	mut out := '= Accessibility Snapshot =\n'
	out += render_ax_tree(nodes_json, 1, mut sess.axref)
	return json_str(out)
}

fn render_ax_tree(nodes_json string, start_counter int, mut store AxRefStore) string {
	mut out := ''
	mut counter := start_counter
	mut pos := 1 // skip opening '['
	mut i := 0
	for pos < nodes_json.len - 1 {
		if nodes_json[pos] == `{` {
			node_str := cdp_balanced(nodes_json[pos..])
			role := ax_prop(node_str, 'role')
			name := ax_prop(node_str, 'name')
			bnid := cdp_extract_int(node_str, '"backendDOMNodeId":')
			if (role != '' && role != 'none' && role != 'generic') || name != '' {
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
		if i > 10000 { break } // 安全上限
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
	if sel == '' { return 'ERROR:missing selector' }
	if el := resolve_selector(mut sess, sel) {
		mouse_click(mut sess, el.x, el.y) or { return 'ERROR:${err}' }
		return 'null'
	}
	run_element_action(mut sess, sel, build_click_action_body()) or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_dblclick(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' { return 'ERROR:missing selector' }
	run_element_action(mut sess, sel, build_dblclick_action_body()) or { return 'ERROR:${err}' }
	return 'null'
}

fn mouse_click(mut sess CdpSession, x f64, y f64) ! {
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseMoved","x":${x},"y":${y},"button":"none","buttons":0}')!
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mousePressed","x":${x},"y":${y},"button":"left","buttons":1,"clickCount":1}')!
	time.sleep(20 * time.millisecond)
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${x},"y":${y},"button":"left","buttons":0,"clickCount":1}')!
}

// ─── hover ──────────────────────────────────────────────────
fn cmd_hover(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' { return 'ERROR:missing selector' }
	run_element_action(mut sess, sel, build_hover_action_body()) or { return 'ERROR:${err}' }
	return 'null'
}

// ─── focus ──────────────────────────────────────────────────
fn cmd_focus(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' { return 'ERROR:missing selector' }
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
	if sel == '' { return 'ERROR:missing selector' }
	run_element_action(mut sess, sel, build_fill_action_body(text)) or { return 'ERROR:${err}' }
	return 'null'
}

// ─── type ───────────────────────────────────────────────────
fn cmd_type_text(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' { return 'ERROR:missing selector' }
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
		else { 'ERROR:unknown keyboard action: ${action}' }
	}
}

// ─── press / keydown / keyup ─────────────────────────────────
fn cmd_press(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' { return 'ERROR:missing key' }
	dispatch_key(mut sess, key, 'keyDown') or { return 'ERROR:${err}' }
	dispatch_key(mut sess, key, 'keyUp') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keydown(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' { return 'ERROR:missing key' }
	dispatch_key(mut sess, key, 'keyDown') or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_keyup(mut sess CdpSession, params string) string {
	key := cdp_extract_str(params, 'key')
	if key == '' { return 'ERROR:missing key' }
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
				'alt'     { 1 }
				'control', 'ctrl' { 4 }
				'meta', 'command' { 8 }
				'shift'   { 2 }
				else      { 0 }
			}
		}
	}
	sess.send_command('Input.dispatchKeyEvent', '{"type":"${typ}","key":"${actual_key}","modifiers":${modifiers}}')!
}

// ─── select ─────────────────────────────────────────────────
fn cmd_select(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	value := cdp_extract_str(params, 'value')
	if sel == '' { return 'ERROR:missing selector' }
	js := build_element_scope_js(&sess, sel, 'if(!el) return false; el.value=${js_str(value)}; el.dispatchEvent(new Event("change",{bubbles:true})); return true;')
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// ─── check / uncheck ────────────────────────────────────────
fn cmd_check(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' { return 'ERROR:missing selector' }
	run_element_action(mut sess, sel, build_toggle_action_body(true)) or { return 'ERROR:${err}' }
	return 'null'
}

fn cmd_uncheck(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' { return 'ERROR:missing selector' }
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
		'up'    { dy = -px }
		'down'  { dy = px }
		'left'  { dx = -px }
		'right' { dx = px }
		else    { return 'ERROR:unknown direction: ${direction}' }
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
	if sel == '' { return 'ERROR:missing selector' }
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
	if src == '' || tgt == '' { return 'ERROR:missing source or target' }
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
	if sel == '' { return 'ERROR:missing selector' }
	files := files_str.split(',').map(it.trim_space()).filter(it != '')
	if files.len == 0 { return 'ERROR:no files specified' }
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
		'text'   { build_element_scope_js(&sess, sel, 'return el?.textContent;') }
		'html'   { build_element_scope_js(&sess, sel, 'return el?.innerHTML;') }
		'value'  { build_element_scope_js(&sess, sel, 'return el?.value;') }
		'title'  { 'document.title' }
		'url'    { 'window.location.href' }
		'count'  { build_elements_scope_js(&sess, sel, 'return els.length;') }
		'attr'   {
			attr := cdp_extract_str(params, 'attr')
			build_element_scope_js(&sess, sel, 'return el?.getAttribute(${js_str(attr)});')
		}
		'box' {
			build_rect_query_js(&sess, sel)
		}
		'styles' {
			build_element_scope_js(&sess, sel, 'return el?JSON.stringify(Object.fromEntries(Object.entries(getComputedStyle(el)))):null;')
		}
		else { return 'ERROR:unknown property: ${prop}' }
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
	if sel == '' { return 'ERROR:missing selector' }

	js := match state {
		'visible' { build_element_scope_js(&sess, sel, "if(!el) return false; var r=el.getBoundingClientRect(); return r.width>0&&r.height>0&&getComputedStyle(el).visibility!=='hidden'&&getComputedStyle(el).display!=='none';") }
		'enabled' { build_element_scope_js(&sess, sel, 'return !el?.disabled;') }
		'checked' { build_element_scope_js(&sess, sel, 'return !!el?.checked;') }
		else      { return 'ERROR:unknown state: ${state}' }
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
		'load'             { 'Page.loadEventFired' }
		'domcontentloaded' { 'Page.domContentEventFired' }
		'networkidle' {
			// 监听 Page.lifecycleEvent name=networkIdle
			ch := sess.subscribe('Page.lifecycleEvent')
			defer { sess.unsubscribe('Page.lifecycleEvent', ch) }
			for {
				select {
					evt := <-ch {
						name := cdp_extract_str(evt.params, 'name')
						if name == 'networkIdle' { break }
					}
					30 * time.second { return 'ERROR:timeout waiting for networkidle' }
				}
			}
			return 'null'
		}
		else { return 'ERROR:unknown load state: ${state}' }
	}
	ch := sess.subscribe(event)
	defer { sess.unsubscribe(event, ch) }
	select {
		_ := <-ch { }
		30 * time.second { return 'ERROR:timeout waiting for ${state}' }
	}
	return 'null'
}

fn wait_url(mut sess CdpSession, pattern string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		resp := sess.send_command('Runtime.evaluate', '{"expression":"window.location.href","returnByValue":true}') or { break }
		result := cdp_extract_obj_key(resp.result, '"result":')
		url := cdp_extract_value_from_result(result)
		if glob_match(pattern, url) { return 'null' }
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for url ${pattern}'
}

fn wait_text(mut sess CdpSession, text string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		js := build_document_scope_js(&sess, 'return doc.body?.innerText;')
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or { break }
		result := cdp_extract_obj_key(resp.result, '"result":')
		body := cdp_extract_value_from_result(result)
		if body.contains(text) { return 'null' }
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for text "${text}"'
}

fn wait_fn(mut sess CdpSession, expr string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(expr)},"returnByValue":true}') or { break }
		result := cdp_extract_obj_key(resp.result, '"result":')
		val := cdp_extract_value_from_result(result)
		if val == 'true' { return 'null' }
		time.sleep(200 * time.millisecond)
	}
	return 'ERROR:timeout waiting for fn condition'
}

fn wait_selector(mut sess CdpSession, sel string) string {
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		js := build_element_scope_js(&sess, sel, 'if(!el) return false; var r=el.getBoundingClientRect(); return r.width>0&&r.height>0;')
		resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or { break }
		result := cdp_extract_obj_key(resp.result, '"result":')
		if cdp_extract_value_from_result(result) == 'true' { return 'null' }
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
	index := cdp_extract_str(params, 'index').int()

	if locator == '' {
		return 'ERROR:missing locator'
	}
	if query == '' && locator !in ['first', 'last'] {
		return 'ERROR:missing semantic query'
	}
	js := build_semantic_locator_js(&sess, locator, query, exact, name_filter, index)
	return exec_semantic_action(mut sess, js, locator, action, value)
}

fn build_semantic_locator_js(sess &CdpSession, locator string, query string, exact bool, name_filter string, index int) string {
	query_js := js_str(query)
	name_js := js_str(name_filter)
	index_js := if index > 0 { '${index}' } else { '0' }
	exact_js := if exact { 'true' } else { 'false' }
	locator_body := match locator {
		'role' {
			'var all=Array.from(doc.querySelectorAll("*")); elements=all.filter(el=>roleOf(el)===${query_js}&&matchesName(el, ${name_js}, ${exact_js}));'
		}
		'text' {
			'var all=Array.from(doc.querySelectorAll("*")); elements=all.filter(el=>matchesText(el.innerText||el.textContent||"", ${query_js}, ${exact_js}));'
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
		'last' { 'return elements.length ? elements[elements.length - 1] : null;' }
		'nth'  { 'return elements.length > ${index_js} ? elements[${index_js}] : null;' }
		else   { 'return elements.length ? elements[0] : null;' }
	}
	return build_document_scope_js(sess, '
		function normalizeText(value) { return String(value || "").replace(/\\s+/g, " ").trim(); }
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
	js := build_semantic_action_js(&sess, locator_js,
		'if (!el) return false; el.scrollIntoView({block:"center",inline:"center"}); ${body}')
	ok := evaluate_bool_js(mut sess, js) or { return 'ERROR:${err}' }
	if !ok { return 'ERROR:element not found: ${locator}' }
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
			run_element_action(mut sess, sel, build_click_action_body()) or { return 'ERROR:${err}' }
			return 'null'
		}
		'fill' {
			run_element_action(mut sess, sel, build_fill_action_body(value)) or { return 'ERROR:${err}' }
			return 'null'
		}
		'type' {
			run_element_action(mut sess, sel, build_type_action_body(value)) or { return 'ERROR:${err}' }
			return 'null'
		}
		'hover' {
			run_element_action(mut sess, sel, build_hover_action_body()) or { return 'ERROR:${err}' }
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
			run_element_action(mut sess, sel, build_toggle_action_body(true)) or { return 'ERROR:${err}' }
			return 'null'
		}
		'uncheck' {
			run_element_action(mut sess, sel, build_toggle_action_body(false)) or { return 'ERROR:${err}' }
			return 'null'
		}
		else { return 'ERROR:unknown action: ${action}' }
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
			resp := sess.send_bridge_command('createTab', '{"url":${json_str(if url != '' { url } else { 'about:blank' })}}') or {
				return 'ERROR:${err}'
			}
			axref_clear(mut sess.axref)
			sess.current_frame_selector = ''
			sess.enable_network_tracking() or {}
			return resp.result
		}
		'switch' {
			tab_id := cdp_extract_int(params, '"tabId":')
			window_id := cdp_extract_int(params, '"windowId":')
			if tab_id == 0 { return 'ERROR:missing tabId' }
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
			if tab_id == 0 { return 'ERROR:missing tabId' }
			resp := sess.send_bridge_command('closeTab', '{"tabId":${tab_id}}') or {
				return 'ERROR:${err}'
			}
			return resp.result
		}
		else { return 'ERROR:unknown tab action: ${action}' }
	}
}

fn cmd_window(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'new' {
			url := cdp_extract_str(params, 'url')
			resp := sess.send_bridge_command('createWindow', '{"url":${json_str(if url != '' { url } else { 'about:blank' })}}') or {
				return 'ERROR:${err}'
			}
			axref_clear(mut sess.axref)
			sess.current_frame_selector = ''
			sess.enable_network_tracking() or {}
			return resp.result
		}
		else { return 'ERROR:unknown window action: ${action}' }
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
		else { return 'ERROR:unknown mouse action: ${action}' }
	}
	return 'null'
}

// ─── cookies ────────────────────────────────────────────────
fn cmd_cookies(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'', 'get' {
			resp := sess.send_command('Network.getCookies', '{}') or { return 'ERROR:${err}' }
			return cdp_extract_obj_key(resp.result, '"cookies":')
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
		else { return 'ERROR:unknown cookies action: ${action}' }
	}
}

// ─── storage ────────────────────────────────────────────────
fn cmd_storage(mut sess CdpSession, params string) string {
	storage_type := cdp_extract_str(params, 'type') // 'local' or 'session'
	action := cdp_extract_str(params, 'action')     // 'get', 'set', 'clear'
	key := cdp_extract_str(params, 'key')
	value := cdp_extract_str(params, 'value')

	store := if storage_type == 'session' { 'sessionStorage' } else { 'localStorage' }

	js := match action {
		'', 'get' {
			if key != '' {
				"${store}.getItem(${js_str(key)})"
			} else {
				"JSON.stringify(Object.fromEntries(Object.keys(${store}).map(k=>[k,${store}.getItem(k)])))"
			}
		}
		'set' {
			"${store}.setItem(${js_str(key)},${js_str(value)})"
		}
		'clear' {
			"${store}.clear()"
		}
		else { return 'ERROR:unknown storage action: ${action}' }
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
							if request_id == '' { break }
							if abort {
								sess.send_command('Fetch.failRequest', '{"requestId":${json_str(request_id)},"errorReason":"Aborted"}') or {}
							} else if body != '' {
								sess.send_command('Fetch.fulfillRequest', '{"requestId":${json_str(request_id)},"responseCode":200,"body":${json_str(base64.encode_str(body))}}') or {}
							} else {
								sess.send_command('Fetch.continueRequest', '{"requestId":${json_str(request_id)}}') or {}
							}
						}
						else { break }
					}
				}
			}()
			return 'null'
		}
		'unroute' {
			sess.send_command('Fetch.disable', '{}') or { return 'ERROR:${err}' }
			return 'null'
		}
		else { return 'ERROR:unknown network action: ${action}' }
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
			handle_dialog_with_retry(mut sess,
				'{"accept":true,"promptText":${json_str(text)}}') or {
				return 'ERROR:${err}'
			}
		}
		'dismiss' {
			sess.enable_page_events() or { return 'ERROR:${err}' }
			handle_dialog_with_retry(mut sess, '{"accept":false}') or {
				return 'ERROR:${err}'
			}
		}
		else { return 'ERROR:unknown dialog action: ${action}' }
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
	if sel == '' { return 'ERROR:missing selector' }
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
	if sess.console_msgs.len == 0 { return '[]' }
	out := '[' + sess.console_msgs.map(it).join(',') + ']'
	return out
}

fn cmd_errors(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	if action == 'clear' {
		sess.page_errors.clear()
		return 'null'
	}
	if sess.page_errors.len == 0 { return '[]' }
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
			out_path := if path != '' { path } else { os.join_path(os.temp_dir(), 'trace_${time.now().unix_milli()}.json') }
			ch := sess.subscribe('Tracing.tracingComplete')
			defer { sess.unsubscribe('Tracing.tracingComplete', ch) }
			sess.send_command('Tracing.end', '{}') or { return 'ERROR:${err}' }
			select {
				evt := <-ch {
					stream := cdp_extract_str(evt.params, 'stream')
					if stream == '' { return 'ERROR:trace stream missing' }
					content := read_protocol_stream(mut sess, stream) or { return 'ERROR:${err}' }
					os.write_file(out_path, content) or { return 'ERROR:write failed: ${err}' }
				}
				30 * time.second {
					return 'ERROR:timeout waiting for trace data'
				}
			}
			return json_str(out_path)
		}
		else { return 'ERROR:unknown trace action: ${action}' }
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
			out_path := if path != '' { path } else { os.join_path(os.temp_dir(), 'profile_${time.now().unix_milli()}.json') }
			profile := cdp_extract_obj_key(resp.result, '"profile":')
			os.write_file(out_path, profile) or { return 'ERROR:write failed: ${err}' }
			return json_str(out_path)
		}
		else { return 'ERROR:unknown profiler action: ${action}' }
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
				name: 'custom viewport'
				width: w
				height: h
				scale: scale
				mobile: false
				has_touch: false
				user_agent: ''
			}) or {
				return 'ERROR:${err}'
			}
			return 'null'
		}
		'device' {
			name := cdp_extract_str(params, 'value')
			preset := resolve_device_preset(name) or { return 'ERROR:${err}' }
			apply_device_preset(mut sess, preset) or {
				return 'ERROR:${err}'
			}
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
		else { return 'ERROR:unknown set property: ${prop}' }
	}
}

fn resolve_device_preset(name string) !DevicePreset {
	normalized := name.to_lower().trim_space()
	return match normalized {
		'iphone 14' {
			DevicePreset{ name: 'iPhone 14', width: 390, height: 844, scale: 3.0, mobile: true, has_touch: true, user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1' }
		}
		'iphone 14 pro' {
			DevicePreset{ name: 'iPhone 14 Pro', width: 393, height: 852, scale: 3.0, mobile: true, has_touch: true, user_agent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1' }
		}
		'pixel 7' {
			DevicePreset{ name: 'Pixel 7', width: 412, height: 915, scale: 2.625, mobile: true, has_touch: true, user_agent: 'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36' }
		}
		'ipad mini' {
			DevicePreset{ name: 'iPad mini', width: 768, height: 1024, scale: 2.0, mobile: true, has_touch: true, user_agent: 'Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1' }
		}
		else {
			return error('unknown device preset: ${name}')
		}
	}
}

fn apply_device_preset(mut sess CdpSession, preset DevicePreset) ! {
	sess.send_command('Emulation.setDeviceMetricsOverride', '{"width":${preset.width},"height":${preset.height},"deviceScaleFactor":${preset.scale},"mobile":${preset.mobile}}')!
	sess.send_command('Emulation.setTouchEmulationEnabled', '{"enabled":${preset.has_touch},"maxTouchPoints":${if preset.has_touch { 5 } else { 1 }}}') or {}
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
			current := cmd_snapshot(mut sess, '{}')
			baseline_path := cdp_extract_str(params, 'baseline')
			if baseline_path != '' {
				baseline := os.read_file(baseline_path) or { return 'ERROR:cannot read baseline: ${err}' }
				diff := text_diff(baseline, current.trim('"'))
				return json_str(diff)
			}
			return current
		}
		'screenshot' { return cmd_not_impl('diff screenshot') }
		'url'        { return cmd_not_impl('diff url') }
		else         { return 'ERROR:unknown diff type: ${dtype}' }
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
			if path == '' { return 'ERROR:missing path' }
			// 获取 cookies
			cookie_resp := sess.send_command('Network.getCookies', '{}') or { return 'ERROR:${err}' }
			cookies := cdp_extract_obj_key(cookie_resp.result, '"cookies":')
			// 获取 localStorage
			ls_js := "JSON.stringify(Object.fromEntries(Object.keys(localStorage).map(k=>[k,localStorage.getItem(k)])))"
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
			new := if os.is_abs_path(new_path) { new_path } else { os.join_path(state_dir, new_path) }
			os.mv(old, new) or { return 'ERROR:${err}' }
			return 'null'
		}
		else { return 'ERROR:unknown state action: ${action}' }
	}
}

// ─── 帮助函数 ────────────────────────────────────────────────

// glob_match 简单通配符匹配（支持 * 和 **）
fn glob_match(pattern string, s string) bool {
	if pattern == '*' || pattern == '**' { return true }
	if !pattern.contains('*') { return s == pattern }
	// 简单实现：将 ** 和 * 替换为正则等价处理
	parts := pattern.split('*')
	mut pos := 0
	for i, part in parts {
		if part == '' { continue }
		idx := s.index_after_(part, pos)
		if idx < 0 { return false }
		if i == 0 && idx != 0 { return false } // 开头不匹配
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
	return '"${s.replace("\\", "\\\\").replace('"', '\\"')}"'
}

fn build_storage_restore_script(store_name string, payload_json string) string {
	return "(function(){ try { var data=JSON.parse(${js_str(payload_json)}); ${store_name}.clear(); for (var key in data) { if (Object.prototype.hasOwnProperty.call(data, key)) { ${store_name}.setItem(key, data[key]); } } return true; } catch (e) { return String(e); } })()"
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
