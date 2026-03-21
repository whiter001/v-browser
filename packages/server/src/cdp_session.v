// cdp_session.v — CDP 命令发送器 + 事件总线
// 管理与浏览器扩展之间 WebSocket 上的 CDP 会话：
//   - 发出有序 id 的 CDP 命令并阻塞等候响应
//   - 接收扩展推送的 CDP 事件并分发给订阅者
module main

import x.json2 as json
import sync
import time
import encoding.base64

// ProtocolResponse 扩展发回的任意消息（响应 or 事件）
struct ProtocolResponse {
	id     int    // > 0 ⟹ response;  0 ⟹ event
	method string // CDP method（事件时非空）
	params string // raw JSON（事件 params）
	result string // raw JSON（响应 result）
	err    string // 错误描述
}

// EventSub 单个事件订阅
struct EventSub {
	ch chan ProtocolResponse
}

struct NetworkWatchState {
mut:
	active            bool
	target_dir        string
	filter            string
	candidate_urls    map[string]bool
	saved_request_ids map[string]bool
	next_index        int
}

struct HookState {
mut:
	active            bool
	injected          bool
	script_id         string
	script_version    int
	filter            string
	capture_body      bool
	capture_response  bool
	last_injected_at  string
	last_synced_index int
	record_count      int
}

struct HookRecord {
mut:
	record_id     string
	raw_json      string
	fallback_text string
}

struct RequestRecord {
mut:
	record_id        string
	source           string
	phase            string
	page_url         string
	method           string
	url              string
	signature        string
	cursor_hint      string
	request_headers  string
	request_body     string
	response_status  int
	status_text      string
	response_url     string
	response_ok      bool
	response_type    string
	ready_state      int
	with_credentials bool
	response_headers string
	response_body    string
	error_text       string
	timestamp        int
	fallback_text    string
}

struct ReplayTemplate {
mut:
	template_id             string
	request_signature       string
	method                  string
	url_pattern             string
	required_headers        string
	body_template           string
	transform_rules         string
	expected_response_shape string
	sample_record_id        string
}

struct TabContext {
mut:
	current_frame_selector string
	axref_refs             map[string]AxRef
	network_requests       map[string]TrackedNetworkRequest
	network_request_order  []string
	network_watch          NetworkWatchState
	hook_state             HookState
	hook_records           map[string]HookRecord
	hook_record_order      []string
	console_msgs           []string
	page_errors            []string
	dialog_events          []string
}

struct TabSummary {
	id        int
	window_id int
	title     string
	url       string
	active    bool
}

struct TrackedNetworkRequest {
mut:
	request_id       string
	url              string
	method           string
	resource_type    string
	status           int
	status_text      string
	error_text       string
	finished         bool
	request_headers  string
	response_headers string
}

// CdpSession 管理一个 WebSocket 连接上的 CDP 会话
@[heap]
struct CdpSession {
mut:
	next_id                int = 1
	pending                map[int]chan ProtocolResponse
	pending_mu             sync.Mutex
	send_fn                ?fn (string) ! // 向扩展 WS 发送 JSON 文本
	event_subs             map[string][]chan ProtocolResponse
	event_mu               sync.Mutex
	closed                 bool
	axref                  AxRefStore // @eN 引用映射（snapshot 命令填充）
	current_frame_selector string
	network_requests       map[string]TrackedNetworkRequest
	network_request_order  []string
	network_enabled        bool
	network_mu             sync.Mutex
	network_watch          NetworkWatchState
	network_watch_mu       sync.Mutex
	hook_state             HookState
	hook_records           map[string]HookRecord
	hook_record_order      []string
	hook_mu                sync.Mutex
	current_tab_id         int
	tab_contexts           map[int]TabContext
	tab_contexts_mu        sync.Mutex
	page_enabled           bool
	page_mu                sync.Mutex
	// 运行时缓存（debug 命令使用）
	console_msgs  []string
	page_errors   []string
	dialog_events []string
}

fn new_cdp_session(send_fn fn (string) !) &CdpSession {
	return &CdpSession{
		send_fn:           send_fn
		pending:           map[int]chan ProtocolResponse{}
		event_subs:        map[string][]chan ProtocolResponse{}
		network_requests:  map[string]TrackedNetworkRequest{}
		hook_records:      map[string]HookRecord{}
		hook_record_order: []string{}
		tab_contexts:      map[int]TabContext{}
		network_watch:     NetworkWatchState{
			candidate_urls:    map[string]bool{}
			saved_request_ids: map[string]bool{}
		}
		hook_state:        HookState{}
	}
}

fn (s &CdpSession) do_send(data string) ! {
	if f := s.send_fn {
		f(data)!
	} else {
		return error('send_fn not set')
	}
}

// send_command 发送 CDP 命令并阻塞等待响应（默认 30 s 超时）
// params_json: 参数 JSON 对象字符串，如 '{"url":"https://example.com"}'
fn (mut s CdpSession) send_command(method string, params_json string) !ProtocolResponse {
	return s.send_command_to(method, params_json, '', cdp_default_timeout)
}

fn (mut s CdpSession) send_bridge_command(method string, params_json string) !ProtocolResponse {
	return s.send_bridge_command_to(method, params_json, cdp_default_timeout)
}

fn (mut s CdpSession) send_bridge_command_to(method string, params_json string, timeout time.Duration) !ProtocolResponse {
	s.pending_mu.@lock()
	if s.closed {
		s.pending_mu.unlock()
		return error('cdp session is closed')
	}
	id := s.next_id
	s.next_id++
	ch := chan ProtocolResponse{cap: 1}
	s.pending[id] = ch
	s.pending_mu.unlock()

	params := if params_json == '' || params_json == 'null' { '{}' } else { params_json }
	raw := '{"id":${id},"method":${json_str(method)},"params":${params}}'

	s.do_send(raw) or {
		s.pending_mu.@lock()
		s.pending.delete(id)
		s.pending_mu.unlock()
		return error('send failed: ${err}')
	}

	if timeout != cdp_default_timeout {
		spawn fn [id, timeout, ch] (mut s CdpSession) {
			time.sleep(timeout)
			s.pending_mu.@lock()
			if id in s.pending {
				s.pending.delete(id)
				s.pending_mu.unlock()
				select {
					ch <- ProtocolResponse{
						id:  id
						err: 'timeout'
					} {}
					else {}
				}
			} else {
				s.pending_mu.unlock()
			}
		}(mut s)
		resp := <-ch
		if resp.err != '' {
			return error(resp.err)
		}
		return resp
	}

	select {
		resp := <-ch {
			if resp.err != '' {
				return error(resp.err)
			}
			return resp
		}
		cdp_default_timeout {
			s.pending_mu.@lock()
			s.pending.delete(id)
			s.pending_mu.unlock()
			return error('${method} timed out (30s)')
		}
	}
	return error('unreachable')
}

// send_command_to 带 sessionId + 自定义超时版本
fn (mut s CdpSession) send_command_to(method string, params_json string, session_id string, timeout time.Duration) !ProtocolResponse {
	s.pending_mu.@lock()
	if s.closed {
		s.pending_mu.unlock()
		return error('cdp session is closed')
	}
	id := s.next_id
	s.next_id++
	ch := chan ProtocolResponse{cap: 1}
	s.pending[id] = ch
	s.pending_mu.unlock()

	// 序列化 forwardCDPCommand 外层消息
	params := if params_json == '' || params_json == 'null' { '{}' } else { params_json }
	sid_field := if session_id != '' { ',"sessionId":${json_str(session_id)}' } else { '' }
	inner_params := '{"method":${json_str(method)},"params":${params}${sid_field}}'
	raw := '{"id":${id},"method":"forwardCDPCommand","params":${inner_params}}'

	s.do_send(raw) or {
		s.pending_mu.@lock()
		s.pending.delete(id)
		s.pending_mu.unlock()
		return error('send failed: ${err}')
	}

	// 用 goroutine 模拟可变 timeout（V select 只接受编译期常量 timeout）
	if timeout != cdp_default_timeout {
		// 非默认 timeout：spawn 一个定时取消 goroutine
		spawn fn [id, timeout, ch] (mut s CdpSession) {
			time.sleep(timeout)
			s.pending_mu.@lock()
			if id in s.pending {
				s.pending.delete(id)
				s.pending_mu.unlock()
				select {
					ch <- ProtocolResponse{
						id:  id
						err: 'timeout'
					} {}
					else {}
				}
			} else {
				s.pending_mu.unlock()
			}
		}(mut s)
		resp := <-ch
		if resp.err != '' {
			return error('CDP ${method} timed out or error: ${resp.err}')
		}
		return resp
	}

	select {
		resp := <-ch {
			if resp.err != '' {
				return error(resp.err)
			}
			return resp
		}
		cdp_default_timeout {
			s.pending_mu.@lock()
			s.pending.delete(id)
			s.pending_mu.unlock()
			return error('CDP ${method} timed out (30s)')
		}
	}
	return error('unreachable')
}

// attach_to_tab 发 attachToTab 命令，等扩展 attach chrome.debugger
fn (mut s CdpSession) attach_to_tab() !string {
	resp := s.send_bridge_command_to('attachToTab', '{}', cdp_attach_timeout) or {
		err_msg := err.msg()
		if err_msg.contains('timed out') {
			return error('Extension connection timeout: no extension connected within 60s. Please install the v-browser extension and allow the connection.')
		}
		if err_msg.contains('another debugger is already attached')
			|| err_msg.contains('debugger is already attached to the tab') {
			return error('Debugger conflict: another debugger is already attached to the tab. Close other CDP sessions (like Chrome DevTools) and run v-browser connect again.')
		}
		if err_msg.contains('no target tab available') || err_msg.contains('tab not found') {
			return error('No available tab: no tab is currently accessible. Switch to a normal webpage tab and run v-browser connect again.')
		}
		return error(err_msg)
	}
	s.activate_tab_context_from_result(resp.result) or {}
	return resp.result
}

fn (mut s CdpSession) attach_to_tab_by_url(target_url string) !string {
	if target_url.trim_space() == '' {
		resp := s.send_bridge_command('listTabs', '{}')!
		tab_id, window_id := find_best_tab_for_url_from_json(resp.result, '') or {
			return s.attach_to_tab()
		}
		if tab_id <= 0 {
			return s.attach_to_tab()
		}
		resp2 := s.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}') or {
			return error(err.msg())
		}
		s.activate_tab_context_from_result(resp2.result) or {}
		return resp2.result
	}
	tab_id, window_id := s.find_best_tab_for_url(target_url)!
	if tab_id <= 0 {
		return s.attach_to_tab()
	}
	resp := s.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}') or {
		return error(err.msg())
	}
	s.activate_tab_context_from_result(resp.result) or {}
	return resp.result
}

fn (mut s CdpSession) find_best_tab_for_url(target_url string) !(int, int) {
	resp := s.send_bridge_command('listTabs', '{}')!
	return find_best_tab_for_url_from_json(resp.result, target_url)
}

fn find_best_tab_for_url_from_json(tabs_json string, target_url string) !(int, int) {
	objects := split_json_array_objects(tabs_json)
	if objects.len == 0 {
		return error('no available tab')
	}
	needle := target_url.trim_space()
	mut active_fallback := TabSummary{}
	mut first_fallback := TabSummary{}
	mut matched_active := TabSummary{}
	mut matched := TabSummary{}
	for obj in objects {
		tab := TabSummary{
			id:        cdp_extract_int(obj, '"id":')
			window_id: cdp_extract_int(obj, '"windowId":')
			title:     cdp_extract_str(obj, 'title')
			url:       cdp_extract_str(obj, 'url')
			active:    cdp_extract_bool(obj, 'active')
		}
		if tab.id <= 0 {
			continue
		}
		if !is_connectable_tab_url(tab.url) {
			continue
		}
		if first_fallback.id == 0 {
			first_fallback = tab
		}
		if tab.active && active_fallback.id == 0 {
			active_fallback = tab
		}
		if needle != '' && tab.url.trim_space() == needle {
			if matched.id == 0 {
				matched = tab
			}
			if tab.active {
				matched_active = tab
			}
		}
	}
	if matched_active.id > 0 {
		return matched_active.id, matched_active.window_id
	}
	if matched.id > 0 {
		return matched.id, matched.window_id
	}
	if active_fallback.id > 0 {
		return active_fallback.id, active_fallback.window_id
	}
	if first_fallback.id > 0 {
		return first_fallback.id, first_fallback.window_id
	}
	return error('no available tab')
}

fn is_connectable_tab_url(url string) bool {
	trimmed := url.trim_space().to_lower()
	if trimmed == '' {
		return false
	}
	if trimmed.starts_with('chrome-extension:') {
		return false
	}
	if trimmed.starts_with('chrome:') || trimmed.starts_with('edge:')
		|| trimmed.starts_with('devtools:') {
		return false
	}
	return true
}

fn split_json_array_objects(raw string) []string {
	trimmed := raw.trim_space()
	if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
		return []string{}
	}
	mut items := []string{}
	mut depth := 0
	mut start := -1
	mut in_string := false
	mut escaped := false
	for i, c in trimmed {
		if in_string {
			if escaped {
				escaped = false
				continue
			}
			if c == `\\` {
				escaped = true
				continue
			}
			if c == `"` {
				in_string = false
			}
			continue
		}
		if c == `"` {
			in_string = true
			continue
		}
		if c == `{` {
			if depth == 0 {
				start = i
			}
			depth++
			continue
		}
		if c == `}` {
			if depth > 0 {
				depth--
				if depth == 0 && start >= 0 {
					items << trimmed[start..i + 1]
					start = -1
				}
			}
		}
	}
	return items
}

fn (mut s CdpSession) activate_tab_context_from_result(result string) ! {
	tab_id := cdp_extract_int(result, '"tabId":')
	if tab_id <= 0 {
		return
	}
	if s.current_tab_id > 0 && s.current_tab_id != tab_id {
		s.save_current_tab_context()
	}
	s.current_tab_id = tab_id
	s.restore_tab_context(tab_id)
	s.page_mu.@lock()
	s.page_enabled = false
	s.page_mu.unlock()
	s.network_mu.@lock()
	s.network_enabled = false
	s.network_mu.unlock()
	s.enable_page_events()!
	s.enable_network_tracking()!
	if s.network_watch.active {
		sync_network_watch_existing_requests(mut s)
	}
}

fn (mut s CdpSession) save_current_tab_context() {
	if s.current_tab_id <= 0 {
		return
	}
	mut axref_refs := map[string]AxRef{}
	s.axref.mu.@lock()
	for key, value in s.axref.refs {
		axref_refs[key] = value
	}
	s.axref.mu.unlock()
	mut network_requests := map[string]TrackedNetworkRequest{}
	s.network_mu.@lock()
	for key, value in s.network_requests {
		network_requests[key] = value
	}
	network_request_order := s.network_request_order.clone()
	s.network_mu.unlock()
	mut network_watch := NetworkWatchState{
		active:            s.network_watch.active
		target_dir:        s.network_watch.target_dir
		filter:            s.network_watch.filter
		candidate_urls:    clone_bool_map(s.network_watch.candidate_urls)
		saved_request_ids: clone_bool_map(s.network_watch.saved_request_ids)
		next_index:        s.network_watch.next_index
	}
	mut hook_state := HookState{
		active:            s.hook_state.active
		injected:          s.hook_state.injected
		script_id:         s.hook_state.script_id
		filter:            s.hook_state.filter
		capture_body:      s.hook_state.capture_body
		capture_response:  s.hook_state.capture_response
		last_injected_at:  s.hook_state.last_injected_at
		last_synced_index: s.hook_state.last_synced_index
		record_count:      s.hook_state.record_count
	}
	mut hook_records := map[string]HookRecord{}
	s.hook_mu.@lock()
	for key, value in s.hook_records {
		hook_records[key] = value
	}
	hook_record_order := s.hook_record_order.clone()
	s.hook_mu.unlock()
	s.tab_contexts_mu.@lock()
	s.tab_contexts[s.current_tab_id] = TabContext{
		current_frame_selector: s.current_frame_selector
		axref_refs:             axref_refs
		network_requests:       network_requests
		network_request_order:  network_request_order
		network_watch:          network_watch
		hook_state:             hook_state
		hook_records:           hook_records
		hook_record_order:      hook_record_order
		console_msgs:           s.console_msgs.clone()
		page_errors:            s.page_errors.clone()
		dialog_events:          s.dialog_events.clone()
	}
	s.tab_contexts_mu.unlock()
}

fn (mut s CdpSession) restore_tab_context(tab_id int) {
	s.tab_contexts_mu.@lock()
	ctx := s.tab_contexts[tab_id] or {
		s.tab_contexts_mu.unlock()
		s.current_frame_selector = ''
		s.axref.mu.@lock()
		s.axref.refs.clear()
		s.axref.mu.unlock()
		s.network_mu.@lock()
		s.network_requests.clear()
		s.network_request_order = []string{}
		s.network_enabled = false
		s.network_mu.unlock()
		s.network_watch_mu.@lock()
		s.network_watch = NetworkWatchState{
			candidate_urls:    map[string]bool{}
			saved_request_ids: map[string]bool{}
		}
		s.network_watch_mu.unlock()
		s.hook_mu.@lock()
		s.hook_state = HookState{}
		s.hook_records = map[string]HookRecord{}
		s.hook_record_order = []string{}
		s.hook_mu.unlock()
		s.console_msgs = []string{}
		s.page_errors = []string{}
		s.dialog_events = []string{}
		return
	}
	s.tab_contexts_mu.unlock()
	s.current_frame_selector = ctx.current_frame_selector
	s.axref.mu.@lock()
	s.axref.refs = clone_axref_map(ctx.axref_refs)
	s.axref.mu.unlock()
	s.network_mu.@lock()
	s.network_requests = clone_tracked_request_map(ctx.network_requests)
	s.network_request_order = ctx.network_request_order.clone()
	s.network_enabled = false
	s.network_mu.unlock()
	s.network_watch_mu.@lock()
	s.network_watch = clone_network_watch_state(ctx.network_watch)
	s.network_watch_mu.unlock()
	s.hook_mu.@lock()
	s.hook_state = clone_hook_state(ctx.hook_state)
	s.hook_records = clone_hook_record_map(ctx.hook_records)
	s.hook_record_order = ctx.hook_record_order.clone()
	s.hook_mu.unlock()
	s.console_msgs = ctx.console_msgs.clone()
	s.page_errors = ctx.page_errors.clone()
	s.dialog_events = ctx.dialog_events.clone()
}

// on_message 由 WebSocket on_message 回调调用，分发响应/事件
fn (mut s CdpSession) on_message(raw string) {
	resp := cdp_parse_message(raw)
	if resp.id > 0 {
		// 响应
		s.pending_mu.@lock()
		if ch := s.pending[resp.id] {
			s.pending.delete(resp.id)
			s.pending_mu.unlock()
			ch <- resp
		} else {
			s.pending_mu.unlock()
		}
		return
	}
	// 事件
	if resp.method != '' {
		// 内置缓存（console / errors）
		if resp.method == 'forwardCDPEvent' {
			inner_method := cdp_extract_str(resp.params, 'method')
			inner_params := cdp_extract_obj(resp.params, 'params')
			if inner_method == 'Runtime.consoleAPICalled' {
				s.console_msgs << inner_params
				if s.console_msgs.len > 200 {
					s.console_msgs = s.console_msgs[1..]
				}
			} else if inner_method == 'Runtime.exceptionThrown' {
				s.page_errors << inner_params
				if s.page_errors.len > 200 {
					s.page_errors = s.page_errors[1..]
				}
			} else if inner_method == 'Page.javascriptDialogOpening'
				|| inner_method == 'Page.javascriptDialogClosed' {
				s.dialog_events << '{"method":${json_str(inner_method)},"params":${inner_params}}'
				if s.dialog_events.len > 50 {
					s.dialog_events = s.dialog_events[1..]
				}
			} else if inner_method.starts_with('Network.') {
				track_network_event(mut s, inner_method, inner_params)
				if inner_method == 'Network.loadingFinished' {
					request_id := cdp_extract_str(inner_params, 'requestId')
					if request_id != '' {
						spawn fn [mut s, request_id] () {
							handle_network_watch_loading_finished(mut s, request_id)
						}()
					}
				}
			}
			// 向订阅者分发内层 method
			s.dispatch_event(inner_method, ProtocolResponse{
				method: inner_method
				params: inner_params
			})
		}
		s.dispatch_event(resp.method, resp)
	}
}

fn (mut s CdpSession) dispatch_event(method string, evt ProtocolResponse) {
	s.event_mu.@lock()
	subs := if method in s.event_subs {
		s.event_subs[method].clone()
	} else {
		[]chan ProtocolResponse{}
	}
	s.event_mu.unlock()
	for sub in subs {
		select {
			sub <- evt {}
			else {}
		}
	}
}

// subscribe 订阅 CDP 事件（内层 method，如 "Page.loadEventFired"）
fn (mut s CdpSession) subscribe(method string) chan ProtocolResponse {
	ch := chan ProtocolResponse{cap: 32}
	s.event_mu.@lock()
	if method !in s.event_subs {
		s.event_subs[method] = []chan ProtocolResponse{}
	}
	s.event_subs[method] << ch
	s.event_mu.unlock()
	return ch
}

fn (mut s CdpSession) unsubscribe(method string, ch chan ProtocolResponse) {
	s.event_mu.@lock()
	defer { s.event_mu.unlock() }
	if method in s.event_subs {
		mut filtered := []chan ProtocolResponse{}
		for c in s.event_subs[method] {
			if c != ch {
				filtered << c
			}
		}
		s.event_subs[method] = filtered
	}
}

fn (mut s CdpSession) close() {
	s.pending_mu.@lock()
	s.closed = true
	for id, ch in s.pending {
		ch <- ProtocolResponse{
			id:  id
			err: 'session closed'
		}
	}
	s.pending.clear()
	s.pending_mu.unlock()
}

fn (mut s CdpSession) enable_network_tracking() ! {
	s.network_mu.@lock()
	if s.network_enabled {
		s.network_mu.unlock()
		return
	}
	s.network_mu.unlock()
	s.send_command('Network.enable', '{}')!
	s.network_mu.@lock()
	s.network_enabled = true
	s.network_mu.unlock()
}

fn (mut s CdpSession) enable_page_events() ! {
	s.page_mu.@lock()
	if s.page_enabled {
		s.page_mu.unlock()
		return
	}
	s.page_mu.unlock()
	s.send_command('Page.enable', '{}')!
	s.page_mu.@lock()
	s.page_enabled = true
	s.page_mu.unlock()
}

fn (mut s CdpSession) network_requests_json(filter string) string {
	s.network_mu.@lock()
	defer { s.network_mu.unlock() }
	needle := filter.to_lower()
	mut items := []string{}
	for request_id in s.network_request_order {
		entry := s.network_requests[request_id] or { continue }
		if needle != '' {
			haystack := '${entry.method} ${entry.url} ${entry.resource_type} ${entry.status_text} ${entry.error_text}'.to_lower()
			if !haystack.contains(needle) {
				continue
			}
		}
		items << tracked_network_request_json(entry)
	}
	return '[' + items.join(',') + ']'
}

fn clone_axref_map(src map[string]AxRef) map[string]AxRef {
	mut dst := map[string]AxRef{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn clone_tracked_request_map(src map[string]TrackedNetworkRequest) map[string]TrackedNetworkRequest {
	mut dst := map[string]TrackedNetworkRequest{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn clone_bool_map(src map[string]bool) map[string]bool {
	mut dst := map[string]bool{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn clone_hook_state(src HookState) HookState {
	return HookState{
		active:            src.active
		injected:          src.injected
		script_id:         src.script_id
		script_version:    src.script_version
		filter:            src.filter
		capture_body:      src.capture_body
		capture_response:  src.capture_response
		last_injected_at:  src.last_injected_at
		last_synced_index: src.last_synced_index
		record_count:      src.record_count
	}
}

fn clone_hook_record_map(src map[string]HookRecord) map[string]HookRecord {
	mut dst := map[string]HookRecord{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn clone_network_watch_state(src NetworkWatchState) NetworkWatchState {
	return NetworkWatchState{
		active:            src.active
		target_dir:        src.target_dir
		filter:            src.filter
		candidate_urls:    clone_bool_map(src.candidate_urls)
		saved_request_ids: clone_bool_map(src.saved_request_ids)
		next_index:        src.next_index
	}
}

fn track_network_event(mut s CdpSession, method string, params string) {
	request_id := cdp_extract_str(params, 'requestId')
	if request_id == '' {
		return
	}
	s.network_mu.@lock()
	mut entry := s.network_requests[request_id] or {
		tracked := TrackedNetworkRequest{
			request_id: request_id
		}
		s.network_request_order << request_id
		tracked
	}
	match method {
		'Network.requestWillBeSent' {
			request_obj := cdp_extract_obj(params, 'request')
			entry.url = cdp_extract_str(request_obj, 'url')
			entry.method = cdp_extract_str(request_obj, 'method')
			entry.resource_type = cdp_extract_str(params, 'type')
			// 提取请求头
			headers_obj := cdp_extract_obj(request_obj, 'headers')
			if headers_obj != '' {
				entry.request_headers = headers_obj
			}
		}
		'Network.responseReceived' {
			response_obj := cdp_extract_obj(params, 'response')
			status_val := cdp_extract_obj_key(response_obj, '"status":')
			entry.status = status_val.int()
			entry.status_text = cdp_extract_str(response_obj, 'statusText')
			// 提取响应头
			headers_obj := cdp_extract_obj(response_obj, 'headers')
			if headers_obj != '' {
				entry.response_headers = headers_obj
			}
			if entry.url == '' {
				entry.url = cdp_extract_str(response_obj, 'url')
			}
			if entry.resource_type == '' {
				entry.resource_type = cdp_extract_str(params, 'type')
			}
		}
		'Network.responseReceivedExtraInfo' {
			status_val := cdp_extract_obj_key(params, '"statusCode":')
			if status_val != '' {
				entry.status = status_val.int()
			}
		}
		'Network.loadingFinished' {
			entry.finished = true
		}
		'Network.loadingFailed' {
			entry.finished = true
			entry.error_text = cdp_extract_str(params, 'errorText')
		}
		else {}
	}
	s.network_requests[request_id] = entry
	if s.network_request_order.len > 200 {
		oldest := s.network_request_order[0]
		s.network_request_order = s.network_request_order[1..]
		s.network_requests.delete(oldest)
	}
	s.network_mu.unlock()
}

fn tracked_network_request_json(entry TrackedNetworkRequest) string {
	return '{"requestId":${json_str(entry.request_id)},"method":${json_str(entry.method)},"url":${json_str(entry.url)},"resourceType":${json_str(entry.resource_type)},"status":${entry.status},"statusText":${json_str(entry.status_text)},"errorText":${json_str(entry.error_text)},"finished":${entry.finished},"requestHeaders":${json_str(entry.request_headers)},"responseHeaders":${json_str(entry.response_headers)}}'
}

// get_response_body 获取网络请求的响应体
fn (mut s CdpSession) get_response_body(request_id string) !string {
	s.enable_network_tracking()!
	resp := s.send_command('Network.getResponseBody', '{"requestId":${json_str(request_id)}}')!
	body := cdp_extract_str(resp.result, 'body')
	base64_flag := cdp_extract_obj_key(resp.result, '"base64Encoded":')
	if base64_flag == 'true' {
		// 解码 base64
		return base64.decode_str(body)
	}
	return body
}

fn (mut s CdpSession) get_response_body_bytes(request_id string) ![]u8 {
	s.enable_network_tracking()!
	resp := s.send_command('Network.getResponseBody', '{"requestId":${json_str(request_id)}}')!
	body := cdp_extract_str(resp.result, 'body')
	base64_flag := cdp_extract_obj_key(resp.result, '"base64Encoded":')
	if base64_flag == 'true' {
		return base64.decode(body)
	}
	return body.bytes()
}

// get_response_headers 获取网络请求的响应头（从本地追踪记录中获取）
fn (mut s CdpSession) get_response_headers(request_id string) !string {
	s.enable_network_tracking()!
	// 从本地追踪的请求中获取响应头
	entry := s.network_requests[request_id] or { return error('request not found: ${request_id}') }
	if entry.response_headers == '' {
		return error('response headers not available for: ${request_id}')
	}
	return entry.response_headers
}

// ─── 超时常量 ───────────────────────────────────────────────
const cdp_default_timeout = 60 * time.second
const cdp_attach_timeout = 60 * time.second

// ─── JSON 解析帮助函数 ──────────────────────────────────────

// cdp_parse_message 解析扩展 WebSocket 消息
fn cdp_parse_message(raw string) ProtocolResponse {
	id := cdp_extract_int(raw, '"id":')
	method := cdp_extract_str(raw, 'method')
	result := cdp_extract_obj_key(raw, '"result":')
	err_str := cdp_extract_error(raw)
	params := cdp_extract_obj_key(raw, '"params":')
	return ProtocolResponse{
		id:     id
		method: method
		result: result
		err:    err_str
		params: params
	}
}

fn cdp_extract_int(s string, key string) int {
	idx := s.index(key) or { return 0 }
	rest := s[idx + key.len..].trim_left(' ')
	mut end := 0
	for end < rest.len && rest[end] in [`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `-`] {
		end++
	}
	if end == 0 {
		return 0
	}
	return rest[..end].int()
}

fn cdp_extract_bool(s string, key string) bool {
	search := '"${key}":'
	idx := s.index(search) or { return false }
	rest := s[idx + search.len..].trim_left(' ')
	// Check for true or false boolean value
	if rest.starts_with('true') {
		return true
	}
	if rest.starts_with('false') {
		return false
	}
	// Handle string "true" or "false"
	if rest.starts_with('"true"') {
		return true
	}
	if rest.starts_with('"false"') {
		return false
	}
	return false
}

fn cdp_extract_str(s string, key string) string {
	search := '"${key}":'
	idx := s.index(search) or { return '' }
	rest := s[idx + search.len..].trim_left(' ')
	if !rest.starts_with('"') {
		return ''
	}
	mut j := 1
	for j < rest.len {
		if rest[j] == `\\` {
			j += 2
			continue
		}
		if rest[j] == `"` {
			return decode_json_string_literal(rest[..j + 1])
		}
		j++
	}
	return ''
}

fn decode_json_string_literal(raw string) string {
	trimmed := raw.trim_space()
	if trimmed.len == 0 {
		return ''
	}
	wrapped := if trimmed.starts_with('"') { trimmed } else { '"${trimmed}"' }
	return json.decode[string](wrapped) or {
		if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len >= 2 {
			return trimmed[1..trimmed.len - 1]
		}
		return trimmed
	}
}

fn cdp_extract_obj_key(s string, key string) string {
	idx := s.index(key) or { return '' }
	rest := s[idx + key.len..].trim_left(' ')
	return cdp_extract_value(rest)
}

fn cdp_extract_obj(s string, key string) string {
	return cdp_extract_obj_key(s, '"${key}":')
}

fn cdp_extract_value(s string) string {
	if s.len == 0 {
		return ''
	}
	c := s[0]
	if c == `{` || c == `[` {
		return cdp_balanced(s)
	}
	if c == `"` {
		mut j := 1
		for j < s.len {
			if s[j] == `\\` {
				j += 2
				continue
			}
			if s[j] == `"` {
				return s[..j + 1]
			}
			j++
		}
		return s
	}
	mut j := 0
	for j < s.len && s[j] !in [`,`, `}`, `]`, ` `, `\n`, `\t`].map(u8(it)) {
		j++
	}
	return s[..j]
}

fn cdp_balanced(s string) string {
	if s.len == 0 {
		return ''
	}
	open := s[0]
	close := if open == `{` { u8(`}`) } else { u8(`]`) }
	mut depth := 0
	mut in_str := false
	for i := 0; i < s.len; i++ {
		c := s[i]
		if in_str {
			if c == `\\` {
				i++
				continue
			}
			if c == `"` {
				in_str = false
			}
		} else {
			if c == `"` {
				in_str = true
			} else if c == open {
				depth++
			} else if c == close {
				depth--
				if depth == 0 {
					return s[..i + 1]
				}
			}
		}
	}
	return s
}

fn cdp_extract_error(s string) string {
	key := '"error":'
	idx := s.index(key) or { return '' }
	val := cdp_extract_value(s[idx + key.len..].trim_left(' '))
	if val.starts_with('{') {
		// 对象形式：提取 message 字段
		msg_key := '"message":'
		if midx := val.index(msg_key) {
			inner := cdp_extract_value(val[midx + msg_key.len..].trim_left(' '))
			return inner.trim('"')
		}
		return val
	}
	return val.trim('"')
}

// json_str 简单字符串 JSON 编码
fn json_str(s string) string {
	mut escaped := s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r',
		'\\r').replace('\t', '\\t')
	// 过滤不可见的控制字符（0x00-0x1F，除了已处理的 \n \r \t），避免前端 JSON.parse 失败
	mut clean := []u8{cap: escaped.len}
	for i in 0 .. escaped.len {
		b := escaped[i]
		if b < 32 && b !in [`\n`, `\r`, `\t`] {
			continue
		}
		clean << b
	}
	return '"${clean.bytestr()}"'
}
