// cdp_session.v — CDP 命令发送器 + 事件总线
// 管理与浏览器扩展之间 WebSocket 上的 CDP 会话：
//   - 发出有序 id 的 CDP 命令并阻塞等候响应
//   - 接收扩展推送的 CDP 事件并分发给订阅者
module main

import x.json2 as json
import strings
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

// EventDispatch 描述一个事件订阅的内部分发状态。
// 每个订阅独占一条分发线程 + 一个有界队列：
//   - 投递方（WebSocket 读线程）只做非阻塞入队，绝不阻塞；
//   - 分发线程负责把事件转交给订阅方 channel；
//   - 队列满时普通事件丢弃并计数，route 关键事件走失败处理；
//   - unsubscribe / close 会停掉分发线程，解除在途阻塞。
@[heap]
struct EventDispatch {
mut:
	method   string
	ch       chan ProtocolResponse // 订阅方读取的 channel
	queue    chan ProtocolResponse // 分发队列（有界）
	stop_ch  chan bool             // 停止信号（容量 1）
	critical bool                  // route 类关键事件：溢出时不能静默丢弃
	dropped  int                   // 该订阅被丢弃的事件数
	overflow bool                  // 是否已经发生过队列溢出
	stopped  bool
	done_ch  chan bool = chan bool{cap: 1}
	mu       sync.Mutex
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
	active               bool
	injected             bool
	script_id            string
	script_version       int
	filter               string
	capture_body         bool
	capture_response     bool
	max_body_len         int
	all_frames           bool
	activate_js          string
	last_injected_at     string
	last_synced_index    int
	last_pushed_count    int
	record_count         int
	record_bytes         int // 累计记录字节数（受上限约束）
	record_bytes_tracked int // 已计入 record_bytes 的记录条数（用于发现外部增删）
}

// NetworkFilter 用于细粒度过滤网络请求记录
struct NetworkFilter {
mut:
	url    string // 子串匹配 method+url
	mime   string // 子串匹配 Content-Type（response headers）
	status string // 精确或通配 "2xx" "4xx" "5xx"
	domain string // 子串匹配 URL 主机名
	rtype  string // 子串匹配 resource_type
	// 预计算的 lowercase 版本，避免每次匹配重复 to_lower()
	url_lower    string
	mime_lower   string
	domain_lower string
	rtype_lower  string
}

// normalize_network_filter 预计算 lowercase 字段，供 matches_network_filter 使用
fn normalize_network_filter(f NetworkFilter) NetworkFilter {
	return NetworkFilter{
		...f
		url_lower:    f.url.to_lower()
		mime_lower:   f.mime.to_lower()
		domain_lower: f.domain.to_lower()
		rtype_lower:  f.rtype.to_lower()
	}
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

struct RuntimeExecutionContext {
mut:
	id         int
	frame_id   string
	is_default bool
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
	runtime_contexts       map[int]RuntimeExecutionContext
	network_requests       map[string]TrackedNetworkRequest
	network_request_order  []string
	network_watch          NetworkWatchState
	hook_state             HookState
	hook_records           map[string]HookRecord
	hook_record_order      []string
	console_msgs           []string
	page_errors            []string
	dialog_events          []string
	auto_body_cache        bool
}

struct PageStateSnapshot {
mut:
	current_frame_selector string
	page_enabled           bool
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
	request_id                string
	url                       string
	method                    string
	resource_type             string
	status                    int
	status_from_extra         bool
	status_text               string
	error_text                string
	finished                  bool
	request_headers           string
	response_headers          string
	response_headers_complete bool
	request_body              string
	response_body             string
	response_body_raw         string
	response_body_base64      bool
	response_body_cached      bool
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
	event_dispatchers      map[string][]&EventDispatch // 与 event_subs 一一对应的分发器
	event_dropped          int                         // 累计丢弃的事件数（event_mu 保护）
	event_mu               sync.Mutex
	closed                 bool
	axref                  AxRefStore // @eN 引用映射（snapshot 命令填充）
	current_frame_selector string
	network_requests       map[string]TrackedNetworkRequest
	network_request_order  []string
	network_enabled        bool
	auto_body_cache        bool
	network_mu             sync.Mutex
	network_watch          NetworkWatchState
	network_watch_mu       sync.Mutex
	hook_state             HookState
	hook_records           map[string]HookRecord
	hook_record_order      []string
	// hook 记录上限（每会话）：条数 / 累计字节 / 单条 payload
	hook_record_limit  int = hook_max_records
	hook_byte_limit    int = hook_max_total_bytes
	hook_payload_limit int = hook_max_record_bytes
	hook_mu            sync.Mutex
	runtime_contexts   map[int]RuntimeExecutionContext
	runtime_mu         sync.Mutex
	current_tab_id     int
	tab_contexts       map[int]TabContext
	tab_contexts_mu    sync.Mutex
	page_enabled       bool
	page_mu            sync.Mutex
	// 运行时缓存（debug 命令使用）
	console_msgs  []string
	page_errors   []string
	dialog_events []string
	// network route 状态
	route_ch      chan ProtocolResponse
	route_stop_ch chan bool
	has_route     bool
	// #23: loadingFinished 固定 worker 池（替代每条事件 spawn 协程）
	body_task_ch         chan string
	body_workers_started bool
	body_workers_alive   int // 存活 worker 计数（network_mu 保护，供测试和观测）
}

fn new_cdp_session(send_fn fn (string) !) &CdpSession {
	mut s := &CdpSession{
		send_fn:           send_fn
		pending:           map[int]chan ProtocolResponse{}
		event_subs:        map[string][]chan ProtocolResponse{}
		event_dispatchers: map[string][]&EventDispatch{}
		network_requests:  map[string]TrackedNetworkRequest{}
		runtime_contexts:  map[int]RuntimeExecutionContext{}
		hook_records:      map[string]HookRecord{}
		hook_record_order: []string{}
		tab_contexts:      map[int]TabContext{}
		network_watch:     NetworkWatchState{
			candidate_urls:    map[string]bool{}
			saved_request_ids: map[string]bool{}
		}
		hook_state:        HookState{}
		body_task_ch:      chan string{cap: 4096}
	}
	// 历史背景：旧版 V 不会自动初始化结构体里的 sync.Mutex 字段（init_with 未实现），
	// macOS 上全零 pthread_mutex_t 会让 pthread_mutex_lock 静默失败、完全不互斥
	// （Linux 上全零恰好等于静态初始化器所以不暴露）。上游已修复：Mutex 现在自带
	// 原子 lazy_init，零值安全（见 vlib/sync/sync_darwin.c.v 及回归测试
	// mutex_zero_value_darwin_test.c.v）。这里保留显式 init() 以兼容旧版 V，
	// 调用幂等无副作用。详见 issues/bug/07-sync-mutex-field-uninitialized-macos.md。
	s.pending_mu.init()
	s.event_mu.init()
	s.network_mu.init()
	s.network_watch_mu.init()
	s.hook_mu.init()
	s.runtime_mu.init()
	s.tab_contexts_mu.init()
	s.page_mu.init()
	s.axref.mu.init()
	return s
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
					} {
					}
					else {
					}
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
					} {
					}
					else {
					}
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
	s.activate_tab_context_from_result(resp.result) or {
		// 初始化失败不能吞掉：attach 成功但会话没就绪时，调用方必须知道
		return error(err.msg())
	}
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
		s.activate_tab_context_from_result(resp2.result) or {
			// 目标已切换但初始化失败 / 初始化失败，都要如实上报
			return error(err.msg())
		}
		return resp2.result
	}
	tab_id, window_id := s.find_best_tab_for_url(target_url)!
	if tab_id <= 0 {
		return s.attach_to_tab()
	}
	resp := s.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}') or {
		return error(err.msg())
	}
	s.activate_tab_context_from_result(resp.result) or {
		return error(err.msg())
	}
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
	mut last_fallback := TabSummary{}
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
		last_fallback = tab
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
	if last_fallback.id > 0 {
		return last_fallback.id, last_fallback.window_id
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

// activate_tab_context_from_result 激活目标 tab 的上下文。
// 初始化失败必须把错误抛给调用方（attach / switch 靠它判断目标是否真的就绪），
// 错误信息里区分「目标已切换」和「会话初始化失败」两种情况。
fn (mut s CdpSession) activate_tab_context_from_result(result string) ! {
	tab_id := cdp_extract_int(result, '"tabId":')
	if tab_id <= 0 {
		return
	}
	mut switched := false
	if s.current_tab_id > 0 && s.current_tab_id != tab_id {
		switched = true
		s.save_current_tab_context()
		// 切 tab 时旧 tab 还未回的 CDP 命令再回来就会投递到新 tab 的等待者
		// 上，可能在错误的 page / network 上下文里执行；这里统一 reject 掉
		// (#9)。同 tab 刷新（current_tab_id == tab_id）不触发，避免影响合法的
		// 在飞请求。
		s.reject_pending_reqs('tab switched away')
		// 清空事件订阅 channel，避免旧 tab 还在路上或已经 buffered 的
		// `Page.loadEventFired` / `Runtime.consoleAPICalled` 等事件被新 tab 的
		// 等待者当作新 tab 的事件接收 (#10)。
		s.clear_event_subs()
	}
	s.current_tab_id = tab_id
	s.restore_tab_context(tab_id)
	s.page_mu.@lock()
	s.page_enabled = false
	s.page_mu.unlock()
	s.network_mu.@lock()
	s.network_enabled = false
	s.network_mu.unlock()
	s.enable_page_events() or {
		return error(activation_failure_text(switched, tab_id, err.msg()))
	}
	s.enable_network_tracking() or {
		return error(activation_failure_text(switched, tab_id, err.msg()))
	}
	s.restore_runtime_hook_state() or {
		return error(activation_failure_text(switched, tab_id, err.msg()))
	}
	s.network_watch_mu.@lock()
	watch_active := s.network_watch.active
	s.network_watch_mu.unlock()
	if watch_active {
		sync_network_watch_existing_requests(mut s)
	}
}

// activation_failure_text 组装 tab 激活失败的错误信息。
// switched=true 表示目标已经切到新 tab、只是后续初始化没成功；
// 否则是当前 tab 的会话初始化失败 —— 两者对调用方的处理方式不同。
fn activation_failure_text(switched bool, tab_id int, reason string) string {
	if switched {
		return 'target switched to tab ${tab_id}, but session initialization failed: ${reason}'
	}
	return 'session initialization failed for tab ${tab_id}: ${reason}'
}

// clear_event_subs 清空所有事件订阅 channel。在 tab 切换时调用，避免旧 tab
// 的事件投递到新 tab 等待者 (#10)。
// 同时停掉所有分发线程：否则在途分发还可能往旧订阅的 channel 里塞事件。
fn (mut s CdpSession) clear_event_subs() {
	s.event_mu.@lock()
	mut all := []&EventDispatch{}
	for _, dispatchers in s.event_dispatchers {
		all << dispatchers
	}
	s.event_subs = map[string][]chan ProtocolResponse{}
	s.event_dispatchers = map[string][]&EventDispatch{}
	s.event_mu.unlock()
	for d in all {
		d.stop()
	}
}

fn (mut s CdpSession) restore_runtime_hook_state() ! {
	s.hook_mu.@lock()
	state := clone_hook_state(s.hook_state)
	s.hook_mu.unlock()
	if !state.injected && !state.active {
		return
	}
	s.runtime_mu.@lock()
	s.runtime_contexts.clear()
	s.runtime_mu.unlock()
	script_id := network_hook_script_id(state.script_id)
	install_network_hook(mut s, script_id, true, true)!
	if !state.active {
		return
	}
	activate_js := if state.activate_js != '' {
		state.activate_js
	} else {
		network_hook_activate_js(state.filter, state.capture_body, state.capture_response, false,
			state.max_body_len, script_id)
	}
	eval_scoped_expression(mut s, activate_js, false)!
}

fn (mut s CdpSession) save_current_tab_context() {
	if s.current_tab_id <= 0 {
		return
	}
	page_state := s.page_state_snapshot()
	mut axref_refs := map[string]AxRef{}
	s.axref.mu.@lock()
	for key, value in s.axref.refs {
		axref_refs[key] = value
	}
	s.axref.mu.unlock()
	mut runtime_contexts := map[int]RuntimeExecutionContext{}
	s.runtime_mu.@lock()
	for key, value in s.runtime_contexts {
		runtime_contexts[key] = value
	}
	s.runtime_mu.unlock()
	mut network_requests := map[string]TrackedNetworkRequest{}
	s.network_mu.@lock()
	for key, value in s.network_requests {
		network_requests[key] = value
	}
	network_request_order := s.network_request_order.clone()
	auto_body_cache := s.auto_body_cache
	s.network_mu.unlock()
	// network_watch / hook_state 必须在各自的锁内克隆：
	// 否则快照会和 body worker、消息回调并发读写同一份状态，快照内部不一致
	s.network_watch_mu.@lock()
	network_watch := clone_network_watch_state(s.network_watch)
	s.network_watch_mu.unlock()
	s.hook_mu.@lock()
	hook_state := clone_hook_state(s.hook_state)
	mut hook_records := map[string]HookRecord{}
	for key, value in s.hook_records {
		hook_records[key] = value
	}
	hook_record_order := s.hook_record_order.clone()
	s.hook_mu.unlock()
	s.tab_contexts_mu.@lock()
	s.tab_contexts[s.current_tab_id] = TabContext{
		current_frame_selector: page_state.current_frame_selector
		axref_refs:             axref_refs
		runtime_contexts:       runtime_contexts
		network_requests:       network_requests
		network_request_order:  network_request_order
		network_watch:          network_watch
		hook_state:             hook_state
		hook_records:           hook_records
		hook_record_order:      hook_record_order
		console_msgs:           page_state.console_msgs
		page_errors:            page_state.page_errors
		dialog_events:          page_state.dialog_events
		auto_body_cache:        auto_body_cache
	}
	s.tab_contexts_mu.unlock()
}

fn (mut s CdpSession) restore_tab_context(tab_id int) {
	s.tab_contexts_mu.@lock()
	ctx := s.tab_contexts[tab_id] or {
		s.tab_contexts_mu.unlock()
		s.set_current_frame_selector('')
		s.axref.mu.@lock()
		s.axref.refs.clear()
		s.axref.mu.unlock()
		s.runtime_mu.@lock()
		s.runtime_contexts.clear()
		s.runtime_mu.unlock()
		s.network_mu.@lock()
		s.network_requests.clear()
		s.network_request_order = []string{}
		s.network_enabled = false
		s.auto_body_cache = false
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
		s.page_mu.@lock()
		s.page_enabled = false
		s.console_msgs = []string{}
		s.page_errors = []string{}
		s.dialog_events = []string{}
		s.page_mu.unlock()
		return
	}
	s.tab_contexts_mu.unlock()
	s.set_current_frame_selector(ctx.current_frame_selector)
	s.axref.mu.@lock()
	s.axref.refs = clone_axref_map(ctx.axref_refs)
	s.axref.mu.unlock()
	s.runtime_mu.@lock()
	s.runtime_contexts = clone_runtime_context_map(ctx.runtime_contexts)
	s.runtime_mu.unlock()
	s.network_mu.@lock()
	s.network_requests = clone_tracked_request_map(ctx.network_requests)
	s.network_request_order = ctx.network_request_order.clone()
	s.network_enabled = false
	s.auto_body_cache = ctx.auto_body_cache
	s.network_mu.unlock()
	s.network_watch_mu.@lock()
	s.network_watch = clone_network_watch_state(ctx.network_watch)
	s.network_watch_mu.unlock()
	s.hook_mu.@lock()
	s.hook_state = clone_hook_state(ctx.hook_state)
	s.hook_records = clone_hook_record_map(ctx.hook_records)
	s.hook_record_order = ctx.hook_record_order.clone()
	s.hook_mu.unlock()
	s.page_mu.@lock()
	s.page_enabled = false
	s.console_msgs = ctx.console_msgs.clone()
	s.page_errors = ctx.page_errors.clone()
	s.dialog_events = ctx.dialog_events.clone()
	s.page_mu.unlock()
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
			// 每层只访问直接字段，避免嵌套同名字段和字段顺序影响解析。
			outer := cdp_json_object(resp.params)
			inner_method := cdp_json_str(outer, 'method')
			params_value := outer['params'] or { return }
			if params_value !is map[string]json.Any || inner_method == '' {
				return
			}
			inner_params_map := cdp_json_object_field(outer, 'params')
			inner_params := json.Any(inner_params_map).str()
			if inner_method == 'Runtime.consoleAPICalled' {
				s.append_console_message(inner_params)
			} else if inner_method == 'Runtime.exceptionThrown' {
				s.append_page_error(inner_params)
			} else if inner_method == 'Page.javascriptDialogOpening'
				|| inner_method == 'Page.javascriptDialogClosed' {
				s.append_dialog_event('{"method":${json_str(inner_method)},"params":${inner_params}}')
			} else if inner_method.starts_with('Network.') {
				track_network_event(mut s, inner_method, inner_params_map)
				if inner_method == 'Network.loadingFinished' {
					request_id := cdp_json_str(inner_params_map, 'requestId')
					if request_id != '' {
						// #23: 投递给固定 worker 池，不再每条事件 spawn 协程
						s.queue_loading_finished(request_id)
					}
				}
			} else if inner_method == 'Runtime.bindingCalled' {
				name := cdp_json_str(inner_params_map, 'name')
				if name == '__vBrowserHookPush' {
					payload := cdp_json_str(inner_params_map, 'payload')
					s.handle_hook_binding_push(payload)
				}
			} else if inner_method == 'Runtime.executionContextCreated' {
				ctx_obj := cdp_json_object_field(inner_params_map, 'context')
				ctx_id := cdp_json_int(ctx_obj, 'id')
				aux_data := cdp_json_object_field(ctx_obj, 'auxData')
				is_default := cdp_json_bool(aux_data, 'isDefault')
				frame_id := cdp_json_str(aux_data, 'frameId')
				if ctx_id > 0 {
					s.runtime_mu.@lock()
					s.runtime_contexts[ctx_id] = RuntimeExecutionContext{
						id:         ctx_id
						frame_id:   frame_id
						is_default: is_default
					}
					s.runtime_mu.unlock()
				}
				// all_frames hook：新执行上下文创建时，对所有 default context 注入激活脚本
				s.hook_mu.@lock()
				should_inject := s.hook_state.all_frames && s.hook_state.active
					&& s.hook_state.activate_js != ''
				activate_js := s.hook_state.activate_js
				s.hook_mu.unlock()
				if should_inject {
					if is_default && ctx_id > 0 {
						spawn fn [mut s, activate_js, ctx_id] () {
							s.send_command('Runtime.evaluate',
								'{"expression":${json_str(activate_js)},"contextId":${ctx_id},"silent":true}') or {}
						}()
					}
				}
			} else if inner_method == 'Runtime.executionContextDestroyed' {
				ctx_id := cdp_json_int(inner_params_map, 'executionContextId')
				if ctx_id > 0 {
					s.runtime_mu.@lock()
					s.runtime_contexts.delete(ctx_id)
					s.runtime_mu.unlock()
				}
			} else if inner_method == 'Runtime.executionContextsCleared' {
				s.runtime_mu.@lock()
				s.runtime_contexts.clear()
				s.runtime_mu.unlock()
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

// dispatch_event 把事件投递给所有订阅者。
//
// 关键约束：这里绝不能阻塞。on_message 跑在 WebSocket 读线程上，同时负责
// 分发 CDP 响应 —— 一旦在这里卡住，所有 CDP 命令都等不到回包，整个 session
// 死锁到超时，unsubscribe / clear_event_subs / close 也都解不开。
//
// 因此每个订阅都有独立的有界队列 + 独立分发线程，投递方只做非阻塞入队：
//   - 队列没满 → 入队，由分发线程转交给订阅方；
//   - 队列满 → 普通事件丢弃并计数告警；
//   - 队列满且是关键事件（Fetch.requestPaused）→ 对被拦截的请求做失败处理，
//     并停掉这个订阅，绝不无限阻塞。
fn (mut s CdpSession) dispatch_event(method string, evt ProtocolResponse) {
	s.event_mu.@lock()
	mut dispatchers := (s.event_dispatchers[method] or { []&EventDispatch{} }).clone()
	s.event_mu.unlock()
	for i in 0 .. dispatchers.len {
		mut d := dispatchers[i]
		if d.enqueue(evt) {
			continue
		}
		if d.critical {
			s.handle_critical_event_overflow(d, evt)
		} else {
			s.event_mu.@lock()
			s.event_dropped++
			dropped := s.event_dropped
			s.event_mu.unlock()
			if dropped % event_dropped_warn_every == 1 {
				eprintln('[cdp] event ${method} queue overflow, dropped ${dropped} events in total')
			}
		}
	}
}

// is_critical_event_method 判断事件是否属于「不能静默丢弃」的关键事件。
// Fetch.requestPaused 丢弃后被拦截的请求会一直挂着，页面直接卡死。
fn is_critical_event_method(method string) bool {
	return method in ['Fetch.requestPaused', 'Fetch.authRequired']
}

// handle_critical_event_overflow 处理 route 关键事件（Fetch.requestPaused）溢出。
// 被拦截的请求如果既不 fulfill 也不 fail 就会一直挂着，页面直接卡死，
// 所以这里显式失败该请求，并停掉这个订阅，避免事件无限堆积。
fn (mut s CdpSession) handle_critical_event_overflow(d &EventDispatch, evt ProtocolResponse) {
	if !d.mark_overflow() {
		return
	}
	request_id := cdp_json_str(cdp_json_object(evt.params), 'requestId')
	s.remove_event_dispatch(d.method, d)
	s.event_mu.@lock()
	s.event_dropped++
	s.event_mu.unlock()
	eprintln('[cdp] critical event ${d.method} queue overflow; disabling Fetch interception')
	// 不能在读线程等 CDP 响应。关闭 Fetch 同时释放队列中及后续暂停的请求，
	// 否则仅失败溢出的那一条仍会让已积压的请求永久挂起。
	spawn fn [mut s, request_id, d] () {
		if request_id != '' {
			method := if d.method == 'Fetch.authRequired' {
				'Fetch.continueWithAuth'
			} else {
				'Fetch.failRequest'
			}
			params := if d.method == 'Fetch.authRequired' {
				'{"requestId":${json_str(request_id)},"authChallengeResponse":{"response":"CancelAuth"}}'
			} else {
				'{"requestId":${json_str(request_id)},"errorReason":"Aborted"}'
			}
			s.send_command(method, params) or {
				eprintln('[cdp] failed to abort paused request ${request_id}: ${err.msg()}')
			}
		}
		s.send_command('Fetch.disable', '{}') or {
			eprintln('[cdp] failed to disable overflowing Fetch interception: ${err.msg()}')
		}
	}()
}

// remove_event_dispatch 从订阅表里移除分发器（订阅被关闭时调用）。
fn (mut s CdpSession) remove_event_dispatch(method string, target &EventDispatch) {
	s.event_mu.@lock()
	if method in s.event_dispatchers {
		mut dispatchers := s.event_dispatchers[method] or { []&EventDispatch{} }
		for i, d in dispatchers {
			if d.ch == target.ch {
				dispatchers.delete(i)
				s.event_dispatchers[method] = dispatchers
				mut subs := s.event_subs[method] or { []chan ProtocolResponse{} }
				if i < subs.len {
					subs.delete(i)
					s.event_subs[method] = subs
				}
				break
			}
		}
	}
	s.event_mu.unlock()
	target.stop()
}

// subscribe 订阅 CDP 事件（内层 method，如 "Page.loadEventFired"）。
// 每个订阅独占一条分发线程 + 一个有界队列：投递方只做非阻塞入队，
// 订阅方消费慢也不会阻塞 WebSocket 读线程。
fn (mut s CdpSession) subscribe(method string) chan ProtocolResponse {
	ch := chan ProtocolResponse{cap: 32}
	mut d := &EventDispatch{
		method:   method
		ch:       ch
		queue:    chan ProtocolResponse{cap: event_queue_capacity}
		stop_ch:  chan bool{cap: 1}
		critical: is_critical_event_method(method)
	}
	d.mu.init()
	s.event_mu.@lock()
	s.pending_mu.@lock()
	closed := s.closed
	s.pending_mu.unlock()
	if closed {
		s.event_mu.unlock()
		return ch
	}
	if method !in s.event_subs {
		s.event_subs[method] = []chan ProtocolResponse{}
		s.event_dispatchers[method] = []&EventDispatch{}
	}
	s.event_subs[method] << ch
	mut dispatchers := s.event_dispatchers[method] or { []&EventDispatch{} }
	dispatchers << d
	s.event_dispatchers[method] = dispatchers
	s.event_mu.unlock()
	spawn fn [mut d] () {
		d.run()
	}()
	return ch
}

// unsubscribe 取消订阅。
// #40: 改用下标遍历 + delete 替代全量 filter+copy，O(n) → O(1) ~ O(n) 单次匹配。
// 注意：V 里 map value 的 mutation 需要赋值回 map，否则只改了局部副本。
// 同时停掉分发线程：订阅方不再消费时，在途分发也必须能立刻结束。
fn (mut s CdpSession) unsubscribe(method string, ch chan ProtocolResponse) {
	mut target := &EventDispatch{}
	mut found := false
	s.event_mu.@lock()
	if method in s.event_subs {
		mut subs := s.event_subs[method] or { []chan ProtocolResponse{} }
		mut dispatchers := s.event_dispatchers[method] or { []&EventDispatch{} }
		for i, c in subs {
			if c == ch {
				subs.delete(i)
				s.event_subs[method] = subs
				if i < dispatchers.len {
					target = dispatchers[i]
					dispatchers.delete(i)
					s.event_dispatchers[method] = dispatchers
				}
				found = true
				break
			}
		}
	}
	s.event_mu.unlock()
	if found {
		target.stop()
	}
}

// stop_all_event_dispatchers 停掉所有事件分发线程（close 时调用），
// 保证在途分发不会一直挂着。
fn (mut s CdpSession) stop_all_event_dispatchers() {
	s.clear_event_subs()
}

// enqueue 把事件放进有界队列。队列满（或订阅已停）时返回 false，
// 由调用方决定丢弃还是做失败处理 —— 这里绝不阻塞。
fn (mut d EventDispatch) enqueue(evt ProtocolResponse) bool {
	d.mu.@lock()
	defer { d.mu.unlock() }
	if d.stopped {
		return false
	}
	mut queued := false
	select {
		d.queue <- evt {
			queued = true
		}
		else {
		}
	}
	return queued
}

// forward 把事件转交给订阅方 channel。
// 订阅方长时间不消费时不能永久卡住（否则 unsubscribe / close 无法终止分发），
// 所以每轮最多等 event_forward_wait，stop 有信号时立即退出。
fn (mut d EventDispatch) forward(evt ProtocolResponse) bool {
	for {
		select {
			d.ch <- evt {
				return true
			}
			<-d.stop_ch {
				return false
			}
			event_forward_wait {
				// 订阅方还没腾出位置，继续等下一轮
			}
		}
	}
}

// run 分发线程主循环：从队列取事件转交给订阅方。
fn (mut d EventDispatch) run() {
	defer { d.done_ch <- true }
	for {
		d.mu.@lock()
		stopped := d.stopped
		d.mu.unlock()
		if stopped {
			return
		}
		select {
			evt := <-d.queue {
				if !d.forward(evt) {
					return
				}
			}
			<-d.stop_ch {
				return
			}
		}
	}
}

// stop 停掉分发线程：置 stopped 标志并唤醒阻塞中的分发循环。
fn (mut d EventDispatch) stop() {
	d.mu.@lock()
	if d.stopped {
		d.mu.unlock()
		return
	}
	d.stopped = true
	d.mu.unlock()
	select {
		d.stop_ch <- true {
		}
		else {
		}
	}
}

// mark_overflow 记录一次队列溢出。
fn (mut d EventDispatch) mark_overflow() bool {
	d.mu.@lock()
	defer { d.mu.unlock() }
	if d.stopped || d.overflow {
		return false
	}
	d.overflow = true
	d.dropped++
	return true
}

fn (mut s CdpSession) page_state_snapshot() PageStateSnapshot {
	s.page_mu.@lock()
	defer { s.page_mu.unlock() }
	return PageStateSnapshot{
		current_frame_selector: s.current_frame_selector
		page_enabled:           s.page_enabled
		console_msgs:           s.console_msgs.clone()
		page_errors:            s.page_errors.clone()
		dialog_events:          s.dialog_events.clone()
	}
}

fn (mut s CdpSession) current_frame_selector_value() string {
	s.page_mu.@lock()
	defer { s.page_mu.unlock() }
	return s.current_frame_selector
}

fn (mut s CdpSession) set_current_frame_selector(selector string) {
	s.page_mu.@lock()
	s.current_frame_selector = selector
	s.page_mu.unlock()
}

fn (mut s CdpSession) append_console_message(message string) {
	s.page_mu.@lock()
	s.console_msgs << message
	if s.console_msgs.len > 200 {
		s.console_msgs = s.console_msgs[1..]
	}
	s.page_mu.unlock()
}

fn (mut s CdpSession) append_page_error(message string) {
	s.page_mu.@lock()
	s.page_errors << message
	if s.page_errors.len > 200 {
		s.page_errors = s.page_errors[1..]
	}
	s.page_mu.unlock()
}

fn (mut s CdpSession) append_dialog_event(message string) {
	s.page_mu.@lock()
	s.dialog_events << message
	if s.dialog_events.len > 50 {
		s.dialog_events = s.dialog_events[1..]
	}
	s.page_mu.unlock()
}

fn (mut s CdpSession) console_messages_snapshot() []string {
	s.page_mu.@lock()
	defer { s.page_mu.unlock() }
	return s.console_msgs.clone()
}

fn (mut s CdpSession) page_errors_snapshot() []string {
	s.page_mu.@lock()
	defer { s.page_mu.unlock() }
	return s.page_errors.clone()
}

fn (mut s CdpSession) dialog_events_snapshot() []string {
	s.page_mu.@lock()
	defer { s.page_mu.unlock() }
	return s.dialog_events.clone()
}

fn (mut s CdpSession) clear_console_messages() {
	s.page_mu.@lock()
	s.console_msgs = []string{}
	s.page_mu.unlock()
}

fn (mut s CdpSession) clear_page_errors() {
	s.page_mu.@lock()
	s.page_errors = []string{}
	s.page_mu.unlock()
}

fn (mut s CdpSession) clear_dialog_events() {
	s.page_mu.@lock()
	s.dialog_events = []string{}
	s.page_mu.unlock()
}

fn (mut s CdpSession) close() {
	s.pending_mu.@lock()
	s.closed = true
	s.pending_mu.unlock()
	// 关掉 session 时也复用 reject_pending_reqs 把 pending 请求一并回收
	s.reject_pending_reqs('cdp session closed')
	// 同时停掉 network route 的后台 goroutine，避免客户端断连后永久挂起
	s.stop_route()
	// 停掉所有事件分发线程：解除在途分发，订阅方不消费也不会挂住读线程
	s.stop_all_event_dispatchers()
}

// reject_pending_reqs 拒绝所有 pending 中的 CDP 命令，按 reason 写入错误并清空 map。
// 在 close() 和 tab 切换时使用，避免旧 tab / 旧 session 的回包投递到错误等待者。
// 见 #9（tab 切换吞请求）和 close()。
fn (mut s CdpSession) reject_pending_reqs(reason string) {
	s.pending_mu.@lock()
	for id, ch in s.pending {
		ch <- ProtocolResponse{
			id:  id
			err: reason
		}
	}
	s.pending.clear()
	s.pending_mu.unlock()
}

// stop_route 停止当前 network route 的后台 goroutine 并清理订阅状态。
// 在 session close() 和外部 'route' / 'unroute' 命令路径调用，避免旧 goroutine
// 在客户端断连 / server 异常退出后永久挂起 (#11)。
fn (mut s CdpSession) stop_route() {
	if s.has_route {
		select {
			s.route_stop_ch <- true {
			}
			else {
			}
		}
		s.unsubscribe('Fetch.requestPaused', s.route_ch)
		s.has_route = false
	}
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

fn (mut s CdpSession) network_requests_json(f NetworkFilter, limit int) string {
	nf := normalize_network_filter(f)
	s.network_mu.@lock()
	defer { s.network_mu.unlock() }
	mut out := strings.new_builder(256)
	out.write_string('[')
	mut count := 0
	for request_id in s.network_request_order {
		entry := s.network_requests[request_id] or { continue }
		if !matches_network_filter(entry, nf) {
			continue
		}
		if count > 0 {
			out.write_u8(`,`)
		}
		out.write_string(tracked_network_request_json(entry))
		count++
		if limit > 0 && count >= limit {
			break
		}
	}
	out.write_u8(`]`)
	return out.str()
}

// matches_network_filter 检查 TrackedNetworkRequest 是否满足所有过滤条件
fn matches_network_filter(entry TrackedNetworkRequest, f NetworkFilter) bool {
	if f.url != '' {
		haystack :=
			'${entry.method} ${entry.url} ${entry.resource_type} ${entry.status_text} ${entry.error_text}'.to_lower()
		if !haystack.contains(f.url_lower) {
			return false
		}
	}
	if f.mime != '' {
		if !entry.response_headers.to_lower().contains(f.mime_lower) {
			return false
		}
	}
	if f.status != '' && !matches_status_filter(entry.status, f.status) {
		return false
	}
	if f.domain != '' {
		domain := url_hostname(entry.url)
		if !domain.to_lower().contains(f.domain_lower) {
			return false
		}
	}
	if f.rtype != '' {
		if !entry.resource_type.to_lower().contains(f.rtype_lower) {
			return false
		}
	}
	return true
}

// matches_status_filter 支持精确匹配 "200" 或通配 "2xx" "4xx" "5xx"
fn matches_status_filter(status int, pattern string) bool {
	if pattern == '' {
		return true
	}
	pat := pattern.to_lower()
	if pat.ends_with('xx') {
		prefix := pat[..pat.len - 2]
		return status.str().starts_with(prefix)
	}
	return status.str() == pattern
}

// url_hostname 从 URL 中提取主机名（不含端口）
fn url_hostname(raw_url string) string {
	after_scheme := if raw_url.contains('://') { raw_url.after('://') } else { raw_url }
	mut host := after_scheme.split('/')[0]
	if host.contains('@') {
		host = host.after('@')
	}
	if host.contains(':') {
		host = host.split(':')[0]
	}
	return host
}

fn clone_axref_map(src map[string]AxRef) map[string]AxRef {
	mut dst := map[string]AxRef{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn clone_runtime_context_map(src map[int]RuntimeExecutionContext) map[int]RuntimeExecutionContext {
	mut dst := map[int]RuntimeExecutionContext{}
	for key, value in src {
		dst[key] = value
	}
	return dst
}

fn (mut s CdpSession) default_execution_context_ids() []int {
	s.runtime_mu.@lock()
	defer { s.runtime_mu.unlock() }
	mut ids := []int{}
	for ctx_id, ctx in s.runtime_contexts {
		if ctx.is_default {
			ids << ctx_id
		}
	}
	ids.sort()
	return ids
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
		active:               src.active
		injected:             src.injected
		script_id:            src.script_id
		script_version:       src.script_version
		filter:               src.filter
		capture_body:         src.capture_body
		capture_response:     src.capture_response
		max_body_len:         src.max_body_len
		last_injected_at:     src.last_injected_at
		last_synced_index:    src.last_synced_index
		last_pushed_count:    src.last_pushed_count
		record_count:         src.record_count
		record_bytes:         src.record_bytes
		record_bytes_tracked: src.record_bytes_tracked
		all_frames:           src.all_frames
		activate_js:          src.activate_js
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

fn (mut s CdpSession) network_request_snapshot(request_id string) !TrackedNetworkRequest {
	s.network_mu.@lock()
	defer { s.network_mu.unlock() }
	entry := s.network_requests[request_id] or { return error('request not found: ${request_id}') }
	return entry
}

fn (mut s CdpSession) network_request_entries_snapshot() []TrackedNetworkRequest {
	s.network_mu.@lock()
	defer { s.network_mu.unlock() }
	mut entries := []TrackedNetworkRequest{cap: s.network_request_order.len}
	for request_id in s.network_request_order {
		entry := s.network_requests[request_id] or { continue }
		entries << entry
	}
	return entries
}

// track_network_event 处理 Network.* 事件。
// params 已经是解析好的 JSON 对象：字段必须按层级取，全局子串搜索会命中
// 嵌套层级里的同名字段（例如 request.headers.method）。
fn track_network_event(mut s CdpSession, method string, params map[string]json.Any) {
	request_id := cdp_json_str(params, 'requestId')
	if request_id == '' {
		return
	}
	// 锁外解析 — 所有字段提取在此完成
	mut parsed_url := ''
	mut parsed_method := ''
	mut parsed_resource_type := ''
	mut parsed_request_headers := ''
	mut parsed_request_body := ''
	mut parsed_status := 0
	mut parsed_status_text := ''
	mut parsed_response_headers := ''
	mut parsed_response_url := ''
	mut parsed_response_resource_type := ''
	mut parsed_error_text := ''
	mut has_status := false
	mut has_extra_status := false
	mut has_extra_headers := false
	mut is_redirect := false
	match method {
		'Network.requestWillBeSent' {
			request_obj := cdp_json_object_field(params, 'request')
			parsed_url = cdp_json_str(request_obj, 'url')
			parsed_method = cdp_json_str(request_obj, 'method')
			parsed_resource_type = cdp_json_str(params, 'type')
			headers_obj := cdp_json_object_field(request_obj, 'headers')
			if headers_obj.len > 0 {
				parsed_request_headers = json.Any(headers_obj).str()
			}
			parsed_request_body = cdp_json_str(request_obj, 'postData')
			// redirectResponse 存在 = 这是重定向后的新一跳（requestId 会被复用）
			is_redirect = 'redirectResponse' in params
		}
		'Network.responseReceived' {
			response_obj := cdp_json_object_field(params, 'response')
			status_val, status_ok := cdp_json_int_ok(response_obj, 'status')
			if status_ok {
				parsed_status = status_val
				has_status = true
			}
			parsed_status_text = cdp_json_str(response_obj, 'statusText')
			headers_obj := cdp_json_object_field(response_obj, 'headers')
			if headers_obj.len > 0 {
				parsed_response_headers = json.Any(headers_obj).str()
			}
			parsed_response_url = cdp_json_str(response_obj, 'url')
			parsed_response_resource_type = cdp_json_str(params, 'type')
		}
		'Network.responseReceivedExtraInfo' {
			status_val, status_ok := cdp_json_int_ok(params, 'statusCode')
			if status_ok {
				parsed_status = status_val
				has_extra_status = true
			}
			headers_obj := cdp_json_object_field(params, 'headers')
			if headers_obj.len > 0 {
				parsed_response_headers = json.Any(headers_obj).str()
				has_extra_headers = true
			}
		}
		'Network.loadingFailed' {
			parsed_error_text = cdp_json_str(params, 'errorText')
		}
		else {}
	}
	// 锁内仅做 map 读写 + 字段赋值
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
			// 上一跳是否已经产生过响应（重定向或 requestId 被复用）
			had_response := is_redirect || entry.url != '' || entry.method != '' || entry.finished
			// 新一跳开始：请求字段整体覆盖（POST→302→GET 时新的一跳没有 body，
			// 旧 body 必须清掉，否则会串到下一跳）
			entry.url = parsed_url
			entry.method = parsed_method
			entry.resource_type = parsed_resource_type
			entry.request_headers = parsed_request_headers
			entry.request_body = parsed_request_body
			entry.finished = false
			entry.error_text = ''
			// 旧响应头 / 旧状态 / 旧 ExtraInfo 标志必须清空
			if had_response {
				entry.status = 0
				entry.status_text = ''
				entry.status_from_extra = false
				entry.response_headers = ''
				entry.response_headers_complete = false
				entry.response_body = ''
				entry.response_body_raw = ''
				entry.response_body_base64 = false
				entry.response_body_cached = false
			}
		}
		'Network.responseReceived' {
			if has_status && !entry.status_from_extra {
				entry.status = parsed_status
			}
			entry.status_text = parsed_status_text
			if parsed_response_headers != '' && !entry.response_headers_complete {
				entry.response_headers = parsed_response_headers
			}
			if entry.url == '' {
				entry.url = parsed_response_url
			}
			if entry.resource_type == '' {
				entry.resource_type = parsed_response_resource_type
			}
		}
		'Network.responseReceivedExtraInfo' {
			if has_extra_status {
				entry.status = parsed_status
				entry.status_from_extra = true
			}
			if has_extra_headers {
				entry.response_headers = parsed_response_headers
				entry.response_headers_complete = true
			}
		}
		'Network.loadingFinished' {
			entry.finished = true
		}
		'Network.loadingFailed' {
			entry.finished = true
			entry.error_text = parsed_error_text
		}
		else {}
	}
	s.network_requests[request_id] = entry
	if s.network_request_order.len > 1000 {
		oldest := s.network_request_order[0]
		s.network_request_order = s.network_request_order[1..]
		s.network_requests.delete(oldest)
	}
	s.network_mu.unlock()
}

fn tracked_network_request_json(entry TrackedNetworkRequest) string {
	return '{"requestId":${json_str(entry.request_id)},"method":${json_str(entry.method)},"url":${json_str(entry.url)},"resourceType":${json_str(entry.resource_type)},"status":${entry.status},"statusText":${json_str(entry.status_text)},"errorText":${json_str(entry.error_text)},"finished":${entry.finished},"requestHeaders":${json_str(entry.request_headers)},"responseHeaders":${json_str(entry.response_headers)},"requestBody":${json_str(entry.request_body)},"responseBody":${json_str(entry.response_body)}}'
}

fn response_body_cache_preview(raw_body string, base64_encoded bool) string {
	if base64_encoded {
		return '[base64-encoded body cached]'
	}
	return raw_body
}

fn (mut s CdpSession) cache_response_body_payload(request_id string, raw_body string, base64_encoded bool) !TrackedNetworkRequest {
	s.network_mu.@lock()
	mut entry := s.network_requests[request_id] or {
		s.network_mu.unlock()
		return error('request not found: ${request_id}')
	}
	entry.response_body_raw = raw_body
	entry.response_body_base64 = base64_encoded
	entry.response_body_cached = true
	entry.response_body = response_body_cache_preview(raw_body, base64_encoded)
	s.network_requests[request_id] = entry
	s.network_mu.unlock()
	return entry
}

fn cached_response_body_as_string(entry TrackedNetworkRequest) string {
	if entry.response_body_base64 {
		return base64.decode_str(entry.response_body_raw)
	}
	return entry.response_body_raw
}

fn cached_response_body_as_bytes(entry TrackedNetworkRequest) []u8 {
	if entry.response_body_base64 {
		return base64.decode(entry.response_body_raw)
	}
	return entry.response_body_raw.bytes()
}

fn (mut s CdpSession) ensure_response_body_cached(request_id string) !TrackedNetworkRequest {
	entry := s.network_request_snapshot(request_id)!
	if entry.response_body_cached {
		return entry
	}
	if !entry.finished {
		return error('response body not available until request finishes: ${request_id}')
	}
	s.enable_network_tracking()!
	resp := s.send_command('Network.getResponseBody', '{"requestId":${json_str(request_id)}}')!
	// double-check：CDP fetch 期间另一个 goroutine 可能已完成缓存
	recheck := s.network_request_snapshot(request_id) or {
		return error('request not found: ${request_id}')
	}
	if recheck.response_body_cached {
		return recheck
	}
	body := cdp_extract_str(resp.result, 'body')
	base64_encoded := cdp_extract_obj_key(resp.result, '"base64Encoded":') == 'true'
	return s.cache_response_body_payload(request_id, body, base64_encoded)
}

// get_response_body 获取网络请求的响应体
fn (mut s CdpSession) get_response_body(request_id string) !string {
	entry := s.ensure_response_body_cached(request_id)!
	return cached_response_body_as_string(entry)
}

fn (mut s CdpSession) get_response_body_bytes(request_id string) ![]u8 {
	entry := s.ensure_response_body_cached(request_id)!
	return cached_response_body_as_bytes(entry)
}

// get_response_headers 获取网络请求的响应头（从本地追踪记录中获取）
fn (mut s CdpSession) get_response_headers(request_id string) !string {
	entry := s.network_request_snapshot(request_id)!
	if entry.response_headers == '' {
		return error('response headers not available for: ${request_id}')
	}
	return entry.response_headers
}

// cache_response_body 在 loadingFinished 后异步缓存响应体，供 auto_body_cache 使用
fn (mut s CdpSession) cache_response_body(request_id string) {
	_ := s.ensure_response_body_cached(request_id) or { return }
}

// ensure_body_workers 惰性启动固定大小的 loadingFinished worker 池 (#23)。
// 原来每条 Network.loadingFinished 事件都 spawn 1-2 个 goroutine，高频页面
// （一秒几百请求）会造成协程风暴；改为 body_worker_count 个常驻 worker 从
// body_task_ch 消费任务。
fn (mut s CdpSession) ensure_body_workers() {
	s.network_mu.@lock()
	if s.body_workers_started {
		s.network_mu.unlock()
		return
	}
	s.body_workers_started = true
	s.network_mu.unlock()
	for _ in 0 .. body_worker_count {
		spawn fn [mut s] () {
			s.network_mu.@lock()
			s.body_workers_alive++
			s.network_mu.unlock()
			for {
				select {
					request_id := <-s.body_task_ch {
						// watch 未激活时内部会直接 return，无需在此判断
						handle_network_watch_loading_finished(mut s, request_id)
						s.network_mu.@lock()
						do_cache := s.auto_body_cache
						s.network_mu.unlock()
						if do_cache {
							s.cache_response_body(request_id)
						}
					}
					// 空闲巡检：session 关闭后退出，防止 worker 泄漏
					500 * time.millisecond {
						s.pending_mu.@lock()
						closed := s.closed
						s.pending_mu.unlock()
						if closed {
							s.network_mu.@lock()
							s.body_workers_alive--
							s.network_mu.unlock()
							return
						}
					}
				}
			}
		}()
	}
}

// queue_loading_finished 把 loadingFinished 任务投递给 worker 池 (#23)。
// network watch 和 auto_body_cache 都关闭时直接返回，默认路径零开销。
fn (mut s CdpSession) queue_loading_finished(request_id string) {
	s.network_watch_mu.@lock()
	watch_active := s.network_watch.active
	s.network_watch_mu.unlock()
	s.network_mu.@lock()
	do_cache := s.auto_body_cache
	s.network_mu.unlock()
	if !watch_active && !do_cache {
		return
	}
	s.ensure_body_workers()
	// 必须非阻塞投递：worker 内的 CDP round-trip（getResponseBody）响应要靠
	// on_message 这同一条 goroutine 分发；若这里阻塞在满队列上，就会出现
	// worker 等响应、on_message 等队列空位的死锁。队列满时丢弃任务即可。
	select {
		s.body_task_ch <- request_id {
		}
		else {
			eprintln('[network] body task queue full, dropping ${request_id}')
		}
	}
}

// handle_hook_binding_push 处理 Runtime.bindingCalled 推送的 hook 记录，无需轮询。
//
// 页面可以随意推送记录，这里必须限制规模，否则 daemon 内存会被页面撑爆：
//   - 单条 payload 上限：超长记录直接丢弃；
//   - 每会话记录条数上限 + 累计字节上限：超限环形淘汰最旧的记录；
//   - 非活动状态（hook 已停止 / 会话已关闭）拒绝接收。
fn (mut s CdpSession) handle_hook_binding_push(payload string) {
	// 单条 payload 上限：一条超长记录就能撑爆 daemon 内存
	if payload.len > s.hook_payload_limit {
		return
	}
	record := cdp_json_object(payload)
	record_id := cdp_json_str(record, 'recordId')
	if record_id == '' {
		return
	}
	s.hook_mu.@lock()
	defer { s.hook_mu.unlock() }
	// 非活动状态拒绝接收：hook 已停止但页面脚本还在跑时不再收数据
	if !s.hook_state.active {
		return
	}
	s.pending_mu.@lock()
	closed := s.closed
	s.pending_mu.unlock()
	if closed {
		return
	}
	if record_id in s.hook_records {
		return
	}
	// 外部路径（轮询同步 / clear）也会改记录集合，条数对不上时重新统计累计字节
	if s.hook_records.len != s.hook_state.record_bytes_tracked {
		s.hook_state.record_bytes = hook_records_total_bytes(s.hook_records)
		s.hook_state.record_bytes_tracked = s.hook_records.len
	}
	s.hook_records[record_id] = HookRecord{
		record_id: record_id
		raw_json:  payload
	}
	s.hook_record_order << record_id
	s.hook_state.record_bytes += payload.len
	s.hook_state.record_bytes_tracked++
	s.hook_state.last_pushed_count++
	// 超限就环形淘汰最旧的记录
	s.evict_hook_records()
	s.hook_state.record_count = s.hook_record_order.len
}

// evict_hook_records 按条数 / 字节上限环形淘汰最旧的 hook 记录。
// map 和 hook_record_order 必须同步清理，否则顺序里会留下空洞。
fn (mut s CdpSession) evict_hook_records() {
	for s.hook_record_order.len > s.hook_record_limit {
		s.evict_oldest_hook_record()
	}
	for s.hook_state.record_bytes > s.hook_byte_limit && s.hook_record_order.len > 0 {
		s.evict_oldest_hook_record()
	}
}

// evict_oldest_hook_record 淘汰最旧的一条 hook 记录。
fn (mut s CdpSession) evict_oldest_hook_record() {
	if s.hook_record_order.len == 0 {
		return
	}
	oldest := s.hook_record_order[0]
	s.hook_record_order = s.hook_record_order[1..]
	if record := s.hook_records[oldest] {
		s.hook_state.record_bytes -= record.raw_json.len
	}
	s.hook_records.delete(oldest)
	if s.hook_state.record_bytes < 0 {
		s.hook_state.record_bytes = 0
	}
	if s.hook_state.record_bytes_tracked > 0 {
		s.hook_state.record_bytes_tracked--
	}
}

// hook_records_total_bytes 统计所有 hook 记录占用的字节数（重新统计时用）。
fn hook_records_total_bytes(records map[string]HookRecord) int {
	mut total := 0
	for _, record in records {
		total += record.raw_json.len
	}
	return total
}

// ─── 超时常量 ───────────────────────────────────────────────
const cdp_default_timeout = 60 * time.second
const cdp_attach_timeout = 60 * time.second

// loadingFinished worker 池大小 (#23)
const body_worker_count = 4

// ─── 事件分发常量 ───────────────────────────────────────────
// 每个事件订阅的分发队列容量（突发时最多缓存这么多事件）
const event_queue_capacity = 256
// 分发线程等待订阅方腾出位置的最长时间
const event_forward_wait = 50 * time.millisecond
// 累计丢弃事件的告警间隔
const event_dropped_warn_every = 100

// ─── hook 记录上限常量 ──────────────────────────────────────
// 每个会话最多保留的 hook 记录条数
const hook_max_records = 10000
// 每个会话 hook 记录的累计字节上限（64 MiB）
const hook_max_total_bytes = 64 * 1024 * 1024
// 单条 hook 记录 payload 上限（1 MiB）
const hook_max_record_bytes = 1024 * 1024

// ─── JSON 解析帮助函数 ──────────────────────────────────────

// cdp_json_object 解析 JSON 对象文本；解析失败或不是对象时返回空 map。
fn cdp_json_object(text string) map[string]json.Any {
	trimmed := text.trim_space()
	if trimmed == '' {
		return map[string]json.Any{}
	}
	return json.decode[map[string]json.Any](trimmed) or { map[string]json.Any{} }
}

// cdp_json_str 取对象里的字符串字段；字段缺失或类型不符返回 ''。
// （处理浏览器事件的路径必须走这里：子串搜索会命中嵌套层级里的同名字段）
fn cdp_json_str(obj map[string]json.Any, key string) string {
	value := obj[key] or { return '' }
	if value is string {
		return value
	}
	return ''
}

// cdp_json_int 取对象里的整数字段；字段缺失或类型不符返回 0。
fn cdp_json_int(obj map[string]json.Any, key string) int {
	value, _ := cdp_json_int_ok(obj, key)
	return value
}

// cdp_json_int_ok 取整数字段并同时返回是否合法
//（用于区分「没有这个字段」和「字段值是 0」）。
fn cdp_json_int_ok(obj map[string]json.Any, key string) (int, bool) {
	value := obj[key] or { return 0, false }
	if value is int {
		return value, true
	}
	if value is i64 {
		return int(value), true
	}
	if value is f64 {
		return int(value), true
	}
	return 0, false
}

fn cdp_json_bool(obj map[string]json.Any, key string) bool {
	value := obj[key] or { return false }
	if value is bool {
		return value
	}
	return false
}

// cdp_json_object_field 取对象里的子对象；字段缺失或类型不符返回空 map。
fn cdp_json_object_field(obj map[string]json.Any, key string) map[string]json.Any {
	value := obj[key] or { return map[string]json.Any{} }
	if value is map[string]json.Any {
		return value
	}
	return map[string]json.Any{}
}

// cdp_parse_message 解析扩展 WebSocket 消息。
// 用 json.decode 一次解析成 map[string]json.Any，再用 map 查字段，避免
// cdp_extract_* 的 substring 扫描。raw 消息越复杂、字段越多，省得越多 (#35)。
// 为了避开 V 内建 `error` 函数，错误字段用 key 'error' 直接从 map 拿。
fn cdp_parse_message(raw string) ProtocolResponse {
	parsed := json.decode[map[string]json.Any](raw) or {
		return ProtocolResponse{
			id:  0
			err: 'invalid JSON: ${err.msg()}'
		}
	}
	// 顶层字段：map[key] 返回 Option<Any>，absent 时用 default
	id_val := cdp_json_int(parsed, 'id')
	method_val := cdp_json_str(parsed, 'method')
	// result / params 是 JSON 值（object/array/string），下游仍按 JSON
	// 字符串消费（cdp_extract_*），所以再序列化成字符串。
	result_str := parsed['result'] or { json.Any('') }.str()
	params_val := parsed['params'] or { json.Any('') }
	params_str := if params_val is map[string]json.Any { json.Any(params_val).str() } else { '' }
	// error 字段特殊处理：CDP 可能返回 string 或 {code, message} 对象
	mut err_str := ''
	err_any := parsed['error'] or { json.Any('') }
	if err_any != json.Any('') {
		// as_map 对任何非 map 类型会返回包装（如 string → {'0': v}），
		// 所以不能用 .len > 0 判定。改为查 'message' key 是否存在。
		err_obj := err_any.as_map()
		if 'message' in err_obj {
			msg_val := err_obj['message'] or { json.Any('') }
			err_str = msg_val.str()
		} else {
			// 不是真正的 error 对象（多半是字符串）：直接 .str() 取字符串
			err_str = err_any.str()
		}
	}
	return ProtocolResponse{
		id:     id_val
		method: method_val
		result: result_str
		err:    err_str
		params: params_str
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
