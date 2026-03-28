// resolver.v — 统一选择器解析：@eN → CSS/XPath → 坐标
// 输出: (x, y f64) 用于 Input.dispatchMouseEvent
//        + backend_node_id 用于 DOM 操作
module main

struct ResolvedElement {
	x               f64
	y               f64
	width           f64
	height          f64
	backend_node_id int
	object_id       string // Runtime RemoteObjectId
}

struct DomNodeRef {
	backend_node_id int
	object_id       string
}

// resolve_selector 统一解析选择器，返回元素信息
fn resolve_selector(mut sess CdpSession, sel string) !ResolvedElement {
	if axref_is_ref(sel) {
		return resolve_axref(mut sess, sel)
	}
	return resolve_css(mut sess, sel)
}

// resolve_axref 通过 @eN 引用查元素坐标
fn resolve_axref(mut sess CdpSession, ref string) !ResolvedElement {
	r := axref_get(&sess.axref, ref) or {
		return error('unknown ref ${ref}: run `v-browser snapshot` first')
	}
	if r.selector != '' {
		return resolve_css(mut sess, r.selector)
	}
	if r.has_coords {
		return ResolvedElement{
			x:               r.x
			y:               r.y
			backend_node_id: r.backend_node_id
		}
	}
	// 通过 backendNodeId 查边界框
	if r.backend_node_id == 0 {
		return error('ref ${ref} cannot be resolved')
	}
	return get_box_by_backend_node_id(mut sess, r.backend_node_id)
}

// resolve_css 通过 CSS 选择器查元素（支持 XPath: 以 //  开头）
fn resolve_css(mut sess CdpSession, sel string) !ResolvedElement {
	js := build_rect_query_js(&sess, sel)

	eval_resp := sess.send_command('Runtime.evaluate', '{"expression":${js_str(js)},"returnByValue":true}') or {
		return error('Runtime.evaluate failed: ${err}')
	}

	result_obj := cdp_extract_obj_key(eval_resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	if value_obj == '' || value_obj == 'null' {
		return error('element not found: ${sel}')
	}

	x := cdp_extract_float(value_obj, 'x')
	y := cdp_extract_float(value_obj, 'y')
	w := cdp_extract_float(value_obj, 'width')
	h := cdp_extract_float(value_obj, 'height')

	node_ref := get_dom_node_ref(mut sess, sel) or { DomNodeRef{} }

	return ResolvedElement{
		x:               x + w / 2
		y:               y + h / 2
		width:           w
		height:          h
		backend_node_id: node_ref.backend_node_id
		object_id:       node_ref.object_id
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
	// 通过 Runtime 获取 boundingClientRect
	call_resp := sess.send_command('Runtime.callFunctionOn', '{"objectId":${json_str(object_id)},"functionDeclaration":"function(){return this.getBoundingClientRect()}","returnByValue":true}') or {
		return error('callFunctionOn failed: ${err}')
	}
	result_obj := cdp_extract_obj_key(call_resp.result, '"result":')
	value_obj := cdp_extract_obj_key(result_obj, '"value":')
	x := cdp_extract_float(value_obj, 'x')
	y := cdp_extract_float(value_obj, 'y')
	w := cdp_extract_float(value_obj, 'width')
	h := cdp_extract_float(value_obj, 'height')
	return ResolvedElement{
		x:               x + w / 2
		y:               y + h / 2
		width:           w
		height:          h
		backend_node_id: bnid
		object_id:       object_id
	}
}

fn get_dom_node_ref(mut sess CdpSession, sel string) !DomNodeRef {
	lookup_js := build_element_scope_js(&sess, sel, 'return el;')
	resolve_resp := sess.send_command('Runtime.evaluate', '{"expression":${json_str(lookup_js)}}') or {
		return error(err.msg())
	}
	object_id := cdp_extract_str(resolve_resp.result, 'objectId')
	if object_id == '' {
		return error('element not found: ${sel}')
	}
	node_resp := sess.send_command('DOM.requestNode', '{"objectId":${json_str(object_id)}}') or {
		return DomNodeRef{
			object_id: object_id
		}
	}
	nid := cdp_extract_int(node_resp.result, '"nodeId":')
	if nid == 0 {
		return DomNodeRef{
			object_id: object_id
		}
	}
	desc_resp := sess.send_command('DOM.describeNode', '{"nodeId":${nid},"depth":0}') or {
		return DomNodeRef{
			object_id: object_id
		}
	}
	return DomNodeRef{
		backend_node_id: cdp_extract_int(desc_resp.result, '"backendNodeId":')
		object_id:       object_id
	}
}

// 在当前 frame 或主文档上下文中包装一段 JS。
fn build_document_scope_js(sess &CdpSession, body string) string {
	if sess.current_frame_selector == '' {
		return '(function(){ var frame=null; var doc=document; var win=window; ${body} })()'
	}
	frame_sel := js_str(sess.current_frame_selector)
	return '(function(){ var frame=document.querySelector(${frame_sel}); if(!frame) return null; var doc; try { doc=frame.contentDocument; } catch (e) { return null; } if(!doc) return null; var win=frame.contentWindow || doc.defaultView; ${body} })()'
}

// 生成带单个元素查询的 JS 包装器。
fn build_element_scope_js(sess &CdpSession, sel string, body string) string {
	query := if sel.starts_with('//') || sel.starts_with('(//') {
		'var el=doc.evaluate(${js_str(sel)}, doc, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;'
	} else {
		'var el=doc.querySelector(${js_str(sel)});'
	}
	return build_document_scope_js(sess, '${query} ${body}')
}

// 生成带多元素查询的 JS 包装器。
fn build_elements_scope_js(sess &CdpSession, sel string, body string) string {
	return build_document_scope_js(sess, 'var els=doc.querySelectorAll(${js_str(sel)}); ${body}')
}

// 构造获取元素边界框的 JS 查询。
fn build_rect_query_js(sess &CdpSession, sel string) string {
	return build_element_scope_js(sess, sel, 'if(!el) return null; var r=el.getBoundingClientRect(); if(frame){ var fr=frame.getBoundingClientRect(); return {x:fr.x+r.x,y:fr.y+r.y,width:r.width,height:r.height}; } return r;')
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
