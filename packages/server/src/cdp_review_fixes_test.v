module main

import time

fn review_noop_send(_ string) ! {}

fn review_attach_mock_send(mut sess CdpSession, sent chan string) {
	sess.send_fn = fn [mut sess, sent] (data string) ! {
		sent <- data
		id := cdp_extract_int(data, '"id":')
		sess.on_message('{"id":${id},"result":{}}')
	}
}

// ─────────────────────────────────────────────────────────────
// 审查修复回归测试（cdp_session.v）
// 覆盖：事件分发不阻塞、hook 推送限额、tab 快照一致性、
//       重定向状态重置、attach/switch 错误传播、分层 JSON 取值。
// 本文件不连接任何端口（47978 / 47979 完全不涉及）。
// ─────────────────────────────────────────────────────────────

// review_drain_events 把 channel 里已缓冲的事件读干净，返回读到的条数。
fn review_drain_events(ch chan ProtocolResponse) int {
	mut count := 0
	mut done := false
	for !done {
		select {
			_ := <-ch {
				count++
			}
			else {
				done = true
			}
		}
	}
	return count
}

// review_fill_subscription 往订阅里灌大量事件，把分发队列填满
// （订阅方不消费）。
fn review_fill_subscription(mut sess CdpSession, method string, total int) {
	for i in 0 .. total {
		sess.on_message('{"method":"forwardCDPEvent","params":{"method":${json_str(method)},"params":{"requestId":"paused-${i}"}}}')
	}
}

// ─── 1. 事件分发不再阻塞 WebSocket 读线程 ──────────────────────

fn test_review_dispatch_event_never_blocks_on_full_queue() {
	mut sess := new_cdp_session(review_noop_send)
	_ := sess.subscribe('Page.loadEventFired')
	// 订阅方不消费：队列很快被填满
	review_fill_subscription(mut sess, 'Page.loadEventFired', 2000)
	sess.event_mu.@lock()
	dropped := sess.event_dropped
	sess.event_mu.unlock()
	// 溢出的事件被丢弃并计数（不能静默卡住读线程）
	assert dropped > 0
}

fn test_review_dispatch_event_is_fast_under_burst() {
	mut sess := new_cdp_session(review_noop_send)
	_ := sess.subscribe('Network.requestWillBeSent')
	start := time.now()
	review_fill_subscription(mut sess, 'Network.requestWillBeSent', 5000)
	elapsed := time.now() - start
	// 5000 条突发事件必须瞬间投递完，绝不能阻塞
	assert elapsed < u64(2 * time.second)
}

fn test_review_on_message_still_dispatches_responses_after_overflow() {
	mut sess := new_cdp_session(review_noop_send)
	sess.send_fn = fn [mut sess] (data string) ! {
		id := cdp_extract_int(data, '"id":')
		sess.on_message('{"id":${id},"result":{"ok":true}}')
	}
	// 订阅方不消费，把事件分发队列灌满
	_ = sess.subscribe('Network.requestWillBeSent')
	review_fill_subscription(mut sess, 'Network.requestWillBeSent', 1000)
	// 读线程没有被卡住：CDP 响应依然能正常分发
	start := time.now()
	resp := sess.send_command('Runtime.enable', '{}') or { panic(err) }
	elapsed := time.now() - start
	assert elapsed < u64(2 * time.second)
	assert resp.result.contains('"ok"')
}

fn test_review_unsubscribe_releases_inflight_dispatch() {
	mut sess := new_cdp_session(review_noop_send)
	ch := sess.subscribe('Page.loadEventFired')
	d := (sess.event_dispatchers['Page.loadEventFired'] or { panic('missing dispatcher') })[0]
	review_fill_subscription(mut sess, 'Page.loadEventFired', 2000)
	assert sess.event_dropped > 0
	// unsubscribe 必须立刻返回（不能等在途分发结束）
	start := time.now()
	sess.unsubscribe('Page.loadEventFired', ch)
	elapsed := time.now() - start
	assert elapsed < u64(time.second)
	// 分发线程已经退出：之后不会再有事件投递
	select {
		_ := <-d.done_ch {
		}
		time.second {
			panic('dispatcher did not terminate')
		}
	}
	review_drain_events(ch)
	time.sleep(200 * time.millisecond)
	select {
		_ := <-ch {
			panic('dispatcher should be stopped after unsubscribe')
		}
		200 * time.millisecond {
		}
	}
}

fn test_review_close_releases_inflight_dispatch() {
	mut sess := new_cdp_session(review_noop_send)
	ch := sess.subscribe('Page.loadEventFired')
	d := (sess.event_dispatchers['Page.loadEventFired'] or { panic('missing dispatcher') })[0]
	review_fill_subscription(mut sess, 'Page.loadEventFired', 2000)
	assert sess.event_dropped > 0
	// close 必须立刻返回
	start := time.now()
	sess.close()
	elapsed := time.now() - start
	assert elapsed < u64(time.second)
	select {
		_ := <-d.done_ch {
		}
		time.second {
			panic('dispatcher did not terminate')
		}
	}
	review_drain_events(ch)
	time.sleep(200 * time.millisecond)
	select {
		_ := <-ch {
			panic('dispatcher should be stopped after close')
		}
		200 * time.millisecond {
		}
	}
}

fn test_review_critical_event_overflow_fails_paused_request() {
	sent := chan string{cap: 1024}
	mut sess := new_cdp_session(review_noop_send)
	defer { sess.close() }
	review_attach_mock_send(mut sess, sent)
	_ = sess.subscribe('Fetch.requestPaused')
	review_fill_subscription(mut sess, 'Fetch.requestPaused', 2000)
	select {
		data := <-sent {
			assert data.contains('Fetch.failRequest')
			assert data.contains('"requestId":"paused-')
		}
		2 * time.second {
			panic('missing overflow failure')
		}
	}
	select {
		data := <-sent {
			assert data.contains('Fetch.disable')
		}
		2 * time.second {
			panic('queued requests were not released')
		}
	}
	// 溢出的订阅被关闭：不再有分发器残留
	sess.event_mu.@lock()
	remaining := (sess.event_dispatchers['Fetch.requestPaused'] or { []&EventDispatch{} }).len
	sess.event_mu.unlock()
	assert remaining == 0
}

// ─── 2. hook 推送限额 ───────────────────────────────────────

fn test_review_hook_push_enforces_record_count_limit() {
	mut sess := new_cdp_session(review_noop_send)
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_record_limit = 100
	for i in 0 .. 150 {
		sess.handle_hook_binding_push('{"recordId":"rec-${i}"}')
	}
	// 条数被限制住，且 map 与顺序表保持一致
	assert sess.hook_record_order.len == 100
	assert sess.hook_records.len == 100
	// 环形淘汰：最旧的被淘汰，最新的还在
	assert 'rec-0' !in sess.hook_records
	assert 'rec-149' in sess.hook_records
	assert sess.hook_record_order[0] == 'rec-50'
}

fn test_review_hook_push_enforces_total_byte_limit() {
	mut sess := new_cdp_session(review_noop_send)
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_byte_limit = 200
	for i in 0 .. 20 {
		sess.handle_hook_binding_push('{"recordId":"rec-${i}","pad":"0123456789"}')
	}
	// 累计字节被限制住，map 与顺序表保持一致
	assert sess.hook_state.record_bytes <= 200
	assert sess.hook_records.len == sess.hook_record_order.len
	assert sess.hook_record_order.len > 0
}

fn test_review_hook_push_rejects_oversized_payload() {
	mut sess := new_cdp_session(review_noop_send)
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_payload_limit = 64
	sess.handle_hook_binding_push('{"recordId":"big","pad":"${'x'.repeat(200)}"}')
	// 超长 payload 直接丢弃
	assert sess.hook_record_order.len == 0
	assert 'big' !in sess.hook_records
}

fn test_review_hook_push_rejected_when_hook_inactive() {
	mut sess := new_cdp_session(review_noop_send)
	// hook 已安装但被停止：属于非活动状态，不再接收推送
	sess.hook_state.injected = true
	sess.hook_state.active = false
	sess.handle_hook_binding_push('{"recordId":"stopped-1"}')
	assert sess.hook_record_order.len == 0
	assert 'stopped-1' !in sess.hook_records
}

fn test_review_hook_push_ignores_records_without_id() {
	mut sess := new_cdp_session(review_noop_send)
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.handle_hook_binding_push('{"method":"GET"}')
	sess.handle_hook_binding_push('not-json')
	assert sess.hook_record_order.len == 0
}

// ─── 3. tab 快照一致性 ──────────────────────────────────────

fn test_review_tab_snapshot_keeps_consistent_state() {
	mut sess := new_cdp_session(review_noop_send)
	sess.current_tab_id = 7
	sess.hook_state.active = true
	sess.hook_state.injected = true
	sess.hook_state.filter = 'api'
	sess.hook_state.record_bytes = 42
	sess.hook_state.record_bytes_tracked = 1
	sess.hook_records['rec-1'] = HookRecord{
		record_id: 'rec-1'
		raw_json:  '{"recordId":"rec-1"}'
	}
	sess.hook_record_order = ['rec-1']
	sess.network_watch.active = true
	sess.network_watch.filter = 'api'
	sess.network_watch.candidate_urls = map[string]bool{
		'u1': true
	}
	sess.save_current_tab_context()
	ctx := sess.tab_contexts[7] or { panic('missing tab context') }
	// hook / watch 状态必须在锁内克隆，快照内部一致
	assert ctx.hook_state.active
	assert ctx.hook_state.filter == 'api'
	assert ctx.hook_state.record_bytes == 42
	assert ctx.hook_state.record_bytes_tracked == 1
	assert ctx.hook_records.len == 1
	assert ctx.hook_record_order == ['rec-1']
	assert ctx.network_watch.active
	assert ctx.network_watch.filter == 'api'
	assert ctx.network_watch.candidate_urls['u1']
}

// ─── 4. 重定向复用 requestId 时重置上一跳状态 ──────────────────

fn test_review_redirect_resets_previous_hop_state() {
	mut sess := new_cdp_session(review_noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r1","type":"XHR","request":{"url":"https://api.example.com/p","method":"POST","postData":"a=1","headers":{"content-type":"application/x-www-form-urlencoded"}}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.responseReceived","params":{"requestId":"r1","type":"XHR","response":{"url":"https://api.example.com/p","status":302,"statusText":"Found","headers":{"location":"https://api.example.com/q"}}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r1","type":"XHR","redirectResponse":{"url":"https://api.example.com/p","status":302},"request":{"url":"https://api.example.com/q","method":"GET","headers":{"accept":"*/*"}}}}}')
	entry := sess.network_request_snapshot('r1') or { panic(err) }
	// 新一跳：旧 body / 旧响应头 / 旧状态都不能混进来
	assert entry.method == 'GET'
	assert entry.url == 'https://api.example.com/q'
	assert entry.request_body == ''
	assert entry.status == 0
	assert entry.response_headers == ''
	assert !entry.status_from_extra
}

fn test_review_redirect_resets_extra_info_flags() {
	mut sess := new_cdp_session(review_noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r2","type":"XHR","request":{"url":"https://api.example.com/p","method":"POST","postData":"a=1"}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.responseReceivedExtraInfo","params":{"requestId":"r2","statusCode":302,"headers":{"location":"https://api.example.com/q"}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r2","type":"XHR","redirectResponse":{"status":302},"request":{"url":"https://api.example.com/q","method":"GET"}}}}')
	entry := sess.network_request_snapshot('r2') or { panic(err) }
	// ExtraInfo 的状态标志必须随上一跳一起清掉
	assert entry.status == 0
	assert !entry.status_from_extra
	assert entry.response_headers == ''
	assert entry.request_body == ''
}

// ─── 5. attach / switch 不再吞掉初始化错误 ────────────────────

fn test_review_attach_propagates_initialization_error() {
	mut sess := new_cdp_session(review_noop_send)
	sess.send_fn = fn [mut sess] (data string) ! {
		id := cdp_extract_int(data, '"id":')
		method := cdp_extract_str(data, 'method')
		if method == 'attachToTab' {
			sess.on_message('{"id":${id},"result":{"tabId":5}}')
			return
		}
		return error('cdp unavailable')
	}
	err_msg := sess.attach_to_tab() or { err.msg() }
	// 初始化失败必须上报，并说明是「会话初始化失败」
	assert err_msg.contains('session initialization failed')
	assert err_msg.contains('tab 5')
}

fn test_review_activate_reports_session_init_failure_without_switch() {
	mut sess := new_cdp_session(review_noop_send)
	review_attach_mock_send(mut sess, chan string{cap: 16})
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }
	sess.send_fn = fn (_ string) ! { return error('cdp unavailable') }
	mut err_msg := ''
	sess.activate_tab_context_from_result('{"tabId":1}') or { err_msg = err.msg() }
	// 同一个 tab：属于「会话初始化失败」
	assert err_msg.contains('session initialization failed')
	assert !err_msg.contains('target switched')
}

fn test_review_activate_reports_target_switched_failure() {
	mut sess := new_cdp_session(review_noop_send)
	review_attach_mock_send(mut sess, chan string{cap: 16})
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }
	sess.send_fn = fn (_ string) ! { return error('cdp unavailable') }
	mut err_msg := ''
	sess.activate_tab_context_from_result('{"tabId":2}') or { err_msg = err.msg() }
	// 切到新 tab 后初始化失败：错误信息要区分「目标已切换」
	assert err_msg.contains('target switched')
	assert err_msg.contains('session initialization failed')
}

// ─── 6. JSON 字段按层级取值 ──────────────────────────────────

fn test_review_request_method_not_taken_from_nested_headers() {
	mut sess := new_cdp_session(review_noop_send)
	// request.headers 里也有 "method"：必须取 request.method，不能取嵌套层级的
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r3","type":"XHR","request":{"headers":{"method":"DELETE"},"method":"GET","url":"https://api.example.com/x"}}}}')
	entry := sess.network_request_snapshot('r3') or { panic(err) }
	assert entry.method == 'GET'
	assert entry.url == 'https://api.example.com/x'
}

fn test_review_console_event_uses_structured_params() {
	mut sess := new_cdp_session(review_noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Runtime.consoleAPICalled","params":{"type":"log","args":[{"type":"string","value":"hello"}]}}}')
	msgs := sess.console_messages_snapshot()
	assert msgs.len == 1
	assert cdp_json_str(cdp_json_object(msgs[0]), 'type') == 'log'
}

fn test_review_hook_rejects_uninitialized_and_closed_sessions() {
	mut sess := new_cdp_session(review_noop_send)
	sess.handle_hook_binding_push('{"recordId":"before-start"}')
	assert sess.hook_records.len == 0
	sess.hook_state.active = true
	sess.close()
	sess.handle_hook_binding_push('{"recordId":"after-close"}')
	assert sess.hook_records.len == 0
}

fn test_review_hook_eviction_updates_counters_and_accepts_evicted_id() {
	mut sess := new_cdp_session(review_noop_send)
	sess.hook_state.active = true
	sess.hook_record_limit = 2
	for id in ['one', 'two', 'three', 'one'] {
		sess.handle_hook_binding_push('{"recordId":"${id}"}')
	}
	assert sess.hook_record_order == ['three', 'one']
	assert sess.hook_state.record_count == 2
	assert sess.hook_state.record_bytes == hook_records_total_bytes(sess.hook_records)
}

fn test_review_nested_envelopes_and_wrong_types_are_not_events() {
	mut sess := new_cdp_session(review_noop_send)
	defer { sess.close() }
	sess.on_message('{"decoy":{"params":{"method":"Network.requestWillBeSent","params":{"requestId":"wrong"}}},"method":"forwardCDPEvent","params":{"decoy":{"params":{"requestId":"also-wrong"}},"method":"Network.requestWillBeSent","params":{"nested":{"requestId":"nested"},"requestId":"right","request":{"headers":{"url":"bad","method":"DELETE"},"url":"https://example.test","method":"GET"}}}}')
	assert sess.network_requests.len == 1
	entry := sess.network_request_snapshot('right') or { panic(err) }
	assert entry.method == 'GET'
	assert cdp_json_str(cdp_json_object(entry.request_headers), 'method') == 'DELETE'
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":123}}}')
	assert sess.network_requests.len == 1
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Runtime.executionContextCreated","params":{"context":{"id":7,"auxData":{"isDefault":"true"}}}}}')
	assert sess.default_execution_context_ids().len == 0
	assert cdp_parse_message('{"id":"123","method":123}').id == 0
	assert cdp_parse_message('{"method":123}').method == ''
	fake_params := '{"method":"Network.requestWillBeSent","params":{"requestId":"string-envelope"}}'
	sess.on_message('{"method":"forwardCDPEvent","params":${json_str(fake_params)}}')
	assert sess.network_requests.len == 1
}

fn test_review_attach_by_url_reports_switched_initialization_failure() {
	for url in ['', 'https://example.test'] {
		mut sess := new_cdp_session(review_noop_send)
		sess.current_tab_id = 1
		sess.send_fn = fn [mut sess] (data string) ! {
			obj := cdp_json_object(data)
			id := cdp_json_int(obj, 'id')
			method := cdp_json_str(obj, 'method')
			if method == 'listTabs' {
				sess.on_message('{"id":${id},"result":[{"id":2,"windowId":1,"url":"https://example.test"}]}')
			} else if method == 'switchToTab' {
				sess.on_message('{"id":${id},"result":{"tabId":2}}')
			} else {
				return error('initialization refused')
			}
		}
		msg := sess.attach_to_tab_by_url(url) or { err.msg() }
		assert msg.contains('target switched to tab 2')
		assert msg.contains('initialization refused')
		assert sess.current_tab_id == 2
	}
}

fn test_review_snapshot_is_consistent_during_hook_pushes() {
	mut sess := new_cdp_session(review_noop_send)
	sess.current_tab_id = 1
	sess.hook_state.active = true
	sess.hook_record_limit = 20
	worker := spawn fn [mut sess] () {
		for i in 0 .. 500 {
			sess.handle_hook_binding_push('{"recordId":"concurrent-${i}"}')
			sess.network_watch_mu.@lock()
			sess.network_watch.next_index = i
			sess.network_watch.filter = i.str()
			sess.network_watch_mu.unlock()
		}
	}()
	for _ in 0 .. 500 {
		sess.save_current_tab_context()
		ctx := sess.tab_contexts[1] or { panic('missing snapshot') }
		assert ctx.hook_state.record_count == ctx.hook_record_order.len
		assert ctx.hook_records.len == ctx.hook_record_order.len
		assert ctx.hook_state.record_bytes == hook_records_total_bytes(ctx.hook_records)
		assert ctx.network_watch.filter.int() == ctx.network_watch.next_index
	}
	worker.wait()
}

fn test_review_reused_request_id_resets_cached_body_and_flags() {
	mut sess := new_cdp_session(review_noop_send)
	sess.network_requests['reuse'] = TrackedNetworkRequest{
		request_id:                'reuse'
		url:                       'https://old.test'
		method:                    'POST'
		finished:                  true
		request_body:              'old'
		response_body:             'old'
		response_body_raw:         'b2xk'
		response_body_base64:      true
		response_body_cached:      true
		response_headers_complete: true
		status_from_extra:         true
		status_text:               'Found'
		error_text:                'old error'
	}
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"reuse","request":{"url":"https://new.test","method":"GET"}}}}')
	entry := sess.network_request_snapshot('reuse') or { panic(err) }
	assert entry.request_body == ''
	assert entry.response_body == ''
	assert entry.response_body_raw == ''
	assert !entry.response_body_base64
	assert !entry.response_body_cached
	assert !entry.response_headers_complete
	assert !entry.status_from_extra
	assert !entry.finished
	assert entry.status_text == ''
	assert entry.error_text == ''
}
