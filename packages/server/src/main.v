// main.v — v-browser CLI 入口
// 用法:
//   v-browser server          — 启动中继服务（守护模式）
//   v-browser connect         — 触发 attachToTab（需要打开过 Chrome 并连接中继服务）
//   v-browser status          — 检查中继服务是否运行 + 是否已连接扩展
//   v-browser open <url>      — 导航到指定 URL
//   v-browser click <sel>     — 点击元素
//   v-browser fill <sel> <txt>— 填写输入框
//   v-browser press <key>     — 按下按键
//   v-browser screenshot [p]  — 截图
//   v-browser snapshot        — accessibility 快照
//   v-browser download <sel> <path> — 点击并等待下载完成
//   v-browser eval <expr>     — 执行 JS 表达式（-b/--base64, --stdin, --file）
//   v-browser wait <ms|sel>   — 等待
//   v-browser find --role button --name "OK" --click
//   ...（其余命令见 commands.v）
module main

import os
import net
import net.urllib
import time

type EvalStdinReader = fn () !string

type EvalFileReader = fn (string) !string

type IPCSender = fn (string, string) !string

fn main() {
	raw_args := os.args[1..]
	if raw_args.len == 0 {
		print_usage()
		return
	}
	mut json_output := false
	mut raw_output := false
	mut args := []string{}
	for arg in raw_args {
		match arg {
			'--json' { json_output = true }
			'--raw', '-r' { raw_output = true }
			else { args << arg }
		}
	}
	if args.len == 0 {
		print_usage()
		return
	}

	cmd := args[0]
	rest := args[1..].clone()

	// 特殊：server 子命令本地处理，不需要 IPC
	if cmd == 'server' || cmd == 'daemon' {
		if rest.len > 0 {
			match rest[0] {
				'stop' {
					handle_server_stop(json_output, false, true) or {
						print_error(err.msg(), json_output)
						exit(1)
					}
					return
				}
				'restart' {
					handle_server_stop(json_output, true, false) or {
						print_error(err.msg(), json_output)
						exit(1)
					}
					start_server_daemon() or {
						print_error('failed to restart server: ${err}', json_output)
						exit(1)
					}
					wait_for_server_ready() or {
						print_error('failed to restart server: ${err}', json_output)
						exit(1)
					}
					eprintln('[v-browser] Server restarted.')
					return
				}
				else {}
			}
		}
		run_server()
		return
	}
	if cmd == 'connect' {
		handle_connect_command(rest, json_output)
		return
	}

	// 所有其他子命令转为 IPC 请求转发给 server
	method, params := parse_cli_to_ipc(cmd, rest, raw_output)
	result := run_cli_command(method, params) or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	// Server 侧把可恢复/可提示的命令错误封装成 ERROR:，这里统一转成真正的错误输出。
	if is_cli_error_result(result) {
		print_error(cli_error_message(result), json_output)
		exit(1)
	}
	// status 命令：未连接时显示友好提示
	if method == 'status' && !json_output && result.contains('"connected":false') {
		eprintln('Not connected. Run `v-browser connect` to connect.')
		if result.contains('"extensionConnected":true') && result.contains('"attached":false') {
			eprintln('Hint: the extension is connected but no tab is attached yet. Switch to a normal webpage tab, then run v-browser connect again.')
		} else {
			eprintln('Hint: if the extension page is already open, switch to a normal webpage tab, then run v-browser connect again.')
		}
	}
	// CLI 模式自动解码 JSON 字符串
	if !json_output && raw_output {
		println(decode_json_string(result))
	} else {
		println(format_output(result, json_output))
	}
}

fn handle_connect_command(args []string, json_output bool) {
	tab_id := extract_flag_value(args, '--tab-id').int()
	window_id := extract_flag_value(args, '--window-id').int()
	target_url := extract_connect_target_url(args)
	extension_id := resolve_extension_id(args)
	status_before := send_ipc('status', '{}') or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	if !is_extension_connected(status_before) {
		if extension_id != '' {
			connect_url := open_extension_connect_page(extension_id) or {
				print_error(err.msg(), json_output)
				exit(1)
				return
			}
			eprintln('[v-browser] Opened extension connect page: ${connect_url}')
			if !wait_for_extension_connection(35 * time.second) {
				print_error('extension did not connect within 35s; select a tab in the extension page, then run v-browser connect again',
					json_output)
				return
			}
		} else {
			print_error('no extension connected; set V_BROWSER_EXTENSION_ID or run v-browser connect --extension-id <id>',
				json_output)
			exit(1)
		}
	}
	params := build_connect_ipc_params(tab_id, window_id, target_url)
	result := connect_active_session(params) or {
		err_msg := err.msg()
		if is_attach_conflict_error(err_msg) {
			eprintln('Debugger conflict: another debugger is already attached to the tab. Close Chrome DevTools or other CDP sessions, then run v-browser connect again.')
		} else if err_msg.contains('no available tab')
			|| err_msg.contains('no tab is currently accessible') {
			eprintln('No tab available: switch to a normal webpage tab (not the extension page), then run v-browser connect again.')
		} else if err_msg.contains('timeout') {
			eprintln('Connection timed out. Make sure the extension is installed and the extension connect page is open.')
		} else {
			print_error(err_msg, json_output)
		}
		exit(1)
	}
	println(format_output(result, json_output))
}

fn build_connect_ipc_params(tab_id int, window_id int, target_url string) string {
	return '{"tabId":${tab_id},"windowId":${window_id},"url":${json_str(target_url)}}'
}

fn extract_connect_target_url(args []string) string {
	url := extract_flag_value(args, '--url').trim_space()
	if url != '' {
		return url
	}
	if args.len == 0 {
		return ''
	}
	first := args[0].trim_space()
	if first == '' || first.starts_with('-') {
		return ''
	}
	if first.contains('://') {
		return first
	}
	return ''
}

fn run_cli_command(method string, params string) !string {
	result := send_ipc(method, params) or {
		if should_retry_after_reconnect(method, err.msg()) {
			reconnect_current_session()!
			return send_ipc(method, params)!
		}
		return error(err.msg())
	}
	return result
}

fn connect_active_session(params string) !string {
	return connect_active_session_with(send_ipc, params)
}

fn connect_active_session_with(send_ipc_fn IPCSender, params string) !string {
	result := send_ipc_fn('connect', params) or {
		if is_attach_conflict_error(err.msg()) {
			return error(err.msg())
		}
		return error(err.msg())
	}
	return result
}

fn reconnect_current_session() ! {
	connect_active_session('{}') or {
		status_before := send_ipc('status', '{}') or { '{"connected":false}' }
		if !is_extension_connected(status_before) {
			extension_id := resolve_extension_id([]string{})
			if extension_id == '' {
				return error('no extension connected; set V_BROWSER_EXTENSION_ID or run v-browser connect --extension-id <id>')
			}
			connect_url := open_extension_connect_page(extension_id)!
			eprintln('[v-browser] Reconnecting via extension page: ${connect_url}')
			if !wait_for_extension_connection(35 * time.second) {
				return error('extension did not connect within 35s; select a tab in the extension page, then rerun the command')
			}
		}
		connect_active_session('{}')!
		return
	}
}

// 判断当前命令是否适合在重连后自动重试。
fn should_retry_after_reconnect(method string, err_msg string) bool {
	if method in ['connect', 'status'] {
		return false
	}
	lower := err_msg.to_lower()
	return lower.contains('no extension connected') || lower.contains('no tab is connected')
		|| lower.contains('cdp session is closed')
}

// 识别“已经有其他调试器附加到同一标签页”的冲突错误。
fn is_attach_conflict_error(err_msg string) bool {
	lower := err_msg.to_lower()
	return lower.contains('another debugger is already attached')
		|| lower.contains('debugger is already attached to the tab')
}

// 确保后台 server 已启动；如果 IPC 不可达则先拉起守护进程。
fn ensure_server_running() ! {
	if can_reach_ipc_server() {
		if server_runtime_version_matches() {
			return
		}
		eprintln('[v-browser] Detected stale server version; restarting...')
		restart_server_daemon()!
		return
	}
	start_server_daemon()!
	wait_for_server_ready()!
}

// 轮询等待 server 对外可连接。
fn wait_for_server_ready() ! {
	deadline := time.now().add(8 * time.second)
	for time.now() < deadline {
		if can_reach_ipc_server() && server_runtime_version_matches() {
			return
		}
		time.sleep(200 * time.millisecond)
	}
	return error('v-browser server did not become ready. Check ${background_server_diagnostics_hint()}')
}

// 检查当前后台 server 是否写入了与本地 CLI 一致的版本标记。
fn server_runtime_version_matches() bool {
	stored := os.read_file(server_version_path()) or { return false }
	return stored.trim_space() == v_browser_version
}

// 通过本地 IPC 标记和 TCP 连接判断 server 是否可用。
fn can_reach_ipc_server() bool {
	port_str := os.read_file(ipc_sock_path()) or { return false }
	port := port_str.trim_space().int()
	if port == 0 {
		return false
	}
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { return false }
	conn.close() or {}
	return true
}

// 优先通过 pueue 启动后台 server，失败时回退到 nohup。
fn start_server_daemon() ! {
	os.mkdir_all(os.dir(server_log_path()))!
	executable := os.executable()
	if executable == '' {
		return error('could not determine current executable path')
	}
	result := os.execute(build_pueue_add_command(executable))
	if result.exit_code != 0 {
		$if windows {
			return error('failed to enqueue v-browser server with pueue: ${result.output}')
		}
		fallback := os.execute('nohup ${shell_quote(executable)} server >> ${shell_quote(server_log_path())} 2>&1 &')
		if fallback.exit_code != 0 {
			return error('failed to start v-browser server: ${result.output}\nfallback failed: ${fallback.output}')
		}
		os.write_file(server_task_path(), '') or {}
		return
	}
	task_id := result.output.trim_space()
	if task_id != '' {
		os.write_file(server_task_path(), task_id) or {}
	}
}

// 停止旧 server 并重新拉起当前版本的 daemon。
fn restart_server_daemon() ! {
	_ := handle_server_stop(false, true, false) or {
		return error('failed to stop stale v-browser server: ${err.msg()}')
	}
	start_server_daemon()!
	wait_for_server_ready()!
}

// 构造 pueue 任务命令，并保留当前可执行文件所在目录。
fn build_pueue_add_command(executable string) string {
	work_dir := os.dir(executable)
	return 'pueue add --immediate --print-task-id --label ${host_shell_quote('v-browser server')} --working-directory ${host_shell_quote(work_dir)} --escape ${host_shell_quote(executable)} server'
}

// 返回后台 server 的排查入口，优先给出 pueue log。
fn background_server_diagnostics_hint() string {
	task_id := (os.read_file(server_task_path()) or { '' }).trim_space()
	if task_id != '' {
		return 'pueue log ${task_id}'
	}
	return server_log_path()
}

// ─── 停止服务 ────────────────────────────────────────────────
// 尝试用 IPC、PID 和端口三种方式停止 server。
fn handle_server_stop(json_output bool, allow_missing bool, emit_output bool) !bool {
	pid := read_server_pid()
	mut found_running_server := pid > 0 && is_process_running(pid)
	mut stop_mode := ''

	if can_reach_ipc_server() {
		found_running_server = true
		shutdown_result := send_ipc_without_start('shutdown', '{}') or { '' }
		if shutdown_result != '' {
			if wait_for_server_shutdown(pid, 5 * time.second) {
				cleanup_server_runtime_state()
				if emit_output {
					report_server_stop('server shutdown via IPC', json_output)
				}
				return true
			}
			stop_mode = 'IPC shutdown timed out'
		}
	}

	if pid > 0 && is_process_running(pid) {
		found_running_server = true
		if terminate_process(pid) && wait_for_server_shutdown(pid, 5 * time.second) {
			cleanup_server_runtime_state()
			if emit_output {
				report_server_stop('server killed', json_output)
			}
			return true
		}
		stop_mode = 'pid termination failed'
	}

	if kill_server_by_ports() && wait_for_server_shutdown(0, 5 * time.second) {
		cleanup_server_runtime_state()
		if emit_output {
			report_server_stop('server killed', json_output)
		}
		return true
	}

	if !found_running_server {
		cleanup_server_runtime_state()
		if allow_missing {
			return false
		}
		return error('no running server found')
	}

	err_msg := if stop_mode != '' {
		'failed to stop v-browser server: ${stop_mode}'
	} else {
		'failed to stop v-browser server'
	}
	return error(err_msg)
}

// 按 JSON 或普通文本输出 server 停止结果。
fn report_server_stop(message string, json_output bool) {
	if json_output {
		println('{"ok":true,"result":${json_str(message)}}')
	} else {
		eprintln('[v-browser] ${message}.')
	}
}

// 清理 server 的 pid、socket 和 pueue 任务残留。
fn cleanup_server_runtime_state() {
	for path in [ipc_sock_path(), server_pid_path(), server_version_path()] {
		os.rm(path) or {}
	}
	task_id := (os.read_file(server_task_path()) or { '' }).trim_space()
	if task_id != '' {
		os.execute('pueue remove ${task_id}')
	}
	os.write_file(server_task_path(), '') or {}
}

// 读取记录在磁盘上的 server pid。
fn read_server_pid() int {
	pid_str := os.read_file(server_pid_path()) or { return 0 }
	return pid_str.trim_space().int()
}

// 检查指定 pid 是否仍在运行。
fn is_process_running(pid int) bool {
	if pid <= 0 {
		return false
	}
	$if windows {
		result := os.execute('tasklist /FI "PID eq ${pid}" /NH')
		return result.exit_code == 0 && result.output.contains('${pid}')
	} $else {
		result := os.execute('kill -0 ${pid} 2>/dev/null')
		return result.exit_code == 0
	}
}

// 跨平台终止指定进程。
fn terminate_process(pid int) bool {
	if pid <= 0 {
		return false
	}
	$if windows {
		result := os.execute('taskkill /PID ${pid} /T /F')
		return result.exit_code == 0
	} $else {
		result := os.execute('kill -TERM ${pid} 2>/dev/null')
		return result.exit_code == 0
	}
}

// 通过监听端口反查并终止残留的 server 进程。
fn kill_server_by_ports() bool {
	$if windows {
		return false
	} $else {
		result := os.execute('lsof -ti:${configured_relay_port()} -ti:${configured_ipc_port()} 2>/dev/null | sort -u')
		if result.exit_code != 0 || result.output.trim_space() == '' {
			return false
		}
		mut killed := false
		for line in result.output.split_into_lines() {
			pid := line.trim_space().int()
			if terminate_process(pid) {
				killed = true
			}
		}
		return killed
	}
}

// 等待 server 的进程和监听端口都退出。
fn wait_for_server_shutdown(pid int, timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		if server_is_stopped(pid) {
			return true
		}
		time.sleep(100 * time.millisecond)
	}
	return server_is_stopped(pid)
}

// 判断 server 是否已经完全停止。
fn server_is_stopped(pid int) bool {
	if pid > 0 && is_process_running(pid) {
		return false
	}
	return !is_port_listening(configured_relay_port()) && !is_port_listening(configured_ipc_port())
}

// 测试本地 TCP 端口是否还在监听。
fn is_port_listening(port int) bool {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { return false }
	conn.close() or {}
	return true
}

// ─── 启动服务 ────────────────────────────────────────────────
// 启动 server 主循环，并在失败时直接退出。
fn run_server() {
	mut s := new_server() or {
		eprintln('Error: ${err}')
		exit(1)
	}
	eprintln('[v-browser] Server starting...')
	s.start() or {
		eprintln('[v-browser] Server error: ${err}')
		exit(1)
	}
}

// 按 CLI 参数、环境变量和持久化配置的优先级解析扩展 ID。
fn resolve_extension_id(args []string) string {
	explicit := extract_flag_value(args, '--extension-id')
	if explicit != '' {
		save_extension_id(explicit) or {}
		return explicit
	}
	env_id := get_env_with_config('V_BROWSER_EXTENSION_ID').trim_space()
	if env_id != '' {
		return env_id
	}
	stored := os.read_file(extension_id_path()) or { '' }
	return stored.trim_space()
}

// 从参数数组中提取指定 flag 的值。
fn extract_flag_value(args []string, flag string) string {
	mut i := 0
	for i < args.len {
		if args[i] == flag {
			if i + 1 < args.len {
				return args[i + 1].trim_space()
			}
			return ''
		}
		i++
	}
	return ''
}

// 将扩展 ID 持久化到本地状态目录。
fn save_extension_id(extension_id string) ! {
	if extension_id.trim_space() == '' {
		return
	}
	os.mkdir_all(os.dir(extension_id_path()))!
	os.write_file(extension_id_path(), extension_id.trim_space())!
}

// 生成扩展 connect 页面所需的完整 URL。
fn build_extension_connect_url(extension_id string, token string) string {
	relay_url := 'ws://127.0.0.1:${configured_relay_port()}'
	client_info := '{"name":"v-browser","version":"${v_browser_version}"}'
	return 'chrome-extension://${extension_id}/connect.html?mcpRelayUrl=${urllib.query_escape(relay_url)}&client=${urllib.query_escape(client_info)}&protocolVersion=1&token=${urllib.query_escape(token)}'
}

// 打开扩展 connect 页面，并返回实际使用的 URL。
fn open_extension_connect_page(extension_id string) !string {
	if extension_id.trim_space() == '' {
		return error('missing extension id')
	}
	token := load_or_create_token()!
	connect_url := build_extension_connect_url(extension_id.trim_space(), token)
	open_url_in_browser(connect_url)!
	return connect_url
}

// 按平台选择可用的 Chromium 浏览器打开指定 URL。
fn open_url_in_browser(url string) ! {
	$if macos {
		candidates := browser_open_candidates(get_env_with_config('V_BROWSER_BROWSER_APP').trim_space())
		mut last_output := ''
		for app in candidates {
			result := os.execute(build_macos_open_command(app, url))
			if result.exit_code == 0 {
				return
			}
			if result.output.trim_space() != '' {
				last_output = result.output.trim_space()
			}
		}
		mut reason := 'failed to open extension connect page in a Chromium-based browser'
		if last_output != '' {
			reason += ': ${last_output}'
		}
		if get_env_with_config('V_BROWSER_BROWSER_APP').trim_space() == '' {
			reason += '. Set V_BROWSER_BROWSER_APP to an installed browser app name if needed'
		}
		return error(reason)
	}
	$if windows {
		browser_app := get_env_with_config('V_BROWSER_BROWSER_APP').trim_space()
		result := os.execute(build_windows_open_command(url, browser_app))
		if result.exit_code != 0 {
			mut reason := 'failed to open extension connect page'
			if result.output.trim_space() != '' {
				reason += ': ${result.output}'
			}
			if browser_app == '' {
				reason += '. Set V_BROWSER_BROWSER_APP to your browser executable path if the default handler is not a Chromium-based browser'
			}
			return error(reason)
		}
		return
	}
	result := os.execute('xdg-open ${shell_quote(url)}')
	if result.exit_code != 0 {
		return error('failed to open extension connect page: ${result.output}')
	}
}

// 返回 macOS 下尝试打开 URL 的浏览器候选列表。
fn browser_open_candidates(preferred string) []string {
	mut candidates := []string{}
	if preferred != '' {
		candidates << preferred
	}
	for app in ['Google Chrome', 'Microsoft Edge', 'Chromium'] {
		if !candidates.contains(app) {
			candidates << app
		}
	}
	return candidates
}

// 构造 macOS open 命令。
fn build_macos_open_command(app string, url string) string {
	return 'open -a ${shell_quote(app)} ${shell_quote(url)}'
}

// 构造 Windows start 命令。
fn build_windows_open_command(url string, browser_app string) string {
	if browser_app.trim_space() != '' {
		return 'cmd /c start "" ${host_shell_quote(browser_app)} ${host_shell_quote(url)}'
	}
	return 'cmd /c start "" ${host_shell_quote(url)}'
}

// 按宿主 shell 的规则包裹并转义参数。
fn host_shell_quote(value string) string {
	$if windows {
		return '"' + value.replace('"', '""') + '"'
	}
	return shell_quote(value)
}

// 用单引号构造安全的 shell 字符串。
fn shell_quote(value string) string {
	return "'" + value.replace("'", "'\\''") + "'"
}

// 轮询等待扩展和 relay 建立连接。
fn wait_for_extension_connection(timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		status := send_ipc('status', '{}') or {
			time.sleep(500 * time.millisecond)
			continue
		}
		if is_extension_connected(status) {
			return true
		}
		time.sleep(500 * time.millisecond)
	}
	return false
}

// 判断 status 响应里是否已经有扩展连接。
fn is_extension_connected(status string) bool {
	return status.contains('"connected":true')
}

// 默认从标准输入读取 eval 表达式。
fn default_eval_stdin_reader() !string {
	return os.get_raw_lines_joined()
}

// 默认从文件读取 eval 表达式。
fn default_eval_file_reader(path string) !string {
	return os.read_file(path)!
}

// 统一解析 eval 输入来源，兼容 base64、stdin、文件和位置参数。
fn resolve_eval_input(flags map[string]string, positionals []string, stdin_reader EvalStdinReader, file_reader EvalFileReader) (string, bool, string) {
	base64_value := flags['b'] or { flags['base64'] or { 'false' } }
	as_b64 := base64_value != 'false'
	file_path := flags['file'] or { '' }
	stdin_value := flags['stdin'] or { 'false' }
	use_stdin := stdin_value == 'true' || (positionals.len > 0 && positionals[0] == '-')
	if use_stdin {
		expr := stdin_reader() or { return '', as_b64, 'failed to read stdin: ${err.msg()}' }
		return expr.trim_space(), as_b64, ''
	}
	if file_path != '' {
		expr := file_reader(file_path) or {
			return '', as_b64, 'failed to read eval file ${file_path}: ${err.msg()}'
		}
		return expr.trim_space(), as_b64, ''
	}
	expr := if as_b64 {
		base64_value
	} else if positionals.len > 0 {
		positionals[0]
	} else {
		flags['expression'] or { flags['expr'] or { '' } }
	}
	return expr, as_b64, ''
}

// ─── CLI → IPC 参数解析 ──────────────────────────────────────
// 将命令行参数转换为 (method, params_json) 对
// 将 CLI 命令翻译成 IPC method/params。
fn parse_cli_to_ipc(cmd string, args []string, raw_output bool) (string, string) {
	return parse_cli_to_ipc_with_readers(cmd, args, raw_output, default_eval_stdin_reader,
		default_eval_file_reader)
}

// 带可注入输入源的 CLI 转 IPC 版本，便于测试 eval 读取逻辑。
fn parse_cli_to_ipc_with_readers(cmd string, args []string, raw_output bool, stdin_reader EvalStdinReader, file_reader EvalFileReader) (string, string) {
	// 解析标志位
	mut flags := map[string]string{}
	mut positionals := []string{}
	mut i := 0
	for i < args.len {
		arg := args[i]
		if arg.starts_with('--') {
			key := arg[2..]
			if i + 1 < args.len && !args[i + 1].starts_with('--') {
				flags[key] = args[i + 1]
				i += 2
			} else {
				flags[key] = 'true'
				i++
			}
		} else if arg.starts_with('-') && arg.len == 2 {
			key := arg[1..]
			if i + 1 < args.len && !args[i + 1].starts_with('-') {
				flags[key] = args[i + 1]
				i += 2
			} else {
				flags[key] = 'true'
				i++
			}
		} else {
			positionals << arg
			i++
		}
	}

	match cmd {
		// ── 导航 ──
		'open', 'goto', 'navigate' {
			url := flags['url'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'open', '{"url":${json_str(url)}}'
		}
		'close', 'quit', 'exit' {
			return 'close', '{}'
		}
		'back' {
			return 'eval', '{"expression":"history.back()"}'
		}
		'forward' {
			return 'eval', '{"expression":"history.forward()"}'
		}
		'reload', 'refresh' {
			return 'eval', '{"expression":"location.reload()"}'
		}
		// ── 连接 ──
		'connect' {
			tab_id := flags['tab-id'] or { '' }
			window_id := flags['window-id'] or { '' }
			if tab_id != '' {
				return 'connect', '{"tabId":${tab_id},"windowId":${if window_id != '' {
					window_id
				} else {
					'0'
				}}}'
			}
			return 'connect', '{}'
		}
		'status' {
			return 'status', '{}'
		}
		// ── 截图 ──
		'screenshot', 'shot', 'ss' {
			path := flags['path'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			full := flags['full'] or { 'false' }
			fmt := flags['format'] or { 'png' }
			return 'screenshot', '{"path":${json_str(path)},"full":${json_str(full)},"format":${json_str(fmt)}}'
		}
		// ── PDF ──
		'pdf' {
			path := flags['path'] or {
				if positionals.len > 0 { positionals[0] } else { 'output.pdf' }
			}
			return 'pdf', '{"path":${json_str(path)}}'
		}
		// ── 快照 ──
		'snapshot', 'snap', 'ax' {
			raw := if raw_output { 'true' } else { 'false' }
			// extra 是新版开关；interactive 作为旧参数保留兼容。
			extra := flags['extra'] or { flags['interactive'] or { 'false' } }
			interactive := flags['interactive'] or { 'false' }
			// maxNodes 限制最终输出的引用总数，AX Tree 和补全共享同一预算。
			max_nodes := flags['maxNodes'] or { '0' }
			// selector 限制快照范围到指定元素子树。
			sel_filter := flags['selector'] or { flags['sel'] or { '' } }
			if sel_filter != '' {
				return 'snapshot', '{"raw":${raw},"extra":${extra},"interactive":${interactive},"maxNodes":${max_nodes},"selector":${json_str(sel_filter)}}'
			}
			return 'snapshot', '{"raw":${raw},"extra":${extra},"interactive":${interactive},"maxNodes":${max_nodes}}'
		}
		// ── 元素操作 ──
		'click' {
			sel := flags['selector'] or {
				flags['sel'] or {
					if positionals.len > 0 { positionals[0] } else { '' }
				}
			}
			return 'click', '{"selector":${json_str(sel)}}'
		}
		'dblclick', 'doubleclick' {
			sel := flags['selector'] or {
				flags['sel'] or {
					if positionals.len > 0 { positionals[0] } else { '' }
				}
			}
			return 'dblclick', '{"selector":${json_str(sel)}}'
		}
		'download' {
			sel := flags['selector'] or {
				flags['sel'] or {
					if positionals.len > 0 { positionals[0] } else { '' }
				}
			}
			path := flags['path'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			return 'download', '{"selector":${json_str(sel)},"path":${json_str(path)}}'
		}
		'hover' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'hover', '{"selector":${json_str(sel)}}'
		}
		'focus' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'focus', '{"selector":${json_str(sel)}}'
		}
		'fill' {
			sel := flags['selector'] or {
				flags['sel'] or {
					if positionals.len > 0 { positionals[0] } else { '' }
				}
			}
			text := flags['text'] or {
				flags['value'] or {
					if positionals.len > 1 { positionals[1] } else { '' }
				}
			}
			verify := if flags.keys().contains('verify') { 'true' } else { 'false' }
			verify_timeout := flags['verify-timeout'] or { flags['verifyTimeout'] or { '1500' } }
			return 'fill', '{"selector":${json_str(sel)},"text":${json_str(text)},"verify":${json_str(verify)},"verifyTimeout":${verify_timeout}}'
		}
		'type' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			text := flags['text'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			verify := if flags.keys().contains('verify') { 'true' } else { 'false' }
			verify_timeout := flags['verify-timeout'] or { flags['verifyTimeout'] or { '1500' } }
			return 'type', '{"selector":${json_str(sel)},"text":${json_str(text)},"verify":${json_str(verify)},"verifyTimeout":${verify_timeout}}'
		}
		'keyboard' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			text := flags['text'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			return 'keyboard', '{"action":${json_str(action)},"text":${json_str(text)}}'
		}
		'press', 'key' {
			key := flags['key'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'press', '{"key":${json_str(key)}}'
		}
		'select' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			value := flags['value'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			return 'select', '{"selector":${json_str(sel)},"value":${json_str(value)}}'
		}
		'check' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'check', '{"selector":${json_str(sel)}}'
		}
		'uncheck' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'uncheck', '{"selector":${json_str(sel)}}'
		}
		// ── 滚动 ──
		'scroll' {
			dir := flags['direction'] or {
				flags['dir'] or {
					if positionals.len > 0 { positionals[0] } else { 'down' }
				}
			}
			px := flags['px'] or { '300' }
			sel := flags['selector'] or { '' }
			return 'scroll', '{"direction":${json_str(dir)},"px":${px},"selector":${json_str(sel)}}'
		}
		'scrollintoview', 'scrollinto' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'scrollintoview', '{"selector":${json_str(sel)}}'
		}
		// ── 拖拽 ──
		'drag' {
			src := flags['source'] or { flags['from'] or { '' } }
			tgt := flags['target'] or { flags['to'] or { '' } }
			return 'drag', '{"source":${json_str(src)},"target":${json_str(tgt)}}'
		}
		// ── 上传 ──
		'upload' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			files := flags['files'] or {
				if positionals.len > 1 { positionals[1..].join(',') } else { '' }
			}
			verify := if flags.keys().contains('verify') { 'true' } else { 'false' }
			verify_timeout := flags['verify-timeout'] or { flags['verifyTimeout'] or { '1500' } }
			wait_preview := if flags.keys().contains('wait-preview') { 'true' } else { 'false' }
			preview_selector := flags['preview-selector'] or { flags['previewSelector'] or { '' } }
			return 'upload', '{"selector":${json_str(sel)},"files":${json_str(files)},"verify":${json_str(verify)},"verifyTimeout":${verify_timeout},"waitPreview":${json_str(wait_preview)},"previewSelector":${json_str(preview_selector)}}'
		}
		// ── 获取属性 ──
		'get' {
			prop := flags['property'] or {
				flags['prop'] or {
					if positionals.len > 0 { positionals[0] } else { 'text' }
				}
			}
			sel := flags['selector'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			attr := flags['attr'] or { '' }
			return 'get', '{"property":${json_str(prop)},"selector":${json_str(sel)},"attr":${json_str(attr)}}'
		}
		'text' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'get', '{"property":"text","selector":${json_str(sel)}}'
		}
		'html' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'get', '{"property":"html","selector":${json_str(sel)}}'
		}
		'title' {
			return 'get', '{"property":"title","selector":""}'
		}
		'url' {
			return 'get', '{"property":"url","selector":""}'
		}
		// ── 状态检查 ──
		'is' {
			state := flags['state'] or {
				if positionals.len > 0 { positionals[0] } else { 'visible' }
			}
			sel := flags['selector'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			return 'is', '{"state":${json_str(state)},"selector":${json_str(sel)}}'
		}
		// ── 等待 ──
		'wait' {
			download_path := flags['download'] or { flags['d'] or { '' } }
			if download_path != '' || 'download' in flags || 'd' in flags {
				timeout := flags['timeout'] or { '30000' }
				resolved_download_path := if download_path == 'true' { '' } else { download_path }
				return 'wait', '{"download":${json_str(resolved_download_path)},"timeout":${timeout}}'
			}
			if positionals.len > 0 {
				arg := positionals[0]
				// 纯数字 → ms
				if arg.int() > 0 {
					return 'wait', '{"ms":${arg}}'
				}
				// 选择器
				return 'wait', '{"selector":${json_str(arg)}}'
			}
			if load := flags['load'] {
				return 'wait', '{"load":${json_str(load)}}'
			}
			if url_p := flags['url'] {
				return 'wait', '{"url":${json_str(url_p)}}'
			}
			if text := flags['text'] {
				return 'wait', '{"text":${json_str(text)}}'
			}
			if fn_e := flags['fn'] {
				return 'wait', '{"fn":${json_str(fn_e)}}'
			}
			if stable := flags['stable'] {
				timeout := flags['timeout'] or { '30000' }
				return 'wait', '{"stable":${json_str(stable)},"timeout":${timeout}}'
			}
			return 'wait', '{"ms":"1000"}'
		}
		// ── find（语义定位器）──
		'find' {
			loc_key := if flags.keys().contains('role') {
				'role'
			} else if flags.keys().contains('text') {
				'text'
			} else if flags.keys().contains('label') {
				'label'
			} else if flags.keys().contains('placeholder') {
				'placeholder'
			} else if flags.keys().contains('alt') {
				'alt'
			} else if flags.keys().contains('title') {
				'title'
			} else if flags.keys().contains('testid') {
				'testid'
			} else if flags.keys().contains('first') {
				'first'
			} else if flags.keys().contains('last') {
				'last'
			} else if flags.keys().contains('nth') {
				'nth'
			} else if positionals.len > 0 {
				positionals[0]
			} else {
				''
			}
			mut query := flags[loc_key] or { '' }
			mut index := flags['index'] or { '' }
			debug_mode := if flags.keys().contains('debug') { 'true' } else { 'false' }
			list_mode := if flags.keys().contains('list') { 'true' } else { 'false' }
			mut action_pos := 1
			if query == '' && positionals.len > 1 {
				match loc_key {
					'nth' {
						index = positionals[1]
						if positionals.len > 2 {
							query = positionals[2]
						}
						action_pos = 3
					}
					'role', 'text', 'label', 'placeholder', 'alt', 'title', 'testid', 'first',
					'last' {
						query = positionals[1]
						action_pos = 2
					}
					else {}
				}
			}
			action := if flags.keys().contains('click') {
				'click'
			} else if flags.keys().contains('fill') {
				'fill'
			} else if flags.keys().contains('type') {
				'type'
			} else if flags.keys().contains('hover') {
				'hover'
			} else if flags.keys().contains('focus') {
				'focus'
			} else if flags.keys().contains('check') {
				'check'
			} else if flags.keys().contains('uncheck') {
				'uncheck'
			} else if flags.keys().contains('text') && loc_key != 'text' {
				'text'
			} else {
				flags['action'] or {
					if positionals.len > action_pos { positionals[action_pos] } else { 'click' }
				}
			}
			value := flags['value'] or {
				if positionals.len > action_pos + 1 { positionals[action_pos + 1] } else { '' }
			}
			exact := if flags.keys().contains('exact') { 'true' } else { 'false' }
			name_filter := flags['name'] or { '' }
			return 'find', '{"locator":${json_str(loc_key)},"query":${json_str(query)},"action":${json_str(action)},"value":${json_str(value)},"exact":${json_str(exact)},"name":${json_str(name_filter)},"index":${json_str(index)},"debug":${json_str(debug_mode)},"list":${json_str(list_mode)}}'
		}
		// ── eval ──
		'eval', 'js', 'execute', 'run' {
			expr, as_b64, read_error := resolve_eval_input(flags, positionals, stdin_reader,
				file_reader)
			await_p := flags['await'] or { 'false' }
			return 'eval', '{"expression":${json_str(expr)},"awaitPromise":${json_str(await_p)},"base64":${json_str(if as_b64 {
				'true'
			} else {
				'false'
			})},"readError":${json_str(read_error)}}'
		}
		// ── tab ──
		'tab' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'list' }
			}
			match action {
				'new' {
					url := flags['url'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					return 'tab', '{"action":"new","url":${json_str(url)}}'
				}
				'switch' {
					tab_id := flags['id'] or {
						flags['tab-id'] or {
							if positionals.len > 1 { positionals[1] } else { '' }
						}
					}
					window_id := flags['window-id'] or { '' }
					return 'tab', '{"action":"switch","tabId":${if tab_id != '' {
						tab_id
					} else {
						'0'
					}},"windowId":${if window_id != '' {
						window_id
					} else {
						'0'
					}}}'
				}
				'close' {
					tid := flags['id'] or {
						flags['tab-id'] or {
							if positionals.len > 1 { positionals[1] } else { '' }
						}
					}
					return 'tab', '{"action":"close","tabId":${if tid != '' {
						tid
					} else {
						'0'
					}}}'
				}
				else {
					return 'tab', '{"action":"list"}'
				}
			}
		}
		'window' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'new' }
			}
			url := flags['url'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			return 'window', '{"action":${json_str(action)},"url":${json_str(url)}}'
		}
		// ── mouse ──
		'mouse' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			x := flags['x'] or {
				if positionals.len > 1 { positionals[1] } else { '0' }
			}
			y := flags['y'] or {
				if positionals.len > 2 { positionals[2] } else { '0' }
			}
			btn := flags['button'] or { 'left' }
			dx := flags['dx'] or { '0' }
			dy := flags['dy'] or { '0' }
			return 'mouse', '{"action":${json_str(action)},"x":${x},"y":${y},"button":${json_str(btn)},"dx":${dx},"dy":${dy}}'
		}
		// ── cookies ──
		'cookies', 'cookie' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'get' }
			}
			name := flags['name'] or { '' }
			value := flags['value'] or { '' }
			domain := flags['domain'] or { '' }
			return 'cookies', '{"action":${json_str(action)},"name":${json_str(name)},"value":${json_str(value)},"domain":${json_str(domain)}}'
		}
		// ── storage ──
		'storage', 'localstorage', 'sessionstorage' {
			storage_type := if cmd == 'sessionstorage' {
				'session'
			} else {
				flags['type'] or { 'local' }
			}
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'get' }
			}
			key := flags['key'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			value := flags['value'] or {
				if positionals.len > 2 { positionals[2] } else { '' }
			}
			return 'storage', '{"type":${json_str(storage_type)},"action":${json_str(action)},"key":${json_str(key)},"value":${json_str(value)}}'
		}
		// ── network ──
		'network' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'requests' }
			}
			url := flags['url'] or { '' }
			abort := flags['abort'] or { 'false' }
			body := flags['body'] or { '' }
			filter := flags['filter'] or { '' }
			mut limit := flags['limit'] or { '' }
			mut subaction := flags['subaction'] or { '' }
			mut path := flags['path'] or {
				if positionals.len > 2 { positionals[2] } else { '' }
			}
			mut request_id := flags['request-id'] or { '' }
			mut record_id := flags['record-id'] or { '' }
			method_override := flags['method'] or { '' }
			url_override := flags['override-url'] or { flags['url-override'] or { '' } }
			body_override := flags['override-body'] or { flags['body-override'] or { '' } }
			headers_override := flags['override-headers'] or { flags['headers-override'] or { '' } }
			dry_run := flags['dry-run'] or { flags['dryRun'] or { 'false' } }
			capture_body := flags['capture-body'] or { flags['captureBody'] or { 'false' } }
			capture_response := flags['capture-response'] or {
				flags['captureResponse'] or { 'false' }
			}
			persistent := flags['persistent'] or { 'true' }
			clear := flags['clear'] or { 'true' }
			script_id := flags['script-id'] or { flags['scriptId'] or { '' } }
			mut max_body_len := flags['max-body-len'] or { flags['maxBodyLen'] or { '' } }
			mime := flags['mime'] or { '' }
			status_filter := flags['status'] or { '' }
			domain := flags['domain'] or { '' }
			rtype := flags['type'] or { '' }
			all_frames := flags['all-frames'] or { flags['allFrames'] or { 'false' } }
			// 支持 network body/headers <requestId> 语法
			if action == 'body' && request_id == '' && positionals.len > 1 {
				request_id = positionals[1]
			}
			if action == 'headers' && request_id == '' && positionals.len > 1 {
				request_id = positionals[1]
			}
			if action == 'save' && request_id == '' && positionals.len > 1 {
				request_id = positionals[1]
			}
			if action == 'save-images' && path == '' && positionals.len > 1 {
				path = positionals[1]
			}
			if action == 'watch' {
				if subaction == '' && positionals.len > 1 {
					subaction = positionals[1]
				}
				if subaction == '' && path != '' {
					subaction = 'start'
				}
				if subaction == '' {
					subaction = 'status'
				}
				if subaction == 'start' && path == '' && positionals.len > 2 {
					path = positionals[2]
				}
			}
			if action == 'hook' {
				if subaction == '' && positionals.len > 1 {
					subaction = positionals[1]
				}
				if subaction == '' {
					subaction = 'start'
				}
				if subaction == 'replay' && record_id == '' && positionals.len > 2 {
					record_id = positionals[2]
				}
				if subaction == 'replay' && record_id == '' {
					record_id = request_id
				}
			}
			if max_body_len == '' {
				max_body_len = if action == 'hook' && subaction == 'start' { '4000' } else { '0' }
			}
			if action == 'inspect' && limit == '' && positionals.len > 1 {
				limit = positionals[1]
			}
			return 'network', '{"action":${json_str(action)},"subaction":${json_str(subaction)},"url":${json_str(url)},"abort":${json_str(abort)},"body":${json_str(body)},"filter":${json_str(filter)},"limit":${json_str(limit)},"requestId":${json_str(request_id)},"recordId":${json_str(record_id)},"method":${json_str(method_override)},"overrideUrl":${json_str(url_override)},"overrideBody":${json_str(body_override)},"overrideHeaders":${json_str(headers_override)},"dryRun":${json_str(dry_run)},"captureBody":${json_str(capture_body)},"captureResponse":${json_str(capture_response)},"persistent":${json_str(persistent)},"clear":${json_str(clear)},"scriptId":${json_str(script_id)},"maxBodyLen":${json_str(max_body_len)},"mime":${json_str(mime)},"status":${json_str(status_filter)},"domain":${json_str(domain)},"type":${json_str(rtype)},"allFrames":${json_str(all_frames)},"path":${json_str(path)}}'
		}
		// ── frame ──
		'frame' {
			selector := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { 'main' }
			}
			return 'frame', '{"selector":${json_str(selector)}}'
		}
		// ── dialog ──
		'dialog' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'accept' }
			}
			text := flags['text'] or { '' }
			return 'dialog', '{"action":${json_str(action)},"text":${json_str(text)}}'
		}
		// ── highlight ──
		'highlight' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			return 'highlight', '{"selector":${json_str(sel)}}'
		}
		// ── console / errors ──
		'console' {
			action := flags['action'] or { '' }
			return 'console', '{"action":${json_str(action)}}'
		}
		'errors' {
			action := flags['action'] or { '' }
			return 'errors', '{"action":${json_str(action)}}'
		}
		// ── trace ──
		'trace' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'start' }
			}
			path := flags['path'] or { '' }
			return 'trace', '{"action":${json_str(action)},"path":${json_str(path)}}'
		}
		// ── profiler ──
		'profiler', 'profile' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'start' }
			}
			path := flags['path'] or { '' }
			return 'profiler', '{"action":${json_str(action)},"path":${json_str(path)}}'
		}
		// ── set ──
		'set' {
			prop := flags['property'] or {
				flags['prop'] or {
					if positionals.len > 0 { positionals[0] } else { '' }
				}
			}
			match prop {
				'viewport' {
					w := flags['width'] or {
						if positionals.len > 1 { positionals[1] } else { '1280' }
					}
					h := flags['height'] or {
						if positionals.len > 2 { positionals[2] } else { '800' }
					}
					scale := flags['scale'] or {
						if positionals.len > 3 { positionals[3] } else { '1' }
					}
					return 'set', '{"property":"viewport","width":${w},"height":${h},"scale":${scale}}'
				}
				'device' {
					value := flags['value'] or {
						if positionals.len > 1 { positionals[1..].join(' ') } else { '' }
					}
					return 'set', '{"property":"device","value":${json_str(value)}}'
				}
				'geo', 'geolocation' {
					lat := flags['lat'] or {
						if positionals.len > 1 { positionals[1] } else { '0' }
					}
					lng := flags['lng'] or {
						flags['lon'] or {
							if positionals.len > 2 { positionals[2] } else { '0' }
						}
					}
					return 'set', '{"property":"geo","lat":${lat},"lng":${lng}}'
				}
				'offline' {
					value := flags['value'] or { 'on' }
					return 'set', '{"property":"offline","value":${json_str(value)}}'
				}
				'headers' {
					headers := flags['headers'] or { '{}' }
					return 'set', '{"property":"headers","headers":${headers}}'
				}
				'credentials' {
					user := flags['username'] or { flags['user'] or { '' } }
					pass := flags['password'] or { flags['pass'] or { '' } }
					return 'set', '{"property":"credentials","username":${json_str(user)},"password":${json_str(pass)}}'
				}
				'media', 'color-scheme' {
					value := flags['value'] or { 'dark' }
					return 'set', '{"property":"media","value":${json_str(value)}}'
				}
				else {
					return 'set', '{"property":${json_str(prop)}}'
				}
			}
		}
		// ── diff ──
		'diff' {
			dtype := flags['type'] or {
				if positionals.len > 0 { positionals[0] } else { 'snapshot' }
			}
			match dtype {
				'screenshot' {
					baseline := flags['baseline'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					output := flags['output'] or { flags['o'] or { '' } }
					threshold := flags['threshold'] or { flags['t'] or { '0.1' } }
					selector := flags['selector'] or { flags['s'] or { '' } }
					full := flags['full'] or { 'false' }
					return 'diff', '{"type":"screenshot","baseline":${json_str(baseline)},"output":${json_str(output)},"threshold":${threshold},"selector":${json_str(selector)},"full":${json_str(full)}}'
				}
				'url' {
					url1 := flags['url1'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					url2 := flags['url2'] or {
						if positionals.len > 2 { positionals[2] } else { '' }
					}
					screenshot := flags['screenshot'] or { 'false' }
					full := flags['full'] or { 'false' }
					wait_until := flags['wait-until'] or { 'load' }
					selector := flags['selector'] or { flags['s'] or { '' } }
					compact := flags['compact'] or { 'false' }
					max_depth := flags['depth'] or { flags['d'] or { '0' } }
					return 'diff', '{"type":"url","url1":${json_str(url1)},"url2":${json_str(url2)},"screenshot":${json_str(screenshot)},"full":${json_str(full)},"waitUntil":${json_str(wait_until)},"selector":${json_str(selector)},"compact":${json_str(compact)},"maxDepth":${max_depth}}'
				}
				else {
					baseline := flags['baseline'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					selector := flags['selector'] or { flags['s'] or { '' } }
					compact := flags['compact'] or { 'false' }
					max_depth := flags['depth'] or { flags['d'] or { '0' } }
					return 'diff', '{"type":${json_str(dtype)},"baseline":${json_str(baseline)},"selector":${json_str(selector)},"compact":${json_str(compact)},"maxDepth":${max_depth}}'
				}
			}
		}
		// ── clipboard ──
		'clipboard' {
			subcmd := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			kind := flags['kind'] or {
				if positionals.len > 1 { positionals[1] } else { 'image' }
			}
			path := flags['path'] or {
				flags['p'] or {
					if positionals.len > 2 { positionals[2] } else { '' }
				}
			}
			return 'clipboard', '{"action":${json_str(subcmd)},"kind":${json_str(kind)},"path":${json_str(path)}}'
		}
		// ── state ──
		'state' {
			action := flags['action'] or {
				if positionals.len > 0 { positionals[0] } else { 'list' }
			}
			path := flags['path'] or {
				flags['name'] or {
					if positionals.len > 1 { positionals[1] } else { '' }
				}
			}
			new_path := flags['newPath'] or { flags['new'] or { '' } }
			return 'state', '{"action":${json_str(action)},"path":${json_str(path)},"newPath":${json_str(new_path)}}'
		}
		// ── 快捷方式 ──
		'help', '-h', '--help' {
			print_usage()
			exit(0)
			return '', ''
		}
		'version', '-v', '--version' {
			println('v-browser ${v_browser_version}')
			exit(0)
			return '', ''
		}
		else {
			// 未知命令直接透传到 dispatch_command
			// 构造最简 params：把所有 positionals 和 flags 塞进去
			mut p := '{"_cmd":${json_str(cmd)}'
			for k, v in flags {
				p += ',"${k}":${json_str(v)}'
			}
			for j, pos in positionals {
				p += ',"arg${j}":${json_str(pos)}'
			}
			p += '}'
			return cmd, p
		}
	}
}

// ─── IPC 客户端 ──────────────────────────────────────────────
fn send_ipc(method string, params string) !string {
	return send_ipc_internal(method, params, true)
}

fn send_ipc_without_start(method string, params string) !string {
	return send_ipc_internal(method, params, false)
}

fn send_ipc_internal(method string, params string, auto_start bool) !string {
	if auto_start {
		ensure_server_running()!
	} else if !can_reach_ipc_server() {
		return error('v-browser server is not running. Start it with: v-browser server')
	}
	// 读取 server port
	port_str := os.read_file(ipc_sock_path()) or {
		return error('v-browser server is not running. Start it with: v-browser server')
	}
	port := port_str.trim_space().int()
	if port == 0 {
		return error('invalid port in ${ipc_sock_path()}')
	}

	// 连接 IPC
	mut conn := net.dial_tcp('127.0.0.1:${port}') or {
		return error('cannot connect to v-browser server on port ${port}: ${err}')
	}
	defer { conn.close() or {} }
	conn.set_read_timeout(180 * time.second)

	// 发送请求
	req := IpcRequest{
		id:     1
		method: method
		params: params
	}
	conn.write_string(ipc_encode_request(req)) or { return error('send failed: ${err}') }

	// 读取响应
	mut buf := []u8{len: 65536}
	mut raw := ''
	for {
		n := conn.read(mut buf) or { break }
		if n == 0 {
			break
		}
		raw += buf[..n].bytestr()
		if raw.contains('\n') {
			break
		}
	}

	resp := ipc_decode_response(raw.trim_space()) or { return error('parse response: ${err}') }
	if resp.err != '' {
		return error(resp.err)
	}
	// 美化输出：去除外层引号（如果是字符串 JSON）
	result := resp.result
	if result.starts_with('"') && result.ends_with('"') {
		return result[1..result.len - 1].replace('\\"', '"').replace('\\n', '\n').replace('\\\\',
			'\\')
	}
	return result
}
