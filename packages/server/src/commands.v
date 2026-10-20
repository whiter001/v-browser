// commands.v — 所有 CLI 命令实现
// dispatch_command 由 server.v 的 IPC dispatch 调用
module main

import os
import time
import encoding.base64
import x.json2 as json_urls
import strings
import sync
import rand

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

// cmd_eval 在页面上下文中执行 JavaScript 表达式
// 支持参数：
//   - expression: 要执行的表达式
//   - awaitPromise: 是否等待 Promise
//   - base64: 是否使用 base64 编码表达式
//   - readError: 返回错误信息（用于测试）
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

// build_scoped_runtime_js 在当前 frame 上下文中包装 JavaScript 代码
// 如果当前有 iframe 选择器，则在 iframe 的 document/window 中执行
fn build_scoped_runtime_js(mut sess CdpSession, body string) string {
	frame_selector := sess.current_frame_selector_value()
	if frame_selector == '' {
		return '(function(document, window){ ${body} })(document, window)'
	}
	frame_sel := js_str(frame_selector)
	return '(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; return (function(document, window){ ${body} })(doc, win); })()'
}

// evaluate_check_exception 检查 Runtime.evaluate 响应里的 exceptionDetails。
// 页面脚本抛异常时 CDP 仍然返回 result（只是带 exceptionDetails），
// 不检查就会把「抛了异常」当成「执行成功但没有返回值」。
// 解析统一走 cdp_exception_detail（与 resolver.v 的调用点共用同一实现），
// 避免两处对 "exceptionDetails":null / {} 的判断不一致。
fn evaluate_check_exception(result string) ! {
	detail := cdp_exception_detail(result)
	// 空详情（字段缺失 / null / {}）表示这次执行没有异常。
	if detail == '' || detail == '{}' {
		return
	}
	// 详情里没有可读文案时用固定提示，不要把原始 JSON 抛给用户。
	message := if detail.starts_with('{') { 'javascript exception' } else { detail }
	return error(message)
}

// evaluate_result_value 统一解析 Runtime.evaluate 的响应：
// 先看异常详情，再取返回值。
fn evaluate_result_value(result string) !string {
	evaluate_check_exception(result)!
	return cdp_extract_value_from_result(cdp_extract_obj_key(result, '"result":'))
}

// evaluate_bool_js 在页面上下文中执行 JavaScript 并返回布尔值结果
// 用于检查元素可见性、可操作性等条件
fn evaluate_bool_js(mut sess CdpSession, js string) !bool {
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	val := evaluate_result_value(resp.result)!
	return val == 'true'
}

// eval_prepared_js 执行「已经完成作用域包装」的 JavaScript。
//
// 这里和 eval_scoped_expression 是两种不同的 API，职责必须分开：
//   - eval_scoped_expression：传入**原始表达式**，由它负责套一层作用域
//     （必要时进入 iframe），整段代码只包装一次；
//   - eval_prepared_js：传入的脚本**自带作用域包装**（例如
//     build_document_scope_js / build_element_scope_js / build_element_action_js
//     的产物），这里绝不能再包装一次。
//
// 旧实现把这两者混用：run_element_action 生成的脚本本身已经进入了 iframe，
// 却又被 eval_scoped_expression 包了一层，于是内层脚本在子文档里再执行一次
// querySelector(frame_selector)——搜的已经不是主文档，选择 iframe 之后的
// click / check / uncheck 等元素动作必然失败。
fn eval_prepared_js(mut sess CdpSession, js string, await_promise bool) !string {
	p := '{"expression":${json_str(js)},"returnByValue":true,"awaitPromise":${await_promise}}'
	resp := sess.send_command('Runtime.evaluate', p)!
	return evaluate_result_value(resp.result)
}

// eval_prepared_js_short 是 eval_prepared_js 的短超时（3 秒）版本，
// 用于可能触发对话框、不能长时间阻塞整个 CDP 会话的操作。
fn eval_prepared_js_short(mut sess CdpSession, js string) !string {
	p := '{"expression":${json_str(js)},"returnByValue":true,"awaitPromise":false}'
	resp := sess.send_command_to('Runtime.evaluate', p, '', 3 * time.second)!
	return evaluate_result_value(resp.result)
}

// eval_scoped_expression 在当前 frame 上下文中执行**原始表达式**。
// 作用域只包装一次：没有 frame 选择器时直接在当前文档执行，
// 有 frame 选择器时进入该 iframe 的 document/window 后再求值。
fn eval_scoped_expression(mut sess CdpSession, expr string, await_promise bool) !string {
	// #21: 直接 json_str 嵌入表达式，浏览器端用 JSON.parse 取回。
	// 旧实现先 V 端 base64.encode，再浏览器 atob + Uint8Array + TextDecoder，
	// 每次 eval 多 ~3 次全字符扫描 + 二进制解码。JSON 字符串本身就是合法
	// 的 JS 字符串字面量，json_str 已经处理好转义。
	scoped_expr := build_scoped_runtime_js(mut sess, 'return eval(JSON.parse(${js_str(json_str(expr))}));')
	p := '{"expression":${json_str(scoped_expr)},"returnByValue":true,"awaitPromise":${await_promise}}'
	resp := sess.send_command('Runtime.evaluate', p)!
	return evaluate_result_value(resp.result)
}

// Short-timeout (3 s) variant for use during dialog-triggering actions to avoid
// blocking the whole CLI when the CDP session is frozen by a synchronous alert/prompt.
// eval_scoped_expression_short 短超时版本（3秒），用于可能触发对话框的操作
// 避免对话框阻塞整个 CDP 会话。传入的同样是**原始表达式**。
fn eval_scoped_expression_short(mut sess CdpSession, expr string) !string {
	// 同上 #21
	scoped_expr := build_scoped_runtime_js(mut sess, 'return eval(JSON.parse(${js_str(json_str(expr))}));')
	p := '{"expression":${json_str(scoped_expr)},"returnByValue":true,"awaitPromise":false}'
	resp := sess.send_command_to('Runtime.evaluate', p, '', 3 * time.second)!
	return evaluate_result_value(resp.result)
}

// build_element_action_js 生成「定位元素 + 执行动作」的完整页面脚本。
// 脚本自带作用域（必要时进入 iframe 并把 document/window 绑定到子文档），
// 因此只能配合 eval_prepared_js / eval_prepared_js_short 使用，
// 不能再被 eval_scoped_expression 二次包装。
fn build_element_action_js(mut sess CdpSession, sel string, body string) string {
	query := if sel.starts_with('//') || sel.starts_with('(//') {
		'var el=doc.evaluate(${js_str(sel)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;'
	} else {
		'var el=doc.querySelector(${js_str(sel)});'
	}
	frame_selector := sess.current_frame_selector_value()
	if frame_selector == '' {
		return '(function(){ var frame=null; var doc=document; var win=window; ${query} if(el === null) return false; ${body} })()'
	}
	frame_sel := js_str(frame_selector)
	return '(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; ${query} if(el === null) return false; ${body} })()'
}

// Run element action with a short (3 s) timeout — used when the action may
// trigger a blocking dialog so we do not want to wait the full CDP timeout.
fn run_element_action_short(mut sess CdpSession, sel string, body string) ! {
	js := build_element_action_js(mut sess, sel, body)
	result := eval_prepared_js_short(mut sess, js)!
	ok := result == 'true'
	if !ok {
		return error('element not found: ${sel}')
	}
}

// resolve_object_id_by_selector 通过选择器获取元素的 Runtime RemoteObjectId
// 用于需要对象引用的 CDP 操作（如 callFunctionOn）
fn resolve_object_id_by_selector(mut sess CdpSession, sel string) !string {
	js := build_scoped_runtime_js(mut sess, 'return document.querySelector(${js_str(sel)});')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}')!
	object_id := cdp_extract_str(resp.result, 'objectId')
	if object_id == '' {
		return error('element not found: ${sel}')
	}
	return object_id
}

fn run_element_action(mut sess CdpSession, sel string, body string) ! {
	// Build a self-contained page script so selector lookup and event dispatch run in the same DOM scope.
	// 脚本已自带作用域，只能用 eval_prepared_js 执行（避免二次进入 iframe）。
	js := build_element_action_js(mut sess, sel, body)
	result := eval_prepared_js(mut sess, js, false)!
	ok := result == 'true'
	if !ok {
		return error('element not found: ${sel}')
	}
}

// build_action_point_query_js 生成查询元素中心点坐标的 JavaScript
// 包括可见性检查、元素滚动到视口中央、边框计算等
fn build_action_point_query_js(mut sess CdpSession, locator_js string) string {
	return build_document_scope_js(mut sess, '
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

// resolve_action_point_by_js 通过 JavaScript 定位器获取元素的坐标和尺寸
fn resolve_action_point_by_js(mut sess CdpSession, locator_js string) !ResolvedElement {
	js := build_action_point_query_js(mut sess, locator_js)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	// 页面脚本抛异常时不能当成「元素不可操作」
	evaluate_check_exception(resp.result)!
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

// scroll_resolved_element_into_view 将已解析的元素滚动到视口中
// 优先使用 backend_node_id 调用 DOM.scrollIntoViewIfNeeded
fn scroll_resolved_element_into_view(mut sess CdpSession, sel string, el ResolvedElement) ! {
	if el.backend_node_id > 0 {
		sess.send_command('DOM.scrollIntoViewIfNeeded', '{"backendNodeId":${el.backend_node_id}}')!
		return
	}
	js := build_element_scope_js(mut sess, sel, 'if(!el) return false; el.scrollIntoView({block:"center",inline:"center"}); return true;')
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

// pointer_click 在指定坐标执行鼠标点击操作
// click_count 指定点击次数（1=单击，2=双击）
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

// resolve_axref_object_id 通过 backendNodeId 解析出 Runtime RemoteObjectId。
// @eN 引用不是 CSS 选择器，必须走 backendNodeId / objectId 这条路。
fn resolve_axref_object_id(mut sess CdpSession, backend_node_id int) !string {
	resp := sess.send_command('DOM.resolveNode', '{"backendNodeId":${backend_node_id}}')!
	object_id := cdp_extract_str(resp.result, 'objectId')
	if object_id == '' {
		return error('could not resolve backendNodeId ${backend_node_id}')
	}
	return object_id
}

// 所有快照引用优先绑定 backendNodeId；节点失效时禁止回退到可能已指向别人的 selector。
fn run_axref_action(mut sess CdpSession, ref string, body string) ! {
	r := axref_get(&sess.axref, ref) or {
		return error('unknown ref ${ref}: run `v-browser snapshot` first')
	}
	if r.backend_node_id <= 0 {
		return error('stale-reference ${ref}: run `v-browser snapshot` again')
	}
	object_id := resolve_axref_object_id(mut sess, r.backend_node_id) or {
		return error('stale-reference ${ref}: ${err}')
	}
	defer { release_remote_object(mut sess, object_id) }
	// 先检查连接状态，避免 detached 节点仍能成功派发事件。
	declaration := 'function(){ var el = this; if (!el.isConnected) throw new Error("stale-reference: detached node"); var win = el.ownerDocument.defaultView; ${body} }'
	resp := sess.send_command('Runtime.callFunctionOn', '{"objectId":${json_str(object_id)},"functionDeclaration":${json_str(declaration)},"returnByValue":true}')!
	value := evaluate_result_value(resp.result)!
	if value != 'true' {
		return error('element action failed for ref ${ref}')
	}
}

// run_element_action_by_selector 是元素动作的统一入口：
// @eN 引用走 backendNodeId / objectId 解析，普通选择器走 CSS / XPath。
fn run_element_action_by_selector(mut sess CdpSession, sel string, body string) ! {
	if axref_is_ref(sel) {
		run_axref_action(mut sess, sel, body)!
		return
	}
	run_element_action(mut sess, sel, body)!
}

// pointer_action_for_selector 对选择器指定的元素执行指针操作（click/dblclick/hover）
// #22: 单次 Runtime.evaluate 同时做 scrollIntoView + 可见性检查 + rect 读取，
// 替代旧的 3 次 CDP round-trip（旧流程 resolve → scrollIntoView → 再 resolve）。
fn pointer_action_for_selector(mut sess CdpSession, sel string, action string) ! {
	// @eN 不是 CSS 选择器：鼠标回退路径必须用 backendNodeId 解析出的边界框
	el := if axref_is_ref(sel) {
		resolve_selector(mut sess, sel)!
	} else {
		resolve_action_point_by_selector(mut sess, sel)!
	}
	match action {
		'click' { pointer_click(mut sess, el.x, el.y, 1)! }
		'dblclick' { pointer_click(mut sess, el.x, el.y, 2)! }
		'hover' { pointer_hover(mut sess, el.x, el.y)! }
		else { return error('unknown pointer action: ${action}') }
	}
}

// resolve_action_point_by_selector 单次 eval 完成：querySelector/XPath + 可见性 +
// 滚动到视口中央 + 读 rect。复用 build_action_point_query_js 的合并逻辑。
fn resolve_action_point_by_selector(mut sess CdpSession, sel string) !ResolvedElement {
	// build_element_scope_js 生成的是一个 IIFE，函数体必须显式 return el，
	// 否则表达式求值得到 undefined，鼠标回退（click/dblclick/hover）全部失效。
	locator_js := build_element_scope_js(mut sess, sel, 'if(!el) return null; return el;')
	// build_action_point_query_js 会拼上 visibility / scrollIntoView / rect
	js := build_action_point_query_js(mut sess, locator_js)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	// 页面脚本抛异常时不能当成「元素不可操作」
	evaluate_check_exception(resp.result)!
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('element not actionable: ${sel}')
	}
	return ResolvedElement{
		x:      cdp_extract_float(value_obj, 'x')
		y:      cdp_extract_float(value_obj, 'y')
		width:  cdp_extract_float(value_obj, 'width')
		height: cdp_extract_float(value_obj, 'height')
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

// build_dblclick_action_body 生成双击元素的 JavaScript 代码
fn build_dblclick_action_body() string {
	return 'if(typeof el.click === "function") { el.click(); el.click(); } el.dispatchEvent(new MouseEvent("dblclick", { bubbles: true, cancelable: true, view: win, detail: 2 })); return true;'
}

// build_hover_action_body 生成悬停元素的 JavaScript 代码
// 派发 pointerover, mouseover, pointerenter, mouseenter, mousemove 事件序列
fn build_hover_action_body() string {
	return 'var events=["pointerover","mouseover","pointerenter","mouseenter","mousemove"]; for (var i=0;i<events.length;i++) { var name=events[i]; el.dispatchEvent(new MouseEvent(name, { bubbles: name !== "mouseenter" && name !== "pointerenter", cancelable: true, view: window })); } return true;'
}

// build_fill_action_body 生成清空并填入文本的 JavaScript 代码
// 支持 input/textarea 的 value 属性和 contenteditable 元素
// 触发 input 和 change 事件
fn build_fill_action_body(text string) string {
	value_js := js_str(text)
	return 'el.focus(); function setValue(target, value) { var proto = Object.getPrototypeOf(target); var desc = Object.getOwnPropertyDescriptor(proto, "value") || Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value") || Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value"); if (desc && desc.set) { desc.set.call(target, value); } else { target.value = value; } } if ("value" in el) { setValue(el, ""); el.dispatchEvent(new Event("input", { bubbles: true })); setValue(el, ${value_js}); el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } if (el.isContentEditable) { el.textContent = ${value_js}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true; } return false;'
}

// parse_verify_settings 从参数中解析验证设置
// 返回是否启用验证以及验证超时时间
fn parse_verify_settings(params string, default_timeout time.Duration) (bool, time.Duration) {
	verify := cdp_extract_str(params, 'verify') == 'true'
	verify_timeout_ms := cdp_extract_int(params, '"verifyTimeout":')
	if verify_timeout_ms <= 0 {
		return verify, default_timeout
	}
	return verify, time.millisecond * verify_timeout_ms
}

fn read_element_text_or_value(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(mut sess, sel, 'if(!el) return null; if ("value" in el) return el.value; return el.textContent || "";')
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	return eval_prepared_js(mut sess, js, false)
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

// read_file_input_names 读取文件选择框已选中的文件名列表
// 以换行符分隔返回所有文件名
fn read_file_input_names(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(mut sess, sel, 'if(!el) return null; if (!el.files) return ""; return Array.from(el.files).map(function(file) { return file.name; }).join("\\n");')
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	return eval_prepared_js(mut sess, js, false)
}

// read_preview_text 读取预览区域元素的内容
// 支持 innerText、textContent、value 属性
fn read_preview_text(mut sess CdpSession, sel string) !string {
	js := build_element_scope_js(mut sess, sel, 'if(!el) return null; return (el.innerText || el.textContent || el.value || "").trim();')
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	return eval_prepared_js(mut sess, js, false)
}

// wait_for_file_input_names 等待文件选择框包含期望的文件
// 轮询检查，文件名列表稳定后才返回
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

// verification_poll_interval 根据超时时间计算轮询间隔
// 超时越短，轮询越频繁
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

// upload_result_json 生成上传结果的 JSON 响应
// 包含已上传文件名列表、阶段和预览选择器
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

	resp := sess.send_command('Page.navigate', '{"url":${json_str(url)}}') or { return 'ERROR:${err}' }
	// 导航失败时 Page.navigate 会返回 errorText，必须报错而不是当作成功
	error_text := cdp_extract_str(resp.result, 'errorText')
	if error_text != '' {
		return 'ERROR:navigation failed: ${error_text}'
	}
	// 等待页面加载完成（最多 30s）
	mut loaded := false
	select {
		_ := <-load_ch {
			loaded = true
		}
		30 * time.second {
		}
	}
	if !loaded {
		return 'ERROR:timeout waiting for page load: ${url}'
	}
	clear_document_context(mut sess)
	return json_str('navigated to ${url}')
}

fn clear_document_context(mut sess CdpSession) {
	// Navigation must drop any stale frame or AX state so the next page starts from the main document.
	sess.set_current_frame_selector('')
	axref_clear(mut sess.axref)
}

// cmd_close 关闭当前 CDP 会话对应的目标
// 发送 Target.closeTarget 命令并关闭本地连接
fn cmd_close(mut sess CdpSession) string {
	sess.send_command('Target.closeTarget', '{}') or {}
	sess.close()
	return 'null'
}

// normalize_screenshot_format 校验截图格式白名单。
// format 会拼进 Page.captureScreenshot 的方法参数，必须限制成已知格式，
// 否则可以注入改写整个 CDP 方法调用。
fn normalize_screenshot_format(format string) !string {
	f := format.trim_space().to_lower()
	match f {
		'png' { return 'png' }
		'jpeg' { return 'jpeg' }
		'webp' { return 'webp' }
		else { return error('unsupported screenshot format: ${format}') }
	}
}

// cmd_screenshot 截取当前页面截图
// 支持参数：
//   - path: 保存路径
//   - format: 图片格式（png/jpeg/webp）
//   - quality: 图片质量（jpeg/webp）
//   - full: 是否截取整个页面
//   - annotate: 是否添加 UI 标注
fn cmd_screenshot(mut sess CdpSession, params string) string {
	path := cdp_extract_str(params, 'path')
	full := cdp_extract_str(params, 'full') == 'true'
	format := cdp_extract_str(params, 'format')
	fmt := if format != '' {
		normalize_screenshot_format(format) or { return 'ERROR:${err}' }
	} else {
		'png'
	}
	quality := cdp_extract_int(params, '"quality":')
	annotate := cdp_extract_bool(params, 'annotate')
	mut max_labels := cdp_extract_int(params, 'maxLabels')
	if max_labels == 0 {
		max_labels = 20
	}

	if annotate {
		return cmd_screenshot_annotate(mut sess, params, path, fmt, full, max_labels)
	}

	mut p := '{"format":${json_str(fmt)},"captureBeyondViewport":${full}'
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

// ─── 标注截图 ───────────────────────────────────────────────
//
// 旧实现把标注逻辑整个塞进页面脚本，靠 chrome.runtime.sendMessage 找扩展要
// 无障碍树和截图：扩展里根本没有 getAXTree / captureScreenshot 消息处理器，
// 脚本本身还带着嵌套引号的语法错误，命令必然失败。
//
// 现在全部走 CDP：
//   1. Accessibility.getFullAXTree 拿 AX 节点；
//   2. DOM.resolveNode + Runtime.callFunctionOn 拿节点在文档坐标系里的矩形；
//   3. 页面里只注入一个纯 DOM 的标注覆盖层（不依赖任何扩展 API）；
//   4. Page.captureScreenshot 截图，随后移除覆盖层。

// annotate_interactive_roles 参与标注的 AX 角色。
const annotate_interactive_roles = ['button', 'link', 'textbox', 'checkbox', 'radio', 'combobox',
	'listbox', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option', 'searchbox', 'slider',
	'spinbutton', 'switch', 'tab', 'treeitem', 'heading', 'image']

// annotate_rect_function 计算元素在**顶层文档坐标系**里的矩形。
// 同源 iframe 里的元素会逐层累加 iframe 自身的偏移。
const annotate_rect_function = 'function(){var own=this.ownerDocument.defaultView;var child=own!==own.top;var node=this;var x=0,y=0;while(node){var r=node.getBoundingClientRect();x+=r.left;y+=r.top;var w=node.ownerDocument&&node.ownerDocument.defaultView;if(!w)throw new Error("annotation coordinate conversion failed: missing window");if(w===w.top)break;var fe;try{fe=w.frameElement;}catch(e){throw new Error("annotation coordinate conversion failed: cross-origin frame");}if(!fe)throw new Error("annotation coordinate conversion failed: cross-origin frame owner unavailable");x+=fe.clientLeft||0;y+=fe.clientTop||0;node=fe;}var rect=this.getBoundingClientRect();return {x:x+(child?0:own.scrollX),y:y+(child?0:own.scrollY),width:rect.width,height:rect.height,needsTopScroll:child};}'

// AnnotateLabel 是一个待标注的元素（坐标为文档坐标系）。
struct AnnotateLabel {
	num    int
	role   string
	name   string
	x      f64
	y      f64
	width  f64
	height f64
}

// AnnotateRect 是元素在文档坐标系里的矩形。
struct AnnotateRect {
	x      f64
	y      f64
	width  f64
	height f64
}

// annotate_node_rect 解析某个 backendNodeId 对应的矩形。
fn annotate_node_rect(mut sess CdpSession, backend_node_id int) !AnnotateRect {
	resolve_resp := sess.send_command('DOM.resolveNode', '{"backendNodeId":${backend_node_id}}')!
	object_id := cdp_extract_str(resolve_resp.result, 'objectId')
	if object_id == '' {
		return error('could not resolve backendNodeId ${backend_node_id}')
	}
	// 远端对象只服务这一次取矩形，取完立即释放
	defer { release_remote_object(mut sess, object_id) }
	resp := sess.send_command('Runtime.callFunctionOn', '{"objectId":${json_str(object_id)},"functionDeclaration":${json_str(annotate_rect_function)},"returnByValue":true}')!
	evaluate_check_exception(resp.result)!
	value_obj := cdp_extract_obj_key(cdp_extract_obj_key(resp.result, '"result":'), '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('could not read box of backendNodeId ${backend_node_id}')
	}
	mut scroll_x := 0.0
	mut scroll_y := 0.0
	if cdp_extract_bool(value_obj, 'needsTopScroll') {
		// 顶层独立求值，不允许子 frame 跨源读取 top.scrollX/Y 后静默退回 0。
		scroll := eval_prepared_js(mut sess, '(function(){if(window !== window.top) throw new Error("annotation coordinate conversion failed: not top context");return {x:window.scrollX,y:window.scrollY};})()', false)!
		if cdp_extract_obj_key(scroll, '"x":') == '' || cdp_extract_obj_key(scroll, '"y":') == '' {
			return error('annotation coordinate conversion failed: top scroll is unavailable')
		}
		scroll_x = cdp_extract_float(scroll, 'x')
		scroll_y = cdp_extract_float(scroll, 'y')
	}
	return AnnotateRect{
		x:      cdp_extract_float(value_obj, 'x') + scroll_x
		y:      cdp_extract_float(value_obj, 'y') + scroll_y
		width:  cdp_extract_float(value_obj, 'width')
		height: cdp_extract_float(value_obj, 'height')
	}
}

// collect_annotate_labels 从 AX 树里收集需要标注的可交互元素。
fn collect_annotate_labels(mut sess CdpSession, max_labels int) ![]AnnotateLabel {
	resp := sess.send_command('Accessibility.getFullAXTree', '{}')!
	nodes_json := cdp_extract_obj_key(resp.result, '"nodes":')
	if nodes_json == '' {
		return error('no AX tree returned')
	}
	limit := if max_labels > 0 { max_labels } else { 20 }
	mut labels := []AnnotateLabel{}
	mut counter := 1
	mut pos := 1
	mut guard := 0
	for pos < nodes_json.len - 1 && labels.len < limit {
		guard++
		if guard > 20000 {
			break
		}
		if nodes_json[pos] != `{` {
			pos++
			continue
		}
		node_str := cdp_balanced(nodes_json[pos..])
		pos += node_str.len
		role := ax_prop(node_str, 'role')
		bnid := cdp_extract_int(node_str, '"backendDOMNodeId":')
		if role == '' || role !in annotate_interactive_roles || bnid <= 0 {
			continue
		}
		rect := annotate_node_rect(mut sess, bnid) or { return error('annotation failed: ${err}') }
		if rect.width <= 0 || rect.height <= 0 {
			continue
		}
		labels << AnnotateLabel{
			num:    counter
			role:   role
			name:   ax_prop(node_str, 'name')
			x:      rect.x
			y:      rect.y
			width:  rect.width
			height: rect.height
		}
		counter++
	}
	return labels
}

// build_screenshot_overlay_js 生成标注覆盖层的页面脚本。
// 纯 DOM 实现，不调用任何扩展 API；返回 Promise，由 CDP 以 awaitPromise 等待，
// 保证覆盖层绘制完成之后才截图。
fn build_screenshot_overlay_js(labels []AnnotateLabel, overlay_ids ...string) string {
	overlay_id := if overlay_ids.len > 0 { overlay_ids[0] } else { '__vBrowserAnnotateOverlay' }
	mut items := []string{}
	for l in labels {
		items << '{"num":${l.num},"x":${l.x},"y":${l.y},"width":${l.width},"height":${l.height}}'
	}
	items_json := '[' + items.join(',') + ']'
	return [
		'(async function(){',
		'  var labels = ${items_json};',
		'  var id = ${json_str(overlay_id)};',
		'  if (document.getElementById(id)) throw new Error("annotation overlay id collision");',
		'  var layer = document.createElement("div");',
		'  layer.id = id;',
		'  layer.setAttribute("data-vbrowser-annotate", "1");',
		'  var st = layer.style;',
		'  st.position = "absolute";',
		'  st.left = "0px";',
		'  st.top = "0px";',
		'  st.width = "0px";',
		'  st.height = "0px";',
		'  st.pointerEvents = "none";',
		'  st.zIndex = "2147483647";',
		'  for (var i = 0; i < labels.length; i++) {',
		'    var l = labels[i];',
		'    var box = document.createElement("div");',
		'    var bs = box.style;',
		'    bs.position = "absolute";',
		'    bs.left = (Number(l.x) || 0) + "px";',
		'    bs.top = (Number(l.y) || 0) + "px";',
		'    bs.width = Math.max(0, Number(l.width) || 0) + "px";',
		'    bs.height = Math.max(0, Number(l.height) || 0) + "px";',
		'    bs.border = "2px solid #ff0000";',
		'    bs.boxSizing = "border-box";',
		'    var tag = document.createElement("div");',
		'    tag.textContent = String(l.num);',
		'    var ts = tag.style;',
		'    ts.position = "absolute";',
		'    ts.left = "-2px";',
		'    ts.top = "-22px";',
		'    ts.width = "20px";',
		'    ts.height = "20px";',
		'    ts.lineHeight = "20px";',
		'    ts.textAlign = "center";',
		'    ts.background = "#ff0000";',
		'    ts.color = "#ffffff";',
		'    ts.font = "bold 13px monospace";',
		'    box.appendChild(tag);',
		'    layer.appendChild(box);',
		'  }',
		'  if (!document.documentElement) return false;',
		'  document.documentElement.appendChild(layer);',
		'  // 等一帧，确保覆盖层已经画到页面上',
		'  await new Promise(function(resolve) {',
		'    if (typeof requestAnimationFrame === "function") { requestAnimationFrame(function() { resolve(true); }); }',
		'    else { setTimeout(resolve, 0); }',
		'  });',
		'  return true;',
		'})()',
	].join('\n')
}

// build_screenshot_overlay_remove_js 生成移除标注覆盖层的脚本。
fn build_screenshot_overlay_remove_js(overlay_ids ...string) string {
	overlay_id := if overlay_ids.len > 0 { overlay_ids[0] } else { '__vBrowserAnnotateOverlay' }
	return '(function(){ var el = document.getElementById(${json_str(overlay_id)}); if (el && el.attributes && el.attributes["data-vbrowser-annotate"] && el.parentNode) el.parentNode.removeChild(el); return true; })()'
}

// 清理幂等且只删除本次注入的标记节点，失败不影响主流程。
fn remove_screenshot_overlay(mut sess CdpSession, overlay_id string) {
	eval_prepared_js(mut sess, build_screenshot_overlay_remove_js(overlay_id), false) or {}
}

// annotate_labels_json 输出标注元素列表。
fn annotate_labels_json(labels []AnnotateLabel) string {
	mut items := []string{}
	for l in labels {
		items << '{"num":${l.num},"role":${json_str(l.role)},"name":${json_str(l.name)},"x":${l.x},"y":${l.y},"width":${l.width},"height":${l.height}}'
	}
	return '[' + items.join(',') + ']'
}

// cmd_screenshot_annotate 截取带标注的页面截图
// 标注元素来自 CDP 的 AX 树，标注由页面内的纯 DOM 覆盖层绘制。
fn cmd_screenshot_annotate(mut sess CdpSession, _params string, path string, fmt string, full bool, max_labels int) string {
	labels := collect_annotate_labels(mut sess, max_labels) or { return 'ERROR:${err}' }
	if labels.len == 0 {
		return 'ERROR:no interactive elements found for annotation'
	}
	overlay_id := '__vBrowserAnnotateOverlay_${rand.uuid_v4()}'
	// 必须在注入前注册清理，Promise 超时或注入半途失败也不能残留覆盖层。
	defer { remove_screenshot_overlay(mut sess, overlay_id) }
	installed := eval_prepared_js(mut sess, build_screenshot_overlay_js(labels, overlay_id), true) or {
		return 'ERROR:${err}'
	}
	if installed != 'true' { return 'ERROR:annotation overlay injection failed' }
	mut p := '{"format":${json_str(fmt)},"captureBeyondViewport":${full}}'
	resp := sess.send_command('Page.captureScreenshot', p) or { return 'ERROR:${err}' }
	data := cdp_extract_str(resp.result, 'data')
	if data == '' {
		return 'ERROR:no screenshot data returned'
	}
	out_path := if path != '' {
		path
	} else {
		os.join_path(os.temp_dir(), 'screenshot_annotated_${time.now().unix_milli()}.${fmt}')
	}
	raw_bytes := base64.decode(data)
	os.write_file_array(out_path, raw_bytes) or { return 'ERROR:write failed: ${err}' }
	return '{"path":${json_str(out_path)},"labelsCount":${labels.len},"labels":${annotate_labels_json(labels)}}'
}

fn capture_screenshot_base64(mut sess CdpSession, format string, full bool, selector string) !string {
	// 格式同样要过白名单，避免注入改写 CDP 方法
	safe_format := normalize_screenshot_format(format)!
	mut p := '{"format":${json_str(safe_format)}'
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

// ensure_download_behavior 确保浏览器允许文件下载
// 返回下载模式：'dom'（DOM直接设置）或 'default'（默认浏览器行为）
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

// resolve_downloaded_file_path 解析下载文件的实际路径
// 根据下载状态事件确定文件名
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
	js := build_document_scope_js(mut sess, '
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
	eval_prepared_js(mut sess, js, false)!
}

fn pull_dom_download_capture(mut sess CdpSession) !string {
	js := build_document_scope_js(mut sess, 'var queue = win.__vBrowserDownloadQueue || []; if (queue.length === 0) return null; return JSON.stringify(queue.shift());')
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	return eval_prepared_js(mut sess, js, false)!
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
	out_path := resolve_dom_download_path(filename, target_path)!
	os.write_file_array(out_path, base64.decode(data))!
	return out_path
}

// sanitize_download_filename 把文件名压成安全的单段文件名。
// 只做字符层面的清洗，路径语义的拒绝在 resolve_dom_download_path 里做。
fn sanitize_download_filename(name string) string {
	mut out := []u8{cap: name.len}
	for ch in name {
		if ch < 32 || ch == 127 {
			continue
		}
		if ch in [`/`, `\\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`] {
			continue
		}
		out << ch
	}
	mut result := out.bytestr().trim_space()
	if result == '' || result == '.' || result == '..' {
		return 'download.bin'
	}
	if result.len > 120 {
		result = result[..120]
	}
	return result
}

// resolve_dom_download_path 计算 DOM 下载的落盘路径。
// 网页给出的文件名不可信：绝对路径、.. 与路径分隔符一律拒绝；
// 合法文件名只作元数据保留，实际落盘使用独立下载目录内生成的安全文件名，
// 并校验规范化后的路径仍在下载目录内。
fn resolve_dom_download_path(raw_filename string, target_path string) !string {
	if target_path != '' {
		// 调用方显式给的目标路径由用户自己负责
		parent_dir := os.dir(target_path)
		if parent_dir != '' {
			os.mkdir_all(parent_dir)!
		}
		return target_path
	}
	name := if raw_filename.trim_space() == '' { 'download.bin' } else { raw_filename.trim_space() }
	if os.is_abs_path(name) || name.contains('/') || name.contains('\\') || name.contains('..') || name.contains(':') {
		return error('unsafe download filename: ${raw_filename}')
	}
	// 原子创建私有目录，避免时间戳碰撞及预先放置的符号链接。
	download_dir := os.join_path(os.temp_dir(), 'v_browser_dom_download_${rand.uuid_v4()}')
	os.mkdir(download_dir)!
	os.chmod(download_dir, 0o700)!
	out_path := os.join_path(download_dir, sanitize_download_filename(name))
	norm_dir := os.real_path(download_dir)
	norm_path := os.norm_path(os.join_path(norm_dir, os.file_name(out_path)))
	if !norm_path.starts_with(norm_dir + os.path_separator) {
		return error('download path escaped download dir: ${out_path}')
	}
	return out_path
}

fn fetch_download_via_dom(mut sess CdpSession, sel string, target_path string) !string {
	js := build_element_scope_js(mut sess, sel, '
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
	raw := eval_prepared_js(mut sess, js, true)!
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

// wait_for_download 等待浏览器下载完成
// 订阅 Page.downloadWillBegin 和 Page.downloadProgress 事件
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
			250 * time.millisecond {
			}
		}
		fallback_path := detect_completed_download_in_dir(download_dir)
		if fallback_path != '' {
			return finalize_download_path(fallback_path, target_path)!
		}
	}
	return error('timeout waiting for download')
}

fn build_dom_snapshot_js(mut sess CdpSession, selector string, compact bool, max_depth int) string {
	selector_expr := if selector == '' {
		'doc.body || doc.documentElement'
	} else if selector.starts_with('//') || selector.starts_with('(//') {
		'doc.evaluate(${js_str(selector)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue'
	} else {
		'doc.querySelector(${js_str(selector)})'
	}
	compact_js := if compact { 'true' } else { 'false' }
	depth_limit := if max_depth > 0 { max_depth } else { 8 }
	return build_document_scope_js(mut sess, '
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
	js := build_dom_snapshot_js(mut sess, selector, compact, max_depth)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}')!
	result := cdp_extract_obj_key(resp.result, '"result":')
	return cdp_extract_value_from_result(result)
}

// enable_lifecycle_events 打开 Page.lifecycleEvent 上报。
// CDP 默认不发送 lifecycle 事件，不显式打开就永远等不到 networkIdle。
fn enable_lifecycle_events(mut sess CdpSession) ! {
	sess.send_command('Page.setLifecycleEventsEnabled', '{"enabled":true}')!
}

// LifecycleTarget 描述等待 networkidle 时应该关注的 frame 及其当前文档。
struct LifecycleTarget {
	frame_id  string
	loader_id string
}

// resolve_lifecycle_target 的失败必须显式传播，不能把 iframe 错误降级成主 frame。

// FrameEntry 是 frame 树里的一个 frame（id + 当前文档的 loaderId）。
struct FrameEntry {
	frame_id  string
	loader_id string
}

// parse_frame_node 递归解析 frame 树节点，收集所有 frame。
fn parse_frame_node(node_json string, mut out []FrameEntry) {
	frame := cdp_extract_obj_key(node_json, '"frame":')
	if frame != '' {
		out << FrameEntry{
			frame_id:  cdp_extract_str(frame, 'id')
			loader_id: cdp_extract_str(frame, 'loaderId')
		}
	}
	children := cdp_extract_obj_key(node_json, '"childFrames":')
	if children == '' || children == '[]' {
		return
	}
	mut pos := 1
	for pos < children.len {
		if children[pos] == `{` {
			item := cdp_balanced(children[pos..])
			parse_frame_node(item, mut out)
			pos += item.len
		} else {
			pos++
		}
	}
}

// collect_frame_entries 收集 frame 树里的所有 frame。
fn collect_frame_entries(tree_json string) []FrameEntry {
	mut out := []FrameEntry{}
	parse_frame_node(tree_json, mut out)
	return out
}

// iframe_backend_node_id 解析 iframe 元素（主文档里的 CSS 选择器）的 backendNodeId。
fn iframe_backend_node_id(mut sess CdpSession, selector string) !int {
	doc_resp := sess.send_command('DOM.getDocument', '{"depth":0}')!
	root_node_id := cdp_extract_int(doc_resp.result, '"nodeId":')
	if root_node_id == 0 {
		return error('could not get document root')
	}
	qs_resp := sess.send_command('DOM.querySelector', '{"nodeId":${root_node_id},"selector":${json_str(selector)}}')!
	target_node_id := cdp_extract_int(qs_resp.result, '"nodeId":')
	if target_node_id == 0 {
		return error('selector not found: ${selector}')
	}
	desc_resp := sess.send_command('DOM.describeNode', '{"nodeId":${target_node_id}}')!
	bnid := cdp_extract_int(desc_resp.result, '"backendNodeId":')
	if bnid == 0 {
		return error('could not get backendNodeId for ${selector}')
	}
	return bnid
}

// find_frame_by_owner 在 frame 列表里找出 owner backendNodeId 匹配的那个 frame。
fn find_frame_by_owner(mut sess CdpSession, frames []FrameEntry, owner_bnid int) ?FrameEntry {
	for f in frames {
		resp := sess.send_command('Page.getFrameOwner', '{"frameId":${json_str(f.frame_id)}}') or {
			continue
		}
		bnid := cdp_extract_int(resp.result, '"backendNodeId":')
		if bnid == owner_bnid {
			return f
		}
	}
	return none
}

// resolve_lifecycle_target 找出等待 networkidle 时应该关注的 frame。
// 默认是主 frame；当前处于 iframe 上下文时，改为该 iframe 对应的子 frame
// （用 Page.getFrameOwner 的 backendNodeId 与 iframe 元素对上号）。
fn resolve_lifecycle_target(mut sess CdpSession) !LifecycleTarget {
	resp := sess.send_command('Page.getFrameTree', '{}') or { return error(err.msg()) }
	tree := cdp_extract_obj_key(resp.result, '"frameTree":')
	if tree == '' {
		return error('cannot resolve lifecycle target: frame tree is empty')
	}
	frame := cdp_extract_obj_key(tree, '"frame":')
	target := LifecycleTarget{
		frame_id:  cdp_extract_str(frame, 'id')
		loader_id: cdp_extract_str(frame, 'loaderId')
	}
	if target.frame_id == '' {
		return error('cannot resolve lifecycle target: main frame id is missing')
	}
	selector := sess.current_frame_selector_value()
	if selector == '' {
		return target
	}
	owner_bnid := iframe_backend_node_id(mut sess, selector) or {
		return error('cannot resolve lifecycle target for iframe ${selector}: ${err}')
	}
	child := find_frame_by_owner(mut sess, collect_frame_entries(tree), owner_bnid) or {
		return error('cannot resolve lifecycle target for iframe ${selector}: child frame is missing')
	}
	return LifecycleTarget{
		frame_id:  child.frame_id
		loader_id: child.loader_id
	}
}

// lifecycle_event_matches 判断 lifecycle 事件是否命中目标 frame / loader。
//   - frame_id 为空表示不限制 frame；
//   - loader_id 为空表示不限制 loader；
//   - exclude_loader 非空表示该 loader（旧文档）必须被排除。
fn lifecycle_event_matches(params string, frame_id string, loader_id string, exclude_loader string) bool {
	if cdp_extract_str(params, 'name') != 'networkIdle' {
		return false
	}
	if frame_id != '' {
		evt_frame := cdp_extract_str(params, 'frameId')
		if evt_frame != '' && evt_frame != frame_id {
			return false
		}
	}
	evt_loader := cdp_extract_str(params, 'loaderId')
	if loader_id != '' {
		// loader 已知时拒绝缺失 loaderId 的事件，避免导航后误收旧文档事件。
		return evt_loader != '' && evt_loader == loader_id
	}
	if exclude_loader != '' && evt_loader != '' {
		return evt_loader != exclude_loader
	}
	return true
}

// wait_for_networkidle 等待 networkIdle 生命周期事件。
//   - 等待前显式打开 lifecycle 事件上报（CDP 默认关闭，等不到事件）；
//   - 用固定 deadline 控制整个循环：收到无关事件不会重置时限；
//   - 事件必须属于目标 frame / loader 才算命中。
fn wait_for_networkidle(mut sess CdpSession, timeout time.Duration) ! {
	// 先订阅再开启上报，避免漏掉开启后立刻到达的事件
	ch := sess.subscribe('Page.lifecycleEvent')
	defer { sess.unsubscribe('Page.lifecycleEvent', ch) }
	enable_lifecycle_events(mut sess)!
	target := resolve_lifecycle_target(mut sess) or { return error(err.msg()) }
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		select {
			evt := <-ch {
				if lifecycle_event_matches(evt.params, target.frame_id, target.loader_id, '') {
					return
				}
			}
			250 * time.millisecond {
				// 轮询检查 deadline（收到无关事件不会重置时限）
			}
		}
	}
	return error('timeout waiting for networkidle')
}

// 导航使用 Page.navigate 返回的 loaderId，不能依赖可能先到或缺失的 frameNavigated。
fn navigate_and_wait_networkidle(mut sess CdpSession, url string) ! {
	lifecycle_ch := sess.subscribe('Page.lifecycleEvent')
	same_document_ch := sess.subscribe('Page.navigatedWithinDocument')
	defer {
		sess.unsubscribe('Page.lifecycleEvent', lifecycle_ch)
		sess.unsubscribe('Page.navigatedWithinDocument', same_document_ch)
	}
	enable_lifecycle_events(mut sess)!
	target := resolve_lifecycle_target(mut sess)!
	resp := sess.send_command('Page.navigate', '{"url":${json_str(url)},"frameId":${json_str(target.frame_id)}}')!
	error_text := cdp_extract_str(resp.result, 'errorText')
	if error_text != '' { return error('navigation failed: ${error_text}') }
	if cdp_extract_bool(resp.result, 'isDownload') {
		return error('navigation started a download, not a document')
	}
	new_loader := cdp_extract_str(resp.result, 'loaderId')
	frame_id := cdp_extract_str(resp.result, 'frameId')
	if frame_id == '' || frame_id != target.frame_id {
		return error('navigation response has no matching frameId')
	}
	deadline := time.now().add(30 * time.second)
	for time.now() < deadline {
		select {
			evt := <-same_document_ch {
				// 同文档导航不创建新 loader，也不会再触发新文档的 networkIdle。
				if new_loader == '' && cdp_extract_str(evt.params, 'frameId') == frame_id
					&& cdp_extract_str(evt.params, 'url') == url {
					return
				}
			}
			evt := <-lifecycle_ch {
				if new_loader != '' && lifecycle_event_matches(evt.params, frame_id, new_loader, '') {
					return
				}
			}
			250 * time.millisecond {
			}
		}
	}
	return error('timeout waiting for networkidle')
}

// wait_for_navigation_state 等待页面导航到指定状态
// 支持状态：commit/domcontentloaded/loaded/networkidle
fn wait_for_navigation_state(mut sess CdpSession, state string) ! {
	if state == 'networkidle' {
		wait_for_networkidle(mut sess, 30 * time.second)!
		return
	}
	match state {
		'', 'load' {
			ch := sess.subscribe('Page.loadEventFired')
			defer { sess.unsubscribe('Page.loadEventFired', ch) }
			select {
				_ := <-ch {
				}
				30 * time.second {
					return error('timeout waiting for load')
				}
			}
		}
		'domcontentloaded' {
			ch := sess.subscribe('Page.domContentEventFired')
			defer { sess.unsubscribe('Page.domContentEventFired', ch) }
			select {
				_ := <-ch {
				}
				30 * time.second {
					return error('timeout waiting for domcontentloaded')
				}
			}
		}
		else {
			return error('unknown waitUntil state: ${state}')
		}
	}
}

fn navigate_and_wait(mut sess CdpSession, url string, state string) ! {
	if state == 'networkidle' {
		navigate_and_wait_networkidle(mut sess, url)!
		return
	}
	mut event := 'Page.loadEventFired'
	if state == 'domcontentloaded' {
		event = 'Page.domContentEventFired'
	}
	ch := sess.subscribe(event)
	defer { sess.unsubscribe(event, ch) }
	sess.send_command('Page.navigate', '{"url":${json_str(url)}}')!
	select {
		_ := <-ch {
		}
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

// cmd_pdf 生成当前页面的 PDF 文档
// 支持参数：
//   - path: 保存路径
//   - landscape: 横向布局
//   - displayHeaderFooter: 显示页眉页脚
//   - printBackground: 打印背景色和图片
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

// cmd_snapshot 获取页面快照（Accessibility Tree）
// 支持参数：
//   - raw: 是否输出原始格式
//   - extra/interactive: 是否包含 cursor-interactive 补全扫描
//   - maxNodes: 返回的最大节点数限制
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

// cursor_selector_helper_js 返回 cursor-interactive 快照用到的选择器辅助函数源码。
// 单独抽出来是为了能在 node 沙箱里直接验证索引语义：
//   - nthOfTypeIndex：CSS :nth-of-type 只按「标签」计数，
//     所以索引必须基于**所有同标签兄弟**，不能按「同标签且同 class」过滤；
//   - strictSelector：兜底路径，只用 tag:nth-child 逐级定位，保证唯一命中。
fn cursor_selector_helper_js() string {
	return [
		'function nthOfTypeIndex(el) {',
		'  var parent = el.parentElement;',
		'  if (!parent) return 1;',
		'  var kids = parent.children || [];',
		'  var sameTag = [];',
		'  for (var i = 0; i < kids.length; i++) {',
		'    if (kids[i].tagName === el.tagName) sameTag.push(kids[i]);',
		'  }',
		'  return sameTag.indexOf(el) + 1;',
		'}',
		'function strictSelector(el) {',
		'  var parts = [];',
		'  var current = el;',
		'  while (current && current.parentElement) {',
		'    var parent = current.parentElement;',
		'    var kids = parent.children || [];',
		'    parts.unshift(current.tagName.toLowerCase() + ":nth-child(" + (kids.indexOf(current) + 1) + ")");',
		'    current = parent;',
		'  }',
		'  return parts.join(" > ");',
		'}',
	].join('\n')
}

fn build_cursor_interactive_snapshot_js(mut sess CdpSession, candidate_limit int) string {
	limit := if candidate_limit > 0 { candidate_limit } else { 1000 }
	return build_document_scope_js(mut sess, '
		${cursor_selector_helper_js()}
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
			// 特殊属性值可能生成非法 CSS；候选唯一性检查失败时继续走路径兜底。
			function unique(candidate) { try { var found=doc.querySelectorAll(candidate); return found.length === 1 && found[0] === el; } catch (e) { return false; } }
			var testId = el.getAttribute("data-testid");
			var testSelector = testId ? "[data-testid=" + JSON.stringify(testId) + "]" : "";
			if (testSelector && unique(testSelector)) return testSelector;
			var idSelector = el.id ? "#" + CSS.escape(el.id) : "";
			if (idSelector && unique(idSelector)) return idSelector;
			var path = [];
			var current = el;
			while (current && current !== doc.body) {
				var sel = current.tagName.toLowerCase();
				var classes = Array.from(current.classList || []).filter(function(name) { return String(name || "").trim() !== ""; });
				if (classes.length > 0) sel += "." + CSS.escape(classes[0]);
				var parent = current.parentElement;
				if (parent) {
					var sameTag = Array.from(parent.children || []).filter(function(node) {
						return node.tagName === current.tagName;
					});
					// :nth-of-type 只按标签计数（class 不参与），
					// 索引必须基于所有同标签兄弟，否则会指向另一个元素。
					if (sameTag.length > 1) {
						sel += ":nth-of-type(" + nthOfTypeIndex(current) + ")";
					}
				}
				path.unshift(sel);
				current = current.parentElement;
				try {
					var candidate = path.join(" > ");
					var found = doc.querySelectorAll(candidate);
					// 必须唯一命中原元素，否则继续往上级补路径
					if (found.length === 1 && found[0] === el) return candidate;
				} catch (e) {}
				if (path.length >= 8) break;
			}
			// 兜底：只用 tag:nth-child 逐级定位，保证唯一命中
			var fallback = strictSelector(el);
			try {
				var found = doc.querySelectorAll(fallback);
				if (found.length === 1 && found[0] === el) return fallback;
			} catch (e) {}
			return path.join(" > ");
		}
		var seen = new Set();
		var results = [];
		// 保存扫描时的真实节点，后续换取 backendNodeId，不再重新按 selector 指向替代节点。
		var snapshotNodes = win.__vBrowserCursorSnapshotNodes = [];
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
			snapshotNodes.push(el);
			results.push({ selector: selector, text: text.slice(0, 120), role: hasCursorPointer || hasOnClick ? "clickable" : "focusable", hints: hints.join(", ") });
		}
		return results.map(function(item) {
			return [item.selector, item.text.replace(/[\\t\\n\\r]+/g, " "), item.role, item.hints.replace(/[\\t\\n\\r]+/g, " ")].join("\\t");
		}).join("\\n");
	')
}

fn render_cursor_interactive_snapshot(mut sess CdpSession, start_counter int, mut store AxRefStore,
	max_nodes int) !string {
	js := build_cursor_interactive_snapshot_js(mut sess, max_nodes)
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return error('cursor scan failed: ${err}')
	}
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	raw_lines := cdp_extract_value_from_result(result_obj)
	if raw_lines == '' || raw_lines == 'null' {
		return ''
	}
	defer {
		cleanup := build_document_scope_js(mut sess, 'delete win.__vBrowserCursorSnapshotNodes; return true;')
		eval_prepared_js(mut sess, cleanup, false) or {}
	}
	mut out := strings.new_builder(4096)
	mut counter := start_counter
	for node_index, line in raw_lines.split('\n') {
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
		lookup := build_document_scope_js(mut sess, 'var el=(win.__vBrowserCursorSnapshotNodes || [])[${node_index}]; if(!el || !el.isConnected) throw new Error("stale-reference: cursor snapshot node disappeared"); return el;')
		node_resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(lookup)}}')!
		evaluate_check_exception(node_resp.result)!
		object_id := cdp_extract_str(node_resp.result, 'objectId')
		if object_id == '' { return error('stale-reference: cannot resolve cursor snapshot node') }
		desc := sess.send_command('DOM.describeNode', '{"objectId":${json_str(object_id)}}') or {
			release_remote_object(mut sess, object_id)
			return error('stale-reference: ${err}')
		}
		release_remote_object(mut sess, object_id)
		backend_node_id := cdp_extract_int(desc.result, '"backendNodeId":')
		if backend_node_id <= 0 {
			return error('stale-reference: cursor snapshot backendNodeId is missing')
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
			// 引用只用稳定节点身份，避免 resolver 的 selector 优先路径重新指向别的元素。
			backend_node_id: backend_node_id
			role:            resolved_role
			name:            text
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

// cmd_click 点击选择器指定的元素
// 优先使用页面内的 el.click() 方法（最接近真实用户点击）
// 支持参数：selector（CSS选择器）
// dispatch_pointer_action 统一处理 click / dblclick / hover 的双路径回退。
// 优先走 DOM 事件触发（最贴合页面自身的监听器），失败时回退到 CDP 鼠标输入。
// 两条路径都失败时，会把两条错误信息合并回报，避免只看到 fallback 的错误而
// 丢失首选路径的根因（旧版会出现这种 swallow，见 #8）。
//
// V 的 `or` 块不支持给 err 命名，嵌套 or 还会触发编译器 bug，所以用 TryResult
// 显式传递错误消息。
struct TryResult {
	ok  bool
	msg string
}

fn try_run_element_action(mut sess CdpSession, sel string, body string) TryResult {
	run_element_action_by_selector(mut sess, sel, body) or {
		return TryResult{
			ok:  false
			msg: err.msg()
		}
	}
	return TryResult{
		ok: true
	}
}

fn try_pointer_action(mut sess CdpSession, sel string, action string) TryResult {
	pointer_action_for_selector(mut sess, sel, action) or {
		return TryResult{
			ok:  false
			msg: err.msg()
		}
	}
	return TryResult{
		ok: true
	}
}

fn dispatch_pointer_action(mut sess CdpSession, sel string, action string) string {
	body := match action {
		'click' { build_click_action_body() }
		'dblclick' { build_dblclick_action_body() }
		'hover' { build_hover_action_body() }
		else { return 'ERROR:unknown pointer action: ${action}' }
	}
	dom_result := try_run_element_action(mut sess, sel, body)
	if dom_result.ok {
		return 'null'
	}
	// stale 引用不能通过鼠标回退伪装成功。
	if dom_result.msg.contains('stale-reference') { return 'ERROR:${dom_result.msg}' }
	mouse_result := try_pointer_action(mut sess, sel, action)
	if mouse_result.ok {
		// DOM path 失败但 mouse fallback 成功；保留 dom 错误供诊断
		srv_log('[${action}] DOM path failed for ${sel}: ${dom_result.msg}; mouse fallback succeeded.')
		return 'null'
	}
	return 'ERROR:${action} failed for selector ${sel}: dom: ${dom_result.msg}; mouse: ${mouse_result.msg}'
}

fn cmd_click(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	return dispatch_pointer_action(mut sess, sel, 'click')
}

// cmd_dblclick 双击指定选择器或坐标的元素
fn cmd_dblclick(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	return dispatch_pointer_action(mut sess, sel, 'dblclick')
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

// cmd_hover 将鼠标悬停到指定元素
fn cmd_hover(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	return dispatch_pointer_action(mut sess, sel, 'hover')
}

// cmd_focus 聚焦到指定元素
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
		js := build_element_scope_js(mut sess, sel, 'el?.focus(); return true;')
		if !evaluate_bool_js(mut sess, js)! {
			return error('element not found: ${sel}')
		}
	}
}

// cmd_fill 清空并填入文本到输入框
// 支持参数：selector（CSS选择器）、text（要填入的文本）
fn cmd_fill(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	text := cdp_extract_str(params, 'text')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	if sess.current_frame_selector_value() != '' {
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

// cmd_type_text 模拟逐字符输入文本（像用户打字一样）
// 支持参数：selector、text，以及 verify/timeout 验证设置
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

// cmd_keyboard 执行键盘操作
// 支持 action：type/inserttext（输入文本）、down/up（按键按下/释放）、setvalue（设置值）
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
			// CDP 规范里的修饰键位掩码：Alt=1、Ctrl=2、Meta=4、Shift=8
			modifiers |= match mod.to_lower() {
				'alt' { 1 }
				'control', 'ctrl' { 2 }
				'meta', 'command' { 4 }
				'shift' { 8 }
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
	js := build_element_scope_js(mut sess, sel, 'if(!el) return false; el.value=${js_str(value)}; el.dispatchEvent(new Event("input",{bubbles:true})); el.dispatchEvent(new Event("change",{bubbles:true})); return true;')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	// 页面脚本抛异常时必须报错，不能当成选择成功
	evaluate_result_value(resp.result) or { return 'ERROR:${err}' }
	return 'null'
}

// cmd_check 勾选复选框或单选按钮
fn cmd_check(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action_by_selector(mut sess, sel, build_toggle_action_body(true)) or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// cmd_uncheck 取消勾选复选框
fn cmd_uncheck(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	run_element_action_by_selector(mut sess, sel, build_toggle_action_body(false)) or {
		return 'ERROR:${err}'
	}
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
		js := build_document_scope_js(mut sess, 'win.scrollBy(${dx}, ${dy}); return true;')
		sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
			return 'ERROR:${err}'
		}
	}
	return 'null'
}

// cmd_scrollintoview 将元素滚动到视口中
// 默认将元素滚动到视口中央
fn cmd_scrollintoview(mut sess CdpSession, params string) string {
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}
	js := build_element_scope_js(mut sess, sel, "el?.scrollIntoView({block:'center',inline:'center'})")
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// cmd_drag 拖拽元素
// 支持参数：source（源选择器）、target（目标选择器）
// 拖拽过程分10步平滑移动
fn cmd_drag(mut sess CdpSession, params string) string {
	src := cdp_extract_str(params, 'source')
	tgt := cdp_extract_str(params, 'target')
	if src == '' || tgt == '' {
		return 'ERROR:missing source or target'
	}
	src_el := resolve_selector(mut sess, src) or { return 'ERROR:src: ${err}' }
	tgt_el := resolve_selector(mut sess, tgt) or { return 'ERROR:tgt: ${err}' }

	// mousePressed → mouseMoved (steps) → mouseReleased
	// 各阶段的 CDP 错误必须往外抛，否则拖拽失败会被当成成功。
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mousePressed","x":${src_el.x},"y":${src_el.y},"button":"left","clickCount":1}') or {
		return 'ERROR:${err}'
	}
	// 分 10 步移动
	for step in 1 .. 11 {
		t := f64(step) / 10.0
		mx := src_el.x + (tgt_el.x - src_el.x) * t
		my := src_el.y + (tgt_el.y - src_el.y) * t
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseMoved","x":${mx},"y":${my},"button":"left"}') or {
			// 已经按下鼠标，中途失败要尽力补发释放事件，避免页面一直处于按下状态
			sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${mx},"y":${my},"button":"left"}') or {}
			return 'ERROR:${err}'
		}
		time.sleep(10 * time.millisecond)
	}
	sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${tgt_el.x},"y":${tgt_el.y},"button":"left"}') or {
		message := err.msg()
		sess.send_command('Input.dispatchMouseEvent', '{"type":"mouseReleased","x":${tgt_el.x},"y":${tgt_el.y},"button":"left"}') or {}
		return 'ERROR:${message}'
	}
	return 'null'
}

// cmd_upload 上传文件到文件输入框
// 支持参数：
//   - selector：文件输入框选择器
//   - files：逗号分隔的文件路径列表
//   - waitPreview：是否等待预览更新
//   - previewSelector：预览元素选择器
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

// cmd_get 获取页面或元素的属性值
// 支持参数：
//   - selector：元素选择器
//   - property：属性类型（text/html/value/title/url/count/attr/box/styles）
//   - attr：当 property 为 attr 时，指定属性名
fn cmd_get(mut sess CdpSession, params string) string {
	prop := cdp_extract_str(params, 'property')
	sel := cdp_extract_str(params, 'selector')

	js := match prop {
		'text' {
			build_element_scope_js(mut sess, sel, 'return el?.textContent;')
		}
		'html' {
			build_element_scope_js(mut sess, sel, 'return el?.innerHTML;')
		}
		'value' {
			build_element_scope_js(mut sess, sel, 'return el?.value;')
		}
		'title' {
			'document.title'
		}
		'url' {
			'window.location.href'
		}
		'count' {
			build_elements_scope_js(mut sess, sel, 'return els.length;')
		}
		'attr' {
			attr := cdp_extract_str(params, 'attr')
			build_element_scope_js(mut sess, sel, 'return el?.getAttribute(${js_str(attr)});')
		}
		'box' {
			if sel == '' {
				return 'ERROR:missing selector'
			}
			build_rect_query_js(mut sess, sel)
		}
		'styles' {
			build_element_scope_js(mut sess, sel, 'return el?JSON.stringify(Object.fromEntries(Object.entries(getComputedStyle(el)))):null;')
		}
		else {
			return 'ERROR:unknown property: ${prop}'
		}
	}

	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	// #36: box 分支需要把 "元素不存在"（JS 返回 null）转成 ERROR，
	// 跟 click / is / wait 等命令保持一致；不然用户拿到的 'null'
	// 无法区分 "元素不存在" 和 "元素 rect 为 0"。
	if prop == 'box' {
		result_obj := cdp_extract_obj_key(resp.result, '"result":')
		value_obj := cdp_extract_obj_key(result_obj, '"value":')
		if value_obj == '' || value_obj == 'null' {
			return 'ERROR:element not found: ${sel}'
		}
		return json_str(value_obj)
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	return json_str(cdp_extract_value_from_result(result))
}

// cmd_is 检查元素的状态
// 支持参数：
//   - selector：元素选择器
//   - state：状态类型（visible/hidden/editable/checked/selected/disabled/enabled）
fn cmd_is(mut sess CdpSession, params string) string {
	state := cdp_extract_str(params, 'state')
	sel := cdp_extract_str(params, 'selector')
	if sel == '' {
		return 'ERROR:missing selector'
	}

	js := match state {
		// visible：排除 visibility:hidden、display:none、opacity:0 以及零尺寸元素
		'visible' {
			build_element_scope_js(mut sess, sel, "if(!el) return false; var r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false; var s=getComputedStyle(el); return s.visibility!=='hidden'&&s.display!=='none'&&s.opacity!=='0';")
		}
		'enabled' {
			build_element_scope_js(mut sess, sel, 'return !el?.disabled;')
		}
		'checked' {
			build_element_scope_js(mut sess, sel, 'return !!el?.checked;')
		}
		// disabled
		'disabled' {
			build_element_scope_js(mut sess, sel, 'return !!el?.disabled;')
		}
		// focused：是否是当前获得焦点的元素
		'focused' {
			build_element_scope_js(mut sess, sel, 'return el === doc.activeElement;')
		}
		// selected：option 被选中 或 aria-selected=true
		'selected' {
			build_element_scope_js(mut sess, sel, "return el?.selected === true || el?.getAttribute('aria-selected') === 'true';")
		}
		// editable：可编辑（非只读、非禁用)
		'editable' {
			build_element_scope_js(mut sess, sel, "if(!el) return false; if(el.disabled) return false; if(el.readOnly) return false; return el.isContentEditable || 'value' in el;")
		}
		// expanded：aria-expanded=true
		'expanded' {
			build_element_scope_js(mut sess, sel, "return el?.getAttribute('aria-expanded') === 'true';")
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

// cmd_wait 等待各种条件
// 支持参数：
//   - ms：等待毫秒数
//   - download：等待下载完成
//   - timeout：超时毫秒数
//   - selector/expected：等待元素文本/值达到期望
//   - navigation：等待导航完成
fn cmd_wait(mut sess CdpSession, params string) string {
	// wait <ms>
	ms_str := cdp_extract_obj_key(params, '"ms":')
	if ms_str != '' && ms_str != 'null' {
		ms := ms_str.int()
		time.sleep(ms * time.millisecond)
		return 'null'
	}
	// wait --download：只有请求里带 download 字段才走下载等待，
	// 否则 --stable --timeout 会被误判成下载等待。
	has_download := cdp_extract_obj_key(params, '"download":') != ''
	download_path := cdp_extract_str(params, 'download')
	timeout_ms := cdp_extract_int(params, '"timeout":')
	if has_download {
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
		// #39: CLI 通用 flag 解析在 --load 不带值时默认赋值为字符串 'true'，
		// 这里把 'true' 当作 'load' 的别名，向后兼容 --load 和 --load load 两种写法。
		state := if load == 'true' { 'load' } else { load }
		return wait_load(mut sess, state)
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

// wait_load 等待页面加载事件
// 支持状态参数控制等待时机
fn wait_load(mut sess CdpSession, state string) string {
	if state == 'networkidle' {
		// 显式打开 lifecycle 事件上报 + 固定 deadline + frame/loader 关联
		wait_for_networkidle(mut sess, 30 * time.second) or { return 'ERROR:${err}' }
		return 'null'
	}
	event := match state {
		'load' {
			'Page.loadEventFired'
		}
		'domcontentloaded' {
			'Page.domContentEventFired'
		}
		else {
			return 'ERROR:unknown load state: ${state}'
		}
	}
	ch := sess.subscribe(event)
	defer { sess.unsubscribe(event, ch) }
	select {
		_ := <-ch {
		}
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
		js := build_document_scope_js(mut sess, 'return doc.body?.innerText;')
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

// wait_fn 等待 JavaScript 表达式返回真值
// 轮询执行表达式直到返回 true 或超时
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
		js := build_element_scope_js(mut sess, sel, 'if(!el) return false; var r=el.getBoundingClientRect(); return r.width>0&&r.height>0;')
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
// wait_stable 等待元素稳定（位置和内容不再变化）
// 用于等待动态内容渲染完成
fn wait_stable(mut sess CdpSession, sel string, timeout time.Duration) string {
	deadline := time.now().add(timeout)
	poll_interval := 300 * time.millisecond
	settled_threshold := 2 // 连续相同次数
	js := build_element_scope_js(mut sess, sel, "if(!el) return null; return el.innerText||el.value||'';")
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

// cmd_find 使用语义定位器查找元素
// 支持参数：
//   - locator：定位器类型（role/text/placeholder/label/title/alt/testid等）
//   - query：语义查询文本
//   - action：找到后执行的动作（click/hover等）
//   - value：action的参数值
//   - exact：是否精确匹配
//   - name：ARIA name 过滤
//   - index：返回第 N 个匹配（从0开始）
//   - debug：调试模式
//   - list：列表模式，返回所有匹配
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
	js := build_semantic_locator_js(mut sess, locator, query, exact, name_filter, index)
	return exec_semantic_action(mut sess, js, locator, action, value)
}

fn semantic_text_candidates_report(mut sess CdpSession, query string, exact bool, selected_index int, limit int, mode string) string {
	js := build_semantic_text_report_js(mut sess, query, exact, selected_index, limit,
		mode)
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

fn build_semantic_text_report_js(mut sess CdpSession, query string, exact bool, selected_index int, limit int, mode string) string {
	query_js := js_str(query)
	selected_index_js := '${selected_index}'
	limit_js := '${limit}'
	mode_js := js_str(mode)
	exact_js := if exact { 'true' } else { 'false' }
	return build_document_scope_js(mut sess, '
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

fn build_semantic_locator_js(mut sess CdpSession, locator string, query string, exact bool, name_filter string, index int) string {
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
	return build_document_scope_js(mut sess, '
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
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; el.focus?.(); if ("value" in el) el.value = ${js_str(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'type' {
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; el.focus?.(); if ("value" in el) el.value = String(el.value || "") + ${js_str(value)}; el.dispatchEvent(new Event("input", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'text' {
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; return el.innerText || el.textContent || "";')
			return evaluate_semantic_result(mut sess, js, locator, true)
		}
		'focus' {
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; el.focus?.(); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'check' {
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; if ("checked" in el) el.checked = true; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
			return evaluate_semantic_result(mut sess, js, locator, false)
		}
		'uncheck' {
			js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return null; if ("checked" in el) el.checked = false; el.dispatchEvent(new Event("input", { bubbles: true })); el.dispatchEvent(new Event("change", { bubbles: true })); return true;')
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
	js := build_semantic_action_js(mut sess, locator_js, 'if (!el) return false; el.scrollIntoView({block:"center",inline:"center"}); ${body}')
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	ok := eval_prepared_js(mut sess, js, false) or {
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

fn build_semantic_action_js(mut sess CdpSession, locator_js string, body string) string {
	return build_document_scope_js(mut sess, 'var el = (${locator_js}); ${body}')
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

// apply_action 对已解析的元素执行动作
// 支持的 action：click、hover、focus、fill、check、uncheck、select 等
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
			js := build_element_scope_js(mut sess, sel, 'return el?.textContent;')
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

// cmd_tab 管理标签页
// 支持 action：
//   - list：列出所有标签页
//   - new：创建新标签页（可指定url）
//   - switch：切换到指定标签页（通过tabId或windowId）
//   - close：关闭当前标签页
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

// cmd_window 管理浏览器窗口
// 支持 action：new（创建新窗口，可指定url）
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

// cmd_mouse 执行鼠标操作
// 支持 action：
//   - move：移动鼠标到坐标
//   - down：按下鼠标按钮
//   - up：释放鼠标按钮
//   - wheel：鼠标滚轮滚动
// 参数：x、y坐标，button（left/right/middle），dx/dy（滚轮增量）
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

// cmd_cookies 管理浏览器 Cookie
// 支持 action：
//   - get/list：获取所有 Cookie
//   - set：设置 Cookie（需要 name、value、domain）
//   - delete：删除 Cookie
//   - clear：清空所有 Cookie
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

// cmd_storage 管理浏览器 Web Storage
// 支持参数：
//   - type：存储类型（local/localStorage 或 session/sessionStorage）
//   - action：操作类型（get、set、clear）
//   - key：键名
//   - value：值（set时使用）
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

// ─── Fetch 拦截（route + HTTP 基本认证）────────────────────────────
//
// route 与 HTTP 基本认证都落在 CDP 的 Fetch 域：Fetch.enable 的参数
// （patterns / handleAuthRequests）会被后一次调用整体覆盖，
// 因此两者必须合并成一次 Fetch.enable 下发，并由同一个消费者协程
// 统一处理 Fetch.requestPaused 与 Fetch.authRequired 两种事件：
//   - requestPaused：按 route 规则 abort / fulfill / continue；
//     没有 route 规则时也必须 continueRequest，否则请求会一直挂在 Fetch 队列里。
//   - authRequired：只对目标 origin 回 ProvideCredentials，
//     其它 origin 一律交回浏览器默认处理，凭据不会外泄给第三方站点。
//
// CdpSession 定义在 cdp_session.v（本次不允许修改），加不了新字段，
// 所以这里用函数级 static 表按会话地址保存 Fetch 配置：
// static 变量不依赖 -enable-globals，且进程内唯一。

struct FetchRouteConfig {
mut:
	active  bool
	pattern string
	abort   bool
	body    string
}

struct FetchAuthConfig {
mut:
	active   bool
	username string
	password string
	origin   string
}

struct FetchSessionConfig {
mut:
	route                  FetchRouteConfig
	auth                   FetchAuthConfig
	interceptor_generation int
	interceptor_running    bool
	paused_ch              chan ProtocolResponse
	auth_ch                chan ProtocolResponse
	stop_ch                chan bool
	// commands.v 独立保存新增状态，避免修改并行维护的 CdpSession 结构。
	watch_generation   string
	saving_request_ids map[string]bool
	poll_document_ids  map[string]string
}

@[unsafe]
fn fetch_config_table() &map[u64]FetchSessionConfig {
	mut static table := &map[u64]FetchSessionConfig{}
	return table
}

@[unsafe]
fn fetch_config_mutex() &sync.Mutex {
	mut static m := &sync.Mutex{}
	return m
}

// fetch_session_key 用会话对象地址作为会话标识。
fn fetch_session_key(mut sess CdpSession) u64 {
	return unsafe { u64(voidptr(&sess.next_id)) }
}

// fetch_config_snapshot 读取当前会话的 Fetch 配置快照。
fn fetch_config_snapshot(mut sess CdpSession) FetchSessionConfig {
	key := fetch_session_key(mut sess)
	unsafe {
		fetch_config_mutex().lock()
		cfg := fetch_config_table()[key]
		fetch_config_mutex().unlock()
		return cfg
	}
}

// fetch_config_update 修改当前会话的 Fetch 配置。
fn fetch_config_update(mut sess CdpSession, mutator fn (mut FetchSessionConfig)) {
	key := fetch_session_key(mut sess)
	unsafe {
		fetch_config_mutex().lock()
		mut cfg := fetch_config_table()[key]
		mutator(mut cfg)
		fetch_config_table()[key] = cfg
		fetch_config_mutex().unlock()
	}
}

// fetch_config_set_route 写入 route 拦截规则。
fn fetch_config_set_route(mut sess CdpSession, pattern string, abort bool, body string) {
	fetch_config_update(mut sess, fn [pattern, abort, body] (mut cfg FetchSessionConfig) {
		cfg.route.active = true
		cfg.route.pattern = pattern
		cfg.route.abort = abort
		cfg.route.body = body
	})
}

// fetch_config_clear_route 清掉 route 规则（认证配置保留）。
fn fetch_config_clear_route(mut sess CdpSession) {
	fetch_config_update(mut sess, fn (mut cfg FetchSessionConfig) {
		cfg.route.active = false
		cfg.route.pattern = ''
		cfg.route.abort = false
		cfg.route.body = ''
	})
}

// fetch_config_set_auth 写入 HTTP 基本认证凭据与目标 origin。
fn fetch_config_set_auth(mut sess CdpSession, username string, password string, origin string) {
	fetch_config_update(mut sess, fn [username, password, origin] (mut cfg FetchSessionConfig) {
		cfg.auth.active = true
		cfg.auth.username = username
		cfg.auth.password = password
		cfg.auth.origin = origin
	})
}

// 认证要接收所有 origin 的挑战，route 在消费者中再按 URL 匹配。
fn fetch_enable_params(mut sess CdpSession) string {
	cfg := fetch_config_snapshot(mut sess)
	pattern := if cfg.auth.active || cfg.route.pattern == '' { '*' } else { cfg.route.pattern }
	return '{"patterns":[{"urlPattern":${json_str(pattern)}}],"handleAuthRequests":${cfg.auth.active}}'
}

fn cdp_session_closed(mut sess CdpSession) bool {
	sess.pending_mu.@lock()
	closed := sess.closed
	sess.pending_mu.unlock()
	return closed
}

// 消费者跟随 session，不因空闲退出；替换 route 时复用订阅，避免丢失暂停请求。
fn ensure_fetch_interceptor(mut sess CdpSession, replace bool) {
	key := fetch_session_key(mut sess)
	previous := fetch_config_snapshot(mut sess)
	if previous.interceptor_running && !replace {
		return
	}
	paused_ch := if previous.interceptor_running {
		previous.paused_ch
	} else {
		sess.subscribe('Fetch.requestPaused')
	}
	auth_ch := if previous.interceptor_running {
		previous.auth_ch
	} else {
		sess.subscribe('Fetch.authRequired')
	}
	stop_ch := chan bool{cap: 1}
	generation := previous.interceptor_generation + 1
	fetch_config_update(mut sess, fn [generation, paused_ch, auth_ch, stop_ch] (mut cfg FetchSessionConfig) {
		cfg.interceptor_generation = generation
		cfg.interceptor_running = true
		cfg.paused_ch = paused_ch
		cfg.auth_ch = auth_ch
		cfg.stop_ch = stop_ch
	})
	if previous.interceptor_running {
		previous.stop_ch <- true
	}
	sess.route_ch = paused_ch
	sess.route_stop_ch = stop_ch
	spawn fn [mut sess, key, generation, paused_ch, auth_ch, stop_ch] () {
		for {
			if cdp_session_closed(mut sess) { break }
			select {
				evt := <-paused_ch {
					handle_fetch_request_paused(mut sess, evt)
				}
				evt := <-auth_ch {
					handle_fetch_auth_required(mut sess, evt)
				}
				_ := <-stop_ch {
					break
				}
				1 * time.second {
				}
			}
		}
		// 旧消费者不能注销新消费者共享的订阅，更不能发送 Fetch.disable。
		unsafe {
			fetch_config_mutex().lock()
			if fetch_config_table()[key].interceptor_generation == generation {
				sess.unsubscribe('Fetch.requestPaused', paused_ch)
				sess.unsubscribe('Fetch.authRequired', auth_ch)
				fetch_config_table().delete(key)
			}
			fetch_config_mutex().unlock()
		}
	}()
}

fn handle_fetch_request_paused(mut sess CdpSession, evt ProtocolResponse) {
	// 结构化解析事件参数：子串搜索会命中嵌套层级里的同名字段
	// （例如 request 内部的 requestId），取到错误的请求 ID。
	params := cdp_json_object(evt.params)
	request_id := cdp_json_str(params, 'requestId')
	if request_id == '' { return }
	cfg := fetch_config_snapshot(mut sess)
	request := cdp_json_object_field(params, 'request')
	url := cdp_json_str(request, 'url')
	matched := cfg.route.active && fetch_url_matches(cfg.route.pattern, url)
	if matched && cfg.route.abort {
		sess.send_command('Fetch.failRequest', '{"requestId":${json_str(request_id)},"errorReason":"Aborted"}') or {}
	} else if matched && cfg.route.body != '' {
		sess.send_command('Fetch.fulfillRequest', '{"requestId":${json_str(request_id)},"responseCode":200,"body":${json_str(base64.encode_str(cfg.route.body))}}') or {}
	} else {
		// 只开启认证时，普通请求也会暂停，必须放行。
		sess.send_command('Fetch.continueRequest', '{"requestId":${json_str(request_id)}}') or {}
	}
}

// CDP URL 模式支持 *、? 和反斜杠转义，不使用文件路径 glob 语义。
fn fetch_url_matches(pattern string, url string) bool {
	if pattern == '' { return true }
	mut row := []bool{len: url.len + 1}
	row[0] = true
	mut i := 0
	for i < pattern.len {
		mut ch := pattern[i]
		mut escaped := false
		if ch == `\\` && i + 1 < pattern.len {
			i++
			ch = pattern[i]
			escaped = true
		}
		mut next := []bool{len: url.len + 1}
		if ch == `*` && !escaped {
			next[0] = row[0]
			for j in 1 .. next.len { next[j] = row[j] || next[j - 1] }
		} else {
			for j in 1 .. next.len {
				next[j] = row[j - 1] && ((ch == `?` && !escaped) || ch == url[j - 1])
			}
		}
		row = next.clone()
		i++
	}
	return row[url.len]
}

fn handle_fetch_auth_required(mut sess CdpSession, evt ProtocolResponse) {
	// 结构化解析事件参数：子串搜索会命中嵌套层级里的同名字段
	// （例如 authChallenge 内部的 requestId），取到错误的请求 ID。
	params := cdp_json_object(evt.params)
	request_id := cdp_json_str(params, 'requestId')
	if request_id == '' { return }
	cfg := fetch_config_snapshot(mut sess)
	challenge := cdp_json_object_field(params, 'authChallenge')
	origin := cdp_json_str(challenge, 'origin')
	challenge_source := cdp_json_str(challenge, 'source')
	// 代理认证不能使用站点凭据，即使代理地址与目标 origin 相同。
	if cfg.auth.active && challenge_source == 'Server'
		&& auth_origin_matches(origin, cfg.auth.origin) {
		sess.send_command('Fetch.continueWithAuth', '{"requestId":${json_str(request_id)},"authChallengeResponse":{"response":"ProvideCredentials","username":${json_str(cfg.auth.username)},"password":${json_str(cfg.auth.password)}}}') or {}
	} else {
		sess.send_command('Fetch.continueWithAuth', '{"requestId":${json_str(request_id)},"authChallengeResponse":{"response":"Default"}}') or {}
	}
}

fn auth_origin_matches(challenge_origin string, target_origin string) bool {
	target := normalize_auth_origin(target_origin)
	return target != '' && normalize_auth_origin(challenge_origin) == target
}

fn normalize_auth_origin(raw string) string {
	text := raw.trim_space()
	sep := text.index('://') or { return '' }
	scheme := text[..sep].to_lower()
	if scheme !in ['http', 'https'] { return '' }
	rest := text[sep + 3..]
	mut end := rest.len
	for i, ch in rest {
		if ch in [`/`, `?`, `#`] {
			end = i
			break
		}
	}
	mut host := rest[..end].to_lower()
	if host == '' || host.contains('@') || host.contains('\\') || host.contains(' ') { return '' }
	if (scheme == 'http' && host.ends_with(':80')) || (scheme == 'https' && host.ends_with(':443')) {
		host = host.all_before_last(':')
	}
	return '${scheme}://${host}'
}

fn current_page_origin(mut sess CdpSession) !string {
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str('String(location.origin || "")')},"returnByValue":true}')!
	origin := normalize_auth_origin(evaluate_result_value(resp.result)!)
	if origin == '' { return error('cannot determine target origin for credentials') }
	return origin
}

// cmd_network 网络请求管理
// 支持 action：
//   - requests：列出网络请求（支持 filter/mime/status/domain/type 过滤）
//   - body：获取请求/响应体（需要 requestId）
//   - save：保存响应到文件（需要 requestId、path）
//   - save-images：批量保存图片
//   - replay：重放请求
fn cmd_network(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	match action {
		'requests' {
			f := NetworkFilter{
				url:    cdp_extract_str(params, 'filter')
				mime:   cdp_extract_str(params, 'mime')
				status: cdp_extract_str(params, 'status')
				domain: cdp_extract_str(params, 'domain')
				rtype:  cdp_extract_str(params, 'type')
			}
			cache_body := cdp_extract_str(params, 'captureBody') == 'true'
			limit := cdp_extract_str(params, 'limit').int()
			sess.enable_network_tracking() or { return 'ERROR:${err}' }
			if cache_body {
				sess.network_mu.@lock()
				sess.auto_body_cache = true
				sess.network_mu.unlock()
			}
			return sess.network_requests_json(f, limit)
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
			previous := fetch_config_snapshot(mut sess).route
			fetch_config_set_route(mut sess, url, abort, body)
			ensure_fetch_interceptor(mut sess, true)
			sess.send_command('Fetch.enable', fetch_enable_params(mut sess)) or {
				fetch_config_update(mut sess, fn [previous] (mut cfg FetchSessionConfig) {
					cfg.route = previous
				})
				return 'ERROR:${err}'
			}
			sess.has_route = true
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
			previous := fetch_config_snapshot(mut sess).route
			fetch_config_clear_route(mut sess)
			method := if fetch_config_snapshot(mut sess).auth.active {
				'Fetch.enable'
			} else {
				'Fetch.disable'
			}
			fetch_params := if method == 'Fetch.enable' {
				fetch_enable_params(mut sess)
			} else {
				'{}'
			}
			sess.send_command(method, fetch_params) or {
				fetch_config_update(mut sess, fn [previous] (mut cfg FetchSessionConfig) {
					cfg.route = previous
				})
				return 'ERROR:${err}'
			}
			// 保留消费者至 session 关闭，继续处理在途事件和认证挑战。
			sess.has_route = false
			return 'null'
		}
		'inspect' {
			f := NetworkFilter{
				url:    cdp_extract_str(params, 'filter')
				mime:   cdp_extract_str(params, 'mime')
				status: cdp_extract_str(params, 'status')
				domain: cdp_extract_str(params, 'domain')
				rtype:  cdp_extract_str(params, 'type')
			}
			limit := cdp_extract_str(params, 'limit').int()
			sess.enable_network_tracking() or { return 'ERROR:${err}' }
			sync_network_hook_records(mut sess) or {}
			return network_inspect_records_json(mut sess, f, limit)
		}
		else {
			return 'ERROR:unknown network action: ${action}'
		}
	}
}

// network_inspect_records_json 合并 CDP tracked requests 与 hook records，
// 按请求签名计数去重，输出统一视图。CDP 记录优先填充 requestId/status，
// hook 记录补充 requestBody/responseBody。
fn network_inspect_records_json(mut sess CdpSession, f NetworkFilter, limit int) string {
	nf := normalize_network_filter(f)
	mut items := []string{}

	// 收集 hook records（源丰富，含 body）
	sess.hook_mu.@lock()
	mut seen_sig_counts := map[string]int{}
	for record_id in sess.hook_record_order {
		record := sess.hook_records[record_id] or { continue }
		view := hook_record_view_from_raw(record)
		if nf.url_lower != '' && !hook_record_matches_filter(view, nf.url_lower) {
			continue
		}
		if nf.mime != '' && !view.response_headers.to_lower().contains(nf.mime_lower) {
			continue
		}
		if nf.status != '' && !matches_status_filter(view.response_status, nf.status) {
			continue
		}
		if nf.domain != '' && !url_hostname(view.url).to_lower().contains(nf.domain_lower) {
			continue
		}
		// rtype 对 hook records 匹配 source 字段（fetch/xhr）
		if nf.rtype != '' && !view.source.to_lower().contains(nf.rtype_lower) {
			continue
		}
		sig := hook_record_dedupe_key(view)
		seen_sig_counts[sig] = seen_sig_counts[sig] + 1
		items << '{"source":"hook","recordId":${json_str(view.record_id)},"method":${json_str(view.method)},"url":${json_str(view.url)},"status":${view.response_status},"statusText":${json_str(view.status_text)},"requestBody":${json_str(view.request_body)},"responseBody":${json_str(view.response_body)},"requestHeaders":${view.request_headers},"responseHeaders":${view.response_headers},"timestamp":${view.timestamp}}'
		if limit > 0 && items.len >= limit {
			break
		}
	}
	sess.hook_mu.unlock()

	// 补充 CDP tracked requests（hook 未覆盖的）
	if limit <= 0 || items.len < limit {
		sess.network_mu.@lock()
		for request_id in sess.network_request_order {
			entry := sess.network_requests[request_id] or { continue }
			sig := tracked_request_dedupe_key(entry)
			if seen_sig_counts[sig] > 0 {
				seen_sig_counts[sig]--
				continue
			}
			if !matches_network_filter(entry, nf) {
				continue
			}
			items << '{"source":"cdp","requestId":${json_str(entry.request_id)},"method":${json_str(entry.method)},"url":${json_str(entry.url)},"status":${entry.status},"statusText":${json_str(entry.status_text)},"resourceType":${json_str(entry.resource_type)},"requestBody":${json_str(entry.request_body)},"responseBody":${json_str(entry.response_body)},"requestHeaders":${json_str(entry.request_headers)},"responseHeaders":${json_str(entry.response_headers)},"finished":${entry.finished}}'
			if limit > 0 && items.len >= limit {
				break
			}
		}
		sess.network_mu.unlock()
	}

	return '[' + items.join(',') + ']'
}

fn hook_record_dedupe_key(view RequestRecord) string {
	return '${view.method}|${view.url}|${view.request_body}|${view.response_status}'
}

fn tracked_request_dedupe_key(entry TrackedNetworkRequest) string {
	return '${entry.method}|${entry.url}|${entry.request_body}|${entry.status}'
}

fn network_hook_script_id(script_id string) string {
	return if script_id != '' { script_id } else { 'hook-v1' }
}

fn network_hook_config_js(filter string, capture_body bool, capture_response bool, clear bool, max_body_len int, script_id string) string {
	return 'window.__vBrowserHookConfig = window.__vBrowserHookConfig || {}; try { if (window.localStorage) { window.localStorage.setItem("__vBrowserHookActive", "true"); } } catch (err) {} try { if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookActive", "true"); } } catch (err) {} window.__vBrowserHookConfig.active = true; window.__vBrowserHookConfig.filter = ${json_str(filter)}; window.__vBrowserHookConfig.captureBody = ${capture_body}; window.__vBrowserHookConfig.captureResponse = ${capture_response}; window.__vBrowserHookConfig.maxBodyLen = ${max_body_len}; window.__vBrowserHookConfig.scriptId = ${json_str(script_id)}; try { var savedHookConfig = JSON.stringify(window.__vBrowserHookConfig); if (window.localStorage) { window.localStorage.setItem("__vBrowserHookConfig", savedHookConfig); } if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookConfig", savedHookConfig); } } catch (err) {} window.__vBrowserHookState = window.__vBrowserHookState || { events: [], nextId: 0 }; if (${clear}) { window.__vBrowserHookState.events = []; window.__vBrowserHookState.nextId = 0; } window.__vBrowserHookInstalled = true; "ok"'
}

fn network_hook_activate_js(filter string, capture_body bool, capture_response bool, clear bool, max_body_len int, script_id string) string {
	return '${network_hook_bootstrap_js()}; ${network_hook_config_js(filter, capture_body, capture_response, clear, max_body_len, script_id)}'
}

fn network_hook_stop_js() string {
	// 完整配置与旧的 __vBrowserHookActive 标记同步置 false，保证降级/旧 bootstrap 路径也不会误恢复
	return 'window.__vBrowserHookConfig = window.__vBrowserHookConfig || {}; window.__vBrowserHookConfig.active = false; try { if (window.localStorage) { window.localStorage.setItem("__vBrowserHookActive", "false"); } } catch (err) {} try { if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookActive", "false"); } } catch (err) {} try { var savedHookConfig = JSON.stringify(window.__vBrowserHookConfig); if (window.localStorage) { window.localStorage.setItem("__vBrowserHookConfig", savedHookConfig); } if (window.sessionStorage) { window.sessionStorage.setItem("__vBrowserHookConfig", savedHookConfig); } } catch (err) {} window.__vBrowserHookInstalled = true; "ok"'
}

fn apply_hook_js_to_default_contexts(mut sess CdpSession, js string) {
	if js == '' {
		return
	}
	context_ids := sess.default_execution_context_ids()
	for context_id in context_ids {
		sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"contextId":${context_id},"silent":true}') or {}
	}
}

fn start_network_hook(mut sess CdpSession, params string) !string {
	filter := cdp_extract_str(params, 'filter')
	capture_body := cdp_extract_str(params, 'captureBody') == 'true'
	capture_response := cdp_extract_str(params, 'captureResponse') == 'true'
	persistent := cdp_extract_str(params, 'persistent') != 'false'
	clear := cdp_extract_str(params, 'clear') != 'false'
	max_body_len := cdp_extract_str(params, 'maxBodyLen').int()
	all_frames := cdp_extract_str(params, 'allFrames') == 'true'
	script_id := network_hook_script_id(cdp_extract_str(params, 'scriptId'))
	install_network_hook(mut sess, script_id, persistent, false)!
	if clear {
		clear_network_hook_records(mut sess)
	}
	activate_js := network_hook_activate_js(filter, capture_body, capture_response, false,
		max_body_len, script_id)
	current_activate_js := if clear {
		network_hook_activate_js(filter, capture_body, capture_response, true, max_body_len,
			script_id)
	} else {
		activate_js
	}
	eval_scoped_expression(mut sess, current_activate_js, false)!
	sess.hook_mu.@lock()
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_state.script_id = script_id
	sess.hook_state.script_version = 4
	sess.hook_state.filter = filter
	sess.hook_state.capture_body = capture_body
	sess.hook_state.capture_response = capture_response
	sess.hook_state.max_body_len = max_body_len
	sess.hook_state.all_frames = all_frames
	sess.hook_state.activate_js = activate_js
	sess.hook_state.last_injected_at = time.now().unix_milli().str()
	if clear {
		sess.hook_state.last_synced_index = 0
		sess.hook_state.last_pushed_count = 0
		sess.hook_state.record_count = 0
	}
	sess.hook_mu.unlock()
	if all_frames {
		apply_hook_js_to_default_contexts(mut sess, current_activate_js)
	}
	return network_hook_status_json(mut sess)
}

fn stop_network_hook(mut sess CdpSession) string {
	stop_js := network_hook_stop_js()
	eval_scoped_expression(mut sess, stop_js, false) or {}
	sess.hook_mu.@lock()
	was_all_frames := sess.hook_state.all_frames
	sess.hook_state.active = false
	sess.hook_state.all_frames = false
	sess.hook_state.activate_js = ''
	sess.hook_mu.unlock()
	if was_all_frames {
		apply_hook_js_to_default_contexts(mut sess, stop_js)
	}
	return network_hook_status_json(mut sess)
}

fn network_hook_status_json(mut sess CdpSession) string {
	sync_network_hook_records(mut sess) or {}
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	return network_hook_status_json_from_state(sess.hook_state)
}

fn network_hook_status_json_from_state(state HookState) string {
	return '{"active":${state.active},"injected":${state.injected},"scriptId":${json_str(state.script_id)},"scriptVersion":${state.script_version},"filter":${json_str(state.filter)},"captureBody":${state.capture_body},"captureResponse":${state.capture_response},"maxBodyLen":${state.max_body_len},"allFrames":${state.all_frames},"lastInjectedAt":${json_str(state.last_injected_at)},"lastSyncedIndex":${state.last_synced_index},"recordCount":${state.record_count}}'
}

fn network_hook_records_json(mut sess CdpSession, params string) !string {
	sync_network_hook_records(mut sess) or { return error(err.msg()) }
	filter := cdp_extract_str(params, 'filter').to_lower()
	limit := cdp_extract_str(params, 'limit').int()
	format := cdp_extract_str(params, 'format').to_lower()
	f := NetworkFilter{
		mime:   cdp_extract_str(params, 'mime')
		status: cdp_extract_str(params, 'status')
		domain: cdp_extract_str(params, 'domain')
		rtype:  cdp_extract_str(params, 'type')
	}
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	mut items := []string{}
	for record_id in sess.hook_record_order {
		record := sess.hook_records[record_id] or { continue }
		view := hook_record_view_from_raw(record)
		if filter != '' && !hook_record_matches_filter(view, filter) {
			continue
		}
		if f.mime != '' && !view.response_headers.to_lower().contains(f.mime.to_lower()) {
			continue
		}
		if f.status != '' && !matches_status_filter(view.response_status, f.status) {
			continue
		}
		if f.domain != '' && !url_hostname(view.url).to_lower().contains(f.domain.to_lower()) {
			continue
		}
		if f.rtype != '' && !view.source.to_lower().contains(f.rtype.to_lower()) {
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
	override_body_provided := params.contains('"overrideBody":')
	override_body := if override_body_provided {
		cdp_extract_str(params, 'overrideBody')
	} else {
		cdp_extract_str(params, 'body')
	}
	mut override_headers := cdp_extract_str(params, 'overrideHeaders')
	dry_run := cdp_extract_str(params, 'dryRun') == 'true'
	// 只在锁内复制记录，后续 CDP 调用不能持有 hook_mu。
	sess.hook_mu.@lock()
	record := sess.hook_records[record_id] or {
		sess.hook_mu.unlock()
		return error('hook record not found: ${record_id}')
	}
	sess.hook_mu.unlock()
	method := if override_method != '' {
		override_method
	} else {
		cdp_extract_str(record.raw_json, 'method')
	}
	url := network_hook_replay_url_from_params(params, record)
	body := if override_body_provided || override_body != '' {
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
		response_status:  cdp_extract_int(raw, '"status":')
		status_text:      cdp_extract_str(raw, 'statusText')
		response_url:     cdp_extract_str(raw, 'responseUrl')
		response_ok:      cdp_extract_bool(raw, 'responseOk')
		response_type:    cdp_extract_str(raw, 'responseType')
		ready_state:      cdp_extract_int(raw, '"readyState":')
		with_credentials: cdp_extract_bool(raw, 'withCredentials')
		response_headers: if response_headers == '' { '{}' } else { response_headers }
		response_body:    response_body
		error_text:       cdp_extract_str(raw, 'errorText')
		timestamp:        cdp_extract_i64(raw, '"timestamp":')
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
	return '${method} ${hook_normalize_signature_url(url)} ${hook_request_body_signature(cdp_extract_str(raw, 'requestBody'))}'
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
	return '{' + rules.join(',') + '}'
}

fn hook_expected_shape_json(view RequestRecord) string {
	return '{"status":${view.response_status},"responseOk":${view.response_ok},"responseType":${json_str(view.response_type)},"statusText":${json_str(view.status_text)}}'
}

fn hook_template_from_signature(signature string, method string, url_pattern string, required_headers string, body_template string, transform_rules string, expected_response_shape string, record_ids []string, _sample string) ReplayTemplate {
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

fn install_network_hook(mut sess CdpSession, script_id string, persistent bool, force_install bool) !string {
	bootstrap_js := network_hook_bootstrap_js()
	sess.send_command('Runtime.enable', '{}')!
	// 注册 binding（幂等），使 JS 可直接推送记录，不再依赖轮询
	sess.send_command('Runtime.addBinding', '{"name":"__vBrowserHookPush"}') or {}
	if persistent {
		sess.hook_mu.@lock()
		should_install := force_install || !sess.hook_state.injected
			|| sess.hook_state.script_id != script_id || sess.hook_state.script_version != 4
		sess.hook_mu.unlock()
		if should_install {
			sess.send_command('Page.addScriptToEvaluateOnNewDocument', '{"source":${json_str(bootstrap_js)}}')!
			sess.hook_mu.@lock()
			sess.hook_state.injected = true
			sess.hook_state.script_id = script_id
			sess.hook_state.script_version = 4
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
	sess.hook_state.last_pushed_count = 0
	sess.hook_state.record_count = 0
	// 记录被清空，累计字节与已计数条数必须一起归零，
	// 否则后续的 push / poll 会按旧字节数继续淘汰。
	sess.hook_state.record_bytes = 0
	sess.hook_state.record_bytes_tracked = 0
	sess.hook_mu.unlock()
}

// append_polled_hook_records 把轮询同步回来的 hook 记录并入会话。
// 与 push 路径（handle_hook_binding_push）保持一致的上限约束：
//   - 单条 payload 超限直接丢弃；
//   - 累计字节计入 hook_state；
//   - 条数 / 字节超限时环形淘汰最旧的记录。
// 否则页面可以靠轮询路径把 daemon 内存撑爆（push 路径有淘汰，poll 路径没有）。
fn append_polled_hook_records(mut sess CdpSession, items []string, last_synced_index int) int {
	if items.len == 0 {
		return 0
	}
	mut added := 0
	sess.hook_mu.@lock()
	defer { sess.hook_mu.unlock() }
	// 外部路径（轮询同步 / push / clear）也会改记录集合，条数对不上时重新统计累计字节
	if sess.hook_records.len != sess.hook_state.record_bytes_tracked {
		sess.hook_state.record_bytes = hook_records_total_bytes(sess.hook_records)
		sess.hook_state.record_bytes_tracked = sess.hook_records.len
	}
	for item in items {
		record_id := cdp_extract_str(item, 'recordId')
		if record_id == '' {
			continue
		}
		// 单条 payload 上限：一条超长记录就能撑爆 daemon 内存
		if item.len > sess.hook_payload_limit {
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
		sess.hook_state.record_bytes += item.len
		sess.hook_state.record_bytes_tracked++
		added++
	}
	// 与 push 路径一致：条数 / 字节超限时环形淘汰最旧的记录
	sess.evict_hook_records()
	sess.hook_state.last_synced_index = last_synced_index + items.len
	sess.hook_state.record_count = sess.hook_record_order.len
	return added
}

fn sync_network_hook_records(mut sess CdpSession) !int {
	sess.hook_mu.@lock()
	last_synced_index := sess.hook_state.last_synced_index
	sess.hook_mu.unlock()
	scope := '${sess.current_tab_id}:${sess.current_frame_selector_value()}'
	previous_document := fetch_config_snapshot(mut sess).poll_document_ids[scope]
	// 在页面中先比较 documentId 再 slice，导航后不能沿用旧文档的游标。
	read_js := '(function(){ var s=window.__vBrowserHookState || {}; var events=s.events || []; var documentId=String(s.documentId || ""); var index=documentId === ${json_str(previous_document)} ? ${last_synced_index} : 0; if(index > events.length) index=0; return JSON.stringify({documentId:documentId,index:index,events:events.slice(index)}); })()'
	raw := eval_scoped_expression(mut sess, read_js, false)!
	if raw.trim_space() in ['', 'null', 'undefined'] { return 0 }
	document_id := cdp_extract_str(raw, 'documentId')
	index := cdp_extract_int(raw, '"index":')
	fetch_config_update(mut sess, fn [scope, document_id] (mut cfg FetchSessionConfig) {
		cfg.poll_document_ids[scope] = document_id
	})
	sess.hook_mu.@lock()
	sess.hook_state.last_synced_index = index
	sess.hook_mu.unlock()
	items := split_json_array_objects(cdp_extract_obj_key(raw, '"events":'))
	return append_polled_hook_records(mut sess, items, index)
}

fn network_hook_bootstrap_js() string {
	return [
		'(function() {',
		'  var SCRIPT_VERSION = 4;',
		// 旧包装器闭包捕获旧配置；停用旧配置后重新包装，不能只改版本号。
		'  if (window.__vBrowserHookInstalled && window.__vBrowserHookVersion !== SCRIPT_VERSION) {',
		'    var previous = window.__vBrowserHookConfig || {}, replacement = Object.assign({}, previous); previous.active = false; window.__vBrowserHookConfig = replacement;',
		'    if (window.fetch) { try { delete window.fetch.__vBrowserHookWrapped; } catch (e) {} }',
		'    if (window.XMLHttpRequest && window.XMLHttpRequest.prototype) { try { delete window.XMLHttpRequest.prototype.__vBrowserHookWrapped; } catch (e) {} }',
		'  }',
		'  var cfg = window.__vBrowserHookConfig = window.__vBrowserHookConfig || {};',
		'  try { var persistedConfig = JSON.parse((window.localStorage && window.localStorage.getItem("__vBrowserHookConfig")) || (window.sessionStorage && window.sessionStorage.getItem("__vBrowserHookConfig")) || "null"); if (persistedConfig && typeof persistedConfig === "object") { Object.keys(persistedConfig).forEach(function(key) { cfg[key] = persistedConfig[key]; }); } } catch (err) {}',
		'  if (cfg.active === undefined) { try { var legacyActive = window.localStorage && window.localStorage.getItem("__vBrowserHookActive"); if (legacyActive === null) { legacyActive = window.sessionStorage && window.sessionStorage.getItem("__vBrowserHookActive"); } if (legacyActive !== null) { cfg.active = legacyActive === "true"; } } catch (err) {} }',
		'  function readPersistedConfig() {',
		'    try {',
		'      var value = window.localStorage && window.localStorage.getItem("__vBrowserHookConfig");',
		'      if (value) { return JSON.parse(value); }',
		'      value = window.sessionStorage && window.sessionStorage.getItem("__vBrowserHookConfig");',
		'      if (value) { return JSON.parse(value); }',
		'    } catch (err) {}',
		'    return null;',
		'  }',
		'  var persistedConfig = readPersistedConfig();',
		'  if (persistedConfig && typeof persistedConfig === "object") { Object.keys(persistedConfig).forEach(function(key) { cfg[key] = persistedConfig[key]; }); }',
		'  var state = window.__vBrowserHookState = window.__vBrowserHookState || { events: [], nextId: 0 };',
		'  if (!state.documentId) { state.documentId = String(Date.now()) + "-" + Math.random().toString(36).slice(2); }',
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
		// 请求体只在 captureBody 打开时才采集：关闭时记空值，
		// 打开时按 maxBodyLen 截断，避免大 body 把内存和记录撑爆。
		'  function captureRequestBody(value) {',
		'    if (!cfg.captureBody) { return ""; }',
		'    try { return truncateBodyBytes(normalizeBody(value)); } catch (e) { return ""; }',
		'  }',
		'  function bodyByteLimit() { return Math.min(cfg.maxBodyLen > 0 ? cfg.maxBodyLen : 4000, 1048576); }',
		'  function truncateBodyBytes(value) {',
		'    var text = String(value == null ? "" : value), limit = bodyByteLimit(), bytes = 0, end = 0;',
		'    for (var ch of text) {',
		'      var cp = ch.codePointAt(0), size = cp <= 127 ? 1 : cp <= 2047 ? 2 : cp <= 65535 ? 3 : 4;',
		'      if (bytes + size > limit) { break; }',
		'      bytes += size; end += ch.length;',
		'    }',
		'    return text.slice(0, end);',
		'  }',
		'  function shouldCapture(method, url) {',
		'    var filter = String(cfg.filter || "");',
		'    if (!filter) { return true; }',
		'    var haystack = String(method || "") + " " + String(url || "");',
		'    return haystack.toLowerCase().indexOf(filter.toLowerCase()) >= 0;',
		'  }',
		'  function pushRecord(record) {',
		'    record.recordId = String(state.documentId) + ":" + String(++state.nextId);',
		'    record.scriptId = String(cfg.scriptId || "");',
		'    record.pageUrl = String(location.href || "");',
		'    record.timestamp = Date.now();',
		'    state.events.push(record);',
		'    if (state.events.length > 1000) { state.events.splice(0, state.events.length - 1000); }',
		'    try { if (typeof window.__vBrowserHookPush === "function") { window.__vBrowserHookPush(JSON.stringify(record)); } } catch (e) {}',
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
		'        if (cfg.captureBody) { body = captureRequestBody(input.body); }',
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
		'        if (cfg.captureBody && init.body !== undefined) { body = captureRequestBody(init.body); }',
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
		'    var responseBodyLimit = cfg.maxBodyLen === 0 ? 0 : (cfg.maxBodyLen || 4000);',
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
		'      responseBody: responseBody ? truncateText(responseBody, responseBodyLimit) : "",',
		'      responseHeaders: response && typeof response.headers === "object" && response.headers ? toPlainHeaders(response.headers) : {},',
		'      errorText: error ? truncateText(error, 2000) : ""',
		'    });',
		'  }',
		'  function captureXhrResult(meta, xhr, errorText) {',
		'    var responseBody = "";',
		'    var responseBodyLimit = cfg.maxBodyLen === 0 ? 0 : (cfg.maxBodyLen || 4000);',
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
		'      responseBody: responseBody ? truncateText(responseBody, responseBodyLimit) : "",',
		'      responseHeaders: parseXhrHeaders(xhr.getAllResponseHeaders ? xhr.getAllResponseHeaders() : ""),',
		'      errorText: errorText ? truncateText(errorText, 2000) : ""',
		'    });',
		'  }',
		// 响应体抓取必须与页面请求解耦：流式响应（SSE 等）永远读不完，
		// 如果等 clone().text() 结束才把 Response 交回页面，页面的 fetch 会一直挂住。
		// 这里改成：clone 出来的流在后台按字节上限 + 超时读取，读完再补一条记录。
		'  function captureFetchResponse(meta, response) {',
		'    var finished = false, reader, timer, limit = bodyByteLimit();',
		'    function cancel() {',
		'      try { if (reader) { Promise.resolve(reader.cancel()).catch(function() {}); } } catch (e) {}',
		'    }',
		'    function finish(text) {',
		'      if (finished) { return; }',
		'      finished = true; clearTimeout(timer);',
		'      try { captureFetchResult(meta, response, null, truncateBodyBytes(text)); } catch (e) {}',
		'    }',
		'    if (!cfg.captureResponse || !response || typeof response.clone !== "function") { finish(""); return; }',
		'    try {',
		'      var stream = response.clone().body;',
		'      if (!stream || typeof stream.getReader !== "function") { finish(""); return; }',
		'      reader = stream.getReader();',
		'      var decoder = new TextDecoder("utf-8"), text = "", total = 0;',
		'      timer = setTimeout(function() { cancel(); finish(text); }, 5000);',
		'      function pump() {',
		'        Promise.resolve().then(function() { return reader.read(); }).then(function(part) {',
		'          if (finished) { return; }',
		'          if (part.done) { finish(text + decoder.decode()); return; }',
		'          if (part.value) {',
		'            var bytes = part.value.subarray(0, limit - total);',
		'            total += bytes.byteLength;',
		'            text += decoder.decode(bytes, { stream: true });',
		'            if (total >= limit) { cancel(); finish(text); return; }',
		'          }',
		'          pump();',
		'        }).catch(function() { cancel(); finish(""); });',
		'      }',
		'      pump();',
		'    } catch (err) { cancel(); finish(""); }',
		'  }',
		'  var originalFetch = window.fetch;',
		'  if (typeof originalFetch === "function" && !originalFetch.__vBrowserHookWrapped) {',
		'    var fetchWrapper = function(input, init) {',
		'      if (!cfg.active) { return originalFetch.apply(this, arguments); }',
		'      var meta = captureFetchRequest(input, init);',
		'      if (!shouldCapture(meta.method, meta.url)) { return originalFetch.apply(this, arguments); }',
		'      try {',
		'        var pending = originalFetch.apply(this, arguments);',
		// 立刻把原始 Response 交回页面，抓取在后台异步进行
		'        var tracked = pending.then(function(response) {',
		'          try { captureFetchResponse(meta, response); } catch (e) {}',
		'          return response;',
		'        }, function(error) {',
		'          captureFetchResult(meta, null, error, "");',
		'          throw error;',
		'        });',
		// 派生 promise 的 rejection 已经处理过，避免变成未捕获异常
		'        tracked.catch(function() {});',
		'        return pending;',
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
		'      var meta = Object.assign({}, xhr.__vBrowserHookMeta || { method: "GET", url: "", headers: {}, body: "" });',
		'      meta.body = captureRequestBody(body);',
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
	body := sess.get_response_body_bytes(request_id)!
	entry := sess.network_request_snapshot(request_id)!
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
	for entry in sess.network_request_entries_snapshot() {
		request_id := entry.request_id
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
	generation := rand.uuid_v4()
	fetch_config_update(mut sess, fn [generation] (mut cfg FetchSessionConfig) {
		cfg.watch_generation = generation
		cfg.saving_request_ids = map[string]bool{}
	})
	sess.network_watch.active = true
	sess.network_watch.target_dir = target_dir
	sess.network_watch.filter = filter
	sess.network_watch.candidate_urls = map[string]bool{}
	sess.network_watch.saved_request_ids = map[string]bool{}
	sess.network_watch.failed_count = 0
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
	sess.network_watch.failed_count = 0
	sess.network_watch.next_index = 0
	sess.network_watch_mu.unlock()
	return '{"ok":true,"active":${active},"targetDir":${json_str(target_dir)},"filter":${json_str(filter)},"candidateCount":${candidate_count},"savedCount":${saved_count}}'
}

fn network_watch_status_json(mut sess CdpSession) string {
	sess.network_watch_mu.@lock()
	defer { sess.network_watch_mu.unlock() }
	return '{"active":${sess.network_watch.active},"targetDir":${json_str(sess.network_watch.target_dir)},"filter":${json_str(sess.network_watch.filter)},"candidateCount":${sess.network_watch.candidate_urls.len},"savedCount":${sess.network_watch.saved_request_ids.len},"failedCount":${sess.network_watch.failed_count},"nextIndex":${sess.network_watch.next_index}}'
}

// 锁内预留在途请求；失败只释放预留，重试由本次保存的三次尝试负责，
// 不承诺后台自动重试。之后显式同步或再次收到事件时可以重新尝试。
fn reserve_network_watch_save(mut sess CdpSession, entry TrackedNetworkRequest) !(string, string) {
	sess.network_watch_mu.@lock()
	defer { sess.network_watch_mu.unlock() }
	cfg := fetch_config_snapshot(mut sess)
	if !sess.network_watch.active || !entry.finished
		|| entry.url !in sess.network_watch.candidate_urls
		|| entry.request_id in sess.network_watch.saved_request_ids
		|| entry.request_id in cfg.saving_request_ids {
		return error('not a pending watch candidate')
	}
	request_id := entry.request_id
	fetch_config_update(mut sess, fn [request_id] (mut state FetchSessionConfig) {
		state.saving_request_ids[request_id] = true
	})
	sess.network_watch.next_index++
	path := os.join_path(sess.network_watch.target_dir, network_image_output_name(sess.network_watch.next_index, entry))
	return path, cfg.watch_generation
}

fn finish_network_watch_save(mut sess CdpSession, request_id string, generation string, saved bool) {
	sess.network_watch_mu.@lock()
	defer { sess.network_watch_mu.unlock() }
	cfg := fetch_config_snapshot(mut sess)
	// stop/start 之间返回的旧回调不能污染新一轮，也不能删除新一轮的预留。
	if !sess.network_watch.active || cfg.watch_generation != generation { return }
	fetch_config_update(mut sess, fn [request_id] (mut state FetchSessionConfig) {
		state.saving_request_ids.delete(request_id)
	})
	if saved {
		sess.network_watch.saved_request_ids[request_id] = true
	} else {
		sess.network_watch.failed_count++
	}
}

fn save_network_watch_reserved(mut sess CdpSession, request_id string, path string, generation string) {
	if _ := save_network_response_with_retry(mut sess, request_id, path, 3, 150 * time.millisecond) {
		finish_network_watch_save(mut sess, request_id, generation, true)
	} else {
		finish_network_watch_save(mut sess, request_id, generation, false)
		eprintln('[network watch] save failed for ${request_id}: ${err}')
	}
}

fn sync_network_watch_existing_requests(mut sess CdpSession) {
	for entry in sess.network_request_entries_snapshot() {
		path, generation := reserve_network_watch_save(mut sess, entry) or { continue }
		request_id := entry.request_id
		spawn fn [mut sess, request_id, path, generation] () {
			save_network_watch_reserved(mut sess, request_id, path, generation)
		}()
	}
}

fn handle_network_watch_loading_finished(mut sess CdpSession, request_id string) {
	entry := sess.network_request_snapshot(request_id) or { return }
	path, generation := reserve_network_watch_save(mut sess, entry) or { return }
	save_network_watch_reserved(mut sess, request_id, path, generation)
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
	js := build_page_primary_image_urls_js(mut sess)
	// 脚本已带作用域包装，用 eval_prepared_js 避免二次包装
	raw := eval_prepared_js(mut sess, js, true)!
	if raw == '' || raw == 'null' || raw == '[]' {
		return []string{}
	}
	if !raw.starts_with('[') || !raw.ends_with(']') {
		return error('invalid image URL JSON: expected array')
	}
	parsed := json_urls.decode[json_urls.Any](raw) or { return error('invalid image URL JSON: ${err}') }
	mut urls := []string{}
	for item in parsed.as_array() {
		url := item.str()
		if url != '' && url !in urls { urls << url }
	}
	return urls
}

fn build_page_primary_image_urls_js(mut sess CdpSession) string {
	return build_document_scope_js(mut sess, '
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

// cmd_frame 切换到 iframe 上下文
// 支持参数：selector（iframe 的 CSS 选择器，'main' 或空值切回主文档）
fn cmd_frame(mut sess CdpSession, params string) string {
	selector := cdp_extract_str(params, 'selector')
	if selector == '' || selector == 'main' {
		sess.set_current_frame_selector('')
		axref_clear(mut sess.axref)
		return json_str('main')
	}
	if axref_is_ref(selector) {
		return 'ERROR:frame switching currently requires a CSS or XPath selector'
	}
	js := build_document_scope_js(mut sess, 'var frameEl=document.querySelector(${js_str(selector)}); if(!frameEl) return "missing"; try { return frameEl.contentDocument ? "ok" : "unavailable"; } catch (e) { return "cross-origin"; }')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return 'ERROR:${err}'
	}
	result := cdp_extract_obj_key(resp.result, '"result":')
	status := cdp_extract_value_from_result(result)
	if status != 'ok' {
		return 'ERROR:cannot switch frame ${selector}: ${status}'
	}
	sess.set_current_frame_selector(selector)
	axref_clear(mut sess.axref)
	return json_str(selector)
}

// cmd_dialog 处理页面对话框（alert/confirm/prompt）
// 支持 action：
//   - events：获取历史对话框事件列表
//   - clear：清空对话框事件历史
//   - accept/dismiss：接受/关闭当前对话框（可指定text参数）
fn cmd_dialog(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	text := cdp_extract_str(params, 'text')
	match action {
		'events' {
			sess.enable_page_events() or { return 'ERROR:${err}' }
			dialog_events := sess.dialog_events_snapshot()
			if dialog_events.len == 0 {
				return '[]'
			}
			return '[' + dialog_events.map(it).join(',') + ']'
		}
		'clear' {
			sess.clear_dialog_events()
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
			mut timeout := if timeout_ms > 0 {
				time.millisecond * time.Duration(timeout_ms)
			} else {
				5 * time.second
			}
			sess.enable_page_events() or { return 'ERROR:${err}' }
			deadline := time.now().add(timeout)
			for time.now() < deadline {
				dialog_events := sess.dialog_events_snapshot()
				for ev in dialog_events {
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
		dialog_events := sess.dialog_events_snapshot()
		if dialog_events.len > 0 {
			for ev in dialog_events {
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
	js := build_element_scope_js(mut sess, sel, "if(!el) return; var old=el.style.outline; el.style.outline='3px solid #FF0080'; setTimeout(()=>el.style.outline=old,2000);")
	sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)}}') or {
		return 'ERROR:${err}'
	}
	return 'null'
}

// cmd_console 获取控制台消息
// 支持 action：clear（清空历史）
// 返回控制台消息数组
fn cmd_console(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	if action == 'clear' {
		sess.clear_console_messages()
		return 'null'
	}
	console_msgs := sess.console_messages_snapshot()
	if console_msgs.len == 0 {
		return '[]'
	}
	out := '[' + console_msgs.map(it).join(',') + ']'
	return out
}

fn cmd_errors(mut sess CdpSession, params string) string {
	action := cdp_extract_str(params, 'action')
	if action == 'clear' {
		sess.clear_page_errors()
		return 'null'
	}
	page_errors := sess.page_errors_snapshot()
	if page_errors.len == 0 {
		return '[]'
	}
	return '[' + page_errors.map(it).join(',') + ']'
}

// cmd_trace Chrome DevTools 性能追踪
// 支持 action：
//   - start：开始追踪
//   - stop：停止追踪并保存到文件（默认临时目录）
// 支持参数：path（输出文件路径）
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

// cmd_profiler Chrome V8 CPU 性能分析器
// 支持 action：
//   - start：开始性能分析
//   - stop：停止分析并保存到文件（默认临时目录）
// 支持参数：path（输出文件路径）
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

// cmd_set 设置浏览器状态
// 支持 property：
//   - viewport：设置视口大小（width/height/scale）
//   - device：设置设备预设（device预设名称）
//   - user_agent：设置 User-Agent
//   - offline：设置离线模式
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
			origin := current_page_origin(mut sess) or { return 'ERROR:${err}' }
			previous := fetch_config_snapshot(mut sess).auth
			fetch_config_set_auth(mut sess, user, pass, origin)
			ensure_fetch_interceptor(mut sess, false)
			sess.send_command('Fetch.enable', fetch_enable_params(mut sess)) or {
				fetch_config_update(mut sess, fn [previous] (mut cfg FetchSessionConfig) {
					cfg.auth = previous
				})
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

// apply_device_preset 应用设备预设配置
// 包括视口大小、缩放比例、是否移动设备、touch支持、userAgent等
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
	mut total_bytes := 0
	deadline := time.now().add(30 * time.second)
	defer { sess.send_command('IO.close', '{"handle":${json_str(stream)}}') or {} }
	for time.now() < deadline {
		resp := sess.send_command('IO.read', '{"handle":${json_str(stream)}}')!
		data := cdp_extract_str(resp.result, 'data')
		if cdp_extract_obj_key(resp.result, '"base64Encoded":') == 'true' {
			decoded := base64.decode(data)
			total_bytes += decoded.len
			if total_bytes > 64 * 1024 * 1024 { return error('protocol stream exceeds 64 MiB') }
			out += decoded.bytestr()
		} else {
			total_bytes += data.len
			if total_bytes > 64 * 1024 * 1024 { return error('protocol stream exceeds 64 MiB') }
			out += data
		}
		if cdp_extract_obj_key(resp.result, '"eof":') == 'true' { return out }
	}
	return error('protocol stream read timed out')
}

// cmd_diff 比较页面状态差异
// 支持 type：
//   - snapshot：比较当前快照与基准文件（返回文本差异）
//   - screenshot：比较截图（支持像素差异阈值）
//   - url：比较两个 URL 的快照和可选截图
// 支持参数：
//   - baseline：基准文件路径
//   - threshold：像素差异容忍度（默认0.1）
//   - output：差异图片输出路径
fn cmd_diff(mut sess CdpSession, params string) string {
	dtype := cdp_extract_str(params, 'type')
	match dtype {
		'snapshot' {
			current := cmd_snapshot(mut sess, '{"raw":true}')
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
			snapshot1 := cmd_snapshot(mut sess, '{"raw":true}')
			mut screenshot1_b64 := ''
			if with_screenshot {
				screenshot1_b64 = capture_screenshot_base64(mut sess, 'png', full, '') or {
					return 'ERROR:${err}'
				}
			}

			navigate_and_wait(mut sess, url2, wait_until) or { return 'ERROR:${err}' }
			snapshot2 := cmd_snapshot(mut sess, '{"raw":true}')
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

// cmd_clipboard 剪贴板操作（支持图片读写）
// 支持 action：
//   - read/r：读取剪贴板图片并保存到临时文件
//   - write/w：写入本地图片文件到剪贴板
// kind 参数：目前只支持 image
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

// cmd_state 会话状态管理
// 支持 action：
//   - save：保存当前会话状态到文件
//   - load：加载会话状态文件
//   - clear：清除会话状态
// 状态保存在 ~/.v-browser/states 目录
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
				return 'ERROR:localStorage export failed: ${err}'
			}
			ls_result := cdp_extract_obj_key(ls_resp.result, '"result":')
			local_storage := cdp_extract_value_from_result(ls_result)
			state := '{"cookies":${cookies},"localStorage":${json_str(local_storage)}}'
			out_path := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			if os.is_link(out_path) { return 'ERROR:refusing to overwrite symbolic link' }
			parent_dir := os.dir(out_path)
			os.mkdir_all(parent_dir) or { return 'ERROR:create state directory failed: ${err}' }
			tmp_path := '${out_path}.tmp-${rand.uuid_v4()}'
			// 创建时即为 0600，内容写入前不存在默认权限泄露窗口。
			mut state_file := os.open_file(tmp_path, 'w', 0o600) or { return 'ERROR:${err}' }
			state_file.write_string(state) or {
				state_file.close()
				os.rm(tmp_path) or {}
				return 'ERROR:write state failed: ${err}'
			}
			state_file.close()
			os.mv(tmp_path, out_path) or {
				os.rm(tmp_path) or {}
				return 'ERROR:atomic state replace failed: ${err}'
			}
			return json_str(out_path)
		}
		'load' {
			file := if os.is_abs_path(path) { path } else { os.join_path(state_dir, path) }
			content := os.read_file(file) or { return 'ERROR:cannot read state: ${err}' }
			cookies_json := cdp_extract_obj_key(content, '"cookies":')
			local_storage_json := cdp_extract_str(content, 'localStorage')
			if cookies_json != '' && cookies_json != '[]' {
				sess.send_command('Network.setCookies', '{"cookies":${cookies_json}}') or { return 'ERROR:cookie restore failed: ${err}' }
			}
			if local_storage_json != '' {
				restore_js := build_storage_restore_script('localStorage', local_storage_json)
				sess.send_command('Runtime.evaluate', '{"expression":${json_str(restore_js)}}') or { return 'ERROR:localStorage restore failed: ${err}' }
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
