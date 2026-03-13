// cdp_session.v — CDP 命令发送器 + 事件总线
// 管理与浏览器扩展之间 WebSocket 上的 CDP 会话：
//   - 发出有序 id 的 CDP 命令并阻塞等候响应
//   - 接收扩展推送的 CDP 事件并分发给订阅者
module main

import sync
import time

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

struct TrackedNetworkRequest {
mut:
	request_id    string
	url           string
	method        string
	resource_type string
	status        int
	status_text   string
	error_text    string
	finished      bool
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
	page_enabled           bool
	page_mu                sync.Mutex
	// 运行时缓存（debug 命令使用）
	console_msgs  []string
	page_errors   []string
	dialog_events []string
}

fn new_cdp_session(send_fn fn (string) !) &CdpSession {
	return &CdpSession{
		send_fn:          send_fn
		pending:          map[int]chan ProtocolResponse{}
		event_subs:       map[string][]chan ProtocolResponse{}
		network_requests: map[string]TrackedNetworkRequest{}
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
		return error(if err.msg().contains('timed out') {
			'Extension connection timeout: no extension connected within 60s. Please install the v-browser extension and allow the connection.'
		} else {
			err.msg()
		})
	}
	s.enable_page_events() or {}
	s.enable_network_tracking() or {}
	return resp.result
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
		}
		'Network.responseReceived' {
			response_obj := cdp_extract_obj(params, 'response')
			status_val := cdp_extract_obj_key(response_obj, '"status":')
			entry.status = status_val.int()
			entry.status_text = cdp_extract_str(response_obj, 'statusText')
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
	return '{"requestId":${json_str(entry.request_id)},"method":${json_str(entry.method)},"url":${json_str(entry.url)},"resourceType":${json_str(entry.resource_type)},"status":${entry.status},"statusText":${json_str(entry.status_text)},"errorText":${json_str(entry.error_text)},"finished":${entry.finished}}'
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
			return rest[1..j]
		}
		j++
	}
	return ''
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
	escaped := s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r',
		'\\r')
	return '"${escaped}"'
}
