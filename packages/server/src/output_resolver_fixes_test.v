module main

import x.json2

// ── output.v：JSON 输出注入防护 ─────────────────────────────

// 断言输出是合法 JSON，顶层只有 ok/result 两个字段，且 result 是原始字符串。
fn assert_result_wrapper_is_string(out string, payload string) {
	obj := json2.decode[map[string]json2.Any](out) or {
		assert false, 'output must be valid JSON: ${out}'
		return
	}
	assert obj.len == 2, 'output must only contain ok/result, got: ${out}'
	ok_val := obj['ok'] or { json2.Any(false) }
	match ok_val {
		bool {
			assert ok_val, 'ok must stay true: ${out}'
		}
		else {
			assert false, 'ok must be a boolean: ${out}'
		}
	}
	result_val := obj['result'] or { json2.Any('') }
	match result_val {
		string {
			assert result_val == payload, 'result must keep the raw payload: ${out}'
		}
		else {
			assert false, 'result must be a string for payload: ${payload}'
		}
	}
}

// 尾随内容 / 非法字面量不能再拼进结果对象，否则会注入顶层字段。
fn test_json_output_rejects_injection_payloads() {
	payloads := ['0,"ok":false', '123abc', 'undefined', '{"a":1},"ok":false', '1 2', 'true,false',
		'[1],"ok":false', '{"ok":true}garbage', '"a","ok":false', 'null}', 'true]', '01', '-01',
		'+1', '1.', '1e+', '[1,]', '{"a":1,}', '{]', '[1 2]', '{"a":1 "b":2}', '"unterminated',
		'"bad\\q"', '"bad\\uZZZZ"', '"line\nbreak"', '{"a":"tab\there"}', '"backslash\\\nnewline"']
	for payload in payloads {
		out := format_output(payload, true)
		assert_result_wrapper_is_string(out, payload)
	}
	// json_str 会过滤这些控制字符；这里仅断言它们不能作为 JSON 空白被放行。
	for payload in ['\v123', '123\f'] {
		assert !is_json_literal(payload)
		assert format_output(payload, true) == '{"ok":true,"result":${json_str(payload)}}'
	}
}

// 合法 JSON 仍然原样透传，不能被降级成字符串。
fn test_json_output_keeps_valid_json_payloads() {
	assert format_output('{"ok":true}', true) == '{"ok":true,"result":{"ok":true}}'
	assert format_output('{"a": 1}', true) == '{"ok":true,"result":{"a": 1}}'
	assert format_output('[1,2,3]', true) == '{"ok":true,"result":[1,2,3]}'
	assert format_output('123', true) == '{"ok":true,"result":123}'
	assert format_output('-1.5', true) == '{"ok":true,"result":-1.5}'
	assert format_output('true', true) == '{"ok":true,"result":true}'
	assert format_output('false', true) == '{"ok":true,"result":false}'
	assert format_output('null', true) == '{"ok":true,"result":null}'
	assert format_output('"text"', true) == '{"ok":true,"result":"text"}'
}

fn test_json_output_keeps_plain_text_as_string() {
	assert format_output('plain text', true) == '{"ok":true,"result":"plain text"}'
	assert format_output('', true) == '{"ok":true,"result":null}'
	assert format_output('  ', true) == '{"ok":true,"result":null}'
}

// error_code 的具体匹配必须排在通用 `invalid ` 之前，否则 AUTH_FAILED 不可达。
fn test_error_code_prefers_auth_failed_over_generic_invalid() {
	assert error_code('invalid token') == 'AUTH_FAILED'
	assert error_code('Invalid token: deadbeef') == 'AUTH_FAILED'
	assert error_code('invalid selector') == 'INVALID_ARGUMENT'
	assert error_code('missing selector') == 'INVALID_ARGUMENT'
	assert error_code('requires selector') == 'INVALID_ARGUMENT'
}

// ── resolver.v：CDP 远端对象释放与异常处理 ──────────────────

// 本文件自带 noop send，避免依赖其它测试文件的辅助函数。
fn resolver_noop_send(_ string) ! {}

// 拆开 send_command 的 forwardCDPCommand 信封，取内层 CDP method。
fn resolver_inner_cdp_method(data string) string {
	outer := cdp_extract_str(data, 'method')
	if outer == 'forwardCDPCommand' {
		params_obj := cdp_extract_obj_key(data, '"params":')
		return cdp_extract_str(params_obj, 'method')
	}
	return outer
}

// 按方法回放的 CDP mock：results 里没登记的方法返回空结果。
fn attach_resolver_mock(mut sess CdpSession, mut sent []string, results map[string]string) {
	sess.send_fn = fn [mut sess, mut sent, results] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := resolver_inner_cdp_method(data)
		result := results[method] or { '{}' }
		sess.on_message('{"id":${id},"result":${result}}')
	}
}

fn count_sent_method(sent []string, method string) int {
	mut count := 0
	for raw in sent {
		if resolver_inner_cdp_method(raw) == method {
			count++
		}
	}
	return count
}

fn test_get_box_by_backend_node_id_returns_center_and_releases_object() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'DOM.resolveNode':        '{"object":{"objectId":"OBJ-1"}}'
		'Runtime.callFunctionOn': '{"result":{"type":"object","value":{"x":10,"y":20,"width":30,"height":40}}}'
		'Runtime.releaseObject':  '{}'
	})
	el := get_box_by_backend_node_id(mut sess, 42) or { panic(err) }
	assert el.x == 25.0
	assert el.y == 40.0
	assert el.width == 30.0
	assert el.height == 40.0
	assert el.backend_node_id == 42
	// 远端对象必须被释放，否则渲染进程会一直堆积对象
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1
	assert sent.join('\n').contains('OBJ-1')
}

// callFunctionOn 抛异常时必须报错，不能当成 0 坐标成功；错误路径也要释放对象。
fn test_get_box_by_backend_node_id_reports_exception_and_releases_object() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'DOM.resolveNode':        '{"object":{"objectId":"OBJ-1"}}'
		'Runtime.callFunctionOn': '{"result":{"type":"object","subtype":"error"},"exceptionDetails":{"text":"Uncaught","exception":{"className":"TypeError","description":"TypeError: this.getBoundingClientRect is not a function"}}}'
		'Runtime.releaseObject':  '{}'
	})
	mut err_msg := ''
	el := get_box_by_backend_node_id(mut sess, 42) or {
		err_msg = err.msg()
		ResolvedElement{}
	}
	assert err_msg.contains('exception')
	assert err_msg.contains('TypeError')
	assert el.width == 0.0
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1
}

// 非 Element 节点必须给出明确错误，而不是返回 0 坐标。
fn test_get_box_by_backend_node_id_rejects_non_element_node() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'DOM.resolveNode':        '{"object":{"objectId":"OBJ-1"}}'
		'Runtime.callFunctionOn': '{"result":{"type":"object","value":{"__vbrowserNotElement":true,"nodeType":3}}}'
		'Runtime.releaseObject':  '{}'
	})
	mut err_msg := ''
	get_box_by_backend_node_id(mut sess, 42) or { err_msg = err.msg() }
	assert err_msg.contains('is not an Element node')
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1
}

// 边界框缺少必要字段时必须报错，不能默认成 0。
fn test_get_box_by_backend_node_id_rejects_incomplete_rect() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'DOM.resolveNode':        '{"object":{"objectId":"OBJ-1"}}'
		'Runtime.callFunctionOn': '{"result":{"type":"object","value":{"x":10,"y":20}}}'
		'Runtime.releaseObject':  '{}'
	})
	mut err_msg := ''
	get_box_by_backend_node_id(mut sess, 42) or { err_msg = err.msg() }
	assert err_msg.contains('missing')
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1
}

// 取 backendNodeId 的 Runtime 远端对象也必须释放。
fn test_get_dom_node_ref_releases_runtime_object() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'Runtime.evaluate':      '{"result":{"type":"object","objectId":"OBJ-2"}}'
		'DOM.requestNode':       '{"nodeId":7}'
		'DOM.describeNode':      '{"node":{"backendNodeId":99}}'
		'Runtime.releaseObject': '{}'
	})
	ref := get_dom_node_ref(mut sess, '#btn') or { panic(err) }
	assert ref.backend_node_id == 99
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1
	assert sent.join('\n').contains('OBJ-2')
}

// resolve_css 的页面异常必须显式上报，不能当成「元素不存在」。
fn test_resolve_css_reports_runtime_exception() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'Runtime.evaluate': '{"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"ReferenceError: el is not defined"}}}'
	})
	mut err_msg := ''
	resolve_css(mut sess, '#btn') or { err_msg = err.msg() }
	assert err_msg.contains('ReferenceError')
}

// resolve_css 拿到的矩形缺字段时必须报错。
fn test_resolve_css_rejects_incomplete_rect() {
	mut sent := []string{}
	mut sess := new_cdp_session(resolver_noop_send)
	attach_resolver_mock(mut sess, mut sent, {
		'Runtime.evaluate': '{"result":{"type":"object","value":{"x":10,"y":20}}}'
	})
	mut err_msg := ''
	resolve_css(mut sess, '#btn') or { err_msg = err.msg() }
	assert err_msg.contains('missing')
}

fn test_json_output_keeps_nested_escaped_and_exponent_values() {
	for payload in ['-0', '1.25e+3', '0E-2', '[]', '{}', '"a\\\"b\\\\c"',
		'{"a":[null,true,{"b":"}][{\\n"}]}'] {
		assert format_output(' \t${payload}\r\n', true) == '{"ok":true,"result":${payload}}'
	}
	assert format_output('0,"ok":false', false) == '0,"ok":false'
}

fn assert_resolver_released(sent []string, object_id string) {
	assert count_sent_method(sent, 'Runtime.releaseObject') == 1, '${object_id}: ${sent}'
	last := sent.last()
	assert resolver_inner_cdp_method(last) == 'Runtime.releaseObject'
	assert cdp_extract_str(last, 'objectId') == object_id
}

fn test_get_box_rejects_invalid_rect_payloads_and_releases() {
	for value in ['null', '[]', '"rect"', '0', '{}', '{"x":"0","y":0,"width":1,"height":2}',
		'{"x":0,"y":null,"width":1,"height":2}', '{"x":0,"y":0,"width":false,"height":2}',
		'{"x":0,"y":0,"width":1,"height":{}}'] {
		mut sent := []string{}
		mut sess := new_cdp_session(resolver_noop_send)
		attach_resolver_mock(mut sess, mut sent, {
			'DOM.resolveNode':        '{"object":{"objectId":"rect-object"}}'
			'Runtime.callFunctionOn': '{"result":{"type":"object","value":${value}}}'
		})
		mut failed := false
		get_box_by_backend_node_id(mut sess, 42) or { failed = true }
		assert failed, value
		assert_resolver_released(sent, 'rect-object')
	}
	zero := parse_rect_value('{"x":0,"y":0,"width":0,"height":0}') or { panic(err) }
	assert zero.x == 0 && zero.width == 0
}

fn attach_resolver_error_mock(mut sess CdpSession, mut sent []string, failed_method string) {
	sess.send_fn = fn [mut sess, mut sent, failed_method] (data string) ! {
		sent << data
		method := resolver_inner_cdp_method(data)
		if method == failed_method {
			return error('mock transport failure')
		}
		id := cdp_extract_int(data, '"id":')
		result := match method {
			'DOM.resolveNode' { '{"object":{"objectId":"error-object"}}' }
			'Runtime.evaluate' { '{"result":{"objectId":"error-object"}}' }
			'DOM.requestNode' { '{"nodeId":7}' }
			else { '{}' }
		}
		sess.on_message('{"id":${id},"result":${result}}')
	}
}

fn test_resolver_releases_objects_on_command_errors() {
	for failed_method in ['Runtime.callFunctionOn', 'DOM.requestNode', 'DOM.describeNode'] {
		mut sent := []string{}
		mut sess := new_cdp_session(resolver_noop_send)
		attach_resolver_error_mock(mut sess, mut sent, failed_method)
		if failed_method == 'Runtime.callFunctionOn' {
			mut failed := false
			get_box_by_backend_node_id(mut sess, 42) or { failed = true }
			assert failed
		} else {
			ref := get_dom_node_ref(mut sess, '#btn') or { panic(err) }
			assert ref.backend_node_id == 0
		}
		assert_resolver_released(sent, 'error-object')
	}
}

fn test_get_dom_node_ref_releases_on_missing_node_and_exception() {
	for evaluation in ['{"result":{"objectId":"eval-object"}}',
		'{"result":{"objectId":"eval-object"},"exceptionDetails":{"text":"Uncaught"}}'] {
		mut sent := []string{}
		mut sess := new_cdp_session(resolver_noop_send)
		attach_resolver_mock(mut sess, mut sent, {
			'Runtime.evaluate': evaluation
		})
		mut message := ''
		ref := get_dom_node_ref(mut sess, '#btn') or {
			message = err.msg()
			DomNodeRef{}
		}
		assert ref.backend_node_id == 0
		if evaluation.contains('exceptionDetails') {
			assert message.contains('exception')
			assert count_sent_method(sent, 'DOM.requestNode') == 0
		}
		assert_resolver_released(sent, 'eval-object')
	}
}
