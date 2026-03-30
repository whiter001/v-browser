// server.v — v-browser WebSocket relay + IPC server
module main

import net.websocket
import net
import os
import time
import sync

pub const relay_port = 47978
pub const ipc_port = 47979
const v_browser_version = '0.1.0'

// 读取 relay 端口；环境变量优先，其次是配置文件，最后回退默认值。
fn configured_relay_port() int {
	override := get_env_with_config('V_BROWSER_RELAY_PORT').trim_space().int()
	if override > 0 {
		return override
	}
	return relay_port
}

// 读取 IPC 端口；环境变量优先，其次是配置文件，最后回退默认值。
fn configured_ipc_port() int {
	override := get_env_with_config('V_BROWSER_IPC_PORT').trim_space().int()
	if override > 0 {
		return override
	}
	return ipc_port
}

// 解析 v-browser 的状态目录根路径。
fn v_browser_home_dir() string {
	override := os.getenv('V_BROWSER_HOME').trim_space()
	if override != '' {
		return override
	}
	return os.home_dir()
}

// 返回全局配置文件路径。
fn v_browser_config_path() string {
	return os.join_path(os.home_dir(), '.config', 'v-browser', 'config')
}

// 从 key=value 格式的配置文件读取全局配置。
fn load_config_from_file() map[string]string {
	mut config := map[string]string{}
	config_path := v_browser_config_path()
	if !os.exists(config_path) {
		return config
	}
	lines := os.read_lines(config_path) or { return config }
	for line_orig in lines {
		line := line_orig.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		if idx := line.index('=') {
			key := line[..idx].trim_space()
			val := line[idx + 1..].trim_space()
			if key != '' {
				config[key] = val
			}
		}
	}
	return config
}

// 按“环境变量 > 配置文件 > 空字符串”的顺序读取配置项。
fn get_env_with_config(key string) string {
	env_val := os.getenv(key).trim_space()
	if env_val != '' {
		return env_val
	}
	config := load_config_from_file()
	if val := config[key] {
		return val
	}
	return ''
}

// 返回 IPC 就绪标记文件路径。
fn ipc_sock_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.sock')
}

// 返回连接 token 的持久化路径。
fn token_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'token')
}

// 返回扩展 ID 的持久化路径。
fn extension_id_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'extension_id')
}

// 返回 server 日志文件路径。
fn server_log_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.log')
}

// 返回 pueue 任务标识缓存路径。
fn server_task_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.task')
}

// 返回 server pid 文件路径。
fn server_pid_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.pid')
}

// 返回 server 版本标记文件路径。
fn server_version_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.version')
}

// ExtensionConn 代表一个已连接的扩展 + 对应 CDP session
@[heap]
struct ExtensionConn {
mut:
	session    &CdpSession
	client_ptr voidptr // unsafe &websocket.Client，用于从其他 goroutine 向扩展发消息
}

// 向已连接的扩展转发一条 WebSocket 消息。
fn (mut ec ExtensionConn) send(data string) ! {
	if ec.client_ptr == 0 {
		return error('no client')
	}
	unsafe {
		mut c := &websocket.Client(ec.client_ptr)
		c.write_string(data)!
	}
}

// VBrowserServer 核心服务
@[heap]
struct VBrowserServer {
mut:
	ext_conn ?&ExtensionConn
	ext_mu   sync.Mutex
	token    string
	running  bool
}

// 初始化 server 实例并加载连接 token。
fn new_server() !&VBrowserServer {
	token := load_or_create_token()!
	return &VBrowserServer{
		token:   token
		running: true
	}
}

// start 启动所有监听（阻塞，直至 WebSocket server 退出）
// 启动 IPC 和 WebSocket 两个监听入口，并在退出后清理现场。
fn (mut s VBrowserServer) start() ! {
	dir := os.dir(ipc_sock_path())
	os.mkdir_all(dir) or {}
	os.write_file(server_pid_path(), '${os.getpid()}') or {}
	os.write_file(server_version_path(), v_browser_version) or {}

	// IPC server 在后台 goroutine 运行
	spawn s.run_ipc_server()

	// WebSocket relay 在主 goroutine 运行
	s.run_ws_server()!
	os.rm(ipc_sock_path()) or {}
	os.rm(server_pid_path()) or {}
	os.rm(server_version_path()) or {}
}

// 启动 WebSocket relay，用于接收扩展连接和转发 CDP 消息。
fn (mut s VBrowserServer) run_ws_server() ! {
	relay := configured_relay_port()
	mut ws := websocket.new_server(.ip, relay, '', websocket.ServerOpt{})
	ws.on_connect(fn [mut s] (mut sc websocket.ServerClient) !bool {
		if !validate_extension_token(sc.resource_name, s.token) {
			srv_log_err('Extension connection rejected: invalid token in ${sc.resource_name}')
			return false
		}
		srv_log('Extension client connecting...')
		// 保存 client_ptr 供后续发送用
		client_ptr := unsafe { voidptr(sc.client) }
		send_fn := fn [client_ptr] (data string) ! {
			unsafe {
				mut c := &websocket.Client(client_ptr)
				c.write_string(data)!
			}
		}
		mut sess := new_cdp_session(send_fn)
		mut conn := &ExtensionConn{ session: sess, client_ptr: client_ptr }
		s.ext_mu.@lock()
		// 关闭旧连接
		if mut old := s.ext_conn {
			old.session.close()
		}
		s.ext_conn = conn
		s.ext_mu.unlock()
		srv_log('Extension connected, waiting for attachToTab...')
		return true
	})!

	ws.on_message_ref(fn [mut s] (mut c websocket.Client, msg &websocket.Message, v voidptr) ! {
		if msg.opcode == .text_frame || msg.opcode == .binary_frame {
			raw := msg.payload.bytestr()
			extension_id := parse_extension_registration(raw)
			if extension_id != '' {
				save_extension_id(extension_id) or {
					srv_log_err('Failed to persist extension id ${extension_id}: ${err}')
					return
				}
				srv_log('Recorded extension id: ${extension_id}')
				return
			}
			s.ext_mu.@lock()
			if mut conn := s.ext_conn {
				conn.session.on_message(raw)
			}
			s.ext_mu.unlock()
		}
	}, unsafe { voidptr(&s) })

	ws.on_close_ref(fn [mut s] (mut c websocket.Client, code int, reason string, v voidptr) ! {
		srv_log('Extension disconnected: code=${code} reason=${reason}')
		s.ext_mu.@lock()
		if mut conn := s.ext_conn {
			conn.session.close()
		}
		s.ext_conn = none
		s.ext_mu.unlock()
	}, unsafe { voidptr(&s) })

	srv_log('WebSocket relay listening on ws://127.0.0.1:${relay}')
	ws.listen()!
}

// 解析扩展注册消息，提取 extensionId。
fn parse_extension_registration(raw string) string {
	msg := cdp_parse_message(raw)
	if msg.id != 0 || msg.method != 'registerExtension' {
		return ''
	}
	return cdp_extract_str(msg.params, 'extensionId').trim_space()
}

// 启动本地 IPC 服务器，供 CLI 与 relay 侧交互。
fn (mut s VBrowserServer) run_ipc_server() {
	ipc := configured_ipc_port()
	mut listener := net.listen_tcp(.ip, ':${ipc}') or {
		srv_log_err('IPC listen failed on :${ipc}: ${err}')
		return
	}
	srv_log('IPC server listening on 127.0.0.1:${ipc}')
	// 写标记文件，告知 CLI server 已就绪
	os.mkdir_all(os.dir(ipc_sock_path())) or {}
	os.write_file(ipc_sock_path(), '${ipc}') or {}

	for s.running {
		mut conn := listener.accept() or {
			if s.running {
				continue
			}
			break
		}
		spawn s.handle_ipc_client(mut conn)
	}
	// 清理 socket 文件
	os.rm(ipc_sock_path()) or {}
	srv_log('IPC server stopped.')
}

// 处理单个 IPC 连接，按行读取请求并逐条回复。
fn (mut s VBrowserServer) handle_ipc_client(mut conn net.TcpConn) {
	defer { conn.close() or {} }
	conn.set_read_timeout(120 * time.second)

	mut buf := []u8{len: 8192}
	mut pending := ''

	for {
		n := conn.read(mut buf) or { break }
		if n == 0 {
			break
		}
		pending += buf[..n].bytestr()

		for {
			nl_idx := pending.index('\n') or { break }
			line := pending[..nl_idx]
			pending = pending[nl_idx + 1..]
			if line.trim_space().len == 0 {
				continue
			}

			req := ipc_decode_request(line) or {
				conn.write_string(ipc_encode_response(IpcResponse{ id: 0, err: 'parse: ${err}' })) or {}
				continue
			}
			resp := s.dispatch(req)
			conn.write_string(ipc_encode_response(resp)) or { break }
		}
	}
}

fn (mut s VBrowserServer) dispatch(req IpcRequest) IpcResponse {
	// status 命令不需要 session
	if req.method == 'status' {
		s.ext_mu.@lock()
		mut connected := false
		mut attached := false
		mut network_enabled := false
		mut page_enabled := false
		mut current_frame_selector := ''
		if mut conn := s.ext_conn {
			connected = true
			page_state := conn.session.page_state_snapshot()
			page_enabled = page_state.page_enabled
			conn.session.network_mu.@lock()
			network_enabled = conn.session.network_enabled
			conn.session.network_mu.unlock()
			current_frame_selector = page_state.current_frame_selector
			attached = page_enabled || network_enabled || current_frame_selector != ''
		}
		s.ext_mu.unlock()
		return IpcResponse{
			id:     req.id
			result: '{"connected":${connected},"extensionConnected":${connected},"attached":${attached},"pageEnabled":${page_enabled},"networkEnabled":${network_enabled},"currentFrameSelector":${json_str(current_frame_selector)}}'
		}
	}
	if req.method == 'connect' {
		attached := s.attach_session(req.params) or {
			return IpcResponse{
				id:  req.id
				err: err.msg()
			}
		}
		return IpcResponse{
			id:     req.id
			result: attached
		}
	}
	// shutdown 命令：让 server 优雅退出
	if req.method == 'shutdown' {
		s.running = false
		spawn shutdown_server_process()
		return IpcResponse{
			id:     req.id
			result: '{"ok":true}'
		}
	}

	// 获取 session
	s.ext_mu.@lock()
	mut conn_opt := s.ext_conn
	s.ext_mu.unlock()
	mut conn := conn_opt or {
		return IpcResponse{
			id:  req.id
			err: 'no extension connected. Open Chrome with the v-browser extension, then run: v-browser connect'
		}
	}

	mut sess := conn.session

	result := dispatch_command(mut sess, req.method, req.params)
	if result.starts_with('ERROR:') {
		return IpcResponse{
			id:  req.id
			err: result[6..]
		}
	}
	return IpcResponse{
		id:     req.id
		result: result
	}
}

fn shutdown_server_process() {
	time.sleep(150 * time.millisecond)
	os.rm(ipc_sock_path()) or {}
	os.rm(server_pid_path()) or {}
	exit(0)
}

// attach_session 在扩展连接后发 attachToTab（被 `v-browser connect` 命令触发）
fn (mut s VBrowserServer) attach_session(params string) !string {
	s.ext_mu.@lock()
	mut conn_opt := s.ext_conn
	s.ext_mu.unlock()
	mut conn := conn_opt or { return error('no extension connected') }
	tab_id := cdp_extract_int(params, '"tabId":')
	window_id := cdp_extract_int(params, '"windowId":')
	target_url := cdp_extract_str(params, 'url')
	if tab_id > 0 {
		resp := conn.session.send_bridge_command('switchToTab', '{"tabId":${tab_id},"windowId":${window_id}}')!
		conn.session.activate_tab_context_from_result(resp.result) or {}
		return resp.result
	}
	return conn.session.attach_to_tab_by_url(target_url)
}

// get_session 获取当前 session，无连接则报错
fn (mut s VBrowserServer) get_session() !&CdpSession {
	s.ext_mu.@lock()
	mut conn_opt := s.ext_conn
	s.ext_mu.unlock()
	mut conn := conn_opt or { return error('no extension connected') }
	return conn.session
}

// ─── Token ──────────────────────────────────────────────────

fn load_or_create_token() !string {
	dir := os.dir(token_path())
	os.mkdir_all(dir) or {}
	if os.exists(token_path()) {
		t := os.read_file(token_path()) or { '' }
		if t.trim_space().len >= 16 {
			return t.trim_space()
		}
	}
	// 简易伪随机 token（生产可换 crypto random）
	now := time.now().unix_milli()
	raw := '${now}-${os.getpid()}-vbrowser'
	mut h := u64(0)
	for b in raw.bytes() {
		h = h * 31 + u64(b)
	}
	token := h.hex()
	os.write_file(token_path(), token)!
	return token
}

fn srv_log(msg string) {
	eprintln('[server] ${msg}')
}

fn srv_log_err(msg string) {
	eprintln('[server ERROR] ${msg}')
}

fn validate_extension_token(resource_name string, expected string) bool {
	token := extract_query_param(resource_name, 'token')
	return token != '' && token == expected
}

fn extract_query_param(resource_name string, key string) string {
	q_idx := resource_name.index('?') or { return '' }
	query := resource_name[q_idx + 1..]
	for pair in query.split('&') {
		if pair.len == 0 {
			continue
		}
		parts := pair.split_nth('=', 2)
		if parts.len == 2 && parts[0] == key {
			return parts[1]
		}
	}
	return ''
}
