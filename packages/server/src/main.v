// main.v — v-browser CLI 入口
// 用法:
//   v-browser server          — 启动中继服务（前台）
//   v-browser server bg       — 后台独立进程启动中继服务，不占用当前 shell
//   v-browser server stop     — 停止中继服务
//   v-browser server restart  — 重启中继服务
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
import os.filelock
import io
import net
import net.urllib
import time
import math
import x.json2 as json
import strconv

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
					restart_server_daemon() or {
						print_error('failed to restart server: ${err}', json_output)
						exit(1)
					}
					eprintln('[v-browser] Server restarted.')
					return
				}
				'bg', 'start' {
					handle_server_start(json_output) or {
						print_error(err.msg(), json_output)
						exit(1)
					}
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
	method, params := parse_cli_to_ipc_checked(cmd, rest, raw_output) or {
		print_error(err.msg(), json_output)
		exit(1)
	}
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
	_, checked := parse_cli_to_ipc_checked('connect', args, false) or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	ids := json.decode[map[string]json.Any](checked) or { panic(err) }
	tab_id := (ids['tabId'] or { json.Any(0) }).int()
	window_id := (ids['windowId'] or { json.Any(0) }).int()
	target_url := extract_connect_target_url(args)
	extension_id := resolve_extension_id(args)
	status_before := send_ipc('status', '{}') or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	if !is_extension_connected(status_before) {
		if extension_id != '' {
			// connect_url 里带 ?token=<真实 token>，属于凭据，绝不能打印到 stderr。
			_ := open_extension_connect_page(extension_id) or {
				print_error(err.msg(), json_output)
				exit(1)
				return
			}
			eprintln('[v-browser] Opened extension connect page.')
			if !wait_for_extension_connection(35 * time.second) {
				print_error('extension did not connect within 35s; select a tab in the extension page, then run v-browser connect again',
					json_output)
				exit(1)
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
			// 同上：返回值含 token，只消费不打印。
			_ := open_extension_connect_page(extension_id)!
			eprintln('[v-browser] Reconnecting via extension page.')
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
	lck := acquire_lifecycle_lock(lifecycle_lock_timeout_seconds * time.second)!
	defer {
		release_lifecycle_lock(lck)
	}
	// 锁内重新检查：并发的另一个 CLI 可能已经把 server 拉起来了。
	if can_reach_ipc_server() {
		if server_runtime_version_matches() {
			return
		}
		eprintln('[v-browser] Detected stale server version; restarting...')
		restart_server_daemon_locked()!
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
	// Windows 不走 pueue：它依赖常驻的 pueued 守护进程，且在 Windows 上经 PowerShell
	// 执行任务、引号规则与 POSIX 不一致，历史上多次导致 server 根本拉不起来；
	// 守护进程一旦退出，pueue 客户端还会阻塞在重连上，让 CLI 整个卡死。
	$if windows {
		start_server_detached_windows(executable)!
		return
	}
	result := os.execute(build_pueue_add_command(executable))
	if result.exit_code != 0 {
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

// 分离启动 server 守护进程（Windows），不依赖 pueue 守护进程。
fn start_server_detached_windows(executable string) ! {
	// 必须用 os.Process 而非 os.execute：os.execute 会一直读取管道直到 EOF，而 V 在
	// Windows 上以 bInheritHandles=TRUE 创建子进程，管道句柄会被 server 继承，
	// server 又永不退出，于是 CLI 永久挂死（无论中间是否套了 cmd / PowerShell）。
	// os.Process 的 run() 只负责启动、不等待，正好用来拉起常驻进程。
	mut p := os.new_process(executable)
	p.set_args(['server'])
	p.set_work_folder(os.dir(executable))
	p.create_no_window = true
	p.run()
	if p.status != .running && p.status != .not_started {
		return error('failed to start v-browser server: ${p.err}')
	}
	// 未经过 pueue，没有任务号可记；留空表示“无 pueue 任务”。
	os.write_file(server_task_path(), '') or {}
}

// 停止旧 server 并重新拉起当前版本的 daemon。
fn restart_server_daemon() ! {
	lck := acquire_lifecycle_lock(lifecycle_lock_timeout_seconds * time.second)!
	defer {
		release_lifecycle_lock(lck)
	}
	restart_server_daemon_locked()!
}

// 已在持有生命周期锁的前提下执行重启。
fn restart_server_daemon_locked() ! {
	_ := stop_server_locked(false, true, false) or {
		return error('failed to stop stale v-browser server: ${err.msg()}')
	}
	start_server_daemon()!
	wait_for_server_ready()!
}

// 构造 pueue 任务命令，并保留当前可执行文件所在目录。仅用于 Unix：Windows 走
// start_server_detached_windows，不经过 pueue。
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
// 整个过程由生命周期锁保护，避免并发的 start/stop/restart 互相踩踏。
fn handle_server_stop(json_output bool, allow_missing bool, emit_output bool) !bool {
	lck := acquire_lifecycle_lock(lifecycle_lock_timeout_seconds * time.second)!
	defer {
		release_lifecycle_lock(lck)
	}
	return stop_server_locked(json_output, allow_missing, emit_output)
}

// 已在持有生命周期锁的前提下执行停止。
fn stop_server_locked(json_output bool, allow_missing bool, emit_output bool) !bool {
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

	// 端口兜底：只能终止确认为 v-browser 的进程，别人的进程一律不碰。
	killed, port_conflicts := kill_server_by_ports()
	if killed && wait_for_server_shutdown(0, 5 * time.second) {
		cleanup_server_runtime_state()
		if emit_output {
			report_server_stop('server killed', json_output)
		}
		return true
	}
	if port_conflicts.len > 0 {
		return error('port conflict: ${port_conflicts.join('; ')}')
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
	// server_task_path() 里存的是 pueue 的 stdout，属于外部数据。
	// 只有能严格解析成正整数（pueue task id 从 1 开始）时才允许拼进 shell，
	// 否则宁可漏清理，也不能把它当命令执行。
	task_id := (os.read_file(server_task_path()) or { '' }).trim_space()
	if task_id != '' {
		if parsed := strconv.atoi(task_id) {
			if parsed > 0 {
				os.execute('pueue remove ${parsed}')
			} else {
				eprintln('[v-browser] Skipping pueue cleanup: recorded task id is not positive.')
			}
		} else {
			eprintln('[v-browser] Skipping pueue cleanup: recorded task id is not an integer.')
		}
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
// 只终止可执行文件确认为 v-browser 的进程；无法确认身份时返回端口冲突，
// 绝不误杀占用同一端口的客户端进程。
fn kill_server_by_ports() (bool, []string) {
	$if windows {
		return false, []string{}
	} $else {
		mut killed := false
		mut conflicts := []string{}
		for port in [configured_relay_port(), configured_ipc_port()] {
			for pid in listening_pids_on_port(port) {
				if is_v_browser_server_process(pid) {
					if terminate_process(pid) {
						killed = true
					}
				} else {
					conflicts << 'port ${port} is held by pid ${pid}, which is not a v-browser process'
				}
			}
		}
		return killed, conflicts
	}
}

// 列出在指定端口处于 LISTEN 状态的进程 pid。
// 只看 LISTEN，避免把连上来的客户端也列进去。
fn listening_pids_on_port(port int) []int {
	if port <= 0 {
		return []int{}
	}
	result := os.execute('lsof -nP -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null')
	if result.exit_code != 0 {
		return []int{}
	}
	mut pids := []int{}
	for line in result.output.split_into_lines() {
		pid := line.trim_space().int()
		if pid > 0 && !(pid in pids) {
			pids << pid
		}
	}
	return pids
}

// 确认 pid 对应的可执行文件是 v-browser，避免误杀占用同一端口的其它程序。
fn is_v_browser_server_process(pid int) bool {
	if pid <= 0 {
		return false
	}
	executable := process_executable_path(pid)
	if executable == '' {
		return false
	}
	name := os.file_name(executable)
	// 同一路径允许测试/自定义构建名；不能仅凭 v-browser 前缀认定身份。
	return name == 'v-browser' || name == 'v-browser.exe'
		|| os.real_path(executable) == os.real_path(os.executable())
}

// 读取进程可执行文件路径：ps 在 Linux/macOS 上都能拿到可执行文件名或全路径。
fn process_executable_path(pid int) string {
	result := os.execute('ps -p ${pid} -o comm= 2>/dev/null')
	if result.exit_code != 0 {
		return ''
	}
	return result.output.trim_space()
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
// 后台拉起 server：已在运行则直接返回，版本过旧则先停再拉，命令本身立即退出，
// 不占用调用方 shell（Windows 用分离进程，Unix 用 pueue，无 pueue 时回退 nohup）。
// 整个过程由生命周期锁保护：并发的 `server bg` 不会各自拉起一个 server，
// 导致 pid 文件与真正监听端口的进程对不上。
fn handle_server_start(json_output bool) ! {
	lck := acquire_lifecycle_lock(lifecycle_lock_timeout_seconds * time.second)!
	defer {
		release_lifecycle_lock(lck)
	}
	// 锁内重新检查状态：等锁期间可能已经有别的进程把 server 拉起来了。
	if can_reach_ipc_server() {
		if server_runtime_version_matches() {
			report_server_start('server already running', json_output)
			return
		}
		restart_server_daemon_locked()!
		report_server_start('server started in background', json_output)
		return
	}
	start_server_daemon()!
	wait_for_server_ready()!
	report_server_start('server started in background', json_output)
}

// ─── 生命周期锁 ──────────────────────────────────────────────
const lifecycle_lock_timeout_seconds = 30

fn lifecycle_lock_path() string {
	return os.join_path(v_browser_home_dir(), '.v-browser', 'server.lifecycle.lock')
}

fn acquire_lifecycle_lock(timeout time.Duration) !filelock.FileLock {
	path := lifecycle_lock_path()
	os.mkdir_all(os.dir(path)) or {
		// 首次并发启动时，另一个 CLI 可能刚好创建了状态目录。
		if !os.is_dir(os.dir(path)) {
			return err
		}
	}
	// 保留同一个 inode，不能在释放后删文件，否则等待者可能锁住旧文件。
	mut file := os.open_append(path)!
	file.close()
	mut lck := filelock.new_file(path, mode: .exclusive)
	if !lck.wait_acquire(timeout) {
		return error('timed out waiting for the v-browser server lock (${path})')
	}
	// 内核在进程退出（包括崩溃）时释放锁，无需有竞争风险的 stale 目录删除。
	return lck
}

fn release_lifecycle_lock(lck filelock.FileLock) {
	mut owned := lck
	owned.release()
}

// 按 JSON 或普通文本输出 server 后台启动结果。
fn report_server_start(message string, json_output bool) {
	if json_output {
		println('{"ok":true,"result":${json_str(message)}}')
	} else {
		eprintln('[v-browser] ${message} (pid ${read_server_pid()}).')
	}
}

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
// 布尔开关名：这些选项自身不携带值，只有显式写出 true / false 时才把下一个
// 参数当成它的值；其余情况一律记为 'true' 且**不消费**后一个参数。
// 否则 `eval --await <expr>`、`screenshot --full shot.png`、`eval --stdin -b`
// 这类命令会把紧随其后的位置参数吞掉。
// 注意：--base64 / -b 与 --raw / -r 不在此列 —— base64 的值就是待执行的脚本，
// 必须作为值消费（见 resolve_eval_input）；raw/r 在 main() 全局预处理里已被剥掉。
const boolean_switch_names = [
	'full',
	'extra',
	'interactive',
	'raw',
	'raw-output',
	'await',
	'stdin',
	'verify',
	'wait-preview',
	'capture-body',
	'captureBody',
	'capture-response',
	'captureResponse',
	'all-frames',
	'allFrames',
	'dry-run',
	'dryRun',
	'debug',
	'list',
	'click',
	'screenshot',
	'abort',
	// 注意：'stable' 不在此列 —— `wait --stable <selector>` 的选择器是它的值，
	// 必须被消费掉，否则选择器会掉进位置参数，退化成普通选择器等待。
	'compact',
	'persistent',
	'clear',
	'exact',
]

// 数值型选项名：取值必须是数字，允许负值（例如 --lat -33.8）。
const numeric_option_names = [
	'px',
	'x',
	'y',
	'dx',
	'dy',
	'lat',
	'lng',
	'lon',
	'width',
	'height',
	'scale',
	'timeout',
	'verify-timeout',
	'verifyTimeout',
	'maxNodes',
	'max-nodes',
	'ms',
	'limit',
	'index',
	'depth',
	'max-body-len',
	'maxBodyLen',
	'threshold',
	'tab-id',
	'tabId',
	'window-id',
	'windowId',
	'id',
	'quality',
	'maxLabels',
]

// 判断某个选项在当前命令下是否按数值处理。
fn is_numeric_option(cmd string, key string) bool {
	if key in numeric_option_names {
		return true
	}
	// -d/-t 只在 diff 里表示 depth/threshold，其它命令里含义不同。
	return cmd == 'diff' && (key == 'd' || key == 't')
}

// 判断某个选项名是否属于布尔开关。
fn is_boolean_switch(name string) bool {
	return name in boolean_switch_names
}

// 决定选项要不要吃掉后一个参数。布尔开关只接受显式的 true/false，
// 这样位置参数不会被开关意外吞掉；数值型选项额外允许负数，
// 否则 --lat -33.8 里的负号会被当成一个新选项。
fn should_consume_flag_value(cmd string, key string, next string, has_next bool) bool {
	if !has_next {
		return false
	}
	if is_boolean_switch(key) {
		return next == 'true' || next == 'false'
	}
	if next.starts_with('-') {
		// 只有数值型选项才消费以 '-' 开头的值，避免把 --foo -1 里的 -1 误当成选项。
		return is_numeric_option(cmd, key) && looks_like_number(next)
	}
	return true
}

// 判断字符串是否是合法数字字面量（用于识别负数参数）。
fn looks_like_number(raw string) bool {
	cli_parse_float(raw) or { return false }
	return true
}

// 严格解析十进制整数：只接受可选正负号与数字，拒绝空串、非数字与溢出。
fn cli_parse_int(raw string) !int {
	s := raw.trim_space()
	if s == '' {
		return error('value is empty')
	}
	mut start := 0
	if s[0] == `+` || s[0] == `-` {
		start = 1
	}
	if start >= s.len {
		return error('not a valid integer')
	}
	for i in start .. s.len {
		if s[i] < `0` || s[i] > `9` {
			return error('not a valid integer')
		}
	}
	return strconv.atoi(s) or { return error('integer out of range') }
}

// 严格解析十进制小数：拒绝 inf/nan/指数等 strconv 会接受的非数字形式。
fn cli_parse_float(raw string) !f64 {
	s := raw.trim_space()
	if s == '' {
		return error('value is empty')
	}
	mut start := 0
	if s[0] == `+` || s[0] == `-` {
		start = 1
	}
	mut int_digits := 0
	mut frac_digits := 0
	mut has_dot := false
	for i in start .. s.len {
		c := s[i]
		if c >= `0` && c <= `9` {
			if has_dot {
				frac_digits++
			} else {
				int_digits++
			}
			continue
		}
		if c == `.` && !has_dot {
			has_dot = true
			continue
		}
		return error('not a valid number')
	}
	if int_digits == 0 || (has_dot && frac_digits == 0) {
		return error('not a valid number')
	}
	value := strconv.atof64(s) or { return error('number out of range') }
	if math.is_nan(value) || math.is_inf(value, 0) {
		return error('number out of range')
	}
	return value
}

// 严格解析布尔值：只接受 true / false。
fn cli_parse_bool(raw string) !bool {
	s := raw.trim_space()
	if s == 'true' {
		return true
	}
	if s == 'false' {
		return false
	}
	return error('not a valid boolean')
}

// 解析整数型参数并检查取值范围。
fn cli_int_arg(raw string, name string, min int, max int) !int {
	value := cli_parse_int(raw) or { return error('invalid value for ${name}: ${raw}') }
	if value < min || value > max {
		return error('value for ${name} is out of range: ${raw}')
	}
	return value
}

// 解析浮点型参数并检查取值范围。
fn cli_float_arg(raw string, name string, min f64, max f64) !f64 {
	value := cli_parse_float(raw) or { return error('invalid value for ${name}: ${raw}') }
	if value < min || value > max {
		return error('value for ${name} is out of range: ${raw}')
	}
	return value
}

// 解析布尔型参数，返回 "true"/"false" 文本。
fn cli_bool_text(raw string, name string) !string {
	value := cli_parse_bool(raw) or {
		return error('invalid value for ${name}: ${raw} (expected true or false)')
	}
	return if value { 'true' } else { 'false' }
}

// 数值文本：整数值的浮点数按整数输出，避免 0.0 这类文本影响服务端解析。
fn cli_number_text(value f64) string {
	if math.abs(value) < 1e15 && math.trunc(value) == value {
		return i64(value).str()
	}
	return value.str()
}

// 解析 JSON 对象参数：先解析再重新编码，禁止原始字符串直接进入行协议。
fn cli_json_object_arg(raw string, name string) !string {
	trimmed := raw.trim_space()
	if !trimmed.starts_with('{') || !trimmed.ends_with('}') {
		return error('invalid value for ${name}: expected a JSON object')
	}
	parsed := json.decode[map[string]json.Any](trimmed) or {
		return error('invalid value for ${name}: expected a JSON object')
	}
	return json.encode(parsed)
}

// 将 CLI 命令翻译成 IPC method/params。
// 兼容入口：参数非法时返回空的 method 与错误说明，调用方需自行判断。
fn parse_cli_to_ipc(cmd string, args []string, raw_output bool) (string, string) {
	return parse_cli_to_ipc_checked(cmd, args, raw_output) or { return '', err.msg() }
}

// 带可注入输入源的 CLI 转 IPC 版本，便于测试 eval 读取逻辑。
fn parse_cli_to_ipc_with_readers(cmd string, args []string, raw_output bool, stdin_reader EvalStdinReader, file_reader EvalFileReader) (string, string) {
	return parse_cli_to_ipc_checked_with_readers(cmd, args, raw_output, stdin_reader,
		file_reader) or { return '', err.msg() }
}

// 将 CLI 命令翻译成 IPC method/params，参数非法时返回错误。
fn parse_cli_to_ipc_checked(cmd string, args []string, raw_output bool) !(string, string) {
	return parse_cli_to_ipc_checked_with_readers(cmd, args, raw_output,
		default_eval_stdin_reader, default_eval_file_reader)
}

// 带可注入输入源的 CLI 转 IPC 版本，参数非法时返回错误。
fn parse_cli_to_ipc_checked_with_readers(cmd string, args []string, raw_output bool, stdin_reader EvalStdinReader, file_reader EvalFileReader) !(string, string) {
	// 解析标志位
	mut flags := map[string]string{}
	mut positionals := []string{}
	mut i := 0
	for i < args.len {
		arg := args[i]
		if arg == '--' {
			positionals << args[i + 1..]
			break
		}
		if arg.starts_with('--') || (arg.starts_with('-') && arg.len == 2 && !looks_like_number(arg)) {
			option := if arg.starts_with('--') { arg[2..] } else { arg[1..] }
			key := option.all_before('=')
			mut value := 'true'
			if option.contains('=') {
				value = option.all_after('=')
				i++
			} else if is_numeric_option(cmd, key) {
				if i + 1 >= args.len {
					return error('missing value for --${key}')
				}
				value = args[i + 1]
				i += 2
			} else if should_consume_flag_value(cmd, key, if i + 1 < args.len {
				args[i + 1]
			} else {
				''
			}, i + 1 < args.len) {
				value = args[i + 1]
				i += 2
			} else {
				i++
			}
			if is_numeric_option(cmd, key) {
				if key in ['x', 'y', 'dx', 'dy', 'lat', 'lng', 'lon', 'scale', 'threshold'] || (cmd == 'diff' && key == 't') {
					cli_parse_float(value) or { return error('invalid value for --${key}: ${value}') }
				} else {
					cli_parse_int(value) or { return error('invalid value for --${key}: ${value}') }
				}
			}
			if is_boolean_switch(key) {
				value = cli_bool_text(value, '--${key}')!
			}
			flags[key] = value
		} else {
			positionals << arg
			i++
		}
	}

	// --stable 是取值型选项：稳定等待必须给出选择器。
	// 裸写 --stable 时通用解析会把值置成 'true'，直接发出去等于把字符串
	// "true" 当成选择器，服务端只会等一个不存在的元素直到超时。
	// 这里在进入命令分派前直接报错，避免发出语义错误的请求。
	if cmd == 'wait' && 'stable' in flags {
		stable_value := flags['stable'] or { '' }
		if stable_value == '' || stable_value == 'true' || stable_value == 'false' {
			return error('wait --stable requires a selector, e.g. v-browser wait --stable "#result"')
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
			if tab_id != '' || window_id != '' {
				tab := cli_int_arg(if tab_id == '' { '0' } else { tab_id }, '--tab-id', 0, 2147483647)!
				mut win := 0
				if window_id != '' {
					win = cli_int_arg(window_id, '--window-id', 0, 2147483647)!
				}
				return 'connect', '{"tabId":${tab},"windowId":${win}}'
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
			full := cli_bool_text(flags['full'] or { 'false' }, '--full')!
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
			extra := cli_bool_text(flags['extra'] or { flags['interactive'] or { 'false' } },
				'--extra')!
			interactive := cli_bool_text(flags['interactive'] or { 'false' }, '--interactive')!
			// maxNodes 限制最终输出的引用总数，AX Tree 和补全共享同一预算。
			max_nodes := cli_int_arg(flags['maxNodes'] or { '0' }, '--maxNodes', 0, 1000000)!
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
			verify := cli_bool_text(flags['verify'] or { 'false' }, '--verify')!
			verify_timeout := cli_int_arg(flags['verify-timeout'] or {
				flags['verifyTimeout'] or { '1500' }
			}, '--verify-timeout', 0, 600000)!
			return 'fill', '{"selector":${json_str(sel)},"text":${json_str(text)},"verify":${json_str(verify)},"verifyTimeout":${verify_timeout}}'
		}
		'type' {
			sel := flags['selector'] or {
				if positionals.len > 0 { positionals[0] } else { '' }
			}
			text := flags['text'] or {
				if positionals.len > 1 { positionals[1] } else { '' }
			}
			verify := cli_bool_text(flags['verify'] or { 'false' }, '--verify')!
			verify_timeout := cli_int_arg(flags['verify-timeout'] or {
				flags['verifyTimeout'] or { '1500' }
			}, '--verify-timeout', 0, 600000)!
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
			px := cli_int_arg(flags['px'] or { '300' }, '--px', -1000000, 1000000)!
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
			verify := cli_bool_text(flags['verify'] or { 'false' }, '--verify')!
			verify_timeout := cli_int_arg(flags['verify-timeout'] or {
				flags['verifyTimeout'] or { '1500' }
			}, '--verify-timeout', 0, 600000)!
			wait_preview := cli_bool_text(flags['wait-preview'] or { 'false' },
				'--wait-preview')!
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
				timeout := cli_int_arg(flags['timeout'] or { '30000' }, '--timeout', 0, 3600000)!
				resolved_download_path := if download_path == 'true' { '' } else { download_path }
				return 'wait', '{"download":${json_str(resolved_download_path)},"timeout":${timeout}}'
			}
			// --stable 必须排在位置参数之前：`wait --stable '#btn'` 的选择器
			// 会被通用 flag 解析收进 flags['stable']，若先处理位置参数就会
			// 退化成普通选择器等待，丢掉「等待内容稳定」的语义。
			if 'stable' in flags {
				stable := flags['stable'] or { '' }
				timeout := cli_int_arg(flags['timeout'] or { '30000' }, '--timeout', 0, 3600000)!
				return 'wait', '{"stable":${json_str(stable)},"timeout":${timeout}}'
			}
			if positionals.len > 0 {
				arg := positionals[0]
				// 数字开头的等待时长不能在解析失败时退化成选择器。
				if arg.len > 0 && (arg[0].is_digit() || arg[0] == `-` || arg[0] == `+`) {
					ms := cli_int_arg(arg, 'ms', 0, 3600000)!
					return 'wait', '{"ms":${ms}}'
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
			return 'wait', '{"ms":1000}'
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
			debug_mode := cli_bool_text(flags['debug'] or { 'false' }, '--debug')!
			list_mode := cli_bool_text(flags['list'] or { 'false' }, '--list')!
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
			action := if cli_parse_bool(flags['click'] or { 'false' })! {
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
			exact := cli_bool_text(flags['exact'] or { 'false' }, '--exact')!
			// index 保持字符串形态（服务端按字符串读取），但必须是合法整数。
			if index != '' {
				index = cli_int_arg(index, '--index', -1, 1000000)!.str()
			}
			name_filter := flags['name'] or { '' }
			return 'find', '{"locator":${json_str(loc_key)},"query":${json_str(query)},"action":${json_str(action)},"value":${json_str(value)},"exact":${json_str(exact)},"name":${json_str(name_filter)},"index":${json_str(index)},"debug":${json_str(debug_mode)},"list":${json_str(list_mode)}}'
		}
		// ── eval ──
		'eval', 'js', 'execute', 'run' {
			expr, as_b64, read_error := resolve_eval_input(flags, positionals, stdin_reader,
				file_reader)
			await_p := cli_bool_text(flags['await'] or { 'false' }, '--await')!
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
					mut tab := 0
					if tab_id != '' {
						tab = cli_int_arg(tab_id, '--tab-id', 0, 2147483647)!
					}
					mut win := 0
					if window_id != '' {
						win = cli_int_arg(window_id, '--window-id', 0, 2147483647)!
					}
					return 'tab', '{"action":"switch","tabId":${tab},"windowId":${win}}'
				}
				'close' {
					tid := flags['id'] or {
						flags['tab-id'] or {
							if positionals.len > 1 { positionals[1] } else { '' }
						}
					}
					mut tab := 0
					if tid != '' {
						tab = cli_int_arg(tid, '--tab-id', 0, 2147483647)!
					}
					return 'tab', '{"action":"close","tabId":${tab}}'
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
			x := cli_float_arg(flags['x'] or {
				if positionals.len > 1 { positionals[1] } else { '0' }
			}, '--x', -100000, 100000)!
			y := cli_float_arg(flags['y'] or {
				if positionals.len > 2 { positionals[2] } else { '0' }
			}, '--y', -100000, 100000)!
			btn := flags['button'] or { 'left' }
			dx := cli_float_arg(flags['dx'] or { '0' }, '--dx', -100000, 100000)!
			dy := cli_float_arg(flags['dy'] or { '0' }, '--dy', -100000, 100000)!
			return 'mouse', '{"action":${json_str(action)},"x":${cli_number_text(x)},"y":${cli_number_text(y)},"button":${json_str(btn)},"dx":${cli_number_text(dx)},"dy":${cli_number_text(dy)}}'
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
			abort := cli_bool_text(flags['abort'] or { 'false' }, '--abort')!
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
			// headers 允许 JSON：必须先解析再重新编码，禁止原始字符串进入行协议。
			headers_override := cli_json_object_arg(flags['override-headers'] or {
				flags['headers-override'] or { '{}' }
			}, '--override-headers')!
			dry_run := cli_bool_text(flags['dry-run'] or { flags['dryRun'] or { 'false' } },
				'--dry-run')!
			capture_body := cli_bool_text(flags['capture-body'] or {
				flags['captureBody'] or { 'false' }
			}, '--capture-body')!
			capture_response := cli_bool_text(flags['capture-response'] or {
				flags['captureResponse'] or { 'false' }
			}, '--capture-response')!
			persistent := cli_bool_text(flags['persistent'] or { 'true' }, '--persistent')!
			clear := cli_bool_text(flags['clear'] or { 'true' }, '--clear')!
			script_id := flags['script-id'] or { flags['scriptId'] or { '' } }
			mut max_body_len := flags['max-body-len'] or { flags['maxBodyLen'] or { '' } }
			mime := flags['mime'] or { '' }
			status_filter := flags['status'] or { '' }
			domain := flags['domain'] or { '' }
			rtype := flags['type'] or { '' }
			all_frames := cli_bool_text(flags['all-frames'] or { flags['allFrames'] or { 'false' } },
				'--all-frames')!
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
			// limit / maxBodyLen 保持字符串形态（服务端按字符串读取），但必须是合法整数。
			if limit != '' {
				limit = cli_int_arg(limit, '--limit', 0, 1000000)!.str()
			}
			if max_body_len != '' {
				max_body_len = cli_int_arg(max_body_len, '--max-body-len', 0, 100000000)!.str()
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
					w := cli_int_arg(flags['width'] or {
						if positionals.len > 1 { positionals[1] } else { '1280' }
					}, '--width', 1, 100000)!
					h := cli_int_arg(flags['height'] or {
						if positionals.len > 2 { positionals[2] } else { '800' }
					}, '--height', 1, 100000)!
					scale := cli_float_arg(flags['scale'] or {
						if positionals.len > 3 { positionals[3] } else { '1' }
					}, '--scale', 0.01, 100)!
					return 'set', '{"property":"viewport","width":${w},"height":${h},"scale":${cli_number_text(scale)}}'
				}
				'device' {
					value := flags['value'] or {
						if positionals.len > 1 { positionals[1..].join(' ') } else { '' }
					}
					return 'set', '{"property":"device","value":${json_str(value)}}'
				}
				'geo', 'geolocation' {
					lat := cli_float_arg(flags['lat'] or {
						if positionals.len > 1 { positionals[1] } else { '0' }
					}, '--lat', -90, 90)!
					lng := cli_float_arg(flags['lng'] or {
						flags['lon'] or {
							if positionals.len > 2 { positionals[2] } else { '0' }
						}
					}, '--lng', -180, 180)!
					return 'set', '{"property":"geo","lat":${cli_number_text(lat)},"lng":${cli_number_text(lng)}}'
				}
				'offline' {
					value := flags['value'] or { 'on' }
					return 'set', '{"property":"offline","value":${json_str(value)}}'
				}
				'headers' {
					// headers 允许 JSON：先解析再重新编码，禁止原始字符串进入行协议。
					headers := cli_json_object_arg(flags['headers'] or { '{}' }, '--headers')!
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
					threshold := cli_float_arg(flags['threshold'] or { flags['t'] or { '0.1' } },
						'--threshold', 0, 1)!
					selector := flags['selector'] or { flags['s'] or { '' } }
					full := cli_bool_text(flags['full'] or { 'false' }, '--full')!
					return 'diff', '{"type":"screenshot","baseline":${json_str(baseline)},"output":${json_str(output)},"threshold":${cli_number_text(threshold)},"selector":${json_str(selector)},"full":${json_str(full)}}'
				}
				'url' {
					url1 := flags['url1'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					url2 := flags['url2'] or {
						if positionals.len > 2 { positionals[2] } else { '' }
					}
					screenshot := cli_bool_text(flags['screenshot'] or { 'false' },
						'--screenshot')!
					full := cli_bool_text(flags['full'] or { 'false' }, '--full')!
					wait_until := flags['wait-until'] or { 'load' }
					selector := flags['selector'] or { flags['s'] or { '' } }
					compact := cli_bool_text(flags['compact'] or { 'false' }, '--compact')!
					max_depth := cli_int_arg(flags['depth'] or { flags['d'] or { '0' } },
						'--depth', 0, 10000)!
					return 'diff', '{"type":"url","url1":${json_str(url1)},"url2":${json_str(url2)},"screenshot":${json_str(screenshot)},"full":${json_str(full)},"waitUntil":${json_str(wait_until)},"selector":${json_str(selector)},"compact":${json_str(compact)},"maxDepth":${max_depth}}'
				}
				else {
					baseline := flags['baseline'] or {
						if positionals.len > 1 { positionals[1] } else { '' }
					}
					selector := flags['selector'] or { flags['s'] or { '' } }
					compact := cli_bool_text(flags['compact'] or { 'false' }, '--compact')!
					max_depth := cli_int_arg(flags['depth'] or { flags['d'] or { '0' } },
						'--depth', 0, 10000)!
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
				// 选项名同样来自外部输入，必须转义后再拼进 JSON。
				p += ',${json_str(k)}:${json_str(v)}'
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
// 响应读取的总超时与大小上限：避免 CLI 永久挂死或被超大响应撑爆内存。
// 没有显式等待时长的命令沿用默认 deadline。
const ipc_default_response_deadline = 60 * time.second

// 命令声明了等待时长时，在其基础上追加的余量（服务端收尾 / 编码耗时）。
const ipc_deadline_margin = 30 * time.second

// deadline 上限：防止异常参数把 CLI 挂死。
const ipc_max_response_deadline = 2 * time.hour

const ipc_max_response_bytes = 16 * 1024 * 1024

// ipc_response_deadline_for_params 按请求参数推导 IPC 响应 deadline。
// 服务端的 wait / wait --download 会睡满请求里的时长，固定 60s 会把
// `wait 90000`、`wait --download --timeout 300000` 这类合法用法掐断，
// 所以按请求声明的等待时长 + 余量计算；没有等待时长时沿用默认 60s。
fn ipc_response_deadline_for_params(params string) time.Duration {
	obj := cdp_json_object(params)
	mut requested_ms := 0
	for key in ['timeout', 'ms', 'verifyTimeout'] {
		ms := ipc_param_duration_ms(obj, key)
		if ms > requested_ms {
			requested_ms = ms
		}
	}
	if requested_ms <= 0 {
		return ipc_default_response_deadline
	}
	deadline := time.Duration(requested_ms) * time.millisecond + ipc_deadline_margin
	// 请求时长比默认等待还短时沿用默认值，不因为一个小的 verify-timeout
	// 把整体 deadline 收窄。
	if deadline < ipc_default_response_deadline {
		return ipc_default_response_deadline
	}
	if deadline > ipc_max_response_deadline {
		return ipc_max_response_deadline
	}
	return deadline
}

// ipc_param_duration_ms 读取参数里的毫秒数：数字或数字字符串都接受，
// 缺失 / 非法一律按 0（不参与 deadline 推导）处理。
fn ipc_param_duration_ms(obj map[string]json.Any, key string) int {
	ms, ok := cdp_json_int_ok(obj, key)
	if ok {
		return ms
	}
	text := cdp_json_str(obj, key)
	if text == '' {
		return 0
	}
	return cli_parse_int(text) or { 0 }
}

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
	// deadline 按请求参数推导：长等待命令不能被固定的 60s 掐断。
	deadline := ipc_response_deadline_for_params(params)
	// 单次读超时与总超时保持一致：整体等待不会超过本次 deadline。
	conn.set_read_timeout(deadline)

	// 发送请求
	req := IpcRequest{
		id:     1
		method: method
		params: params
	}
	conn.write_string(ipc_encode_request(req)) or { return error('send failed: ${err}') }

	return read_ipc_response(mut conn, req.id, deadline, ipc_max_response_bytes)
}

fn read_ipc_response(mut conn net.TcpConn, request_id int, timeout time.Duration, max_bytes int) !string {
	mut buf := []u8{len: 65536}
	mut raw := []u8{}
	deadline := time.now().add(timeout)
	conn.set_read_deadline(deadline)
	for {
		remaining := deadline - time.now()
		if remaining <= 0 {
			return error('timed out waiting for the v-browser server response')
		}
		// 每轮收紧阻塞 recv 的超时，慢速分片不能重新获得完整等待时间。
		conn.set_read_timeout(remaining)
		n := conn.read(mut buf) or {
			if err is io.Eof {
				return error('v-browser server closed the connection before sending a complete response')
			}
			return error('read failed: ${err}')
		}
		if n == 0 {
			return error('v-browser server closed the connection before sending a complete response')
		}
		if time.now() >= deadline {
			return error('timed out waiting for the v-browser server response')
		}
		mut frame_end := n
		mut complete := false
		for j in 0 .. n {
			if buf[j] == `\n` {
				frame_end = j + 1
				complete = true
				break
			}
		}
		if raw.len + frame_end > max_bytes {
			return error('v-browser server response exceeds the ${max_bytes} byte limit')
		}
		raw << buf[..frame_end]
		if complete {
			break
		}
	}

	resp := ipc_decode_response(raw.bytestr().trim_space()) or { return error('parse response: ${err}') }
	if resp.id != request_id {
		return error('unexpected response id ${resp.id} (expected ${request_id})')
	}
	if resp.err != '' {
		return error(resp.err)
	}
	// 美化输出：去除外层引号（如果是字符串 JSON）。
	// 必须用真正的 JSON 解码：手工 replace 会把 `\\n`（字面反斜杠+n）、
	// `\t`/`\r`/`\uXXXX` 全部解错。解不动就原样返回，不算命令失败。
	result := resp.result
	if result.starts_with('"') && result.ends_with('"') {
		return json.decode[string](result) or { return result }
	}
	return result
}
