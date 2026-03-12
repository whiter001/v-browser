module main

import time

fn noop_send(_ string) ! {}

fn test_parse_cli_to_ipc_connect_routes_to_connect() {
	method, params := parse_cli_to_ipc('connect', [])
	assert method == 'connect'
	assert params == '{}'
}

fn test_parse_cli_to_ipc_frame_routes_selector() {
	method, params := parse_cli_to_ipc('frame', ['#child'])
	assert method == 'frame'
	assert params == '{"selector":"#child"}'
}

fn test_parse_cli_to_ipc_set_device_routes_value() {
	method, params := parse_cli_to_ipc('set', ['device', 'iPhone', '14'])
	assert method == 'set'
	assert params == '{"property":"device","value":"iPhone 14"}'
}

fn test_build_extension_connect_url_contains_expected_query() {
	url := build_extension_connect_url('abc123', 'tok-1')
	assert url.starts_with('chrome-extension://abc123/connect.html?')
	assert url.contains('protocolVersion=1')
	assert url.contains('token=tok-1')
	assert url.contains('mcpRelayUrl=')
	assert url.contains('client=')
}

fn test_browser_open_candidates_prefer_explicit_app() {
	candidates := browser_open_candidates('Google Chrome Canary')
	assert candidates.len == 4
	assert candidates[0] == 'Google Chrome Canary'
	assert candidates[1] == 'Google Chrome'
	assert candidates[2] == 'Microsoft Edge'
	assert candidates[3] == 'Chromium'
}

fn test_build_macos_open_command_quotes_arguments() {
	cmd := build_macos_open_command('Google Chrome', "chrome-extension://abc/connect.html?token=o'hara")
	assert cmd == "open -a 'Google Chrome' 'chrome-extension://abc/connect.html?token=o'\\''hara'"
}

fn test_build_pueue_add_command_quotes_arguments() {
	$if windows {
		cmd := build_pueue_add_command('C:\\Program Files\\v-browser\\v-browser.exe')
		assert cmd == 'pueue add --immediate --print-task-id --label "v-browser server" --working-directory "C:\\Program Files\\v-browser" --escape "C:\\Program Files\\v-browser\\v-browser.exe" server'
	} $else {
		cmd := build_pueue_add_command('/tmp/v browser/v-browser')
		assert cmd == "pueue add --immediate --print-task-id --label 'v-browser server' --working-directory '/tmp/v browser' --escape '/tmp/v browser/v-browser' server"
	}
}

fn test_build_windows_open_command_supports_default_or_explicit_browser() {
	$if windows {
		default_cmd := build_windows_open_command('chrome-extension://abc/connect.html?token=tok-1&x=1',
			'')
		assert default_cmd == 'cmd /c start "" "chrome-extension://abc/connect.html?token=tok-1&x=1"'
		explicit_cmd := build_windows_open_command('chrome-extension://abc/connect.html?token=tok-1&x=1',
			'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe')
		assert explicit_cmd == 'cmd /c start "" "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" "chrome-extension://abc/connect.html?token=tok-1&x=1"'
	} $else {
		assert true
	}
}

fn test_shell_quote_escapes_single_quotes() {
	assert shell_quote("a'b") == "'a'\\''b'"
}

fn test_build_storage_restore_script_contains_store_and_payload() {
	script := build_storage_restore_script('localStorage', '{"token":"abc"}')
	assert script.contains('localStorage.clear()')
	assert script.contains('localStorage.setItem(key, data[key])')
	assert script.contains('JSON.parse(')
	assert script.contains('token')
}

fn test_parse_cli_to_ipc_wait_variants() {
	method_ms, params_ms := parse_cli_to_ipc('wait', ['1500'])
	assert method_ms == 'wait'
	assert params_ms == '{"ms":1500}'

	method_sel, params_sel := parse_cli_to_ipc('wait', ['#app'])
	assert method_sel == 'wait'
	assert params_sel == '{"selector":"#app"}'
}

fn test_parse_cli_to_ipc_find_builds_semantic_request() {
	method, params := parse_cli_to_ipc('find', ['--role', 'button', '--name', 'Save', '--click'])
	assert method == 'find'
	assert params.contains('"locator":"role"')
	assert params.contains('"query":"button"')
	assert params.contains('"action":"click"')
	assert params.contains('"name":"Save"')
}

fn test_parse_cli_to_ipc_find_supports_positional_nth() {
	method, params := parse_cli_to_ipc('find', ['nth', '2', '.item', 'text'])
	assert method == 'find'
	assert params.contains('"locator":"nth"')
	assert params.contains('"query":".item"')
	assert params.contains('"index":"2"')
	assert params.contains('"action":"text"')
}

fn test_parse_cli_to_ipc_find_supports_positional_alt_fill() {
	method, params := parse_cli_to_ipc('find', ['alt', 'Hero', 'click'])
	assert method == 'find'
	assert params.contains('"locator":"alt"')
	assert params.contains('"query":"Hero"')
	assert params.contains('"action":"click"')
}

fn test_parse_cli_to_ipc_tab_switch_and_window_new() {
	method_tab, params_tab := parse_cli_to_ipc('tab', ['switch', '12'])
	assert method_tab == 'tab'
	assert params_tab == '{"action":"switch","tabId":12,"windowId":0}'

	method_window, params_window := parse_cli_to_ipc('window', ['new', 'https://example.com'])
	assert method_window == 'window'
	assert params_window == '{"action":"new","url":"https://example.com"}'
}

fn test_ipc_request_round_trip() {
	req := IpcRequest{
		id:     42
		method: 'open'
		params: '{"url":"https://example.com","nested":{"ok":true}}'
	}
	decoded := ipc_decode_request(ipc_encode_request(req)) or { panic(err) }
	assert decoded.id == 42
	assert decoded.method == 'open'
	assert decoded.params == '{"url":"https://example.com","nested":{"ok":true}}'
}

fn test_ipc_response_round_trip() {
	resp := IpcResponse{
		id:     9
		result: '{"ok":true}'
	}
	decoded := ipc_decode_response(ipc_encode_response(resp)) or { panic(err) }
	assert decoded.id == 9
	assert decoded.result == '{"ok":true}'
	assert decoded.err == ''
}

fn test_cdp_parse_message_parses_error_object() {
	resp := cdp_parse_message('{"id":7,"error":{"code":-32000,"message":"boom"}}')
	assert resp.id == 7
	assert resp.err == 'boom'
}

fn test_cdp_on_message_dispatches_inner_event_and_caches_console() {
	mut sess := new_cdp_session(noop_send)
	ch := sess.subscribe('Runtime.consoleAPICalled')
	defer { sess.unsubscribe('Runtime.consoleAPICalled', ch) }

	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Runtime.consoleAPICalled","params":{"type":"log","args":[{"type":"string","value":"hello"}]}}}')

	select {
		evt := <-ch {
			assert evt.method == 'Runtime.consoleAPICalled'
			assert evt.params.contains('"value":"hello"')
		}
		1 * time.second {
			assert false
		}
	}
	assert sess.console_msgs.len == 1
	assert sess.console_msgs[0].contains('"value":"hello"')
}

fn test_cdp_on_message_tracks_network_requests() {
	mut sess := new_cdp_session(noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"req-1","type":"Document","request":{"url":"https://example.com/","method":"GET"}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.responseReceived","params":{"requestId":"req-1","type":"Document","response":{"url":"https://example.com/","status":200,"statusText":"OK"}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.loadingFinished","params":{"requestId":"req-1"}}}')
	json := sess.network_requests_json('example.com')
	assert json.contains('"requestId":"req-1"')
	assert json.contains('"url":"https://example.com/"')
	assert json.contains('"status":200')
	assert json.contains('"finished":true')
}

fn test_cdp_on_message_routes_pending_response() {
	mut sess := new_cdp_session(noop_send)
	ch := chan ProtocolResponse{cap: 1}
	sess.pending[3] = ch

	sess.on_message('{"id":3,"result":{"ok":true}}')

	select {
		resp := <-ch {
			assert resp.id == 3
			assert resp.result == '{"ok":true}'
		}
		1 * time.second {
			assert false
		}
	}
}

fn test_axref_store_round_trip() {
	mut store := AxRefStore{}
	axref_set(mut store, '@e1', AxRef{
		backend_node_id: 101
		role:            'button'
		name:            'Submit'
	})
	r := axref_get(&store, '@e1') or { panic(err) }
	assert r.backend_node_id == 101
	assert r.role == 'button'
	assert r.name == 'Submit'
	assert axref_is_ref('@e1')
	assert !axref_is_ref('#e1')
	axref_clear(mut store)
	assert axref_get(&store, '@e1') == none
}

fn test_glob_match_and_text_diff() {
	assert glob_match('https://example.com/*', 'https://example.com/path')
	assert !glob_match('https://example.com/*', 'https://other.example.com/path')
	diff := text_diff('a\nb\n', 'a\nc\n')
	assert diff.contains('- b')
	assert diff.contains('+ c')
}

fn test_server_dispatch_status_and_connect_without_extension() {
	mut server := VBrowserServer{}
	status := server.dispatch(IpcRequest{ id: 1, method: 'status', params: '{}' })
	assert status.err == ''
	assert status.result == '{"connected":false}'

	connect := server.dispatch(IpcRequest{ id: 2, method: 'connect', params: '{}' })
	assert connect.result == ''
	assert connect.err.contains('no extension connected')
}

fn test_extract_query_param_and_validate_extension_token() {
	assert extract_query_param('/?token=abc123&x=1', 'token') == 'abc123'
	assert extract_query_param('/connect?x=1&token=zzz', 'token') == 'zzz'
	assert extract_query_param('/connect', 'token') == ''
	assert validate_extension_token('/?token=match', 'match')
	assert !validate_extension_token('/?token=mismatch', 'match')
	assert !validate_extension_token('/connect', 'match')
}

fn test_build_document_scope_js_wraps_frame_context() {
	mut sess := new_cdp_session(noop_send)
	sess.current_frame_selector = '#child'
	js := build_document_scope_js(sess, 'return doc ? true : false;')
	assert js.contains('document.querySelector("#child")')
	assert js.contains('contentDocument')
	assert js.contains('return doc ? true : false;')
}

fn test_resolve_device_preset_iphone_14() {
	preset := resolve_device_preset('iPhone 14') or { panic(err) }
	assert preset.mobile
	assert preset.has_touch
	assert preset.width == 390
	assert preset.height == 844
	assert preset.user_agent.contains('iPhone')
}

fn test_format_output_wraps_json_mode() {
	assert format_output('{"ok":true}', true) == '{"ok":true,"result":{"ok":true}}'
	assert format_output('plain text', true) == '{"ok":true,"result":"plain text"}'
}

fn test_error_code_maps_common_failures() {
	assert error_code('missing selector') == 'INVALID_ARGUMENT'
	assert error_code('element not found: #missing') == 'NOT_FOUND'
	assert error_code('no extension connected') == 'NOT_CONNECTED'
	assert error_code('CDP command timed out') == 'TIMEOUT'
}
