module main

import os
import net
import time
import x.json2 as json

fn main_review_reject(cmd string, args []string) {
	if _, _ := parse_cli_to_ipc_checked(cmd, args, false) {
		assert false, 'accepted invalid arguments: ${cmd} ${args}'
	}
}

fn test_main_review_numeric_and_json_injection() {
	payload := '1}\n{"id":2,"method":"shutdown","params":{}}\n'
	for args in [
		['scroll', '--px', payload],
		['fill', '#x', 'text', '--verify-timeout', payload],
		['snapshot', '--maxNodes', payload],
		['tab', 'switch', payload],
		['tab', 'close', payload],
		['mouse', 'move', '--x', payload],
		['set', 'viewport', '--width', payload],
		['set', 'geo', '--lat', payload],
		['diff', 'screenshot', '--threshold', payload],
		['wait', payload],
		['wait', '--download', '--timeout', payload],
		['network', 'requests', '--limit', payload],
		['connect', '--window-id', payload],
	] {
		main_review_reject(args[0], args[1..])
	}
	for value in ['2147483648', '-2147483649', '999999999999999999999', 'NaN', '1x', '1.5'] {
		main_review_reject('scroll', ['--px', value])
	}
	main_review_reject('scroll', ['--px', '1000001'])
	main_review_reject('set', ['geo', '--lat', '91'])
	main_review_reject('set', ['geo', '--lng', '-181'])
	main_review_reject('set', ['viewport', '--width', '0'])
	main_review_reject('set', ['geo', '--lat', '9'.repeat(400)])
	for value in ['[]', 'null', '{bad}', '{}\n{"id":2}', '{"x":"y"}\n{"method":"shutdown"}'] {
		main_review_reject('set', ['headers', '--headers', value])
		main_review_reject('network', ['hook', 'replay', '--override-headers', value])
	}
	_, headers := parse_cli_to_ipc_checked('set', ['headers', '--headers', '{\n"x":"a\\nb"\n}'], false) or { panic(err) }
	assert !headers.contains('\n')
	json.decode[map[string]json.Any](headers) or { panic(err) }
	_, unknown := parse_cli_to_ipc_checked('custom', ['--evil"\nkey', 'value\n'], false) or { panic(err) }
	assert !unknown.contains('\n')
	json.decode[map[string]json.Any](unknown) or { panic(err) }
}

fn test_main_review_negative_and_boolean_arguments() {
	_, geo := parse_cli_to_ipc_checked('set', ['geo', '--lat', '-33.8', '--lng', '-151.2'], false) or { panic(err) }
	assert geo.contains('"lat":-33.8')
	_, mouse := parse_cli_to_ipc_checked('mouse', ['move', '-1', '-2'], false) or { panic(err) }
	assert mouse.contains('"x":-1,"y":-2')
	for args in [['geo', '--lat'], ['geo', '--lat', '--lng', '1'], ['geo', '--lat', '-oops']] {
		main_review_reject('set', args)
	}
	for cmd in ['fill', 'type', 'upload'] {
		_, params := parse_cli_to_ipc_checked(cmd, ['#x', 'value', '--verify', 'false'], false) or { panic(err) }
		assert params.contains('"verify":"false"')
		main_review_reject(cmd, ['--verify=invalid'])
	}
	_, upload := parse_cli_to_ipc_checked('upload', ['--wait-preview', 'false'], false) or { panic(err) }
	assert upload.contains('"waitPreview":"false"')
	_, find := parse_cli_to_ipc_checked('find', ['text', 'label', '--debug', 'false', '--list',
		'false', '--exact', 'false'], false) or { panic(err) }
	assert find.contains('"debug":"false"')
	assert find.contains('"list":"false"')
	assert find.contains('"exact":"false"')
	_, snapshot := parse_cli_to_ipc_checked('snapshot', ['--extra=false', '--interactive=false'], false) or { panic(err) }
	assert snapshot.contains('"extra":false')
	main_review_reject('eval', ['--stdin=invalid'])
}

fn main_review_write_response(mut listener net.TcpListener, chunks []string, delay time.Duration) {
	mut conn := listener.accept() or { return }
	defer { conn.close() or {} }
	for chunk in chunks {
		time.sleep(delay)
		conn.write_string(chunk) or { return }
	}
}

fn main_review_response(chunks []string, delay time.Duration, timeout time.Duration, limit int) !string {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { listener.close() or {} }
	addr := listener.addr()!
	port := addr.port()!
	assert port !in [47978, 47979]
	worker := spawn main_review_write_response(mut listener, chunks, delay)
	mut conn := net.dial_tcp(addr.str())!
	defer {
		conn.close() or {}
		worker.wait()
	}
	return read_ipc_response(mut conn, 1, timeout, limit)
}

fn test_main_review_ipc_framing_limits_and_deadline() {
	assert ipc_max_response_bytes == 16 * 1024 * 1024
	assert main_review_response(['{"id":1,', '"result":"ok"}\n'], 0, time.second, 1024) or { panic(err) } == 'ok'
	for chunks in [[''], ['{"id":1,"result":"ok"}']] {
		main_review_response(chunks, 0, time.second, 1024) or {
			assert err.msg().contains('complete response')
			continue
		}
		assert false, 'accepted EOF without newline'
	}
	if _ := main_review_response(['{"id":2,"result":"ok"}\n'], 0, time.second, 1024) {
		assert false, 'accepted mismatched id'
	} else {
		assert err.msg().contains('unexpected response id')
	}
	if _ := main_review_response(['x'.repeat(ipc_max_response_bytes + 1)], 0, 5 * time.second, ipc_max_response_bytes) {
		assert false, 'accepted oversized response'
	} else {
		assert err.msg().contains('byte limit')
	}
	started := time.now()
	if _ := main_review_response(['{', '"id":1,', '"result":1}\n'], 80 * time.millisecond, 130 * time.millisecond, 1024) {
		assert false, 'accepted response after deadline'
	} else {
		assert err.msg().contains('read failed') || err.msg().contains('timed out')
	}
	assert time.now() - started < time.second
}

// IPC deadline 必须跟随请求声明的等待时长：
// 固定 60s 会把 `wait 90000`、`wait --download --timeout 300000` 这类
// 合法长命令在半路掐断。
fn test_main_review_ipc_deadline_follows_request_timeout() {
	// 没有等待时长时沿用默认 60s
	assert ipc_default_response_deadline == 60 * time.second
	assert ipc_response_deadline_for_params('{}') == 60 * time.second
	assert ipc_response_deadline_for_params('not-json') == 60 * time.second
	assert ipc_response_deadline_for_params('{"selector":"#btn"}') == 60 * time.second
	// 声明了等待时长：请求时长 + 30s 余量
	assert ipc_response_deadline_for_params('{"ms":90000}') == 90 * time.second + 30 * time.second
	assert ipc_response_deadline_for_params('{"download":"","timeout":300000}') ==
		300 * time.second + 30 * time.second
	assert ipc_response_deadline_for_params('{"stable":"#btn","timeout":5000}') == 60 * time.second
	// 比默认等待还短的时长不收窄 deadline
	assert ipc_response_deadline_for_params('{"verifyTimeout":1500}') == 60 * time.second
	// 多个时长取最大值
	assert ipc_response_deadline_for_params('{"ms":70000,"timeout":200000}') ==
		200 * time.second + 30 * time.second
	// 超长参数被上限兜底
	assert ipc_response_deadline_for_params('{"timeout":14400000}') == ipc_max_response_deadline
	// CLI 解析出的参数确实能推导出长 deadline
	_, wait_params := parse_cli_to_ipc_checked('wait', ['90000'], false) or { panic(err) }
	assert ipc_response_deadline_for_params(wait_params) == 90 * time.second + 30 * time.second
	_, download_params := parse_cli_to_ipc_checked('wait', ['--download', '--timeout', '300000'],
		false) or { panic(err) }
	assert ipc_response_deadline_for_params(download_params) == 300 * time.second + 30 * time.second
	_, stable_params := parse_cli_to_ipc_checked('wait', ['--stable', '#btn', '--timeout', '120000'],
		false) or { panic(err) }
	assert ipc_response_deadline_for_params(stable_params) == 120 * time.second + 30 * time.second
}

// CLI 解析层：--stable 必须消费选择器参数，不能退化成普通选择器等待。
fn test_main_review_wait_stable_consumes_selector() {
	_, params := parse_cli_to_ipc_checked('wait', ['--stable', '#btn'], false) or { panic(err) }
	assert params.contains('"stable":"#btn"')
	assert !params.contains('"selector"')
	_, with_timeout := parse_cli_to_ipc_checked('wait', ['--stable', '#btn', '--timeout', '5000'],
		false) or { panic(err) }
	assert with_timeout.contains('"stable":"#btn"')
	assert with_timeout.contains('"timeout":5000')
	// 裸 --stable 没有选择器，必须直接报错，不能把 "true" 当成选择器发出去。
	main_review_reject('wait', ['--stable'])
	main_review_reject('wait', ['--stable', 'true'])
	main_review_reject('wait', ['--stable', 'false'])
	// 其它等待方式不受影响
	_, ms := parse_cli_to_ipc_checked('wait', ['90000'], false) or { panic(err) }
	assert ms.contains('"ms":90000')
	_, selector := parse_cli_to_ipc_checked('wait', ['#btn'], false) or { panic(err) }
	assert selector.contains('"selector":"#btn"')
	_, load := parse_cli_to_ipc_checked('wait', ['--load'], false) or { panic(err) }
	assert load.contains('"load":"true"')
}

fn test_main_review_lifecycle_lock_cross_process_and_stale() {
	$if windows {
		return
	}
	old_home := os.getenv('V_BROWSER_HOME')
	home := os.join_path(os.temp_dir(), 'v-browser-main-lock-${os.getpid()}')
	os.mkdir_all(home) or { panic(err) }
	os.setenv('V_BROWSER_HOME', home, true)
	defer {
		os.setenv('V_BROWSER_HOME', old_home, true)
		os.rmdir_all(home) or {}
	}
	path := lifecycle_lock_path()
	os.mkdir_all(os.dir(path)) or { panic(err) }
	os.write_file(path, '') or { panic(err) }
	// 子进程持有同一文件锁；强制退出后内核应自动回收锁。
	mut holder := os.new_process('/usr/bin/python3')
	holder.set_args(['-c',
		'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.lockf(f,fcntl.LOCK_EX); print("ready",flush=True); time.sleep(10)',
		path])
	holder.set_redirect_stdio()
	holder.run()
	defer {
		if holder.is_alive() {
			holder.signal_kill()
			holder.wait()
		}
		holder.close()
	}
	deadline := time.now().add(3 * time.second)
	mut output := ''
	for time.now() < deadline && !output.contains('ready') {
		output += holder.stdout_read()
		time.sleep(10 * time.millisecond)
	}
	assert output.contains('ready')
	if lck := acquire_lifecycle_lock(100 * time.millisecond) {
		release_lifecycle_lock(lck)
		assert false, 'lock did not exclude another process'
	}
	holder.signal_kill()
	holder.wait()
	lck := acquire_lifecycle_lock(time.second) or { panic(err) }
	release_lifecycle_lock(lck)
	assert os.exists(path)
}

fn test_main_review_port_fallback_preserves_foreign_listener_and_client() {
	$if windows {
		return
	}
	old_relay := os.getenv('V_BROWSER_RELAY_PORT')
	old_ipc := os.getenv('V_BROWSER_IPC_PORT')
	mut foreign := os.new_process('/usr/bin/python3')
	foreign.set_args(['-c',
		'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); print(s.getsockname()[1],flush=True); time.sleep(10)'])
	foreign.set_redirect_stdio()
	foreign.run()
	defer {
		foreign.signal_kill()
		foreign.wait()
		foreign.close()
		os.setenv('V_BROWSER_RELAY_PORT', old_relay, true)
		os.setenv('V_BROWSER_IPC_PORT', old_ipc, true)
	}
	deadline := time.now().add(3 * time.second)
	mut output := ''
	for time.now() < deadline && !output.contains('\n') {
		output += foreign.stdout_read()
		time.sleep(10 * time.millisecond)
	}
	port := cli_int_arg(output.trim_space(), 'port', 1, 65535) or { panic(err) }
	assert port !in [47978, 47979]
	mut client := net.dial_tcp('127.0.0.1:${port}') or { panic(err) }
	defer { client.close() or {} }
	pids := listening_pids_on_port(port)
	assert foreign.pid in pids
	assert os.getpid() !in pids
	assert !is_v_browser_server_process(foreign.pid)
	os.setenv('V_BROWSER_RELAY_PORT', port.str(), true)
	os.setenv('V_BROWSER_IPC_PORT', port.str(), true)
	killed, conflicts := kill_server_by_ports()
	assert !killed
	assert conflicts.len > 0
	assert foreign.is_alive()
}

fn test_main_review_concurrent_background_start_has_one_pid() {
	$if windows {
		return
	}
	home := os.join_path(os.temp_dir(), 'v-browser-main-bg-${os.getpid()}')
	os.mkdir_all(home) or { panic(err) }
	defer { os.rmdir_all(home) or {} }
	binary := os.join_path(home, 'v-browser')
	built := os.execute('v -o ${shell_quote(binary)} ${shell_quote(os.dir(@FILE))}')
	assert built.exit_code == 0, built.output
	// Python 仅编排隔离的子进程和随机端口，避免触及用户的 pueue 或默认端口。
	script := 'import os,socket,subprocess,sys,pathlib
h,b=sys.argv[1:]
ss=[socket.socket(),socket.socket()]
for s in ss: s.bind(("127.0.0.1",0))
ports=[s.getsockname()[1] for s in ss]
assert not set(ports)&{47978,47979}
for s in ss: s.close()
e=dict(os.environ,HOME=h,V_BROWSER_HOME=h,V_BROWSER_RELAY_PORT=str(ports[0]),V_BROWSER_IPC_PORT=str(ports[1]),PATH="/usr/bin:/bin:/usr/sbin:/sbin")
try:
 ps=[subprocess.Popen([b,"server","bg"],env=e,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True) for _ in range(6)]
 results=[(p.communicate(timeout=45)[0],p.returncode) for p in ps]
 assert all(code==0 for _,code in results),results
 pid=pathlib.Path(h,".v-browser/server.pid").read_text().strip()
 for port in ports:
  listeners=subprocess.check_output(["lsof","-nP","-t",f"-iTCP:{port}","-sTCP:LISTEN"],env=e,text=True).strip()
  assert listeners==pid,(pid,listeners)
finally:
 stopped=subprocess.run([b,"server","stop"],env=e,capture_output=True,text=True,timeout=20)
 assert stopped.returncode==0,(stopped.stdout,stopped.stderr)
'
	result := os.execute('/usr/bin/python3 -c ${shell_quote(script)} ${shell_quote(home)} ${shell_quote(binary)}')
	assert result.exit_code == 0, result.output
}
