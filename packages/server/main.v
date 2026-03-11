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
//   v-browser eval <expr>     — 执行 JS 表达式
//   v-browser wait <ms|sel>   — 等待
//   v-browser find --role button --name "OK" --click
//   ...（其余命令见 commands.v）
module main

import os
import net
import net.urllib
import time

fn main() {
	raw_args := os.args[1..]
	if raw_args.len == 0 {
		print_usage()
		return
	}
	mut json_output := false
	mut args := []string{}
	for arg in raw_args {
		if arg == '--json' {
			json_output = true
			continue
		}
		args << arg
	}
	if args.len == 0 {
		print_usage()
		return
	}

	cmd := args[0]
	rest := args[1..]

	// 特殊：server 子命令本地处理，不需要 IPC
	if cmd == 'server' || cmd == 'daemon' {
		run_server()
		return
	}
	if cmd == 'connect' {
		handle_connect_command(rest, json_output)
		return
	}

	// 所有其他子命令转为 IPC 请求转发给 server
	method, params := parse_cli_to_ipc(cmd, rest)
	result := send_ipc(method, params) or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	println(format_output(result, json_output))
}

fn handle_connect_command(args []string, json_output bool) {
	tab_id := extract_flag_value(args, '--tab-id').int()
	window_id := extract_flag_value(args, '--window-id').int()
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
				print_error('extension did not connect within 35s; select a tab in the extension page, then run v-browser connect again', json_output)
				return
			}
		} else {
			print_error('no extension connected; set V_BROWSER_EXTENSION_ID or run v-browser connect --extension-id <id>', json_output)
			exit(1)
		}
	}
	params := if tab_id > 0 { '{"tabId":${tab_id},"windowId":${window_id}}' } else { '{}' }
	result := send_ipc('connect', params) or {
		print_error(err.msg(), json_output)
		exit(1)
	}
	println(format_output(result, json_output))
}

fn ensure_server_running() ! {
	if can_reach_ipc_server() {
		return
	}
	start_server_daemon()!
	deadline := time.now().add(8 * time.second)
	for time.now() < deadline {
		if can_reach_ipc_server() {
			return
		}
		time.sleep(200 * time.millisecond)
	}
	return error('v-browser server did not become ready. Check ${server_log_path()}')
}

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

fn start_server_daemon() ! {
	os.mkdir_all(os.dir(server_log_path()))!
	executable := os.executable()
	if executable == '' {
		return error('could not determine current executable path')
	}
	cmd := 'nohup ${shell_quote(executable)} server >> ${shell_quote(server_log_path())} 2>&1 &'
	result := os.execute(cmd)
	if result.exit_code != 0 {
		return error('failed to start v-browser server: ${result.output}')
	}
}

// ─── 启动服务 ────────────────────────────────────────────────
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

fn resolve_extension_id(args []string) string {
	explicit := extract_flag_value(args, '--extension-id')
	if explicit != '' {
		save_extension_id(explicit) or {}
		return explicit
	}
	env_id := os.getenv('V_BROWSER_EXTENSION_ID').trim_space()
	if env_id != '' {
		return env_id
	}
	stored := os.read_file(extension_id_path()) or { '' }
	return stored.trim_space()
}

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

fn save_extension_id(extension_id string) ! {
	if extension_id.trim_space() == '' { return }
	os.mkdir_all(os.dir(extension_id_path()))!
	os.write_file(extension_id_path(), extension_id.trim_space())!
}

fn build_extension_connect_url(extension_id string, token string) string {
	relay_url := 'ws://127.0.0.1:${configured_relay_port()}'
	client_info := '{"name":"v-browser","version":"0.1.0"}'
	return 'chrome-extension://${extension_id}/connect.html?mcpRelayUrl=${urllib.query_escape(relay_url)}&client=${urllib.query_escape(client_info)}&protocolVersion=1&token=${urllib.query_escape(token)}'
}

fn open_extension_connect_page(extension_id string) !string {
	if extension_id.trim_space() == '' {
		return error('missing extension id')
	}
	token := load_or_create_token()!
	connect_url := build_extension_connect_url(extension_id.trim_space(), token)
	open_url_in_browser(connect_url)!
	return connect_url
}

fn open_url_in_browser(url string) ! {
	$if macos {
		candidates := browser_open_candidates(os.getenv('V_BROWSER_BROWSER_APP').trim_space())
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
		if os.getenv('V_BROWSER_BROWSER_APP').trim_space() == '' {
			reason += '. Set V_BROWSER_BROWSER_APP to an installed browser app name if needed'
		}
		return error(reason)
	}
	result := os.execute('open "${url}"')
	if result.exit_code != 0 {
		return error('failed to open extension connect page: ${result.output}')
	}
}

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

fn build_macos_open_command(app string, url string) string {
	return 'open -a ${shell_quote(app)} ${shell_quote(url)}'
}

fn shell_quote(value string) string {
	return "'" + value.replace("'", "'\\''") + "'"
}

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

fn is_extension_connected(status string) bool {
	return status.contains('"connected":true')
}

// ─── CLI → IPC 参数解析 ──────────────────────────────────────
// 将命令行参数转换为 (method, params_json) 对
fn parse_cli_to_ipc(cmd string, args []string) (string, string) {
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
			url := flags['url'] or { if positionals.len > 0 { positionals[0] } else { '' } }
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
				return 'connect', '{"tabId":${tab_id},"windowId":${if window_id != '' { window_id } else { '0' }}}'
			}
			return 'connect', '{}'
		}
		'status' {
			return 'status', '{}'
		}
		// ── 截图 ──
		'screenshot', 'shot', 'ss' {
			path := flags['path'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			full := flags['full'] or { 'false' }
			fmt := flags['format'] or { 'png' }
			return 'screenshot', '{"path":${json_str(path)},"full":${json_str(full)},"format":${json_str(fmt)}}'
		}
		// ── PDF ──
		'pdf' {
			path := flags['path'] or { if positionals.len > 0 { positionals[0] } else { 'output.pdf' } }
			return 'pdf', '{"path":${json_str(path)}}'
		}
		// ── 快照 ──
		'snapshot', 'snap', 'ax' {
			return 'snapshot', '{}'
		}
		// ── 元素操作 ──
		'click' {
			sel := flags['selector'] or { flags['sel'] or { if positionals.len > 0 { positionals[0] } else { '' } } }
			return 'click', '{"selector":${json_str(sel)}}'
		}
		'dblclick', 'doubleclick' {
			sel := flags['selector'] or { flags['sel'] or { if positionals.len > 0 { positionals[0] } else { '' } } }
			return 'dblclick', '{"selector":${json_str(sel)}}'
		}
		'hover' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'hover', '{"selector":${json_str(sel)}}'
		}
		'focus' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'focus', '{"selector":${json_str(sel)}}'
		}
		'fill' {
			sel := flags['selector'] or { flags['sel'] or { if positionals.len > 0 { positionals[0] } else { '' } } }
			text := flags['text'] or { flags['value'] or { if positionals.len > 1 { positionals[1] } else { '' } } }
			return 'fill', '{"selector":${json_str(sel)},"text":${json_str(text)}}'
		}
		'type' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			text := flags['text'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			return 'type', '{"selector":${json_str(sel)},"text":${json_str(text)}}'
		}
		'press', 'key' {
			key := flags['key'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'press', '{"key":${json_str(key)}}'
		}
		'select' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			value := flags['value'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			return 'select', '{"selector":${json_str(sel)},"value":${json_str(value)}}'
		}
		'check' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'check', '{"selector":${json_str(sel)}}'
		}
		'uncheck' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'uncheck', '{"selector":${json_str(sel)}}'
		}
		// ── 滚动 ──
		'scroll' {
			dir := flags['direction'] or { flags['dir'] or { if positionals.len > 0 { positionals[0] } else { 'down' } } }
			px := flags['px'] or { '300' }
			sel := flags['selector'] or { '' }
			return 'scroll', '{"direction":${json_str(dir)},"px":${px},"selector":${json_str(sel)}}'
		}
		'scrollintoview', 'scrollinto' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
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
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			files := flags['files'] or { if positionals.len > 1 { positionals[1..].join(',') } else { '' } }
			return 'upload', '{"selector":${json_str(sel)},"files":${json_str(files)}}'
		}
		// ── 获取属性 ──
		'get' {
			prop := flags['property'] or { flags['prop'] or { if positionals.len > 0 { positionals[0] } else { 'text' } } }
			sel := flags['selector'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			attr := flags['attr'] or { '' }
			return 'get', '{"property":${json_str(prop)},"selector":${json_str(sel)},"attr":${json_str(attr)}}'
		}
		'text' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			return 'get', '{"property":"text","selector":${json_str(sel)}}'
		}
		'html' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
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
			state := flags['state'] or { if positionals.len > 0 { positionals[0] } else { 'visible' } }
			sel := flags['selector'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			return 'is', '{"state":${json_str(state)},"selector":${json_str(sel)}}'
		}
		// ── 等待 ──
		'wait' {
			if positionals.len > 0 {
				arg := positionals[0]
				// 纯数字 → ms
				if arg.int() > 0 {
					return 'wait', '{"ms":${arg}}'
				}
				// 选择器
				return 'wait', '{"selector":${json_str(arg)}}'
			}
			if load := flags['load'] { return 'wait', '{"load":${json_str(load)}}' }
			if url_p := flags['url'] { return 'wait', '{"url":${json_str(url_p)}}' }
			if text := flags['text'] { return 'wait', '{"text":${json_str(text)}}' }
			if fn_e := flags['fn'] { return 'wait', '{"fn":${json_str(fn_e)}}' }
			return 'wait', '{"ms":"1000"}'
		}
		// ── find（语义定位器）──
		'find' {
			loc_key := if flags.keys().contains('role') { 'role' }
				else if flags.keys().contains('text') { 'text' }
				else if flags.keys().contains('label') { 'label' }
				else if flags.keys().contains('placeholder') { 'placeholder' }
				else if flags.keys().contains('alt') { 'alt' }
				else if flags.keys().contains('title') { 'title' }
				else if flags.keys().contains('testid') { 'testid' }
				else if flags.keys().contains('first') { 'first' }
				else if flags.keys().contains('last') { 'last' }
				else if flags.keys().contains('nth') { 'nth' }
				else if positionals.len > 0 { positionals[0] }
				else { '' }
			mut query := flags[loc_key] or { '' }
			mut index := flags['index'] or { '' }
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
					'role', 'text', 'label', 'placeholder', 'alt', 'title', 'testid', 'first', 'last' {
						query = positionals[1]
						action_pos = 2
					}
					else {}
				}
			}
			action := if flags.keys().contains('click') { 'click' }
				else if flags.keys().contains('fill') { 'fill' }
				else if flags.keys().contains('type') { 'type' }
				else if flags.keys().contains('hover') { 'hover' }
				else if flags.keys().contains('focus') { 'focus' }
				else if flags.keys().contains('check') { 'check' }
				else if flags.keys().contains('uncheck') { 'uncheck' }
				else if flags.keys().contains('text') && loc_key != 'text' { 'text' }
				else { flags['action'] or { if positionals.len > action_pos { positionals[action_pos] } else { 'click' } } }
			value := flags['value'] or { if positionals.len > action_pos + 1 { positionals[action_pos + 1] } else { '' } }
			exact := if flags.keys().contains('exact') { 'true' } else { 'false' }
			name_filter := flags['name'] or { '' }
			return 'find', '{"locator":${json_str(loc_key)},"query":${json_str(query)},"action":${json_str(action)},"value":${json_str(value)},"exact":${json_str(exact)},"name":${json_str(name_filter)},"index":${json_str(index)}}'
		}
		// ── eval ──
		'eval', 'js', 'execute', 'run' {
			expr := flags['expression'] or { flags['expr'] or { if positionals.len > 0 { positionals[0] } else { '' } } }
			await_p := flags['await'] or { 'false' }
			return 'eval', '{"expression":${json_str(expr)},"awaitPromise":${json_str(await_p)}}'
		}
		// ── tab ──
		'tab' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'list' } }
			match action {
				'new' {
					url := flags['url'] or { if positionals.len > 1 { positionals[1] } else { '' } }
					return 'tab', '{"action":"new","url":${json_str(url)}}'
				}
				'switch' {
					tab_id := flags['id'] or { flags['tab-id'] or { if positionals.len > 1 { positionals[1] } else { '' } } }
					window_id := flags['window-id'] or { '' }
					return 'tab', '{"action":"switch","tabId":${if tab_id != '' { tab_id } else { '0' }},"windowId":${if window_id != '' { window_id } else { '0' }}}'
				}
				'close' {
					tid := flags['id'] or { flags['tab-id'] or { if positionals.len > 1 { positionals[1] } else { '' } } }
					return 'tab', '{"action":"close","tabId":${if tid != '' { tid } else { '0' }}}'
				}
				else {
					return 'tab', '{"action":"list"}'
				}
			}
		}
		'window' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'new' } }
			url := flags['url'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			return 'window', '{"action":${json_str(action)},"url":${json_str(url)}}'
		}
		// ── mouse ──
		'mouse' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { '' } }
			x := flags['x'] or { if positionals.len > 1 { positionals[1] } else { '0' } }
			y := flags['y'] or { if positionals.len > 2 { positionals[2] } else { '0' } }
			btn := flags['button'] or { 'left' }
			dx := flags['dx'] or { '0' }
			dy := flags['dy'] or { '0' }
			return 'mouse', '{"action":${json_str(action)},"x":${x},"y":${y},"button":${json_str(btn)},"dx":${dx},"dy":${dy}}'
		}
		// ── cookies ──
		'cookies', 'cookie' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'get' } }
			name := flags['name'] or { '' }
			value := flags['value'] or { '' }
			domain := flags['domain'] or { '' }
			return 'cookies', '{"action":${json_str(action)},"name":${json_str(name)},"value":${json_str(value)},"domain":${json_str(domain)}}'
		}
		// ── storage ──
		'storage', 'localstorage', 'sessionstorage' {
			storage_type := if cmd == 'sessionstorage' { 'session' } else {
				flags['type'] or { 'local' }
			}
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'get' } }
			key := flags['key'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			value := flags['value'] or { if positionals.len > 2 { positionals[2] } else { '' } }
			return 'storage', '{"type":${json_str(storage_type)},"action":${json_str(action)},"key":${json_str(key)},"value":${json_str(value)}}'
		}
		// ── network ──
		'network' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'requests' } }
			url := flags['url'] or { '' }
			abort := flags['abort'] or { 'false' }
			body := flags['body'] or { '' }
			filter := flags['filter'] or { '' }
			return 'network', '{"action":${json_str(action)},"url":${json_str(url)},"abort":${json_str(abort)},"body":${json_str(body)},"filter":${json_str(filter)}}'
		}
		// ── frame ──
		'frame' {
			selector := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { 'main' } }
			return 'frame', '{"selector":${json_str(selector)}}'
		}
		// ── dialog ──
		'dialog' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'accept' } }
			text := flags['text'] or { '' }
			return 'dialog', '{"action":${json_str(action)},"text":${json_str(text)}}'
		}
		// ── highlight ──
		'highlight' {
			sel := flags['selector'] or { if positionals.len > 0 { positionals[0] } else { '' } }
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
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'start' } }
			path := flags['path'] or { '' }
			return 'trace', '{"action":${json_str(action)},"path":${json_str(path)}}'
		}
		// ── profiler ──
		'profiler', 'profile' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'start' } }
			path := flags['path'] or { '' }
			return 'profiler', '{"action":${json_str(action)},"path":${json_str(path)}}'
		}
		// ── set ──
		'set' {
			prop := flags['property'] or { flags['prop'] or { if positionals.len > 0 { positionals[0] } else { '' } } }
			match prop {
				'viewport' {
					w := flags['width'] or { if positionals.len > 1 { positionals[1] } else { '1280' } }
					h := flags['height'] or { if positionals.len > 2 { positionals[2] } else { '800' } }
					scale := flags['scale'] or { if positionals.len > 3 { positionals[3] } else { '1' } }
					return 'set', '{"property":"viewport","width":${w},"height":${h},"scale":${scale}}'
				}
				'device' {
					value := flags['value'] or { if positionals.len > 1 { positionals[1..].join(' ') } else { '' } }
					return 'set', '{"property":"device","value":${json_str(value)}}'
				}
				'geo', 'geolocation' {
					lat := flags['lat'] or { if positionals.len > 1 { positionals[1] } else { '0' } }
					lng := flags['lng'] or { flags['lon'] or { if positionals.len > 2 { positionals[2] } else { '0' } } }
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
				else { return 'set', '{"property":${json_str(prop)}}' }
			}
		}
		// ── diff ──
		'diff' {
			dtype := flags['type'] or { if positionals.len > 0 { positionals[0] } else { 'snapshot' } }
			baseline := flags['baseline'] or { if positionals.len > 1 { positionals[1] } else { '' } }
			return 'diff', '{"type":${json_str(dtype)},"baseline":${json_str(baseline)}}'
		}
		// ── state ──
		'state' {
			action := flags['action'] or { if positionals.len > 0 { positionals[0] } else { 'list' } }
			path := flags['path'] or { flags['name'] or { if positionals.len > 1 { positionals[1] } else { '' } } }
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
			println('v-browser 0.1.0')
			exit(0)
			return '', ''
		}
		else {
			// 未知命令直接透传到 dispatch_command
			// 构造最简 params：把所有 positionals 和 flags 塞进去
			mut p := '{"_cmd":${json_str(cmd)}'
			for k, v in flags { p += ',"${k}":${json_str(v)}' }
			for j, pos in positionals { p += ',"arg${j}":${json_str(pos)}' }
			p += '}'
			return cmd, p
		}
	}
}

// ─── IPC 客户端 ──────────────────────────────────────────────
fn send_ipc(method string, params string) !string {
	ensure_server_running()!
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
	conn.set_read_timeout(60 * time.second)

	// 发送请求
	req := IpcRequest{ id: 1, method: method, params: params }
	conn.write_string(ipc_encode_request(req)) or { return error('send failed: ${err}') }

	// 读取响应
	mut buf := []u8{len: 65536}
	mut raw := ''
	for {
		n := conn.read(mut buf) or { break }
		if n == 0 { break }
		raw += buf[..n].bytestr()
		if raw.contains('\n') { break }
	}

	resp := ipc_decode_response(raw.trim_space()) or { return error('parse response: ${err}') }
	if resp.err != '' {
		return error(resp.err)
	}
	// 美化输出：去除外层引号（如果是字符串 JSON）
	result := resp.result
	if result.starts_with('"') && result.ends_with('"') {
		return result[1..result.len - 1].replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
	}
	return result
}

// ─── 帮助文本 ────────────────────────────────────────────────
fn print_usage() {
	println('v-browser — Chrome 自动化 CLI (CDP 协议)

用法:
  v-browser server              启动中继 WebSocket 服务 (ws://127.0.0.1:47978)
  v-browser status              检查服务状态
  v-browser open <url>          导航到 URL
  v-browser close               关闭标签页
  v-browser back/forward/reload 历史导航
  v-browser screenshot [path]   截图 (--full --format png|jpeg)
  v-browser pdf <path>          生成 PDF
  v-browser snapshot            Accessibility 快照 (@eN 引用)
  v-browser eval <expr>         执行 JS 表达式
  v-browser click <selector>    点击元素
  v-browser dblclick <selector> 双击元素
  v-browser hover <selector>    鼠标悬停
  v-browser focus <selector>    聚焦元素
  v-browser fill <sel> <text>   清空并填入文本
  v-browser type <sel> <text>   追加输入文本
  v-browser press <key>         按键 (Enter, Tab, Escape, Control+a ...)
  v-browser select <sel> <val>  选择 <select> 选项
  v-browser check/uncheck <sel> 勾选/取消勾选
  v-browser scroll <dir> [--px N] [--selector sel]  滚动 (up/down/left/right)
  v-browser scrollintoview <sel> 滚动使元素可见
  v-browser drag --from <sel> --to <sel>  拖拽
  v-browser upload <sel> <files>  文件上传 (逗号分隔)
  v-browser get <prop> [sel]    获取属性 (text/html/value/title/url/count/attr/box)
  v-browser text <selector>     获取元素文本
  v-browser is <state> <sel>    检查状态 (visible/enabled/checked)
  v-browser wait <ms|sel>       等待 (毫秒 / 选择器 / --load / --url / --text / --fn)
  v-browser find --role button --name "OK" --click  语义定位
  v-browser tab list/new/close  标签页管理
  v-browser mouse <action> <x> <y>  鼠标原始操作
  v-browser cookies get/set/clear   Cookie 管理
  v-browser storage get/set/clear   localStorage 管理
  v-browser network route/unroute   网络拦截
  v-browser dialog accept/dismiss   对话框处理
  v-browser highlight <selector>    高亮元素
  v-browser console / errors        查看控制台/错误
  v-browser trace start/stop        性能追踪
  v-browser set viewport --width 1280 --height 800  设置视口
  v-browser diff snapshot [--baseline file]  快照对比
  v-browser state save/load/list    浏览器状态持久化

选项:
  --selector / -s   CSS 选择器或 XPath (//...) 或 @eN 引用
  --url             URL 参数
  --text            文本内容
  --full            完整页面截图
  --format          图片格式
')
}
