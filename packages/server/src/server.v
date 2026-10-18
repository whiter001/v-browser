// server.v — v-browser WebSocket relay + IPC server
module main

import net.websocket
import net
import os
import time
import sync
import crypto.rand

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
	client_ptr voidptr // unsafe &websocket.Client，用于从其他 goroutine 向扩展发消息，
	// 同时用作连接身份标识（on_message / on_close 回调里比对用）
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
	mut s := &VBrowserServer{
		token:   token
		running: true
	}
	// 同 new_cdp_session：上游 V 已修复零值 Mutex 自动初始化，此处保留显式
	// init() 仅为兼容旧版 V（幂等，无副作用）
	s.ext_mu.init()
	return s
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
	// V stdlib 的 websocket.new_server 会把 listener 绑到 INADDR_ANY（无
	// 法只指定 loopback 地址），所以这里在 on_connect 里再二次过滤 peer IP，
	// 拒绝非 loopback 的连接 (#26)。
	mut ws := websocket.new_server(.ip, relay, '', websocket.ServerOpt{})
	ws.on_connect(fn [mut s] (mut sc websocket.ServerClient) !bool {
		// #26: 拒绝非 loopback 连接，避免 LAN / 公网攻击面
		peer_ip_str := sc.client.conn.peer_ip() or {
			srv_log_err('Cannot determine peer IP for relay connection; rejecting')
			return false
		}
		if !is_loopback_ip(peer_ip_str) {
			srv_log_err('Rejected non-loopback relay connection from ${peer_ip_str}')
			return false
		}
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
		mut stale_ptr := voidptr(0)
		s.ext_mu.@lock()
		// 关闭旧连接
		if mut old := s.ext_conn {
			old.session.close()
			stale_ptr = old.client_ptr
		}
		s.ext_conn = conn
		s.ext_mu.unlock()
		// 旧连接的 WebSocket 本身也必须关掉，否则它会一直留着 message/close 回调，
		// 之后再发消息或断开时就会串到新连接上（靠下面回调里的身份校验兜底）。
		// 必须放在 ext_mu 之外：websocket.Client.close() 会同步触发本文件的
		// on_close_ref 回调，持锁调用会自死锁。
		if stale_ptr != 0 && stale_ptr != client_ptr {
			unsafe {
				mut stale_client := &websocket.Client(stale_ptr)
				stale_client.close(1000, 'replaced by a newer extension connection') or {}
			}
		}
		srv_log('Extension connected, waiting for attachToTab...')
		return true
	})!

	ws.on_message_ref(fn [mut s] (mut c websocket.Client, msg &websocket.Message, v voidptr) ! {
		if msg.opcode == .text_frame || msg.opcode == .binary_frame {
			raw := msg.payload.bytestr()
			// 身份校验（必须）：旧扩展连接的 on_message / on_close 回调可能晚于新连接的
			// on_connect 到达。ext_mu 只能保证 ext_conn 不被并发修改，不能保证这个回调
			// 属于当前连接；不校验就会把旧连接的消息投递给新 session（响应串线）。
			caller := unsafe { voidptr(&c) }
			if !s.is_active_conn(caller) {
				srv_log('Dropped relay message from a stale extension connection')
				return
			}
			extension_id := parse_extension_registration(raw)
			if extension_id != '' {
				// 同理，只有当前活动连接发来的注册消息才允许落盘，避免被顶掉的旧连接
				// 覆盖新连接写入的扩展 id。
				save_extension_id(extension_id) or {
					srv_log_err('Failed to persist extension id ${extension_id}: ${err}')
					return
				}
				srv_log('Recorded extension id: ${extension_id}')
				return
			}
			s.ext_mu.@lock()
			if mut conn := s.ext_conn {
				if conn.client_ptr == caller {
					conn.session.on_message(raw)
				} else {
					srv_log('Dropped relay message from a stale extension connection')
				}
			}
			s.ext_mu.unlock()
		}
	}, unsafe { voidptr(&s) })

	ws.on_close_ref(fn [mut s] (mut c websocket.Client, code int, reason string, v voidptr) ! {
		// 身份校验（必须）：被顶掉的旧连接 close 回调晚到时，不能去关新连接的 session，
		// 也不能把 ext_conn 置空——否则新连接还挂着 WebSocket，服务端却认为没有扩展。
		caller := unsafe { voidptr(&c) }
		mut closed_active := false
		s.ext_mu.@lock()
		if mut conn := s.ext_conn {
			if conn.client_ptr == caller {
				conn.session.close()
				s.ext_conn = none
				closed_active = true
			}
		}
		s.ext_mu.unlock()
		if closed_active {
			srv_log('Extension disconnected: code=${code} reason=${reason}')
		} else {
			srv_log('Extension disconnected: code=${code} reason=${reason} (stale connection, ignored)')
		}
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

// is_active_conn 判断 caller（回调里的 websocket.Client 地址）是否就是当前的活动扩展连接。
// 旧连接被新连接顶掉后，它的 message/close 回调仍可能晚到；ext_mu 只能保证 ext_conn
// 不被并发修改，保证不了回调属于当前连接，所以 relay 回调都要做这个身份比对。
fn (mut s VBrowserServer) is_active_conn(caller voidptr) bool {
	s.ext_mu.@lock()
	mut active := false
	if cur := s.ext_conn {
		active = cur.client_ptr == caller
	}
	s.ext_mu.unlock()
	return active
}

// 启动本地 IPC 服务器，供 CLI 与 relay 侧交互。
fn (mut s VBrowserServer) run_ipc_server() {
	ipc := configured_ipc_port()
	// 必须显式绑 127.0.0.1：':port' 是通配地址，会监听 0.0.0.0 上所有网卡，
	// 让同网段的任意主机都能直连 IPC 驱动浏览器。
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${ipc}') or {
		srv_log_err('IPC listen failed on 127.0.0.1:${ipc}: ${err}')
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
	// 二次防线：即便绑定地址被改动，非 loopback 的对端也一律拒绝。
	// 取不到 peer ip 说明连接来路不明，同样按拒绝处理。
	peer := conn.peer_ip() or {
		srv_log_err('IPC connection without a resolvable peer address; rejected.')
		return
	}
	if !is_loopback_ip(peer.str()) {
		srv_log_err('IPC connection from non-loopback peer ${peer.str()}; rejected.')
		return
	}
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
		resp := conn.session.send_bridge_command('switchToTab',
			'{"tabId":${tab_id},"windowId":${window_id}}')!
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
	os.mkdir_all(dir) or {
		return error('could not create token dir ${dir}: ${err}')
	}
	// token 文件是凭据，umask 022 下默认可被同机其他用户读取，这里显式收紧。
	os.chmod(dir, 0o700) or {}
	if os.exists(token_path()) {
		t := os.read_file(token_path()) or { '' }
		if t.trim_space().len >= 16 {
			// 旧版本落盘时没设权限，这里补一次修正。
			os.chmod(token_path(), 0o600) or {}
			return t.trim_space()
		}
	}
	// 必须用密码学随机：时间戳 + PID + 固定后缀是可枚举的，猜到启动时间就能推算出 token。
	raw := rand.bytes(32)!
	token := raw.hex()
	// os.write_file 无法指定权限，用 open_file 以 0600 创建/截断。
	mut f := os.open_file(token_path(), 'w', 0o600)!
	f.write_string(token)!
	f.close()
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

// is_loopback_ip 判断 IP 是否为 loopback 地址（#26）。
// IPv4: 127.0.0.0/8；IPv6: ::1。
fn is_loopback_ip(ip string) bool {
	if ip == '::1' || ip == '127.0.0.1' {
		return true
	}
	if ip.len >= 4 && ip[0..3] == '127' && ip[3] == `.` {
		return true
	}
	return false
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
