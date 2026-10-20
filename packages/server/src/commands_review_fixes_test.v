module main

import os
import time
import rand

// 仅使用内存 CDP 和 Node 沙箱，不连接浏览器或 daemon 端口。
fn commands_review_session(results map[string]string, fail_type string) (&CdpSession, chan string) {
	calls := chan string{cap: 512}
	mut sess := new_cdp_session(fn (_ string) ! {})
	sess.send_fn = fn [mut sess, calls, results, fail_type] (data string) ! {
		inner := cdp_extract_obj_key(data, '"params":')
		calls <- inner
		id := cdp_extract_int(data, '"id":')
		method := cdp_extract_str(inner, 'method')
		if fail_type != '' && cdp_extract_str(data, 'type') == fail_type {
			sess.on_message('{"id":${id},"error":{"message":"injected ${fail_type} failure"}}')
			return
		}
		result := results[method] or { '{}' }
		sess.on_message('{"id":${id},"result":${result}}')
	}
	return sess, calls
}

fn commands_review_call(calls chan string) string {
	select {
		data := <-calls {
			return data
		}
		2 * time.second {
		}
	}
	panic('missing CDP call')
}

// commands_review_count 统计子串出现次数。
fn commands_review_count(haystack string, needle string) int {
	if needle == '' {
		return 0
	}
	return haystack.split(needle).len - 1
}

// commands_review_method 取出外层 CDP 信封里的 method。
fn commands_review_method(data string) string {
	return cdp_extract_str(cdp_extract_obj_key(data, '"params":'), 'method')
}

fn test_commands_review_screenshot_formats() {
	for format in ['png', 'jpeg', 'webp'] {
		assert normalize_screenshot_format(format)! == format
	}
	mut sess, calls := commands_review_session(map[string]string{}, '')
	defer { sess.close() }
	for format in ['gif', 'png","method":"Browser.close', '../png'] {
		assert cmd_screenshot(mut sess, '{"format":${json_str(format)}}').starts_with('ERROR:')
		if _ := capture_screenshot_base64(mut sess, format, false, '') {
			assert false
		}
	}
	assert calls.len == 0
}

fn test_commands_review_dom_download_paths() {
	for filename in ['/tmp/owned', '../owned', 'a/owned', 'a\\owned', 'C:\\owned', '..'] {
		if _ := resolve_dom_download_path(filename, '') {
			assert false, filename
		}
	}
	first := write_dom_download_result('{"ok":true,"filename":"report.txt","data":"b2s="}', '')!
	second := resolve_dom_download_path('report.txt', '')!
	defer {
		os.rmdir_all(os.dir(first)) or {}
		os.rmdir_all(os.dir(second)) or {}
	}
	assert first != second
	assert os.read_file(first)! == 'ok'
	assert os.real_path(first).starts_with(os.real_path(os.dir(first)) + os.path_separator)
}

fn test_commands_review_evaluate_exceptions() {
	bad := '{"result":{"type":"object"},"exceptionDetails":{"text":"Uncaught","exception":{"description":"TypeError: denied"}}}'
	if _ := evaluate_result_value(bad) {
		assert false
	} else {
		assert err.msg() == 'TypeError: denied'
	}
	assert evaluate_result_value('{"result":{"type":"boolean","value":true}}')! == 'true'
	mut sess, _ := commands_review_session({
		'Runtime.evaluate': bad
	}, '')
	defer { sess.close() }
	if _ := eval_scoped_expression(mut sess, 'bad()', false) {
		assert false
	}
	if _ := evaluate_bool_js(mut sess, 'bad()') {
		assert false
	}
	assert cmd_select(mut sess, '{"selector":"select","value":"x"}').contains('TypeError: denied')
}

// 异常详情解析只有一份实现：commands.v 与 resolver.v 共用 cdp_exception_detail，
// "exceptionDetails":null / {} 都必须算作「没有异常」。
fn test_commands_review_exception_details_are_unified() {
	assert evaluate_result_value('{"result":{"type":"boolean","value":true},"exceptionDetails":null}')! ==
		'true'
	assert evaluate_result_value('{"result":{"type":"boolean","value":false},"exceptionDetails":{}}')! ==
		'false'
	if _ := evaluate_result_value('{"result":{},"exceptionDetails":{"text":"Uncaught","exception":{"description":"TypeError: denied"}}}') {
		assert false
	} else {
		assert err.msg() == 'TypeError: denied'
	}
	// 没有可读文案时用固定提示，不把原始 JSON 抛给用户
	if _ := evaluate_result_value('{"result":{},"exceptionDetails":{"exceptionId":3}}') {
		assert false
	} else {
		assert err.msg() == 'javascript exception'
	}
}

// Fetch 事件处理器必须结构化解析参数：嵌套层级里的同名字段
// （例如 request 内部的 requestId）不能覆盖顶层的 requestId。
fn test_commands_review_fetch_events_use_structured_params() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"string","value":"https://example.test"}}'
	}, '')
	defer { sess.close() }
	assert cmd_set(mut sess, '{"property":"credentials","username":"alice","password":"secret"}') == 'null'
	// 排空 cmd_set 产生的调用（Runtime.evaluate 与 Fetch.enable）
	assert cdp_extract_str(commands_review_call(calls), 'method') == 'Runtime.evaluate'
	assert commands_review_call(calls).contains('"handleAuthRequests":true')
	sess.dispatch_event('Fetch.requestPaused', ProtocolResponse{
		params: '{"request":{"url":"https://example.test/a","requestId":"nested"},"requestId":"real-paused"}'
	})
	paused := commands_review_call(calls)
	assert paused.contains('Fetch.continueRequest')
	assert paused.contains('"real-paused"')
	assert !paused.contains('nested')
	sess.dispatch_event('Fetch.authRequired', ProtocolResponse{
		params: '{"authChallenge":{"origin":"https://example.test","source":"Server","requestId":"nested"},"requestId":"real-auth"}'
	})
	auth := commands_review_call(calls)
	assert auth.contains('Fetch.continueWithAuth')
	assert auth.contains('"real-auth"')
	assert !auth.contains('nested')
	assert auth.contains('ProvideCredentials')
}

// hook 记录的轮询路径必须和 push 路径一样受上限约束：
// 条数 / 累计字节超限时环形淘汰最旧的记录，单条超长直接丢弃。
fn test_commands_review_polled_hook_records_are_evicted() {
	mut items := []string{}
	for i in 0 .. 5 {
		items << '{"recordId":"poll-${i}","url":"https://example.test/${i}"}'
	}
	// 条数上限
	mut count_sess, _ := commands_review_session(map[string]string{}, '')
	defer { count_sess.close() }
	count_sess.hook_record_limit = 3
	count_sess.hook_byte_limit = 200
	count_sess.hook_payload_limit = 64
	assert append_polled_hook_records(mut count_sess, items, 0) == 5
	assert count_sess.hook_records.len == 3
	assert count_sess.hook_record_order == ['poll-2', 'poll-3', 'poll-4']
	assert 'poll-0' !in count_sess.hook_records
	assert 'poll-4' in count_sess.hook_records
	// 累计字节计入状态，并与实际记录一致
	assert count_sess.hook_state.record_bytes == hook_records_total_bytes(count_sess.hook_records)
	assert count_sess.hook_state.record_count == 3
	// 累计字节上限
	mut byte_sess, _ := commands_review_session(map[string]string{}, '')
	defer { byte_sess.close() }
	byte_sess.hook_record_limit = 100
	byte_sess.hook_byte_limit = 120
	byte_sess.hook_payload_limit = 64
	assert append_polled_hook_records(mut byte_sess, items, 0) == 5
	assert byte_sess.hook_state.record_bytes <= 120
	assert byte_sess.hook_records.len == 2
	assert byte_sess.hook_record_order == ['poll-3', 'poll-4']
	assert 'poll-0' !in byte_sess.hook_records
	assert 'poll-4' in byte_sess.hook_records
	// 单条 payload 超限直接丢弃
	mut big_sess, _ := commands_review_session(map[string]string{}, '')
	defer { big_sess.close() }
	big_sess.hook_payload_limit = 64
	oversized := '{"recordId":"big","url":"' + 'x'.repeat(80) + '"}'
	assert append_polled_hook_records(mut big_sess, [oversized], 0) == 0
	assert big_sess.hook_records.len == 0
	assert big_sess.hook_state.record_bytes == 0
}

fn test_commands_review_keyboard_masks_and_pointer_return() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"object","value":{"x":12,"y":24,"width":20,"height":10}}}'
	}, '')
	defer { sess.close() }
	for key, mask in {
		'Alt+A':        1
		'Ctrl+A':       2
		'Meta+A':       4
		'Shift+A':      8
		'Ctrl+Shift+A': 10
	} {
		dispatch_key(mut sess, key, 'keyDown', '')!
		assert cdp_extract_int(commands_review_call(calls), '"modifiers":') == mask
	}
	resolve_action_point_by_selector(mut sess, '#button')!
	assert cdp_extract_str(commands_review_call(calls), 'expression').contains('return el;')
}

fn test_commands_review_wait_stable_not_download() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"boolean","value":true}}'
	}, '')
	defer { sess.close() }
	assert cmd_wait(mut sess, '{"stable":"#button","timeout":1}').contains('to stabilize')
	for calls.len > 0 {
		assert !commands_review_call(calls).contains('DownloadBehavior')
	}
}

fn test_commands_review_navigation_errors_and_timeout() {
	mut sess, _ := commands_review_session({
		'Page.navigate': '{"errorText":"net::ERR_NAME_NOT_RESOLVED"}'
	}, '')
	assert cmd_open(mut sess, '{"url":"https://invalid.test"}').contains('ERR_NAME_NOT_RESOLVED')
	sess.close()
	mut timeout_sess, _ := commands_review_session(map[string]string{}, '')
	defer { timeout_sess.close() }
	assert cmd_open(mut timeout_sess, '{"url":"https://invalid.test"}').contains('timeout waiting for page load')
}

fn test_commands_review_drag_propagates_and_releases() {
	for failed in ['mousePressed', 'mouseMoved', 'mouseReleased'] {
		mut sess, calls := commands_review_session({
			'Runtime.evaluate': '{"result":{"value":{"x":10,"y":20,"width":30,"height":40}}}'
		}, failed)
		result := cmd_drag(mut sess, '{"source":"#a","target":"#b"}')
		assert result.contains('injected ${failed} failure'), result
		mut releases := 0
		for calls.len > 0 {
			if cdp_extract_str(commands_review_call(calls), 'type') == 'mouseReleased' {
				releases++
			}
		}
		assert releases == if failed == 'mousePressed' {
			0
		} else if failed == 'mouseReleased' {
			2
		} else {
			1
		}
		sess.close()
	}
}

fn test_commands_review_fetch_auth_route_coexistence_and_idle() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"string","value":"https://example.test"}}'
	}, '')
	defer { sess.close() }
	assert cmd_set(mut sess, '{"property":"credentials","username":"alice","password":"secret"}') == 'null'
	assert cdp_extract_str(commands_review_call(calls), 'method') == 'Runtime.evaluate'
	assert commands_review_call(calls).contains('"handleAuthRequests":true')
	assert cmd_network(mut sess, '{"action":"route","url":"*example.test/private*","body":"ok"}') == 'null'
	assert commands_review_call(calls).contains('"handleAuthRequests":true')
	// 超过旧的 30 秒空闲期限，消费者仍须处理暂停请求。
	time.sleep(31 * time.second)
	sess.dispatch_event('Fetch.requestPaused', ProtocolResponse{ params: '{"requestId":"third","request":{"url":"https://third.test/pixel"}}' })
	assert commands_review_call(calls).contains('Fetch.continueRequest')
	sess.dispatch_event('Fetch.requestPaused', ProtocolResponse{ params: '{"requestId":"first","request":{"url":"https://example.test/private"}}' })
	assert commands_review_call(calls).contains('Fetch.fulfillRequest')
	for origin, source in {
		'https://example.test:443': 'Server'
		'https://third.test':       'Server'
		'https://example.test':     'Proxy'
	} {
		sess.dispatch_event('Fetch.authRequired', ProtocolResponse{ params: '{"requestId":"auth","authChallenge":{"origin":${json_str(origin)},"source":${json_str(source)}}}' })
		call := commands_review_call(calls)
		assert call.contains('Fetch.continueWithAuth')
		assert call.contains('ProvideCredentials') == (origin == 'https://example.test:443')
		assert call.contains('secret') == (origin == 'https://example.test:443')
	}
	assert cmd_network(mut sess, '{"action":"unroute"}') == 'null'
	assert !sess.has_route
	assert commands_review_call(calls).contains('"handleAuthRequests":true')
	assert !auth_origin_matches('https://third.test', '')
	assert !auth_origin_matches('https://example.test.evil', 'https://example.test')
	assert fetch_url_matches('https://?xample.test/*', 'https://example.test/a')
	assert fetch_url_matches('a\\*b', 'a*b')
}

fn test_commands_review_hook_body_limits_and_streaming() {
	dir := os.join_path(os.temp_dir(), 'commands_review_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'hook.cjs')
	js := '
const assert = require("node:assert/strict");
global.window = global;
global.location = {href:"https://example.test/"};
let response = {status:200, headers:{}, clone(){throw Error("unexpected clone");}};
global.fetch = function(){ return Promise.resolve(response); };
class XHR {
  open() {} setRequestHeader() {} send() { this.done(); }
  addEventListener(name, fn) { if(name === "loadend") this.done = fn; }
}
global.XMLHttpRequest = XHR;
global.__vBrowserHookConfig = {active:true,captureBody:false,captureResponse:false,maxBodyLen:7};
${network_hook_bootstrap_js()};
(async function(){
  let reads = 0;
  const body = {toJSON(){ reads++; return "secret"; },toString(){ reads++; return "secret"; }};
  const input = {url:"https://example.test", get body(){reads++; return body;}};
  const init = {get body(){reads++; return body;}};
  await fetch(input, init);
  const xhr = new XMLHttpRequest(); xhr.open("POST", "/"); xhr.send(body);
  assert.equal(reads, 0);
  assert.equal(__vBrowserHookState.events.length, 2);
  assert(__vBrowserHookState.events.every(e => e.requestBody === ""));
  __vBrowserHookConfig.captureBody = true;
  await fetch("/", {body:"中文中文中文"});
  assert.equal(__vBrowserHookState.events.at(-1).requestBody, "中文");
  xhr.send("😀😀😀");
  assert.equal(__vBrowserHookState.events.at(-1).requestBody, "😀");
  __vBrowserHookConfig.captureResponse = true;
  let canceled = 0;
  response = {status:200,headers:{},clone(){return {body:{getReader(){return {
    read(){return Promise.resolve({value:new TextEncoder().encode("中文".repeat(10000))});},
    cancel(){canceled++; return Promise.reject(Error("cancel failed"));}
  };}}};}};
  assert.equal(await fetch("/large"), response);
  await new Promise(r => setTimeout(r, 20));
  assert.equal(canceled, 1);
  assert(Buffer.byteLength(__vBrowserHookState.events.at(-1).responseBody) <= 7);
  response = {status:200,headers:{},clone(){return {body:{getReader(){return {
    read(){return new Promise(()=>{});}, cancel(){canceled++; return Promise.resolve();}
  };}}};}};
  const start = Date.now();
  assert.equal(await fetch("/sse"), response);
  assert(Date.now() - start < 1000);
  await new Promise(r => setTimeout(r, 5200));
  assert.equal(canceled, 2);
  response = {status:200,headers:{},clone(){throw Error("clone failed");}};
  assert.equal(await fetch("/clone-error"), response);
})().catch(e => { console.error(e); process.exitCode = 1; });
'
	os.write_file(path, js)!
	result := os.execute('env HOME=${shell_quote(dir)} node ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// ─── 审查修复 1：iframe 作用域只能包装一次 ──────────────────────

// 选择 iframe 之后，元素动作脚本已经自己进入了 iframe，
// 再被 eval_scoped_expression 包一层就会二次进入：
// 内层脚本在子文档里再 querySelector(frame_selector)，搜的不是主文档。
fn test_commands_review_frame_scope_is_wrapped_once() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"boolean","value":true}}'
	}, '')
	defer { sess.close() }
	sess.set_current_frame_selector('#frm')
	run_element_action(mut sess, '#btn', build_click_action_body())!
	mut joined := ''
	for calls.len > 0 {
		joined += commands_review_call(calls)
	}
	// 只允许出现一次 iframe 进入逻辑
	assert commands_review_count(joined, 'contentDocument') == 1, joined
	// 不能出现 eval(JSON.parse(...)) 这种二次包装
	assert !joined.contains('eval(JSON.parse('), joined
	// frame 选择器仍然按主文档查找
	assert joined.contains('document.querySelector(\\"#frm\\")'), joined
	// 元素选择器在子文档里查
	assert joined.contains('doc.querySelector(\\"#btn\\")'), joined
}

// 已经带作用域的脚本（build_element_scope_js / build_document_scope_js 产物）
// 必须走 eval_prepared_js，不能再被 eval_scoped_expression 包一层。
fn test_commands_review_prepared_js_is_not_wrapped_again() {
	mut sess, calls := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"string","value":"ok"}}'
	}, '')
	defer { sess.close() }
	sess.set_current_frame_selector('#frm')
	js := build_element_scope_js(mut sess, '#btn', 'return el.textContent;')
	eval_prepared_js(mut sess, js, false)!
	mut joined := ''
	for calls.len > 0 {
		joined += commands_review_call(calls)
	}
	assert commands_review_count(joined, 'contentDocument') == 1, joined
	assert !joined.contains('eval(JSON.parse('), joined
}

// ─── 审查修复 2：@eN 引用必须走 backendNodeId / objectId ─────────

// mock: @eN 引用——DOM 动作路径成功。
fn attach_axref_dom_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		match method {
			'DOM.resolveNode' {
				sess.on_message('{"id":${id},"result":{"objectId":"obj-1"}}')
			}
			'Runtime.callFunctionOn' {
				sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":true}}}')
			}
			'Runtime.evaluate' {
				sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":false}}}')
			}
			else {
				sess.on_message('{"id":${id},"result":{}}')
			}
		}
	}
}

// mock: @eN 引用——DOM 动作路径失败，鼠标回退路径按 backendNodeId 取边界框。
fn attach_axref_fallback_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		match method {
			'DOM.resolveNode' {
				sess.on_message('{"id":${id},"result":{"objectId":"obj-1"}}')
			}
			'Runtime.callFunctionOn' {
				if data.contains('var el = this') {
					// 动作体失败
					sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":false}}}')
				} else {
					// 边界框查询
					sess.on_message('{"id":${id},"result":{"result":{"type":"object","value":{"x":10,"y":20,"width":30,"height":40}}}}')
				}
			}
			'Runtime.evaluate' {
				sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":false}}}')
			}
			else {
				sess.on_message('{"id":${id},"result":{}}')
			}
		}
	}
}

// @e1 不是 CSS 选择器：DOM 路径必须通过 backendNodeId 解析后执行动作。
fn test_commands_review_axref_click_uses_backend_node() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_axref_dom_send(mut sess, mut sent)
	defer { sess.close() }
	axref_set(mut sess.axref, '@e1', AxRef{
		backend_node_id: 42
		role:            'button'
		name:            'Save'
	})
	res := cmd_click(mut sess, '{"selector":"@e1"}')
	assert res == 'null', res
	joined := sent.join('\n')
	assert joined.contains('DOM.resolveNode'), joined
	assert joined.contains('Runtime.callFunctionOn'), joined
	// 不能把 @e1 当 CSS 选择器去 querySelector
	assert !joined.contains('@e1'), joined
}

// 鼠标回退路径也必须按 backendNodeId 解析，不能拿 @e1 当 CSS 选择器。
fn test_commands_review_axref_mouse_fallback_uses_backend_node() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_axref_fallback_send(mut sess, mut sent)
	defer { sess.close() }
	axref_set(mut sess.axref, '@e1', AxRef{
		backend_node_id: 42
		role:            'button'
		name:            'Save'
	})
	res := cmd_click(mut sess, '{"selector":"@e1"}')
	assert res == 'null', res
	joined := sent.join('\n')
	assert joined.contains('Input.dispatchMouseEvent'), joined
	assert joined.contains('getBoundingClientRect'), joined
	assert !joined.contains('@e1'), joined
}

// 未知引用必须明确报错，而不是当成 CSS 选择器。
fn test_commands_review_unknown_axref_is_reported() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_axref_fallback_send(mut sess, mut sent)
	defer { sess.close() }
	res := cmd_click(mut sess, '{"selector":"@e99"}')
	assert res.starts_with('ERROR:'), res
	assert res.contains('unknown ref @e99'), res
}

// ─── 审查修复 3：networkidle 等待 ───────────────────────────────

// mock: 只回 frame 树，其它命令成功返回。
fn attach_frame_tree_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		if method == 'Page.getFrameTree' {
			sess.on_message('{"id":${id},"result":{"frameTree":{"frame":{"id":"F1","loaderId":"L1"}}}}')
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

// 等待前必须显式打开 lifecycle 事件上报；
// 事件必须属于目标 frame / loader 才算命中。
fn test_commands_review_networkidle_enables_lifecycle_and_filters_frame() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_frame_tree_send(mut sess, mut sent)
	defer { sess.close() }
	result_ch := chan string{cap: 1}
	spawn fn [mut sess, result_ch] () {
		wait_for_networkidle(mut sess, 5 * time.second) or {
			result_ch <- 'ERROR:${err}'
			return
		}
		result_ch <- 'ok'
	}()
	time.sleep(300 * time.millisecond)
	joined := sent.join('\n')
	assert joined.contains('Page.setLifecycleEventsEnabled'), joined
	// 别的 frame 的 networkIdle 不算命中
	sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{
		method: 'Page.lifecycleEvent'
		params: '{"name":"networkIdle","frameId":"F2","loaderId":"L1"}'
	})
	time.sleep(300 * time.millisecond)
	// 别的 loader 的 networkIdle 也不算命中
	sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{
		method: 'Page.lifecycleEvent'
		params: '{"name":"networkIdle","frameId":"F1","loaderId":"L9"}'
	})
	time.sleep(300 * time.millisecond)
	// 目标 frame + loader 的 networkIdle 才算命中
	sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{
		method: 'Page.lifecycleEvent'
		params: '{"name":"networkIdle","frameId":"F1","loaderId":"L1"}'
	})
	select {
		r := <-result_ch {
			assert r == 'ok', r
		}
		5 * time.second {
			panic('networkidle wait did not finish')
		}
	}
}

// 无关事件不能重置时限：整个等待过程受固定 deadline 约束。
fn test_commands_review_networkidle_uses_fixed_deadline() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_frame_tree_send(mut sess, mut sent)
	defer { sess.close() }
	spawn fn [mut sess] () {
		for _ in 0 .. 40 {
			time.sleep(50 * time.millisecond)
			sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{
				method: 'Page.lifecycleEvent'
				params: '{"name":"domContentLoaded","frameId":"F1","loaderId":"L1"}'
			})
		}
	}()
	start := time.now()
	if _ := wait_for_networkidle(mut sess, 600 * time.millisecond) {
		assert false, 'networkidle should time out'
	}
	elapsed := time.now() - start
	assert elapsed < 3 * time.second, elapsed.str()
}

// ─── 审查修复 4：cursor-interactive 的 nth-of-type 索引 ──────────

// :nth-of-type 只按标签计数，索引必须基于所有同标签兄弟。
fn test_commands_review_cursor_selector_nth_of_type_uses_all_siblings() {
	dir := os.join_path(os.temp_dir(), 'commands_review_cursor_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	js := '
const assert = require("node:assert/strict");
${cursor_selector_helper_js()}
function makeEl(tag) { return { tagName: tag }; }
const span = makeEl("SPAN");
const divY = makeEl("DIV");
const divX = makeEl("DIV");
const parent = { children: [span, divY, divX] };
span.parentElement = parent;
divY.parentElement = parent;
divX.parentElement = parent;
// 两个 DIV 兄弟：第二个 DIV 的 :nth-of-type 索引必须是 2，
// 按「同标签且同 class」过滤会错误地算成 1。
assert.equal(nthOfTypeIndex(divX), 2);
assert.equal(nthOfTypeIndex(divY), 1);
assert.equal(nthOfTypeIndex(span), 1);
// 兜底路径用 nth-child（按所有兄弟计数）
const leaf = makeEl("SPAN");
const mid = makeEl("DIV");
const root = makeEl("BODY");
root.parentElement = null;
root.children = [mid];
mid.parentElement = root;
mid.children = [leaf];
leaf.parentElement = mid;
assert.equal(strictSelector(leaf), "div:nth-child(1) > span:nth-child(1)");
'
	path := os.join_path(dir, 'cursor.cjs')
	os.write_file(path, js)!
	result := os.execute('env HOME=${shell_quote(dir)} node ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// 生成的快照脚本必须用 nthOfTypeIndex，且整体语法正确。
fn test_commands_review_cursor_snapshot_js_uses_nth_of_type_index() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	js := build_cursor_interactive_snapshot_js(mut sess, 7)
	assert js.contains('nthOfTypeIndex(current)'), js
	// 旧的错误实现：按「同标签且同 class」过滤兄弟
	assert !js.contains('matching.indexOf(current)'), js
	dir := os.join_path(os.temp_dir(), 'commands_review_cursor_js_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'snapshot.js')
	os.write_file(path, js)!
	result := os.execute('env HOME=${shell_quote(dir)} node --check ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// ─── 审查修复 5：标注截图 ───────────────────────────────────────

// mock: AX 树 + 节点矩形 + 截图。
fn attach_annotate_send(mut sess CdpSession, mut sent []string, ax_nodes string) {
	sess.send_fn = fn [mut sess, mut sent, ax_nodes] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		match method {
			'Accessibility.getFullAXTree' {
				sess.on_message('{"id":${id},"result":{"nodes":${ax_nodes}}}')
			}
			'DOM.resolveNode' {
				sess.on_message('{"id":${id},"result":{"objectId":"obj-1"}}')
			}
			'Runtime.callFunctionOn' {
				sess.on_message('{"id":${id},"result":{"result":{"type":"object","value":{"x":10,"y":20,"width":30,"height":40}}}}')
			}
			'Runtime.evaluate' {
				sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":true}}}')
			}
			'Page.captureScreenshot' {
				sess.on_message('{"id":${id},"result":{"data":"aGVsbG8="}}')
			}
			else {
				sess.on_message('{"id":${id},"result":{}}')
			}
		}
	}
}

// 标注截图必须走 CDP（AX 树 + 节点坐标 + 截图），不依赖扩展 API。
fn test_commands_review_annotate_uses_cdp_not_extension_api() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_annotate_send(mut sess, mut sent, '[{"nodeId":"1","role":{"type":"role","value":"button"},"name":{"type":"computedString","value":"Save"},"backendDOMNodeId":7}]')
	defer { sess.close() }
	dir := os.join_path(os.temp_dir(), 'commands_review_annotate_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	out_path := os.join_path(dir, 'shot.png')
	res := cmd_screenshot(mut sess, '{"path":${json_str(out_path)},"annotate":true}')
	assert res.contains('"labelsCount":1'), res
	assert res.contains('"role":"button"'), res
	assert res.contains('"name":"Save"'), res
	joined := sent.join('\n')
	assert joined.contains('Accessibility.getFullAXTree'), joined
	assert joined.contains('DOM.resolveNode'), joined
	assert joined.contains('Runtime.callFunctionOn'), joined
	assert joined.contains('Page.captureScreenshot'), joined
	// 旧实现靠 chrome.runtime.sendMessage，扩展里没有对应处理器
	assert !joined.contains('chrome.runtime'), joined
	assert os.exists(out_path)
	// 覆盖层必须在截图后被移除
	assert joined.contains('__vBrowserAnnotateOverlay'), joined
}

// AX 树里没有可交互元素时必须明确报错。
fn test_commands_review_annotate_reports_no_interactive_elements() {
	mut sent := []string{}
	mut sess := new_cdp_session(fn (_ string) ! {})
	attach_annotate_send(mut sess, mut sent, '[]')
	defer { sess.close() }
	res := cmd_screenshot(mut sess, '{"annotate":true}')
	assert res.contains('no interactive elements found'), res
}

// 覆盖层脚本必须语法正确且不调用扩展 API。
fn test_commands_review_annotate_overlay_js_is_valid() {
	labels := [
		AnnotateLabel{
			num:    1
			role:   'button'
			name:   'Save'
			x:      10
			y:      20
			width:  30
			height: 40
		},
	]
	js := build_screenshot_overlay_js(labels)
	assert !js.contains('chrome.runtime'), js
	assert js.contains('__vBrowserAnnotateOverlay'), js
	// 返回 Promise，由 CDP 以 awaitPromise 等待
	assert js.contains('(async function()'), js
	dir := os.join_path(os.temp_dir(), 'commands_review_overlay_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'overlay.js')
	os.write_file(path, js)!
	result := os.execute('env HOME=${shell_quote(dir)} node --check ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// 覆盖层脚本必须在 node 沙箱里真的能跑起来（不只是语法正确）。
fn test_commands_review_annotate_overlay_js_runs_in_node() {
	labels := [
		AnnotateLabel{
			num:    1
			role:   'button'
			name:   'Save'
			x:      10
			y:      20
			width:  30
			height: 40
		},
	]
	js := build_screenshot_overlay_js(labels)
	remove_js := build_screenshot_overlay_remove_js()
	dir := os.join_path(os.temp_dir(), 'commands_review_overlay_run_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	script := '
const assert = require("node:assert/strict");
const registry = {};
function makeEl(tag) {
	return {
		tagName: String(tag).toUpperCase(),
		style: {},
		children: [],
		attributes: {},
		textContent: "",
		setAttribute(k, v) { this.attributes[k] = v; },
		appendChild(child) { child.parentNode = this; this.children.push(child); if (child.id) registry[child.id] = child; return child; },
		removeChild(child) { this.children = this.children.filter(c => c !== child); if (child.id) delete registry[child.id]; return child; },
		parentNode: null,
	};
}
global.document = {
	getElementById(id) { return registry[id] || null; },
	createElement(tag) { return makeEl(tag); },
	documentElement: makeEl("html"),
};
global.requestAnimationFrame = function(fn) { fn(); };
(async function(){
	const overlay = ${json_str(js)};
	const remove = ${json_str(remove_js)};
	assert.equal(await eval(overlay), true);
	const layer = registry["__vBrowserAnnotateOverlay"];
	assert.ok(layer, "overlay layer missing");
	assert.equal(layer.children.length, 1);
	const box = layer.children[0];
	assert.equal(box.style.left, "10px");
	assert.equal(box.style.top, "20px");
	assert.equal(box.style.width, "30px");
	assert.equal(box.style.height, "40px");
	assert.equal(box.style.border, "2px solid #ff0000");
	assert.equal(box.children.length, 1);
	assert.equal(box.children[0].textContent, "1");
	assert.equal(eval(remove), true);
	assert.equal(registry["__vBrowserAnnotateOverlay"], undefined);
})().catch(e => { console.error(e); process.exitCode = 1; });
'
	path := os.join_path(dir, 'overlay_run.cjs')
	os.write_file(path, script)!
	result := os.execute('env HOME=${shell_quote(dir)} node ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// 内存直回响应，避免大块流测试经过 JSON 消息总线产生无关的额外副本。
fn commands_review_respond(mut sess CdpSession, id int, result string, message string) {
	sess.pending_mu.@lock()
	ch := sess.pending[id] or { panic('missing pending request') }
	sess.pending.delete(id)
	sess.pending_mu.unlock()
	ch <- ProtocolResponse{ id: id, result: result, err: message }
}

fn commands_review_node(script string) {
	dir := os.join_path(os.temp_dir(), 'commands_review_node_${rand.uuid_v4()}')
	os.mkdir_all(dir) or { panic(err) }
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'test.cjs')
	os.write_file(path, script) or { panic(err) }
	result := os.execute('env HOME=${shell_quote(dir)} node ${shell_quote(path)}')
	assert result.exit_code == 0, result.output
}

// 分块 base64 必须逐块解码，正常结束和读取失败都必须 IO.close。
fn test_commands_review_protocol_stream_chunks_and_close() {
	for fail in [false, true] {
		mut sess := new_cdp_session(fn (_ string) ! {})
		calls := chan string{cap: 10}
		chunks := chan string{cap: 2}
		chunks <- '{"data":"5Lit","base64Encoded":true,"eof":false}'
		chunks <- '{"data":"5paH","base64Encoded":true,"eof":true}'
		sess.send_fn = fn [mut sess, calls, chunks, fail] (data string) ! {
			method := commands_review_method(data)
			calls <- method
			id := cdp_extract_int(data, '"id":')
			if method == 'IO.read' {
				commands_review_respond(mut sess, id, if fail { '' } else { <-chunks }, if fail {
					'read denied'
				} else {
					''
				})
			} else {
				commands_review_respond(mut sess, id, '{}', '')
			}
		}
		if result := read_protocol_stream(mut sess, 'stream') {
			assert !fail
			assert result == '中文'
		} else {
			assert fail
			assert err.msg() == 'read denied'
		}
		assert <-calls == 'IO.read'
		if !fail {
			assert <-calls == 'IO.read'
		}
		assert <-calls == 'IO.close'
		sess.close()
	}
}

// 实际读取满 64 MiB 后再加一个字节，越界必须报错且执行 defer 关闭。
fn test_commands_review_protocol_stream_64_mib_limit() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	chunks := chan string{cap: 9}
	chunk := '{"data":"' + 'x'.repeat(8 * 1024 * 1024) + '","eof":false}'
	for _ in 0 .. 8 { chunks <- chunk }
	chunks <- '{"data":"x","eof":true}'
	closed := chan bool{cap: 1}
	sess.send_fn = fn [mut sess, chunks, closed] (data string) ! {
		id := cdp_extract_int(data, '"id":')
		if commands_review_method(data) == 'IO.read' {
			commands_review_respond(mut sess, id, <-chunks, '')
		} else {
			closed <- true
			commands_review_respond(mut sess, id, '{}', '')
		}
	}
	if _ := read_protocol_stream(mut sess, 'oversized') {
		assert false
	} else {
		assert err.msg().contains('exceeds 64 MiB')
	}
	assert <-closed
}

fn test_commands_review_transform_rules_strict_json_and_i64_timestamp() {
	view := RequestRecord{ method: 'PO"ST\\中文', request_body: 'body', response_body: 'response', cursor_hint: 'cursor=1' }
	// JSON.parse 而非宽松子串断言，确保对象键、布尔类型与转义全部合法。
	commands_review_node('const assert=require("node:assert/strict"); const rules=JSON.parse(${json_str(hook_transform_rules_json(view))}); assert.deepEqual(rules,{captureBody:true,captureResponse:true,hasCursorHint:true,method:${json_str(view.method)}});')
	assert cdp_extract_i64('{"timestamp":1700000123456}', '"timestamp":') == i64(1700000123456)
	assert cdp_extract_i64('{"timestamp": -1700000123456}', '"timestamp":') == i64(-1700000123456)
	record := hook_record_view_from_raw(HookRecord{ record_id: 'doc:1', raw_json: '{"timestamp":1700000123456}' })
	assert record.timestamp == i64(1700000123456)
}

fn test_commands_review_composite_hook_push_poll_dedup() {
	mut sess, _ := commands_review_session(map[string]string{}, '')
	defer { sess.close() }
	sess.hook_state.active = true
	first := '{"recordId":"document-a:1","timestamp":1700000123456}'
	second := '{"recordId":"document-b:1","timestamp":1700000123457}'
	sess.handle_hook_binding_push(first)
	assert append_polled_hook_records(mut sess, [first, second], 0) == 1
	sess.handle_hook_binding_push(second)
	assert sess.hook_record_order == ['document-a:1', 'document-b:1']
	assert sess.hook_state.record_count == 2
	assert sess.hook_state.record_bytes == first.len + second.len
}

// 真实 v3 旧包装器装上后升级，fetch/XHR 都必须改用复合键且不重复记录。
fn test_commands_review_hook_v3_is_reinstalled_as_v4() {
	legacy := network_hook_bootstrap_js().replace('var SCRIPT_VERSION = 4;', 'var SCRIPT_VERSION = 3;').replace('String(state.documentId) + ":" + String(++state.nextId)', 'String(++state.nextId)')
	commands_review_node('const assert=require("node:assert/strict"); global.window=global; global.location={href:"https://example.test/"}; global.fetch=()=>Promise.resolve({status:200,headers:{}}); class XHR{open(){} setRequestHeader(){} send(){this.done();} addEventListener(n,f){if(n==="loadend")this.done=f;}} global.XMLHttpRequest=XHR; global.__vBrowserHookConfig={active:true,captureBody:true};
${legacy};
(async()=>{await fetch("/old"); assert.equal(__vBrowserHookState.events.at(-1).recordId,"1");
${network_hook_bootstrap_js()};
assert.equal(__vBrowserHookVersion,4); const wrapped=fetch;
${network_hook_bootstrap_js()};
assert.equal(fetch,wrapped); __vBrowserHookState.events=[]; await fetch("/new"); const xhr=new XHR(); xhr.open("POST","/xhr");xhr.send("payload"); assert.equal(__vBrowserHookState.events.length,2); assert(__vBrowserHookState.events.every(e=>e.recordId.startsWith(__vBrowserHookState.documentId+":"))); assert.equal(__vBrowserHookState.events.at(-1).requestBody,"payload");})().catch(e=>{console.error(e);process.exitCode=1;});')
}

fn test_commands_review_poll_resets_index_on_document_change() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	calls := chan string{cap: 4}
	responses := chan string{cap: 3}
	responses <- '{"documentId":"a","index":0,"events":[{"recordId":"a:1"},{"recordId":"a:2"}]}'
	responses <- '{"documentId":"b","index":0,"events":[{"recordId":"b:1"}]}'
	responses <- '{"documentId":"b","index":1,"events":[]}'
	sess.send_fn = fn [mut sess, calls, responses] (data string) ! {
		calls <- data
		value := <-responses
		commands_review_respond(mut sess, cdp_extract_int(data, '"id":'), '{"result":{"type":"string","value":${json_str(value)}}}', '')
	}
	assert sync_network_hook_records(mut sess)! == 2
	assert sess.hook_state.last_synced_index == 2
	assert sync_network_hook_records(mut sess)! == 1
	assert sess.hook_state.last_synced_index == 1
	assert sync_network_hook_records(mut sess)! == 0
	assert sess.hook_record_order == ['a:1', 'a:2', 'b:1']
	assert commands_review_call(calls).contains('documentId')
	second := commands_review_call(calls)
	assert second.contains('slice(index)')
	assert second.contains('? 2 : 0')
	assert commands_review_call(calls).contains('? 1 : 0')
}

// HOME 必须真的隔离；检查落盘权限和符号链接目标未被覆盖。
fn test_commands_review_state_save_private_and_rejects_symlink() {
	home := os.join_path(os.temp_dir(), 'commands_review_state_${rand.uuid_v4()}')
	os.mkdir_all(home)!
	previous := os.getenv('HOME')
	os.setenv('HOME', home, true)
	defer {
		os.setenv('HOME', previous, true)
		os.rmdir_all(home) or {}
	}
	mut sess, _ := commands_review_session({
		'Network.getCookies': '{"cookies":[{"name":"secret","value":"token"}]}'
		'Runtime.evaluate':   '{"result":{"type":"string","value":"{\\"secret\\":\\"storage\\"}"}}'
	}, '')
	defer { sess.close() }
	result := cmd_state(mut sess, '{"action":"save","path":"private.json"}')
	path := os.join_path(home, '.v-browser', 'states', 'private.json')
	assert result == json_str(path), result
	assert os.read_file(path)!.contains('token')
	stat_cmd := $if macos { 'stat -f %Lp' } $else { 'stat -c %a' }
	mode := os.execute('${stat_cmd} ${shell_quote(path)}')
	assert mode.exit_code == 0
	assert mode.output.trim_space() == '600'
	target := os.join_path(home, 'untouched.json')
	os.write_file(target, 'untouched')!
	link := os.join_path(home, '.v-browser', 'states', 'link.json')
	os.symlink(target, link)!
	assert cmd_state(mut sess, '{"action":"save","path":"link.json"}').contains('symbolic link')
	assert os.read_file(target)! == 'untouched'
}

fn test_commands_review_network_watch_generation_inflight_and_accounting() {
	dir := os.join_path(os.temp_dir(), 'commands_review_watch_${rand.uuid_v4()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	mut sess, _ := commands_review_session({
		'Runtime.evaluate': '{"result":{"type":"string","value":"[\\"https://example.test/image.png\\"]"}}'
	}, '')
	defer { sess.close() }
	start_network_watch(mut sess, dir, '')!
	entry := TrackedNetworkRequest{ request_id: 'r1', url: 'https://example.test/image.png', finished: true, response_body_cached: true, response_body_raw: 'image' }
	sess.network_requests['r1'] = entry
	path, first_generation := reserve_network_watch_save(mut sess, entry)!
	if _, _ := reserve_network_watch_save(mut sess, entry) {
		assert false
	}
	sync_network_watch_existing_requests(mut sess)
	assert sess.network_watch.next_index == 1
	assert !os.exists(path)
	stop_network_watch(mut sess)
	// start 会同步已有请求并异步保存；这里暂时移除 mock 请求，避免与 generation 测试抢占同一 in-flight 槽位。
	sess.network_requests.delete('r1')
	start_network_watch(mut sess, dir, '')!
	sess.network_requests['r1'] = entry
	_, second_generation := reserve_network_watch_save(mut sess, entry)!
	assert first_generation != second_generation
	finish_network_watch_save(mut sess, 'r1', first_generation, true)
	finish_network_watch_save(mut sess, 'r1', first_generation, false)
	assert sess.network_watch.saved_request_ids.len == 0
	assert sess.network_watch.failed_count == 0
	if _, _ := reserve_network_watch_save(mut sess, entry) {
		assert false
	}
	finish_network_watch_save(mut sess, 'r1', second_generation, false)
	assert network_watch_status_json(mut sess).contains('"failedCount":1')
	assert network_watch_status_json(mut sess).contains('"savedCount":0')
	// 真正写盘成功才登记 saved。
	handle_network_watch_loading_finished(mut sess, 'r1')
	assert sess.network_watch.saved_request_ids.len == 1
	assert sess.network_watch.failed_count == 1
	assert fetch_config_snapshot(mut sess).saving_request_ids.len == 0
	assert os.ls(dir)!.len == 1
	// 写盘失败（父路径是普通文件）不能算 saved，重试耗尽后 failedCount 加一。
	blocker := os.join_path(dir, 'blocker')
	os.write_file(blocker, 'not a directory')!
	start_network_watch(mut sess, blocker + '/images', '') or {}
	sess.network_watch.target_dir = blocker
	second := TrackedNetworkRequest{ ...entry, request_id: 'r2' }
	sess.network_requests['r2'] = second
	handle_network_watch_loading_finished(mut sess, 'r2')
	assert sess.network_watch.saved_request_ids.len == 1
	assert sess.network_watch.failed_count == 2
	assert fetch_config_snapshot(mut sess).saving_request_ids.len == 0
}

fn test_commands_review_iframe_lifecycle_resolution_never_falls_back() {
	mut sess, _ := commands_review_session({
		'Page.getFrameTree': '{"frameTree":{"frame":{"id":"main","loaderId":"old"},"childFrames":[{"frame":{"id":"child","loaderId":"child-loader"}}]}}'
		'DOM.getDocument':   '{"root":{"nodeId":1}}'
		'DOM.querySelector': '{"nodeId":0}'
	}, '')
	defer { sess.close() }
	sess.set_current_frame_selector('#missing')
	if _ := resolve_lifecycle_target(mut sess) {
		assert false
	} else {
		assert err.msg().contains('iframe #missing')
	}
	if _ := wait_for_networkidle(mut sess, time.millisecond) {
		assert false
	} else {
		assert err.msg().contains('iframe #missing')
		assert !err.msg().contains('timeout')
	}
	assert !lifecycle_event_matches('{"name":"networkIdle","frameId":"main"}', 'main', 'new', '')
	assert !lifecycle_event_matches('{"name":"networkIdle","frameId":"main","loaderId":"old"}', 'main', 'new', '')
	assert lifecycle_event_matches('{"name":"networkIdle","frameId":"main","loaderId":"new"}', 'main', 'new', '')
}

// 不发送 frameNavigated：只靠 navigate 返回的 loaderId 过滤排队的旧 lifecycle。
fn test_commands_review_navigation_loader_and_same_document_events() {
	for same_document in [false, true] {
		mut sess := new_cdp_session(fn (_ string) ! {})
		defer { sess.close() }
		sess.send_fn = fn [mut sess, same_document] (data string) ! {
			id := cdp_extract_int(data, '"id":')
			method := commands_review_method(data)
			if method == 'Page.getFrameTree' {
				commands_review_respond(mut sess, id, '{"frameTree":{"frame":{"id":"F","loaderId":"old"}}}', '')
			} else if method == 'Page.navigate' {
				sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{ params: '{"name":"networkIdle","frameId":"F"}' })
				sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{ params: '{"name":"networkIdle","frameId":"F","loaderId":"old"}' })
				commands_review_respond(mut sess, id, if same_document {
					'{"frameId":"F"}'
				} else {
					'{"frameId":"F","loaderId":"new"}'
				}, '')
			} else {
				commands_review_respond(mut sess, id, '{}', '')
			}
		}
		done := chan string{cap: 1}
		spawn fn [mut sess, done] () {
			navigate_and_wait_networkidle(mut sess, 'https://example.test/#new') or {
				done <- err.msg()
				return
			}
			done <- 'ok'
		}()
		time.sleep(150 * time.millisecond)
		assert done.len == 0
		if same_document {
			sess.dispatch_event('Page.navigatedWithinDocument', ProtocolResponse{ params: '{"frameId":"other","url":"https://example.test/#new"}' })
		} else {
			sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{ params: '{"name":"networkIdle","frameId":"F","loaderId":"unrelated"}' })
		}
		time.sleep(100 * time.millisecond)
		assert done.len == 0
		if same_document {
			sess.dispatch_event('Page.navigatedWithinDocument', ProtocolResponse{ params: '{"frameId":"F","url":"https://example.test/#new"}' })
		} else {
			sess.dispatch_event('Page.lifecycleEvent', ProtocolResponse{ params: '{"name":"networkIdle","frameId":"F","loaderId":"new"}' })
		}
		select {
			result := <-done {
				assert result == 'ok', result
			}
			2 * time.second {
				panic('navigation wait did not complete')
			}
		}
	}
}

fn test_commands_review_networkidle_navigation_reports_error_text_immediately() {
	mut sess, _ := commands_review_session({
		'Page.getFrameTree': '{"frameTree":{"frame":{"id":"F","loaderId":"old"}}}'
		'Page.navigate':     '{"errorText":"net::ERR_NAME_NOT_RESOLVED"}'
	}, '')
	defer { sess.close() }
	start := time.now()
	if _ := navigate_and_wait_networkidle(mut sess, 'https://invalid.test') {
		assert false
	} else {
		assert err.msg().contains('ERR_NAME_NOT_RESOLVED')
	}
	assert time.now() - start < time.second
}

fn test_commands_review_cursor_backend_identity_and_stale_reference() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	calls := chan string{cap: 20}
	sess.send_fn = fn [mut sess, calls] (data string) ! {
		calls <- data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		mut result := '{}'
		if method == 'Runtime.evaluate' {
			expr := cdp_extract_str(data, 'expression')
			result = if expr.contains('snapshotNodes.push(el)') {
				'{"result":{"type":"string","value":"#stable\\tTarget\\tclickable\\tonclick"}}'
			} else if expr.contains('return el;') {
				'{"result":{"objectId":"original-node"}}'
			} else {
				'{"result":{"type":"boolean","value":true}}'
			}
		} else if method == 'DOM.describeNode' {
			result = '{"node":{"backendNodeId":42}}'
		} else if method == 'DOM.resolveNode' {
			result = '{"object":{"objectId":"original-node"}}'
		} else if method == 'Runtime.callFunctionOn' {
			result = '{"result":{"type":"boolean","value":true}}'
		}
		commands_review_respond(mut sess, id, result, '')
	}
	out := render_cursor_interactive_snapshot(mut sess, 1, mut sess.axref, 10)!
	assert out.contains('@e1 [clickable] Target')
	reference := axref_get(&sess.axref, '@e1') or { panic('missing ref') }
	assert reference.backend_node_id == 42
	assert reference.selector == ''
	// 即使旧引用仍带 selector，动作也必须先使用 backendNodeId。
	axref_set(mut sess.axref, '@e1', AxRef{ backend_node_id: 42, selector: '#replacement' })
	assert cmd_click(mut sess, '{"selector":"@e1"}') == 'null'
	mut joined := ''
	for calls.len > 0 { joined += commands_review_call(calls) }
	assert joined.contains('DOM.describeNode')
	assert !joined.contains('#replacement')
	sess.send_fn = fn [mut sess] (data string) ! {
		commands_review_respond(mut sess, cdp_extract_int(data, '"id":'), '{}', if commands_review_method(data) == 'DOM.resolveNode' {
			'No node with given id found'
		} else {
			''
		})
	}
	assert cmd_click(mut sess, '{"selector":"@e1"}').contains('stale-reference')
}

fn test_commands_review_cursor_duplicate_testid_and_id_are_not_trusted() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	js := build_cursor_interactive_snapshot_js(mut sess, 10)
	commands_review_node('const assert=require("node:assert/strict"); global.CSS={escape:s=>s}; const root={tagName:"BODY",children:[],parentElement:null}; function el(){return {tagName:"DIV",id:"duplicate",classList:[],parentElement:root,getAttribute(n){return n==="data-testid"?"duplicate":n==="onclick"?"handler":null;},hasAttribute(n){return n==="onclick";},getBoundingClientRect(){return {width:10,height:10};},innerText:"Target"};} const a=el(),b=el();root.children=[a,b]; global.window={getComputedStyle(){return {cursor:"default"};}};global.document={body:root,querySelectorAll(s){if(s.startsWith("[data-testid="))throw Error("invalid selector");if(s==="#duplicate")return [a,b];if(s==="div:nth-of-type(1)")return [a];if(s==="div:nth-of-type(2)")return [b];if(s.includes("[onclick]"))return [a,b];return [];}}; const result=eval(${json_str(js)});assert(result.includes("div:nth-of-type(1)"));assert(result.includes("div:nth-of-type(2)"));assert(!result.includes("#duplicate"));assert(!result.includes("[data-testid="));')
}

// 带 backendNodeId 的引用即使保留旧 selector，也必须按节点身份解析；节点失效要明确报 stale-reference。
fn test_commands_review_resolver_backend_identity_and_unique_selector_fallback() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	axref_set(mut sess.axref, '@e1', AxRef{ backend_node_id: 42, selector: '#replacement' })
	calls := chan string{cap: 20}
	sess.send_fn = fn [mut sess, calls] (data string) ! {
		calls <- data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		result := match method {
			'DOM.resolveNode' { '{"object":{"objectId":"node-42"}}' }
			'Runtime.callFunctionOn' {
				'{"result":{"type":"object","value":{"x":10,"y":20,"width":30,"height":40}}}'
			}
			else { '{}' }
		}
		commands_review_respond(mut sess, id, result, '')
	}
	resolved := resolve_axref(mut sess, '@e1')!
	assert resolved.x == 25
	assert resolved.y == 40
	mut joined := ''
	for calls.len > 0 { joined += commands_review_call(calls) }
	assert joined.contains('DOM.resolveNode')
	assert !joined.contains('#replacement')

	axref_set(mut sess.axref, '@e2', AxRef{ selector: '#ambiguous' })
	sess.send_fn = fn [mut sess] (data string) ! {
		commands_review_respond(mut sess, cdp_extract_int(data, '"id":'), '{"result":{"type":"object","value":{"__vbrowserSelectorCount":2}}}', '')
	}
	if _ := resolve_axref(mut sess, '@e2') {
		assert false
	} else {
		assert err.msg().contains('stale-reference')
		assert err.msg().contains('exactly one')
	}

	axref_set(mut sess.axref, '@e1', AxRef{ backend_node_id: 42, selector: '#replacement' })
	sess.send_fn = fn [mut sess] (data string) ! {
		commands_review_respond(mut sess, cdp_extract_int(data, '"id":'), '{}', if commands_review_method(data) == 'DOM.resolveNode' {
			'No node with given id found'
		} else {
			''
		})
	}
	if _ := resolve_axref(mut sess, '@e1') {
		assert false
	} else {
		assert err.msg().contains('stale-reference')
	}
}

fn test_commands_review_annotation_coordinates_never_silently_use_zero_scroll() {
	// 同源子 frame 不读 top.scrollX；跨源拿不到 frame owner 必须明确抛错。
	commands_review_node('const assert=require("node:assert/strict");const fn=eval("("+${json_str(annotate_rect_function)}+")"); const top={get scrollX(){throw Error("must not read top scroll in child");}};top.top=top;const owner={ownerDocument:{defaultView:top},clientLeft:2,clientTop:3,getBoundingClientRect(){return {left:100,top:200};}};const child={top:top,frameElement:owner};const node={ownerDocument:{defaultView:child},getBoundingClientRect(){return {left:10,top:20,width:30,height:40};}};const rect=fn.call(node);assert.equal(rect.x,112);assert.equal(rect.y,223);assert.equal(rect.needsTopScroll,true);child.frameElement=null;assert.throws(()=>fn.call(node),/coordinate conversion failed/);')
	mut sess, _ := commands_review_session({
		'DOM.resolveNode':        '{"objectId":"child-node"}'
		'Runtime.callFunctionOn': '{"result":{"type":"object","value":{"x":12,"y":23,"width":30,"height":40,"needsTopScroll":true}}}'
		'Runtime.evaluate':       '{"result":{"type":"object","value":{"x":5,"y":700}}}'
	}, '')
	defer { sess.close() }
	rect := annotate_node_rect(mut sess, 7)!
	assert rect.x == 17
	assert rect.y == 723
	mut denied, _ := commands_review_session({
		'Accessibility.getFullAXTree': '{"nodes":[{"role":{"value":"button"},"backendDOMNodeId":7}]}'
		'DOM.resolveNode':             '{"objectId":"child-node"}'
		'Runtime.callFunctionOn':      '{"exceptionDetails":{"text":"annotation coordinate conversion failed: cross-origin frame"}}'
	}, '')
	defer { denied.close() }
	assert cmd_screenshot(mut denied, '{"annotate":true}').contains('coordinate conversion failed')
}

// 注入已经 appendChild 后抛错也要清理；两次截图使用不同的随机 ID。
fn test_commands_review_annotation_overlay_cleanup_on_injection_failure() {
	mut sess := new_cdp_session(fn (_ string) ! {})
	defer { sess.close() }
	calls := chan string{cap: 30}
	sess.send_fn = fn [mut sess, calls] (data string) ! {
		calls <- data
		id := cdp_extract_int(data, '"id":')
		method := commands_review_method(data)
		result := match method {
			'Accessibility.getFullAXTree' {
				'{"nodes":[{"role":{"value":"button"},"backendDOMNodeId":7}]}'
			}
			'DOM.resolveNode' { '{"objectId":"node"}' }
			'Runtime.callFunctionOn' {
				'{"result":{"type":"object","value":{"x":0,"y":0,"width":10,"height":10}}}'
			}
			'Runtime.evaluate' {
				if cdp_extract_str(data, 'expression').contains('appendChild(layer)') {
					'{"exceptionDetails":{"text":"injection failed after append"}}'
				} else {
					'{"result":{"type":"boolean","value":true}}'
				}
			}
			else { '{}' }
		}
		commands_review_respond(mut sess, id, result, '')
	}
	mut ids := []string{}
	for _ in 0 .. 2 {
		assert cmd_screenshot(mut sess, '{"annotate":true}').contains('injection failed')
		mut injected := ''
		mut cleanup := ''
		for calls.len > 0 {
			expr := cdp_extract_str(commands_review_call(calls), 'expression')
			if expr.contains('appendChild(layer)') { injected = expr }
			if expr.contains('removeChild(el)') { cleanup = expr }
		}
		id := injected.all_after('var id = "').all_before('";')
		assert id.starts_with('__vBrowserAnnotateOverlay_')
		assert cleanup.contains(id)
		ids << id
	}
	assert ids[0] != ids[1]
}

fn test_commands_review_random_overlay_preserves_page_element_and_cleanup_is_idempotent() {
	id := '__vBrowserAnnotateOverlay_${rand.uuid_v4()}'
	js := build_screenshot_overlay_js([AnnotateLabel{ num: 1, width: 10, height: 10 }], id)
	remove := build_screenshot_overlay_remove_js(id)
	commands_review_node('const assert=require("node:assert/strict");const registry={};function el(){return {style:{},attributes:{},children:[],setAttribute(k,v){this.attributes[k]=v;},appendChild(c){c.parentNode=this;this.children.push(c);if(c.id)registry[c.id]=c;},removeChild(c){delete registry[c.id];}};}const page=el();registry.__vBrowserAnnotateOverlay=page;global.document={getElementById(id){return registry[id];},createElement:el,documentElement:el()};global.requestAnimationFrame=f=>f();(async()=>{assert.equal(await eval(${json_str(js)}),true);assert.equal(registry.__vBrowserAnnotateOverlay,page);assert.equal(eval(${json_str(remove)}),true);assert.equal(eval(${json_str(remove)}),true);assert.equal(registry[${json_str(id)}],undefined);assert.equal(registry.__vBrowserAnnotateOverlay,page);})().catch(e=>{console.error(e);process.exitCode=1;});')
}
