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
