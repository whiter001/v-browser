// resolver.v — 统一选择器解析：@eN → CSS/XPath → 坐标
// 输出: (x, y f64) 用于 Input.dispatchMouseEvent
//        + backend_node_id 用于 DOM 操作
module main

import x.json2

struct ResolvedElement {
	x               f64
	y               f64
	width           f64
	height          f64
	backend_node_id int
}

struct DomNodeRef {
	backend_node_id int
}

// Rect 元素在视口中的矩形信息
struct Rect {
	x      f64
	y      f64
	width  f64
	height f64
}

// 取边界框的页面函数：非 Element 节点返回标记对象，避免把异常当成 0 坐标成功。
const rect_query_function = 'function(){if(!this||this.nodeType!==1){return {__vbrowserNotElement:true,nodeType:(this&&this.nodeType||-1)};}var r=this.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height};}'

// resolve_selector 统一解析选择器，返回元素信息
fn resolve_selector(mut sess CdpSession, sel string) !ResolvedElement {
	if axref_is_ref(sel) {
		return resolve_axref(mut sess, sel)
	}
	return resolve_css(mut sess, sel)
}

// resolve_axref 通过 @eN 引用查元素坐标。
// 有 backendNodeId 时禁止按旧 selector 重新定位，避免 DOM 变化后误操作替代节点。
fn resolve_axref(mut sess CdpSession, ref string) !ResolvedElement {
	r := axref_get(&sess.axref, ref) or {
		return error('unknown ref ${ref}: run `v-browser snapshot` first')
	}
	if r.backend_node_id > 0 {
		return get_box_by_backend_node_id(mut sess, r.backend_node_id) or {
			return error('stale-reference ${ref}: ${err}')
		}
	}
	if r.selector != '' {
		return resolve_axref_selector(mut sess, ref, r.selector)
	}
	if r.has_coords {
		return ResolvedElement{
			x:               r.x
			y:               r.y
			backend_node_id: 0
		}
	}
	return error('stale-reference ${ref}: ref cannot be resolved')
}

// resolve_axref_selector 是无 backendNodeId 的兼容路径；selector 必须唯一命中。
fn resolve_axref_selector(mut sess CdpSession, ref string, selector string) !ResolvedElement {
	query := if selector.starts_with('//') || selector.starts_with('(//') {
		'var matches=[]; var xpathResult=doc.evaluate(${js_str(selector)}, doc, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); for(var i=0;i<xpathResult.snapshotLength;i++) matches.push(xpathResult.snapshotItem(i));'
	} else {
		'var matches=Array.from(doc.querySelectorAll(${js_str(selector)}));'
	}
	js := build_document_scope_js(mut sess, '${query} if(matches.length!==1) return {__vbrowserSelectorCount:matches.length}; var el=matches[0]; var r=el.getBoundingClientRect(); if(frame){var fr=frame.getBoundingClientRect(); return {x:fr.x+r.x,y:fr.y+r.y,width:r.width,height:r.height};} return r;')
	resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(js)},"returnByValue":true}') or {
		return error('stale-reference ${ref}: Runtime.evaluate failed: ${err}')
	}
	exc := cdp_exception_detail(resp.result)
	if exc != '' {
		return error('stale-reference ${ref}: selector failed: ${exc}')
	}
	result_obj := cdp_extract_obj_key(resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('stale-reference ${ref}: selector no longer resolves')
	}
	if value_obj.contains('"__vbrowserSelectorCount"') {
		return error('stale-reference ${ref}: selector must match exactly one element')
	}
	rect := parse_rect_value(value_obj) or {
		return error('stale-reference ${ref}: ${err}')
	}
	return ResolvedElement{
		x:      rect.x + rect.width / 2
		y:      rect.y + rect.height / 2
		width:  rect.width
		height: rect.height
	}
}

// resolve_css 通过 CSS 选择器查元素（支持 XPath: 以 //  开头）
fn resolve_css(mut sess CdpSession, sel string) !ResolvedElement {
	js := build_rect_query_js(mut sess, sel)

	eval_resp := sess.send_command('Runtime.evaluate', '{"expression":${js_str(js)},"returnByValue":true}') or {
		return error('Runtime.evaluate failed: ${err}')
	}
	// 页面脚本抛异常时不能当成「元素不存在」，必须显式报错。
	exc := cdp_exception_detail(eval_resp.result)
	if exc != '' {
		return error('Runtime.evaluate raised an exception: ${exc}')
	}

	result_obj := cdp_extract_obj_key(eval_resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('element not found: ${sel}')
	}

	rect := parse_rect_value(value_obj) or { return err }

	node_ref := get_dom_node_ref(mut sess, sel) or { DomNodeRef{} }

	return ResolvedElement{
		x:               rect.x + rect.width / 2
		y:               rect.y + rect.height / 2
		width:           rect.width
		height:          rect.height
		backend_node_id: node_ref.backend_node_id
	}
}

// get_box_by_backend_node_id 通过 backendNodeId 获取元素位置
fn get_box_by_backend_node_id(mut sess CdpSession, bnid int) !ResolvedElement {
	// 先 resolve 到 nodeId
	resolve_resp := sess.send_command('DOM.resolveNode', '{"backendNodeId":${bnid}}') or {
		return error('DOM.resolveNode failed: ${err}')
	}
	object_id := cdp_extract_str(resolve_resp.result, 'objectId')
	if object_id == '' {
		return error('could not resolve backendNodeId ${bnid}')
	}
	// 远端对象只服务于本次边界框查询，退出时（含错误路径）立即释放，避免渲染进程堆积对象。
	defer { release_remote_object(mut sess, object_id) }

	// 通过 Runtime 获取 boundingClientRect
	call_resp := sess.send_command('Runtime.callFunctionOn', '{"objectId":${json_str(object_id)},"functionDeclaration":${json_str(rect_query_function)},"returnByValue":true}') or {
		return error('callFunctionOn failed: ${err}')
	}
	// 先看异常详情：节点失效或不是 Element 都会在这里抛出，不能当成 0 坐标成功。
	exc := cdp_exception_detail(call_resp.result)
	if exc != '' {
		return error('callFunctionOn raised an exception: ${exc}')
	}
	result_obj := cdp_extract_obj_key(call_resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj.contains('"__vbrowserNotElement"') {
		return error('backendNodeId ${bnid} is not an Element node')
	}
	rect := parse_rect_value(value_obj) or { return err }
	return ResolvedElement{
		x:               rect.x + rect.width / 2
		y:               rect.y + rect.height / 2
		width:           rect.width
		height:          rect.height
		backend_node_id: bnid
	}
}

fn get_dom_node_ref(mut sess CdpSession, sel string) !DomNodeRef {
	lookup_js := build_element_scope_js(mut sess, sel, 'return el;')
	resolve_resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(lookup_js)}}') or {
		return error(err.msg())
	}
	object_id := cdp_extract_str(resolve_resp.result, 'objectId')
	if object_id == '' {
		return error('element not found: ${sel}')
	}
	// 远端对象只用来换取 backendNodeId，取到后立即释放（含错误路径）。
	defer { release_remote_object(mut sess, object_id) }
	exc := cdp_exception_detail(resolve_resp.result)
	if exc != '' {
		return error('Runtime.evaluate raised an exception: ${exc}')
	}
	node_resp := sess.send_command('DOM.requestNode', '{"objectId":${json_str(object_id)}}') or {
		return DomNodeRef{}
	}
	nid := cdp_extract_int(node_resp.result, '"nodeId":')
	if nid == 0 {
		return DomNodeRef{}
	}
	desc_resp := sess.send_command('DOM.describeNode', '{"nodeId":${nid},"depth":0}') or {
		return DomNodeRef{}
	}
	return DomNodeRef{
		backend_node_id: cdp_extract_int(desc_resp.result, '"backendNodeId":')
	}
}

// release_remote_object 释放 Runtime 远端对象；会话已断开时忽略失败。
fn release_remote_object(mut sess CdpSession, object_id string) {
	if object_id == '' {
		return
	}
	sess.send_command('Runtime.releaseObject', '{"objectId":${json_str(object_id)}}') or { return }
}

// cdp_exception_detail 从 CDP 响应里提取异常详情文本；没有异常时返回空串。
fn cdp_exception_detail(result string) string {
	exc := cdp_extract_obj_key(result, '"exceptionDetails":')
	if exc == '' || exc == 'null' {
		return ''
	}
	desc := cdp_extract_str(exc, 'description')
	if desc != '' {
		return desc
	}
	text := cdp_extract_str(exc, 'text')
	if text != '' {
		return text
	}
	return exc
}

// parse_rect_value 解析边界框对象：必须是含 x/y/width/height 数字字段的 JSON 对象。
fn parse_rect_value(value_obj string) !Rect {
	trimmed := value_obj.trim_space()
	if !trimmed.starts_with('{') {
		return error('unexpected bounding box payload: ${trimmed}')
	}
	obj := json2.decode[map[string]json2.Any](trimmed) or {
		return error('invalid bounding box payload: ${trimmed}')
	}
	x := rect_number(obj, 'x') or { return err }
	y := rect_number(obj, 'y') or { return err }
	width := rect_number(obj, 'width') or { return err }
	height := rect_number(obj, 'height') or { return err }
	return Rect{
		x:      x
		y:      y
		width:  width
		height: height
	}
}

// rect_number 读取矩形对象里的数值字段；字段缺失或不是数字时返回错误，避免默认成 0 坐标。
fn rect_number(obj map[string]json2.Any, key string) !f64 {
	v := obj[key] or { return error('bounding box is missing "${key}"') }
	match v {
		f64 { return v }
		f32 { return f64(v) }
		i64, int, i32, i16, i8 { return f64(v) }
		u64, u32, u16, u8 { return f64(v) }
		else { return error('bounding box field "${key}" is not a number') }
	}
}

// 在当前 frame 或主文档上下文中包装一段 JS。
fn build_document_scope_js(mut sess CdpSession, body string) string {
	frame_selector := sess.current_frame_selector_value()
	if frame_selector == '' {
		return '(function(){ var frame=null; var doc=document; var win=window; ${body} })()'
	}
	frame_sel := js_str(frame_selector)
	return '(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; ${body} })()'
}

// 生成带单个元素查询的 JS 包装器。
fn build_element_scope_js(mut sess CdpSession, sel string, body string) string {
	query := if sel.starts_with('//') || sel.starts_with('(//') {
		'var el=doc.evaluate(${js_str(sel)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;'
	} else {
		'var el=doc.querySelector(${js_str(sel)});'
	}
	return build_document_scope_js(mut sess, '${query} ${body}')
}

// 生成带多元素查询的 JS 包装器。
fn build_elements_scope_js(mut sess CdpSession, sel string, body string) string {
	return build_document_scope_js(mut sess, 'var els=doc.querySelectorAll(${js_str(sel)}); ${body}')
}

// 构造获取元素边界框的 JS 查询。
fn build_rect_query_js(mut sess CdpSession, sel string) string {
	return build_element_scope_js(mut sess, sel, 'if(!el) return null; var r=el.getBoundingClientRect(); if(frame){ var fr=frame.getBoundingClientRect(); return {x:fr.x+r.x,y:fr.y+r.y,width:r.width,height:r.height}; } return r;')
}

// ─── 帮助函数 ────────────────────────────────────────────────

// 从一段 JSON 文本里提取指定字段的浮点数。
fn cdp_extract_float(s string, key string) f64 {
	search := '"${key}":'
	idx := s.index(search) or { return 0.0 }
	rest := s[idx + search.len..].trim_left(' ')
	mut end := 0
	for end < rest.len && rest[end] !in [`,`, `}`, `]`, ` `, `\n`].map(u8(it)) {
		end++
	}
	return rest[..end].f64()
}

// 将字符串转换为可直接嵌入 JS 的字面量。
fn js_str(s string) string {
	return json_str(s) // JSON 字符串恰好也是合法 JS 字符串字面量
}

// scroll_into_view_js 返回让元素进入视野的 JS 代码片段（injectElement 用）
// 生成把目标元素滚动到视口中央的 JS 片段。
fn scroll_into_view_js(sel string) string {
	return "document.querySelector(${js_str(sel)})?.scrollIntoView({block:'center',inline:'center'})"
}
