module main

import json
import net
import os
import time
import veb

const dashboard_port = 48280
const max_log_lines = 60

struct Context {
	veb.Context
}

pub struct App {
	veb.StaticHandler
pub:
	root_dir       string
	server_dir     string
	server_binary  string
	static_dir     string
	v_browser_home string
}

struct StatusResponse {
	ok                    bool
	server_binary         string
	binary_exists         bool
	v_browser_home        string
	token                 string
	stored_extension_id   string
	extension_status_url  string
	server_running        bool
	extension_connected   bool
	ipc_port              int
	status_raw            string
	server_log_tail       string
	hint                  string
}

struct ActionRequest {
	action       string
	value        string
	command      string
	extension_id string
}

struct ActionResponse {
	ok          bool
	invoked     string
	stdout      string
	stderr      string
	exit_code   int
	duration_ms i64
	error       string
	status      StatusResponse
}

struct CliResult {
	exit_code int
	stdout    string
	stderr    string
}

struct ProbeStatus {
	server_running      bool
	extension_connected bool
	ipc_port            int
	status_raw          string
}

fn main() {
	root_dir := os.dir(os.dir(os.dir(os.dir(@FILE))))
	server_dir := os.join_path(root_dir, 'packages', 'server')
	static_dir := os.join_path(os.dir(os.dir(@FILE)), 'static')
	v_browser_home := resolve_v_browser_home()
	mut app := &App{
		root_dir:       root_dir
		server_dir:     server_dir
		server_binary:  os.join_path(server_dir, 'v-browser')
		static_dir:     static_dir
		v_browser_home: v_browser_home
	}
	app.handle_static(static_dir, true) or {
		eprintln('failed to register static assets: ${err}')
		exit(1)
	}
	eprintln('v-browser test ui listening on http://127.0.0.1:${dashboard_port}')
	veb.run_at[App, Context](mut app,
		host:               '127.0.0.1'
		port:               dashboard_port
		family:             .ip
		timeout_in_seconds: 3
	) or {
		eprintln('failed to start test ui: ${err}')
		exit(1)
	}
}

pub fn (app &App) index(mut ctx Context) veb.Result {
	return ctx.file(os.join_path(app.static_dir, 'index.html'))
}

@['/api/status'; get]
pub fn (app &App) api_status(mut ctx Context) veb.Result {
	return ctx.json(collect_status(app))
}

@['/api/run'; post]
pub fn (app &App) api_run(mut ctx Context) veb.Result {
	request := json.decode(ActionRequest, ctx.req.data) or {
		ctx.res.set_status(.bad_request)
		return ctx.json(ActionResponse{
			ok:    false
			error: 'invalid request body: ${err}'
			status: collect_status(app)
		})
	}
	started := time.now()
	result := app.execute_action(request) or {
		ctx.res.set_status(.bad_request)
		return ctx.json(ActionResponse{
			ok:          false
			invoked:     request.action
			error:       err.msg()
			duration_ms: time.now().unix_milli() - started.unix_milli()
			status:      collect_status(app)
		})
	}
	return ctx.json(ActionResponse{
		ok:          result.exit_code == 0
		invoked:     build_invoked_label(request)
		stdout:      result.stdout
		stderr:      result.stderr
		exit_code:   result.exit_code
		duration_ms: time.now().unix_milli() - started.unix_milli()
		status:      collect_status(app)
	})
}

fn (app &App) execute_action(request ActionRequest) !CliResult {
	match request.action {
		'build' {
			return run_process('v', ['run', './build.vsh'], app.server_dir, app.v_browser_home)
		}
		'connect' {
			mut args := ['connect']
			extension_id := request.extension_id.trim_space()
			if extension_id != '' {
				args << '--extension-id'
				args << extension_id
			}
			return app.run_cli(args)
		}
		'status' {
			return app.run_cli(['status'])
		}
		'open' {
			url := request.value.trim_space()
			if url == '' {
				return error('missing URL')
			}
			return app.run_cli(['open', url])
		}
		'eval' {
			expr := request.value.trim_space()
			if expr == '' {
				return error('missing JavaScript expression')
			}
			return app.run_cli(['eval', expr])
		}
		'snapshot' {
			return app.run_cli(['snapshot'])
		}
		'tab-list' {
			return app.run_cli(['tab', 'list'])
		}
		'custom' {
			args := tokenize_cli_command(request.command)!
			return app.run_cli(args)
		}
		else {
			return error('unsupported action: ${request.action}')
		}
	}
}

fn (app &App) run_cli(args []string) !CliResult {
	if !os.exists(app.server_binary) {
		return error('missing server binary at ${app.server_binary}; click Build Server first')
	}
	return run_process(app.server_binary, args, app.server_dir, app.v_browser_home)
}

fn run_process(binary string, args []string, work_dir string, v_browser_home string) !CliResult {
	mut process := os.new_process(binary)
	process.set_args(args)
	process.set_work_folder(work_dir)
	mut env := os.environ()
	env['HOME'] = v_browser_home
	env['V_BROWSER_HOME'] = v_browser_home
	process.set_environment(env)
	process.set_redirect_stdio()
	process.wait()
	stdout := process.stdout_slurp()
	stderr := process.stderr_slurp()
	exit_code := process.code
	process.close()
	return CliResult{
		exit_code: exit_code
		stdout:    stdout
		stderr:    stderr
	}
}

fn collect_status(app &App) StatusResponse {
	binary_exists := os.exists(app.server_binary)
	token := os.read_file(token_path(app.v_browser_home)) or { '' }
	stored_extension_id := os.read_file(extension_id_path(app.v_browser_home)) or { '' }
	probe := probe_server_status(app.v_browser_home)
	mut hint := 'Load packages/extension/dist in Chromium, then open the extension status page to sync its id.'
	if !binary_exists {
		hint = 'Build packages/server first, or click Build Server in this dashboard.'
	} else if stored_extension_id.trim_space() == '' {
		hint = 'No extension id stored yet. Open the extension status page and click Sync To Local Server.'
	} else if !probe.extension_connected {
		hint = 'Server is reachable, but the extension is not connected. Run connect after syncing the extension id.'
	}
	return StatusResponse{
		ok:                   true
		server_binary:        app.server_binary
		binary_exists:        binary_exists
		v_browser_home:       app.v_browser_home
		token:                token.trim_space()
		stored_extension_id:  stored_extension_id.trim_space()
		extension_status_url: build_extension_status_url(stored_extension_id.trim_space())
		server_running:       probe.server_running
		extension_connected:  probe.extension_connected
		ipc_port:             probe.ipc_port
		status_raw:           probe.status_raw
		server_log_tail:      tail_lines_from_file(server_log_path(app.v_browser_home), max_log_lines)
		hint:                 hint
	}
}

fn probe_server_status(v_browser_home string) ProbeStatus {
	port_str := os.read_file(ipc_sock_path(v_browser_home)) or {
		return ProbeStatus{}
	}
	port := port_str.trim_space().int()
	if port <= 0 {
		return ProbeStatus{}
	}
	mut conn := net.dial_tcp('127.0.0.1:${port}') or {
		return ProbeStatus{}
	}
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(2 * time.second)
	conn.write_string('{"id":1,"method":"status","params":{}}\n') or {
		return ProbeStatus{}
	}
	mut buf := []u8{len: 4096}
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
	line := raw.trim_space()
	return ProbeStatus{
		server_running:      line != ''
		extension_connected: line.contains('"connected":true')
		ipc_port:            port
		status_raw:          line
	}
}

fn tokenize_cli_command(command string) ![]string {
	mut trimmed := command.trim_space()
	if trimmed == '' {
		return error('missing custom command')
	}
	mut args := []string{}
	mut current := []u8{}
	mut quote := u8(0)
	mut escaped := false
	for ch in trimmed.bytes() {
		if escaped {
			current << ch
			escaped = false
			continue
		}
		if ch == `\\` {
			escaped = true
			continue
		}
		if quote != 0 {
			if ch == quote {
				quote = 0
			} else {
				current << ch
			}
			continue
		}
		if ch == `"` || ch == `'` {
			quote = ch
			continue
		}
		if ch.is_space() {
			if current.len > 0 {
				args << current.bytestr()
				current = []u8{}
			}
			continue
		}
		current << ch
	}
	if quote != 0 {
		return error('unterminated quoted argument')
	}
	if escaped {
		current << `\\`
	}
	if current.len > 0 {
		args << current.bytestr()
	}
	if args.len == 0 {
		return error('missing custom command')
	}
	if args[0] == 'v-browser' || args[0].ends_with('/v-browser') {
		args = args[1..].clone()
	}
	if args.len == 0 {
		return error('custom command must include CLI arguments after v-browser')
	}
	return args
}

fn tail_lines_from_file(path string, count int) string {
	content := os.read_file(path) or { return '' }
	lines := content.split_into_lines()
	if lines.len <= count {
		return content.trim_space()
	}
	return lines[lines.len - count..].join('\n').trim_space()
}

fn build_invoked_label(request ActionRequest) string {
	if request.action == 'custom' {
		return request.command.trim_space()
	}
	return request.action
}

fn resolve_v_browser_home() string {
	override := os.getenv('V_BROWSER_HOME').trim_space()
	if override != '' {
		return override
	}
	return os.home_dir()
}

fn ipc_sock_path(home string) string {
	return os.join_path(home, '.v-browser', 'server.sock')
}

fn token_path(home string) string {
	return os.join_path(home, '.v-browser', 'token')
}

fn extension_id_path(home string) string {
	return os.join_path(home, '.v-browser', 'extension_id')
}

fn server_log_path(home string) string {
	return os.join_path(home, '.v-browser', 'server.log')
}

fn build_extension_status_url(extension_id string) string {
	if extension_id == '' {
		return ''
	}
	return 'chrome-extension://${extension_id}/status.html'
}