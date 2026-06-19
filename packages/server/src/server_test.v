module main

import os
import net
import time
import encoding.base64

fn noop_send(_ string) ! {}

fn runtime_eval_ok_result(id int, value string) string {
	return '{"id":${id},"result":{"result":{"type":"string","value":${json_str(value)}}}}'
}

fn empty_cdp_result(id int) string {
	return '{"id":${id},"result":{}}'
}

fn attach_runtime_mock_send(mut sess CdpSession, mut sent []string, runtime_eval_value string) {
	sess.send_fn = fn [mut sess, mut sent, runtime_eval_value] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := cdp_extract_str(data, 'method')
		response := if method == 'Runtime.evaluate' {
			runtime_eval_ok_result(id, runtime_eval_value)
		} else {
			empty_cdp_result(id)
		}
		sess.on_message(response)
	}
}

fn network_body_result_json(body string, base64_encoded bool) string {
	return '{"body":${json_str(body)},"base64Encoded":${base64_encoded}}'
}

fn attach_network_body_mock_send(mut sess CdpSession, mut sent []string, expected_request_id string, response_result string) {
	sess.send_fn = fn [mut sess, mut sent, expected_request_id, response_result] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := cdp_extract_str(data, 'method')
		if method == 'Network.getResponseBody' {
			request_id := cdp_extract_str(data, 'requestId')
			result := if expected_request_id != '' && request_id == expected_request_id {
				response_result
			} else {
				network_body_result_json('', false)
			}
			sess.on_message('{"id":${id},"result":${result}}')
			return
		}
		sess.on_message(empty_cdp_result(id))
	}
}

fn fake_eval_stdin_reader() !string {
	return 'const answer = 42;\nconsole.log(answer);\n'
}

fn fake_eval_file_reader(path string) !string {
	return '// loaded from ${path}\nwindow.__ok = true;\n'
}

fn failing_eval_file_reader(path string) !string {
	return error('cannot read ${path}')
}

fn mock_send_ipc_attach_conflict_no_status(method string, params string) !string {
	if method == 'connect' {
		return error('Debugger conflict: another debugger is already attached to the tab.')
	}
	panic('unexpected IPC method: ${method} ${params}')
}

fn test_parse_cli_to_ipc_connect_routes_to_connect() {
	method, params := parse_cli_to_ipc('connect', []string{}, false)
	assert method == 'connect'
	assert params == '{}'
}

fn test_parse_cli_to_ipc_connect_routes_tab_and_window_ids() {
	method, params := parse_cli_to_ipc('connect', ['--tab-id', '12', '--window-id', '34'], false)
	assert method == 'connect'
	assert params == '{"tabId":12,"windowId":34}'
}

fn test_build_connect_ipc_params_includes_tab_window_and_url() {
	params := build_connect_ipc_params(12, 34, 'https://example.com/path')
	assert params == '{"tabId":12,"windowId":34,"url":"https://example.com/path"}'
}

fn test_parse_cli_to_ipc_frame_routes_selector() {
	method, params := parse_cli_to_ipc('frame', ['#child'], false)
	assert method == 'frame'
	assert params == '{"selector":"#child"}'
}

fn test_parse_cli_to_ipc_set_device_routes_value() {
	method, params := parse_cli_to_ipc('set', ['device', 'iPhone', '14'], false)
	assert method == 'set'
	assert params == '{"property":"device","value":"iPhone 14"}'
}

fn test_parse_cli_to_ipc_snapshot_routes_extra_and_max_nodes() {
	method, params := parse_cli_to_ipc('snapshot', ['--extra', '--maxNodes', '25'], false)
	assert method == 'snapshot'
	assert params == '{"raw":false,"extra":true,"interactive":false,"maxNodes":25}'
}

fn test_parse_cli_to_ipc_snapshot_routes_selector_when_present() {
	method, params := parse_cli_to_ipc('snapshot', ['--selector', '#hero'], false)
	assert method == 'snapshot'
	assert params == '{"raw":false,"extra":false,"interactive":false,"maxNodes":0,"selector":"#hero"}'
}

fn test_build_extension_connect_url_contains_expected_query() {
	url := build_extension_connect_url('abc123', 'tok-1')
	assert url.starts_with('chrome-extension://abc123/connect.html?')
	assert url.contains('protocolVersion=1')
	assert url.contains('token=tok-1')
	assert url.contains('mcpRelayUrl=')
	assert url.contains('client=')
}

fn test_extract_connect_target_url_prefers_flag_and_positional_url() {
	assert extract_connect_target_url(['--url', 'https://x.com/a']) == 'https://x.com/a'
	assert extract_connect_target_url(['https://wx.mail.qq.com/home/index#/notepad']) == 'https://wx.mail.qq.com/home/index#/notepad'
	assert extract_connect_target_url(['--tab-id', '12']) == ''
	assert extract_connect_target_url([]) == ''
}

fn test_find_best_tab_for_url_from_json_prefers_matching_tab_then_last_tab_fallback() {
	tabs_json := '[{"id":11,"windowId":1,"title":"A","url":"https://x.com/a","active":false},{"id":22,"windowId":2,"title":"B","url":"https://wx.mail.qq.com/home/index#/notepad","active":true},{"id":33,"windowId":3,"title":"C","url":"https://x.com/a","active":true}]'
	tab_id, window_id := find_best_tab_for_url_from_json(tabs_json, 'https://x.com/a') or {
		panic(err)
	}
	assert tab_id == 33
	assert window_id == 3

	last_tab_id, last_window_id := find_best_tab_for_url_from_json(tabs_json, '') or { panic(err) }
	assert last_tab_id == 33
	assert last_window_id == 3
}

fn test_find_best_tab_for_url_from_json_ignores_extension_tabs_when_selecting() {
	tabs_json := '[{"id":11,"windowId":1,"title":"Ext","url":"chrome-extension://pcomgagjilgkfioemopicalioepnanjj/connect.html","active":true},{"id":22,"windowId":2,"title":"X","url":"https://x.com/AI_Jasonyu/status/2034524961835225265","active":false}]'
	tab_id, window_id := find_best_tab_for_url_from_json(tabs_json, '') or { panic(err) }
	assert tab_id == 22
	assert window_id == 2
}

fn test_find_best_tab_for_url_from_json_falls_back_to_last_connectable_tab_when_no_match() {
	tabs_json := '[{"id":11,"windowId":1,"title":"A","url":"https://x.com/a","active":false},{"id":22,"windowId":2,"title":"B","url":"https://wx.mail.qq.com/home/index#/notepad","active":true},{"id":33,"windowId":3,"title":"C","url":"https://y.com/b","active":false}]'
	tab_id, window_id := find_best_tab_for_url_from_json(tabs_json, 'https://missing.example/path') or {
		panic(err)
	}
	assert tab_id == 33
	assert window_id == 3
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
	cmd := build_macos_open_command('Google Chrome',
		"chrome-extension://abc/connect.html?token=o'hara")
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
		default_cmd :=
			build_windows_open_command('chrome-extension://abc/connect.html?token=tok-1&x=1', '')
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

fn test_screenshot_diff_js_contains_expected_fields() {
	js := screenshot_diff_js('Zm9v', 'image/png', 'YmFy', 0.1, true)
	assert js.contains('changedPixels')
	assert js.contains('totalPixels')
	assert js.contains('diffData')
	assert js.contains('data:image/png;base64,YmFy')
}

fn test_parse_cli_to_ipc_wait_variants() {
	method_ms, params_ms := parse_cli_to_ipc('wait', ['1500'], false)
	assert method_ms == 'wait'
	assert params_ms == '{"ms":1500}'

	method_sel, params_sel := parse_cli_to_ipc('wait', ['#app'], false)
	assert method_sel == 'wait'
	assert params_sel == '{"selector":"#app"}'
}

fn test_parse_cli_to_ipc_wait_download_variant() {
	method, params := parse_cli_to_ipc('wait',
		['--download', './report.pdf', '--timeout', '45000'], false)
	assert method == 'wait'
	assert params == '{"download":"./report.pdf","timeout":45000}'
}

fn test_parse_cli_to_ipc_download_routes_selector_and_path() {
	method, params := parse_cli_to_ipc('download', ['#export', './report.csv'], false)
	assert method == 'download'
	assert params == '{"selector":"#export","path":"./report.csv"}'
}

fn test_parse_cli_to_ipc_diff_screenshot_variants() {
	method, params := parse_cli_to_ipc('diff', ['screenshot', '--baseline', 'before.png', '-o',
		'diff.png', '-t', '0.2', '--selector', '#hero', '--full'], false)
	assert method == 'diff'
	assert params.contains('"type":"screenshot"')
	assert params.contains('"baseline":"before.png"')
	assert params.contains('"output":"diff.png"')
	assert params.contains('"threshold":0.2')
	assert params.contains('"selector":"#hero"')
	assert params.contains('"full":"true"')
}

fn test_parse_cli_to_ipc_diff_url_variants() {
	method, params := parse_cli_to_ipc('diff', ['url', 'https://a.test', 'https://b.test',
		'--screenshot', '--full', '--wait-until', 'networkidle'], false)
	assert method == 'diff'
	assert params.contains('"type":"url"')
	assert params.contains('"url1":"https://a.test"')
	assert params.contains('"url2":"https://b.test"')
	assert params.contains('"screenshot":"true"')
	assert params.contains('"full":"true"')
	assert params.contains('"waitUntil":"networkidle"')
}

fn test_parse_cli_to_ipc_network_save_variants() {
	method, params := parse_cli_to_ipc('network', ['save', 'req-1', './out/image'], false)
	assert method == 'network'
	assert params.contains('"action":"save"')
	assert params.contains('"requestId":"req-1"')
	assert params.contains('"path":"./out/image"')
}

fn test_parse_cli_to_ipc_network_save_images_variants() {
	method, params := parse_cli_to_ipc('network', ['save-images', './out/images'], false)
	assert method == 'network'
	assert params.contains('"action":"save-images"')
	assert params.contains('"path":"./out/images"')
}

fn test_parse_cli_to_ipc_network_watch_variants() {
	method_start, params_start := parse_cli_to_ipc('network', ['watch', 'start', './out/watch'],
		false)
	assert method_start == 'network'
	assert params_start.contains('"action":"watch"')
	assert params_start.contains('"subaction":"start"')
	assert params_start.contains('"path":"./out/watch"')

	method_status, params_status := parse_cli_to_ipc('network', ['watch', 'status'], false)
	assert method_status == 'network'
	assert params_status.contains('"action":"watch"')
	assert params_status.contains('"subaction":"status"')

	method_stop, params_stop := parse_cli_to_ipc('network', ['watch', 'stop'], false)
	assert method_stop == 'network'
	assert params_stop.contains('"action":"watch"')
	assert params_stop.contains('"subaction":"stop"')
}

fn test_parse_cli_to_ipc_network_hook_variants() {
	method_start, params_start := parse_cli_to_ipc('network', ['hook', 'start', '--capture-body',
		'--capture-response', '--script-id', 'hook-v1'], false)
	assert method_start == 'network'
	assert params_start.contains('"action":"hook"')
	assert params_start.contains('"subaction":"start"')
	assert params_start.contains('"captureBody":"true"')
	assert params_start.contains('"captureResponse":"true"')
	assert params_start.contains('"scriptId":"hook-v1"')

	method_status, params_status := parse_cli_to_ipc('network', ['hook', 'status'], false)
	assert method_status == 'network'
	assert params_status.contains('"action":"hook"')
	assert params_status.contains('"subaction":"status"')

	method_records, params_records := parse_cli_to_ipc('network', ['hook', 'records', '--filter',
		'home', '--limit', '5'], false)
	assert method_records == 'network'
	assert params_records.contains('"action":"hook"')
	assert params_records.contains('"subaction":"records"')
	assert params_records.contains('"filter":"home"')

	method_replay, params_replay := parse_cli_to_ipc('network', ['hook', 'replay', 'record-1',
		'--method', 'POST', '--override-url', 'https://x.com/i/api/test', '--override-body',
		'{"foo":1}', '--override-headers', '{"x-test":"1"}', '--dry-run'], false)
	assert method_replay == 'network'
	assert params_replay.contains('"action":"hook"')
	assert params_replay.contains('"subaction":"replay"')
	assert params_replay.contains('"recordId":"record-1"')
	assert params_replay.contains('"method":"POST"')
	assert params_replay.contains('"overrideUrl":"https://x.com/i/api/test"')
	assert params_replay.contains('"overrideBody":"{\\"foo\\":1}"')
	assert params_replay.contains('"overrideHeaders":"{\\"x-test\\":\\"1\\"}"')
	assert params_replay.contains('"dryRun":"true"')
}

fn test_network_hook_replay_url_from_params_prefers_override_url() {
	record := HookRecord{
		record_id: 'record-1'
		raw_json:  '{"recordId":"record-1","method":"GET","url":"https://x.com/original"}'
	}
	params := '{"overrideUrl":"https://x.com/override","url":"https://x.com/legacy"}'
	assert network_hook_replay_url_from_params(params, record) == 'https://x.com/override'
	assert network_hook_replay_url_from_params('{"url":"https://x.com/legacy"}', record) == 'https://x.com/legacy'
	assert network_hook_replay_url_from_params('{}', record) == 'https://x.com/original'
}

fn test_network_hook_bootstrap_js_includes_extended_record_fields() {
	js := network_hook_bootstrap_js()
	assert js.contains('__vBrowserHookActive')
	assert js.contains('localStorage.getItem')
	assert js.contains('sessionStorage.getItem')
	assert js.contains('requestMode')
	assert js.contains('requestCredentials')
	assert js.contains('requestCache')
	assert js.contains('requestRedirect')
	assert js.contains('requestReferrer')
	assert js.contains('requestReferrerPolicy')
	assert js.contains('requestIntegrity')
	assert js.contains('requestKeepalive')
	assert js.contains('requestPriority')
	assert js.contains('signature')
	assert js.contains('statusText')
	assert js.contains('responseUrl')
	assert js.contains('responseOk')
	assert js.contains('responseType')
	assert js.contains('readyState')
	assert js.contains('withCredentials')
}

fn test_network_hook_status_json_from_state_renders_record_count() {
	state := HookState{
		active:            true
		injected:          true
		script_id:         'hook-v1'
		script_version:    2
		filter:            'MiniMax'
		capture_body:      true
		capture_response:  true
		last_injected_at:  '1774041973915'
		last_synced_index: 5
		record_count:      12
	}
	json := network_hook_status_json_from_state(state)
	assert json.contains('"active":true')
	assert json.contains('"injected":true')
	assert json.contains('"scriptId":"hook-v1"')
	assert json.contains('"scriptVersion":2')
	assert json.contains('"filter":"MiniMax"')
	assert json.contains('"captureBody":true')
	assert json.contains('"captureResponse":true')
	assert json.contains('"lastInjectedAt":"1774041973915"')
	assert json.contains('"lastSyncedIndex":5')
	assert json.contains('"recordCount":12')
}

fn test_build_network_replay_js_includes_headers_and_overrides() {
	js := build_network_replay_js('POST', 'https://x.com/i/api/test', '{"foo":1}',
		'{"accept":"application/json"}', '{"x-test":"1"}')
	assert js.contains('mergeHeaders')
	assert js.contains('requestHeaders: headers')
	assert js.contains('init.headers = headers')
	assert js.contains('credentials: "include"')
	assert js.contains('captureDomFallback')
	assert js.contains('replayKind: "dom-fallback"')
	assert js.contains('document.body.innerText')
	assert js.contains('if (!response.ok)')
}

fn test_network_hook_control_js_persists_active_flag() {
	start_js := build_network_replay_js('GET', 'https://x.com', '', '{}', '{}')
	assert start_js.contains('replayKind')
	start_hook_js := network_hook_bootstrap_js()
	assert start_hook_js.contains('localStorage.getItem')
	assert start_hook_js.contains('__vBrowserHookActive')
}

fn test_hook_json_object_keys_extracts_top_level_keys() {
	keys := hook_json_object_keys('{"a":1,"b":{"c":2},"d":"x"}')
	assert keys == ['a', 'b', 'd']
}

fn test_hook_template_json_serializes_expected_fields() {
	template := hook_template_from_signature('POST https://x.com/i/api/test', 'POST',
		'https://x.com/i/api/test', '["accept"]', '{"foo":1}', '["captureBody":true]',
		'{"status":200}', ['record-1'], '{}')
	json := hook_template_json(template)
	assert json.contains('"templateId":"tpl-post-https-x.com-i-api-test"')
	assert json.contains('"requestSignature":"POST https://x.com/i/api/test"')
	assert json.contains('"method":"POST"')
	assert json.contains('"urlPattern":"https://x.com/i/api/test"')
	assert json.contains('"requiredHeaders":["accept"]')
	assert json.contains('"bodyTemplate":"{\\"foo\\":1}"')
	assert json.contains('"expectedResponseShape":{"status":200}')
	assert json.contains('"sampleRecordId":"record-1"')
}

fn test_hook_record_view_json_includes_fallback_text() {
	record := HookRecord{
		record_id: 'rec-99'
		raw_json:  '{"recordId":"rec-99","source":"fetch","phase":"complete","pageUrl":"https://x.com","method":"GET","url":"https://x.com/api","requestHeaders":"{}","responseHeaders":"{}","fallbackText":"home timeline data"}'
	}
	view := hook_record_view_from_raw(record)
	assert view.fallback_text == 'home timeline data'
	json := hook_record_view_json(view)
	assert json.contains('"fallbackText":"home timeline data"')
}

fn test_hook_record_view_prefers_record_fallback_text_field() {
	record := HookRecord{
		record_id:     'rec-100'
		raw_json:      '{"recordId":"rec-100","source":"fetch","phase":"complete","pageUrl":"https://x.com","method":"GET","url":"https://x.com/api","requestHeaders":"{}","responseHeaders":"{}"}'
		fallback_text: 'from hook record field'
	}
	view := hook_record_view_from_raw(record)
	assert view.fallback_text == 'from hook record field'
	json := hook_record_view_json(view)
	assert json.contains('"fallbackText":"from hook record field"')
}

fn test_hook_record_matches_filter_searches_fallback_text() {
	record := HookRecord{
		record_id: 'rec-1'
		raw_json:  '{"recordId":"rec-1","source":"fetch","phase":"complete","pageUrl":"https://x.com","method":"GET","url":"https://x.com/api","requestHeaders":"{}","responseHeaders":"{}","fallbackText":"timeline snapshot"}'
	}
	view := hook_record_view_from_raw(record)
	assert hook_record_matches_filter(view, 'timeline snapshot')
	assert hook_record_matches_filter(view, 'timeline')
	assert !hook_record_matches_filter(view, 'nomatch')
}

fn test_network_hook_bootstrap_js_parses_xhr_response_headers() {
	js := network_hook_bootstrap_js()
	assert js.contains('parseXhrHeaders')
	assert js.contains('getAllResponseHeaders')
	assert js.contains('responseHeaders: parseXhrHeaders')
}

fn test_network_hook_bootstrap_js_uses_response_headers_for_fetch() {
	js := network_hook_bootstrap_js()
	// fetch path should use toPlainHeaders on response.headers
	assert js.contains('toPlainHeaders(response.headers)')
	assert js.contains('if (!cfg.captureResponse || !response || typeof response.clone !== "function")')
}

fn test_parse_cli_to_ipc_fill_and_upload_include_verify_flags() {
	fill_method, fill_params := parse_cli_to_ipc('fill', ['--selector', '#editor', '--text', 'Hello',
		'--verify', '--verify-timeout', '2750'], false)
	assert fill_method == 'fill'
	assert fill_params.contains('"selector":"#editor"')
	assert fill_params.contains('"text":"Hello"')
	assert fill_params.contains('"verify":"true"')
	assert fill_params.contains('"verifyTimeout":2750')

	type_method, type_params := parse_cli_to_ipc('type', ['--selector', '#editor', '--text', 'Hello',
		'--verify'], false)
	assert type_method == 'type'
	assert type_params.contains('"selector":"#editor"')
	assert type_params.contains('"text":"Hello"')
	assert type_params.contains('"verify":"true"')
	assert type_params.contains('"verifyTimeout":1500')

	upload_method, upload_params := parse_cli_to_ipc('upload', ['--selector', 'input[type=file]',
		'--files', './a.txt,./b.txt', '--verify'], false)
	assert upload_method == 'upload'
	assert upload_params.contains('"selector":"input[type=file]"')
	assert upload_params.contains('"files":"./a.txt,./b.txt"')
	assert upload_params.contains('"verify":"true"')
	assert upload_params.contains('"verifyTimeout":1500')
	assert upload_params.contains('"waitPreview":"false"')
	assert upload_params.contains('"previewSelector":""')

	upload_preview_method, upload_preview_params := parse_cli_to_ipc('upload', [
		'--selector',
		'input[type=file]',
		'--files',
		'./a.txt',
		'--wait-preview',
		'--preview-selector',
		'#uploadPreview',
	], false)
	assert upload_preview_method == 'upload'
	assert upload_preview_params.contains('"waitPreview":"true"')
	assert upload_preview_params.contains('"previewSelector":"#uploadPreview"')
}

fn test_parse_cli_to_ipc_find_builds_semantic_request() {
	method, params := parse_cli_to_ipc('find', ['--role', 'button', '--name', 'Save', '--click'],
		false)
	assert method == 'find'
	assert params.contains('"locator":"role"')
	assert params.contains('"query":"button"')
	assert params.contains('"action":"click"')
	assert params.contains('"name":"Save"')
}

fn test_parse_cli_to_ipc_find_supports_positional_nth() {
	method, params := parse_cli_to_ipc('find', ['nth', '2', '.item', 'text'], false)
	assert method == 'find'
	assert params.contains('"locator":"nth"')
	assert params.contains('"query":".item"')
	assert params.contains('"index":"2"')
	assert params.contains('"action":"text"')
}

fn test_parse_cli_to_ipc_find_supports_positional_alt_fill() {
	method, params := parse_cli_to_ipc('find', ['alt', 'Hero', 'click'], false)
	assert method == 'find'
	assert params.contains('"locator":"alt"')
	assert params.contains('"query":"Hero"')
	assert params.contains('"action":"click"')
}

fn test_parse_cli_to_ipc_find_supports_text_debug_mode() {
	method, params := parse_cli_to_ipc('find', ['text', 'Nightly Build', '--debug'], false)
	assert method == 'find'
	assert params.contains('"locator":"text"')
	assert params.contains('"query":"Nightly Build"')
	assert params.contains('"debug":"true"')
	assert params.contains('"list":"false"')
}

fn test_parse_cli_to_ipc_find_supports_text_list_and_index() {
	method, params := parse_cli_to_ipc('find', ['text', 'Nightly Build', '--list', '--index', '2'],
		false)
	assert method == 'find'
	assert params.contains('"locator":"text"')
	assert params.contains('"query":"Nightly Build"')
	assert params.contains('"list":"true"')
	assert params.contains('"index":"2"')
}

fn test_parse_cli_to_ipc_keyboard_routes_type_and_inserttext() {
	method_type, params_type := parse_cli_to_ipc('keyboard', ['type', 'Hello'], false)
	assert method_type == 'keyboard'
	assert params_type == '{"action":"type","text":"Hello"}'

	method_insert, params_insert := parse_cli_to_ipc('keyboard', ['inserttext', 'Hello'], false)
	assert method_insert == 'keyboard'
	assert params_insert == '{"action":"inserttext","text":"Hello"}'
}

fn test_parse_cli_to_ipc_tab_switch_and_window_new() {
	method_tab, params_tab := parse_cli_to_ipc('tab', ['switch', '12'], false)
	assert method_tab == 'tab'
	assert params_tab == '{"action":"switch","tabId":12,"windowId":0}'

	method_window, params_window := parse_cli_to_ipc('window', ['new', 'https://example.com'],
		false)
	assert method_window == 'window'
	assert params_window == '{"action":"new","url":"https://example.com"}'
}

fn test_tab_context_save_and_restore_keeps_per_tab_state() {
	mut sess := new_cdp_session(noop_send)
	sess.current_tab_id = 11
	sess.current_frame_selector = '#article'
	sess.axref.refs = {
		'@e1': AxRef{
			backend_node_id: 1
			node_id:         2
			selector:        '#article'
			name:            'article'
		}
	}
	sess.network_requests = {
		'req-1': TrackedNetworkRequest{
			request_id: 'req-1'
			url:        'https://example.com/a.png'
			finished:   true
		}
	}
	sess.network_request_order = ['req-1']
	sess.network_watch = NetworkWatchState{
		active:            true
		target_dir:        '/tmp/tab-11'
		filter:            'image'
		candidate_urls:    {
			'https://example.com/a.png': true
		}
		saved_request_ids: {
			'req-1': true
		}
		next_index:        1
	}
	sess.console_msgs = ['console-11']
	sess.page_errors = ['page-11']
	sess.dialog_events = ['dialog-11']
	sess.save_current_tab_context()

	sess.current_tab_id = 22
	sess.current_frame_selector = '#other'
	sess.axref.refs = {}
	sess.network_requests = {}
	sess.network_request_order = []
	sess.network_watch = NetworkWatchState{
		candidate_urls:    {}
		saved_request_ids: {}
	}
	sess.console_msgs = []
	sess.page_errors = []
	sess.dialog_events = []

	sess.restore_tab_context(11)

	assert sess.current_frame_selector == '#article'
	assert '@e1' in sess.axref.refs
	assert sess.axref.refs['@e1'] or { panic('missing axref') }.selector == '#article'
	assert sess.network_requests['req-1'] or { panic('missing request') }.url == 'https://example.com/a.png'
	assert sess.network_request_order == ['req-1']
	assert sess.network_watch.active
	assert sess.network_watch.target_dir == '/tmp/tab-11'
	assert sess.network_watch.filter == 'image'
	assert 'https://example.com/a.png' in sess.network_watch.candidate_urls
	assert sess.network_watch.saved_request_ids['req-1']
	assert sess.network_watch.next_index == 1
	assert sess.console_msgs == ['console-11']
	assert sess.page_errors == ['page-11']
	assert sess.dialog_events == ['dialog-11']
}

fn test_parse_cli_to_ipc_eval_supports_file_input() {
	method, params := parse_cli_to_ipc_with_readers('eval', ['--file', 'script.js'], false,
		fake_eval_stdin_reader, fake_eval_file_reader)
	assert method == 'eval'
	assert params.contains('"expression":"// loaded from script.js\\nwindow.__ok = true;"')
	assert params.contains('"readError":""')
	assert params.contains('"base64":"false"')
}

fn test_parse_cli_to_ipc_eval_supports_stdin_shorthand() {
	method, params := parse_cli_to_ipc_with_readers('eval', ['-'], false, fake_eval_stdin_reader,
		fake_eval_file_reader)
	assert method == 'eval'
	assert params.contains('const answer = 42;')
	assert params.contains('console.log(answer);')
	assert params.contains('"readError":""')
}

fn test_parse_cli_to_ipc_eval_supports_base64_long_flag() {
	method, params := parse_cli_to_ipc_with_readers('eval', ['--base64', 'YWxlcnQoMSk='], false,
		fake_eval_stdin_reader, fake_eval_file_reader)
	assert method == 'eval'
	assert params.contains('"expression":"YWxlcnQoMSk="')
	assert params.contains('"base64":"true"')
}

fn test_parse_cli_to_ipc_eval_reports_file_read_error() {
	method, params := parse_cli_to_ipc_with_readers('eval', ['--file', 'missing.js'], false,
		fake_eval_stdin_reader, failing_eval_file_reader)
	assert method == 'eval'
	assert params.contains('"expression":""')
	assert params.contains('failed to read eval file missing.js: cannot read missing.js')
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

fn test_parse_extension_registration_extracts_runtime_id() {
	extension_id :=
		parse_extension_registration('{"method":"registerExtension","params":{"extensionId":"pcomgagjilgkfioemopicalioepnanjj"}}')
	assert extension_id == 'pcomgagjilgkfioemopicalioepnanjj'
}

fn test_parse_extension_registration_ignores_regular_protocol_messages() {
	extension_id := parse_extension_registration('{"id":1,"method":"attachToTab","params":{}}')
	assert extension_id == ''
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
	json := sess.network_requests_json(NetworkFilter{ url: 'example.com' }, 0)
	assert json.contains('"requestId":"req-1"')
	assert json.contains('"url":"https://example.com/"')
	assert json.contains('"status":200')
	assert json.contains('"finished":true')
}

fn test_cdp_on_message_prefers_extra_info_headers_and_status() {
	mut sess := new_cdp_session(noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.responseReceivedExtraInfo","params":{"requestId":"req-1","statusCode":304,"headers":{"content-type":"application/json","set-cookie":"sid=1"}}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.responseReceived","params":{"requestId":"req-1","type":"XHR","response":{"url":"https://example.com/api","status":200,"statusText":"OK","headers":{"content-type":"application/json"}}}}}')
	headers := sess.get_response_headers('req-1') or { panic(err) }
	entry := sess.network_requests['req-1'] or { panic('missing request') }
	assert entry.status == 304
	assert headers.contains('"set-cookie":"sid=1"')
	assert entry.response_headers_complete
	assert entry.status_from_extra
}

fn test_cdp_on_message_tracks_dialog_events() {
	mut sess := new_cdp_session(noop_send)
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Page.javascriptDialogOpening","params":{"url":"http://127.0.0.1:48280/lab.html","message":"fixture prompt","type":"prompt","hasBrowserHandler":true,"defaultPrompt":"prefilled"}}}')
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Page.javascriptDialogClosed","params":{"result":true,"userInput":"typed by v-browser"}}}')
	assert sess.dialog_events.len == 2
	assert sess.dialog_events[0].contains('Page.javascriptDialogOpening')
	assert sess.dialog_events[0].contains('fixture prompt')
	assert sess.dialog_events[1].contains('Page.javascriptDialogClosed')
	assert sess.dialog_events[1].contains('typed by v-browser')
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
		selector:        '.submit'
		role:            'button'
		name:            'Submit'
	})
	r := axref_get(&store, '@e1') or { panic(err) }
	assert r.backend_node_id == 101
	assert r.selector == '.submit'
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
	assert status.result.contains('"connected":false')
	assert status.result.contains('"extensionConnected":false')
	assert status.result.contains('"attached":false')

	connect := server.dispatch(IpcRequest{ id: 2, method: 'connect', params: '{}' })
	assert connect.result == ''
	assert connect.err.contains('no extension connected')
}

fn test_server_dispatch_status_reports_attached_when_session_is_active() {
	mut server := VBrowserServer{}
	mut sess := new_cdp_session(noop_send)
	sess.page_enabled = true
	server.ext_conn = &ExtensionConn{
		session: sess
	}
	status := server.dispatch(IpcRequest{ id: 1, method: 'status', params: '{}' })
	assert status.err == ''
	assert status.result.contains('"connected":true')
	assert status.result.contains('"extensionConnected":true')
	assert status.result.contains('"attached":true')
}

fn test_extract_query_param_and_validate_extension_token() {
	assert extract_query_param('/?token=abc123&x=1', 'token') == 'abc123'
	assert extract_query_param('/connect?x=1&token=zzz', 'token') == 'zzz'
	assert extract_query_param('/connect', 'token') == ''
	assert validate_extension_token('/?token=match', 'match')
	assert !validate_extension_token('/?token=mismatch', 'match')
	assert !validate_extension_token('/connect', 'match')
}

fn test_server_stop_integration_stops_running_server() {
	$if windows {
		assert true
		return
	}
	bin_path := build_integration_cli_binary() or { panic(err) }
	test_home := new_integration_test_home('stop')
	test_relay_port, test_ipc_port := integration_ports(1)
	defer {
		cleanup_integration_server(bin_path, test_home, test_relay_port, test_ipc_port)
		os.rmdir_all(test_home) or {}
	}

	orig_pid := start_integration_server(bin_path, test_home, test_relay_port, test_ipc_port) or {
		panic(err)
	}
	assert orig_pid > 0
	assert is_integration_process_running(orig_pid)

	stop_result :=
		os.execute('${integration_env_prefix(test_home, test_relay_port, test_ipc_port)} ${shell_quote(bin_path)} server stop')
	assert stop_result.exit_code == 0
	assert stop_result.output.contains('server shutdown via IPC')
		|| stop_result.output.contains('server killed')
	assert wait_for_integration_server_stop(orig_pid, test_relay_port, test_ipc_port,
		5 * time.second)
	assert !is_integration_process_running(orig_pid)
	assert !os.exists(os.join_path(test_home, '.v-browser', 'server.pid'))
}

fn test_server_restart_integration_replaces_running_server() {
	$if windows {
		assert true
		return
	}
	bin_path := build_integration_cli_binary() or { panic(err) }
	test_home := new_integration_test_home('restart')
	test_relay_port, test_ipc_port := integration_ports(2)
	defer {
		cleanup_integration_server(bin_path, test_home, test_relay_port, test_ipc_port)
		os.rmdir_all(test_home) or {}
	}

	orig_pid := start_integration_server(bin_path, test_home, test_relay_port, test_ipc_port) or {
		panic(err)
	}
	assert orig_pid > 0

	restart_result := os.execute('${integration_env_prefix(test_home, test_relay_port,
		test_ipc_port)} ${shell_quote(bin_path)} server restart')
	assert restart_result.exit_code == 0
	assert restart_result.output.contains('Server restarted.')

	new_pid := wait_for_server_pid_file(test_home, orig_pid, 8 * time.second)
	assert new_pid > 0
	assert new_pid != orig_pid
	assert !is_integration_process_running(orig_pid)
	assert is_integration_process_running(new_pid)
	assert wait_for_integration_port_state(test_relay_port, true, 5 * time.second)
	assert wait_for_integration_port_state(test_ipc_port, true, 5 * time.second)
	assert can_reach_integration_ipc(test_ipc_port)
	cleanup_integration_server(bin_path, test_home, test_relay_port, test_ipc_port)
	assert wait_for_integration_server_stop(new_pid, test_relay_port, test_ipc_port,
		5 * time.second)
}

fn test_server_version_mismatch_integration_auto_restarts_server() {
	$if windows {
		assert true
		return
	}
	bin_path := build_integration_cli_binary() or { panic(err) }
	test_home := new_integration_test_home('version-mismatch')
	test_relay_port, test_ipc_port := integration_ports(4)
	version_path := os.join_path(test_home, '.v-browser', 'server.version')
	defer {
		cleanup_integration_server(bin_path, test_home, test_relay_port, test_ipc_port)
		os.rmdir_all(test_home) or {}
	}

	orig_pid := start_integration_server(bin_path, test_home, test_relay_port, test_ipc_port) or {
		panic(err)
	}
	assert orig_pid > 0
	assert os.read_file(version_path) or { '' }.trim_space() == v_browser_version
	os.write_file(version_path, 'stale-version') or { panic(err) }

	status_result :=
		os.execute('${integration_env_prefix(test_home, test_relay_port, test_ipc_port)} ${shell_quote(bin_path)} status')
	assert status_result.exit_code == 0
	assert status_result.output.contains('"connected":false')

	new_pid := wait_for_server_pid_file(test_home, orig_pid, 8 * time.second)
	assert new_pid > 0
	assert new_pid != orig_pid
	assert wait_for_integration_port_state(test_relay_port, true, 5 * time.second)
	assert wait_for_integration_port_state(test_ipc_port, true, 5 * time.second)
	assert can_reach_integration_ipc(test_ipc_port)
	assert os.read_file(version_path) or { '' }.trim_space() == v_browser_version
}

fn test_server_stop_integration_returns_error_when_server_missing() {
	$if windows {
		assert true
		return
	}
	bin_path := build_integration_cli_binary() or { panic(err) }
	test_home := new_integration_test_home('stop-missing')
	test_relay_port, test_ipc_port := integration_ports(3)
	defer { os.rmdir_all(test_home) or {} }

	stop_result :=
		os.execute('${integration_env_prefix(test_home, test_relay_port, test_ipc_port)} ${shell_quote(bin_path)} server stop')
	assert stop_result.exit_code != 0
	assert stop_result.output.contains('no running server found')
}

fn build_integration_cli_binary() !string {
	bin_path := os.join_path(os.temp_dir(), 'v-browser-integration-${os.getpid()}')
	if os.exists(bin_path) {
		return bin_path
	}
	src_dir := os.real_path(os.dir(@FILE))
	result := os.execute('v -o ${shell_quote(bin_path)} ${shell_quote(src_dir)}')
	if result.exit_code != 0 {
		return error('failed to build integration CLI binary: ${result.output}')
	}
	return bin_path
}

fn new_integration_test_home(name string) string {
	stamp := time.now().unix()
	home := os.join_path(os.temp_dir(), 'v-browser-it-${name}-${os.getpid()}-${stamp}')
	os.mkdir_all(home) or { panic(err) }
	return home
}

fn integration_ports(seed int) (int, int) {
	base := 53000 + ((os.getpid() % 1000) * 6) + (seed * 2)
	return base, base + 1
}

fn integration_env_prefix(home string, relay_port int, ipc_port int) string {
	return 'env V_BROWSER_HOME=${shell_quote(home)} V_BROWSER_RELAY_PORT=${shell_quote('${relay_port}')} V_BROWSER_IPC_PORT=${shell_quote('${ipc_port}')}'
}

fn start_integration_server(bin_path string, home string, relay_port int, ipc_port int) !int {
	log_path := os.join_path(home, 'server.log')
	result :=
		os.execute('${integration_env_prefix(home, relay_port, ipc_port)} nohup ${shell_quote(bin_path)} server > ${shell_quote(log_path)} 2>&1 & echo $!')
	if result.exit_code != 0 {
		return error('failed to start integration server: ${result.output}')
	}
	pid := wait_for_server_pid_file(home, 0, 8 * time.second)
	if pid <= 0 {
		return error('integration server did not write server.pid')
	}
	if !wait_for_integration_port_state(relay_port, true, 5 * time.second) {
		return error('integration relay port did not start listening')
	}
	if !wait_for_integration_port_state(ipc_port, true, 5 * time.second) {
		return error('integration IPC port did not start listening')
	}
	return pid
}

fn wait_for_server_pid_file(home string, previous_pid int, timeout time.Duration) int {
	pid_path := os.join_path(home, '.v-browser', 'server.pid')
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		pid_str := os.read_file(pid_path) or {
			time.sleep(100 * time.millisecond)
			continue
		}
		pid := pid_str.trim_space().int()
		if pid > 0 && pid != previous_pid {
			return pid
		}
		time.sleep(100 * time.millisecond)
	}
	return 0
}

fn wait_for_integration_port_state(port int, should_listen bool, timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		listening := can_reach_integration_ipc(port)
		if listening == should_listen {
			return true
		}
		time.sleep(100 * time.millisecond)
	}
	return can_reach_integration_ipc(port) == should_listen
}

fn wait_for_integration_server_stop(pid int, relay_port int, ipc_port int, timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		if !is_integration_process_running(pid) && !can_reach_integration_ipc(relay_port)
			&& !can_reach_integration_ipc(ipc_port) {
			return true
		}
		time.sleep(100 * time.millisecond)
	}
	return !is_integration_process_running(pid) && !can_reach_integration_ipc(relay_port)
		&& !can_reach_integration_ipc(ipc_port)
}

fn can_reach_integration_ipc(port int) bool {
	mut conn := net.dial_tcp('127.0.0.1:${port}') or { return false }
	conn.close() or {}
	return true
}

fn is_integration_process_running(pid int) bool {
	if pid <= 0 {
		return false
	}
	result := os.execute('kill -0 ${pid} 2>/dev/null')
	return result.exit_code == 0
}

fn cleanup_integration_server(bin_path string, home string, relay_port int, ipc_port int) {
	stop_result :=
		os.execute('${integration_env_prefix(home, relay_port, ipc_port)} ${shell_quote(bin_path)} server stop')
	if stop_result.exit_code == 0 {
		return
	}
	pid_path := os.join_path(home, '.v-browser', 'server.pid')
	pid := (os.read_file(pid_path) or { '' }).trim_space().int()
	if pid > 0 {
		os.execute('kill -TERM ${pid} 2>/dev/null')
	}
}

fn test_build_document_scope_js_wraps_frame_context() {
	mut sess := new_cdp_session(noop_send)
	sess.current_frame_selector = '#child'
	js := build_document_scope_js(mut sess, 'return doc ? true : false;')
	assert js.contains('document.querySelector("#child")')
	assert js.contains('contentDocument')
	assert js.contains('return doc ? true : false;')
}

fn test_build_action_point_query_js_checks_actionability() {
	mut sess := new_cdp_session(noop_send)
	js := build_action_point_query_js(mut sess, 'document.querySelector("#submit")')
	assert js.contains('scrollIntoView')
	assert js.contains('pointerEvents === "none"')
	assert js.contains('r.width <= 0 || r.height <= 0')
	assert js.contains('disabled')
}

fn test_build_action_point_query_js_wraps_frame_offsets() {
	mut sess := new_cdp_session(noop_send)
	sess.current_frame_selector = '#child'
	js := build_action_point_query_js(mut sess, 'document.querySelector("#submit")')
	assert js.contains('document.querySelector("#child")')
	assert js.contains('var fr = frame.getBoundingClientRect();')
	assert js.contains('fr.x + r.x + r.width / 2')
}

fn test_cmd_open_clears_frame_context_before_navigation() {
	mut sess := new_cdp_session(noop_send)
	sess.current_frame_selector = '#child'
	_ := cmd_open(mut sess, '{"url":"https://example.com"}')
	assert sess.current_frame_selector == ''
}

fn test_build_semantic_locator_js_prefers_visible_matches() {
	mut sess := new_cdp_session(noop_send)
	js := build_semantic_locator_js(mut sess, 'text', 'Run workflow', true, '', -1)
	assert js.contains('details:not([open])')
	assert js.contains('visibleActionableMatches')
	assert js.contains('getClientRects')
	assert js.contains('actionableSelector()')
	assert js.contains('roleSelector(role)')
}

fn test_build_semantic_text_report_js_includes_hint_and_count() {
	mut sess := new_cdp_session(noop_send)
	js := build_semantic_text_report_js(mut sess, 'Run workflow', true, -1, 5, 'debug')
	assert js.contains('var total = candidates.length')
	assert js.contains('var hint = total === 0 ? "未找到候选"')
	assert js.contains('count: total')
	assert js.contains('selectedIndex: -1')
	assert js.contains('report.candidates = candidates.slice(0, 5)')
}

fn test_build_fill_action_body_uses_native_setter() {
	js := build_fill_action_body('Hello')
	assert js.contains('Object.getOwnPropertyDescriptor')
	assert js.contains('HTMLInputElement.prototype')
	assert js.contains('HTMLTextAreaElement.prototype')
	assert js.contains('dispatchEvent(new Event("input"')
	assert js.contains('dispatchEvent(new Event("change"')
}

fn test_upload_result_json_includes_phase_and_preview_selector() {
	json := upload_result_json(['./a.txt', './b.txt'], 'previewed', '#uploadPreview')
	assert json.contains('"phase":"previewed"')
	assert json.contains('"files":["a.txt","b.txt"]')
	assert json.contains('"previewSelector":"#uploadPreview"')
}

fn test_verification_settle_interval_scales_with_timeout() {
	assert verification_settle_interval(300 * time.millisecond) == 50 * time.millisecond
	assert verification_settle_interval(1500 * time.millisecond) == 75 * time.millisecond
	assert verification_settle_interval(5 * time.second) == 150 * time.millisecond
}

fn test_build_cursor_interactive_snapshot_js_covers_custom_click_targets() {
	mut sess := new_cdp_session(noop_send)
	js := build_cursor_interactive_snapshot_js(mut sess, 7)
	assert js.contains('cursor === "pointer"')
	assert js.contains('onclick')
	assert js.contains('data-testid')
	assert js.contains('clickable')
	assert js.contains('Math.min(candidates.length, 7)')
}

fn test_render_ax_tree_limits_output_nodes() {
	mut store := AxRefStore{}
	mut skipped_nodes := map[int]bool{}
	nodes_json := '[{"role":{"value":"button"},"name":{"value":"Save"},"backendDOMNodeId":1},{"role":{"value":"link"},"name":{"value":"Home"},"backendDOMNodeId":2},{"role":{"value":"textbox"},"name":{"value":"Email"},"backendDOMNodeId":3}]'
	out, next_counter := render_ax_tree(nodes_json, 1, mut store, false, 2, skipped_nodes)
	assert out.contains('@e1 [button] Save')
	assert out.contains('@e2 [link] Home')
	assert !out.contains('Email')
	assert next_counter == 3
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
	assert error_code('ambiguous text match: Run workflow') == 'AMBIGUOUS_MATCH'
	assert error_code('no extension connected') == 'NOT_CONNECTED'
	assert error_code('CDP command timed out') == 'TIMEOUT'
	assert error_code('verification failed: expected foo, got bar') == 'VERIFY_FAILED'
	assert error_code('Debugger conflict: another debugger is already attached') == 'DEBUGGER_CONFLICT'
	assert error_code('No available tab: no tab is currently accessible') == 'NOT_FOUND'
}

fn test_error_suggestion_maps_common_failures() {
	assert error_suggestion('no extension connected') == 'Run v-browser connect after syncing the extension id. If the extension page is already open, switch to a normal webpage tab before reconnecting.'
	assert error_suggestion('element not found: #missing') == 'Check the selector or target tab. Use v-browser snapshot to inspect the current page, or use find --list / find --debug to review semantic candidates.'
	assert error_suggestion('ambiguous text match: Run workflow') == 'Use find --index to select a specific candidate, or add --name / --exact to narrow the match.'
	assert error_suggestion('unknown command: frobnicate').contains('v-browser --help')
	assert error_suggestion('unsupported subcommand: foo').contains('v-browser <command> --help')
	assert error_suggestion('CDP command timed out') == 'Wait for the page to finish loading, or increase the command timeout if the page is expected to take longer.'
	assert error_suggestion('verification failed: expected foo, got bar') == 'Check whether the target element actually changed. If the page is dynamic, increase --verify-timeout or verify a more stable state.'
	assert error_suggestion('failed to start v-browser server') == 'Check the server log, then try v-browser server restart or v-browser status to verify the daemon is healthy.'
	assert error_suggestion('Debugger conflict: another debugger is already attached') == 'Close any other CDP sessions (Chrome DevTools, other automation tools) attached to the same tab, then run v-browser connect again.'
	assert error_suggestion('No available tab: no tab is currently accessible') == 'Switch to a normal webpage tab (not the extension page), then run v-browser connect again.'
}

fn test_cli_error_result_helpers_extract_messages() {
	assert is_cli_error_result('ERROR:missing selector')
	assert cli_error_message('ERROR:missing selector') == 'missing selector'
	assert !is_cli_error_result('{"ok":true}')
	assert cli_error_message('plain text') == 'plain text'
}

fn test_should_retry_after_reconnect_for_connection_failures() {
	assert should_retry_after_reconnect('eval', 'no extension connected')
	assert should_retry_after_reconnect('click', 'CDP session is closed')
	assert !should_retry_after_reconnect('status', 'no extension connected')
	assert !should_retry_after_reconnect('connect', 'no extension connected')
}

fn test_is_attach_conflict_error_matches_debugger_conflict() {
	assert is_attach_conflict_error('Another debugger is already attached to the tab with id: 123')
	assert !is_attach_conflict_error('no extension connected')
}

fn test_connect_active_session_propagates_attach_conflict_without_reuse() {
	result := connect_active_session_with(mock_send_ipc_attach_conflict_no_status,
		'{"tabId":12,"windowId":34}') or {
		assert err.msg() == 'Debugger conflict: another debugger is already attached to the tab.'
		return
	}
	panic('expected attach conflict, got ${result}')
}

fn test_cmd_eval_returns_read_error_before_missing_expression() {
	mut sess := new_cdp_session(noop_send)
	assert cmd_eval(mut sess, '{"expression":"","readError":"failed to read stdin: boom"}') == 'ERROR:failed to read stdin: boom'
}

// ========== 新增单元测试 ==========

fn test_decode_json_string_handles_plain_text() {
	assert decode_json_string('plain text') == 'plain text'
	assert decode_json_string('') == ''
}

fn test_decode_json_string_unwraps_ok_result() {
	// 测试 {"ok":true,"result":...} 包装格式
	result := decode_json_string('{"ok":true,"result":"hello"}')
	assert result == 'hello'
}

fn test_decode_json_string_handles_json_value() {
	// 测试已经是 JSON 值的情况
	result := decode_json_string('{"key":"value"}')
	assert result == '{"key":"value"}'
}

fn test_axref_is_ref_validates_format() {
	// 有效的 @eN 格式
	assert axref_is_ref('@e1')
	assert axref_is_ref('@e123')
	assert axref_is_ref('@e999999')
	// @e0 也是有效的格式（函数只验证格式，不验证索引有效性）
	assert axref_is_ref('@e0')
	// 无效格式
	assert !axref_is_ref('@e') // 缺少数字
	assert !axref_is_ref('e1') // 缺少 @
	assert !axref_is_ref('#e1') // 不是 @
	assert !axref_is_ref('@a1') // 第二位不是 e
	assert !axref_is_ref('@e1a') // 包含非数字字符
}

fn test_ipc_encode_decode_error_response() {
	// 测试错误响应的编解码
	resp := IpcResponse{
		id:  5
		err: 'something went wrong'
	}
	encoded := ipc_encode_response(resp)
	assert encoded.contains('"error":')
	decoded := ipc_decode_response(encoded) or { panic(err) }
	assert decoded.id == 5
	assert decoded.err == 'something went wrong'
}

fn test_ipc_decode_request_handles_empty_params() {
	// 测试省略 params 字段的情况
	req := ipc_decode_request('{"id":1,"method":"status"}') or { panic(err) }
	assert req.id == 1
	assert req.method == 'status'
	assert req.params == '{}'
}

fn test_ipc_decode_response_handles_null_result() {
	// 测试 result 为 null 的情况
	resp := ipc_decode_response('{"id":1,"result":null}') or { panic(err) }
	assert resp.id == 1
	assert resp.result == 'null'
}

// ─── clipboard tests ─────────────────────────────────────────

fn test_parse_cli_to_ipc_clipboard_read_routes_action() {
	method, params := parse_cli_to_ipc('clipboard', ['read', 'image'], false)
	assert method == 'clipboard'
	assert params.contains('"action":"read"')
	assert params.contains('"kind":"image"')
}

fn test_parse_cli_to_ipc_clipboard_write_routes_action_and_path() {
	method, params := parse_cli_to_ipc('clipboard', ['write', 'image', 'photo.png'], false)
	assert method == 'clipboard'
	assert params.contains('"action":"write"')
	assert params.contains('"kind":"image"')
	assert params.contains('"path":"photo.png"')
}

fn test_parse_cli_to_ipc_clipboard_read_via_flag() {
	method, params := parse_cli_to_ipc('clipboard', ['--action', 'read', '--kind', 'image'], false)
	assert method == 'clipboard'
	assert params.contains('"action":"read"')
	assert params.contains('"kind":"image"')
}

fn test_image_mime_type_returns_correct_types() {
	assert image_mime_type('photo.png') == 'image/png'
	assert image_mime_type('photo.PNG') == 'image/png'
	assert image_mime_type('photo.jpg') == 'image/jpeg'
	assert image_mime_type('photo.jpeg') == 'image/jpeg'
	assert image_mime_type('photo.gif') == 'image/gif'
	assert image_mime_type('photo.webp') == 'image/webp'
	assert image_mime_type('photo.bmp') == 'image/bmp'
	assert image_mime_type('photo.unknown') == 'image/png' // default
}

fn test_clipboard_image_extension_matches_mime_type() {
	assert clipboard_image_extension('image/png') == 'png'
	assert clipboard_image_extension('image/jpeg') == 'jpg'
	assert clipboard_image_extension('image/jpg') == 'jpg'
	assert clipboard_image_extension('image/gif') == 'gif'
	assert clipboard_image_extension('image/webp') == 'webp'
	assert clipboard_image_extension('image/bmp') == 'bmp'
}

fn test_clipboard_js_helpers_include_clipboard_calls() {
	read_js := build_clipboard_read_image_js()
	assert read_js.contains('navigator.clipboard.read')
	assert read_js.contains('btoa(binary)')
	assert read_js.contains('return type')

	write_js := build_clipboard_write_image_js('image/png', 'YWJj')
	assert write_js.contains('navigator.clipboard.write')
	assert write_js.contains('ClipboardItem')
	assert write_js.contains('atob(')
	assert write_js.contains('return "ok"')
}

fn test_network_save_path_helpers_infer_extensions() {
	assert network_url_filename('https://pbs.twimg.com/media/HDxhU9RWQAAw-2P?format=jpg&name=medium') == 'HDxhU9RWQAAw-2P'
	assert network_file_extension('image/jpeg', 'https://pbs.twimg.com/media/HDxhU9RWQAAw-2P') == '.jpg'
	assert network_file_extension('',
		'https://pbs.twimg.com/media/HDxhU9RWQAAw-2P?format=jpg&name=medium') == '.jpg'
	assert network_file_extension('application/json', 'https://example.com/api') == '.json'
	assert network_default_filename('req-1', 'https://pbs.twimg.com/media/HDxhU9RWQAAw-2P',
		'image/jpeg') == 'HDxhU9RWQAAw-2P.jpg'
	assert resolve_network_save_path('./tmp/image', 'req-1',
		'https://pbs.twimg.com/media/HDxhU9RWQAAw-2P', 'image/jpeg') == './tmp/image.jpg'
}

fn test_build_page_primary_image_urls_js_mentions_container_scoring() {
	mut sess := new_cdp_session(noop_send)
	js := build_page_primary_image_urls_js(mut sess)
	assert js.contains('article, figure, main, [role=article], [data-testid=tweet]')
	assert js.contains('imageArea(img) >= 40000')
	assert js.contains('best.mediaImages')
	assert js.contains('normalizeUrl(src)')
	assert js.contains('new URL(src, doc.baseURI).href')
}

fn test_parse_cli_to_ipc_network_requests_capture_body() {
	method, params := parse_cli_to_ipc('network', ['requests', '--capture-body'], false)
	assert method == 'network'
	assert params.contains('"action":"requests"')
	assert params.contains('"captureBody":"true"')
}

fn test_parse_cli_to_ipc_network_hook_max_body_len() {
	method, params := parse_cli_to_ipc('network', ['hook', 'start', '--max-body-len', '8000'],
		false)
	assert method == 'network'
	assert params.contains('"action":"hook"')
	assert params.contains('"subaction":"start"')
	assert params.contains('"maxBodyLen":"8000"')
}

fn test_parse_cli_to_ipc_network_hook_default_max_body_len() {
	method, params := parse_cli_to_ipc('network', ['hook', 'start'], false)
	assert method == 'network'
	assert params.contains('"action":"hook"')
	assert params.contains('"subaction":"start"')
	assert params.contains('"maxBodyLen":"4000"')
}

fn test_parse_cli_to_ipc_network_hook_zero_max_body_len() {
	method, params := parse_cli_to_ipc('network', ['hook', 'start', '--max-body-len', '0'], false)
	assert method == 'network'
	assert params.contains('"maxBodyLen":"0"')
}

fn test_parse_cli_to_ipc_network_inspect() {
	method, params := parse_cli_to_ipc('network', ['inspect', '--filter', 'api', '--limit', '10'],
		false)
	assert method == 'network'
	assert params.contains('"action":"inspect"')
	assert params.contains('"filter":"api"')
	assert params.contains('"limit":"10"')
}

fn test_network_hook_bootstrap_js_includes_binding_push() {
	js := network_hook_bootstrap_js()
	assert js.contains('__vBrowserHookPush')
}

fn test_network_hook_activate_js_includes_bootstrap_and_config() {
	js := network_hook_activate_js('api', true, true, true, 0, 'hook-v1')
	assert js.contains('SCRIPT_VERSION = 3')
	assert js.contains('__vBrowserHookConfig.active = true')
	assert js.contains('__vBrowserHookConfig.maxBodyLen = 0')
	assert js.contains('__vBrowserHookActive')
}

fn test_network_hook_bootstrap_js_preserves_zero_max_body_len() {
	js := network_hook_bootstrap_js()
	assert js.contains('cfg.maxBodyLen === 0 ? 0 : (cfg.maxBodyLen || 4000)')
}

fn test_network_hook_stop_js_marks_hook_inactive() {
	js := network_hook_stop_js()
	assert js.contains('__vBrowserHookActive", "false"')
	assert js.contains('window.__vBrowserHookConfig.active = false')
}

fn test_network_hook_status_json_includes_max_body_len() {
	state := HookState{
		active:       true
		max_body_len: 8000
		record_count: 3
	}
	json := network_hook_status_json_from_state(state)
	assert json.contains('"maxBodyLen":8000')
}

fn test_network_hook_status_json_includes_all_frames() {
	state := HookState{
		active:     true
		all_frames: true
	}
	json := network_hook_status_json_from_state(state)
	assert json.contains('"allFrames":true')
}

fn test_handle_hook_binding_push_does_not_advance_poll_index() {
	mut sess := new_cdp_session(noop_send)
	sess.hook_state.last_synced_index = 4
	sess.handle_hook_binding_push('{"recordId":"push-1","method":"GET","url":"https://api.example.com/push"}')
	assert sess.hook_state.last_synced_index == 4
	assert sess.hook_state.last_pushed_count == 1
	assert sess.hook_state.record_count == 1
	assert sess.hook_record_order == ['push-1']
}

fn test_sync_network_hook_records_dedupes_pushed_records() {
	mut sess := new_cdp_session(noop_send)
	sess.handle_hook_binding_push('{"recordId":"push-1","method":"GET","url":"https://api.example.com/push"}')
	items :=
		split_json_array_objects('[{"recordId":"push-1","method":"GET","url":"https://api.example.com/push"},{"recordId":"poll-2","method":"POST","url":"https://api.example.com/poll"}]')
	added := append_polled_hook_records(mut sess, items, 0)
	assert added == 1
	assert sess.hook_record_order == ['push-1', 'poll-2']
	assert sess.hook_state.last_synced_index == 2
	assert sess.hook_state.last_pushed_count == 1
	assert sess.hook_state.record_count == 2
}

fn test_activate_tab_context_restores_runtime_hook_chain() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')
	sess.tab_contexts[7] = TabContext{
		hook_state: HookState{
			active:           true
			injected:         true
			script_id:        'hook-v1'
			script_version:   3
			filter:           'api'
			capture_body:     true
			capture_response: true
			max_body_len:     4000
			all_frames:       true
			activate_js:      network_hook_activate_js('api', true, true, false, 4000, 'hook-v1')
		}
	}
	sess.activate_tab_context_from_result('{"tabId":7}') or { panic(err) }
	joined := sent.join('\n')
	assert joined.contains('"method":"Page.enable"')
	assert joined.contains('"method":"Network.enable"')
	assert joined.contains('"method":"Runtime.enable"')
	assert joined.contains('"method":"Runtime.addBinding"')
	assert joined.contains('"method":"Page.addScriptToEvaluateOnNewDocument"')
	eval_count := joined.split('"method":"Runtime.evaluate"').len - 1
	assert eval_count >= 2
}

fn test_execution_context_payload_parses_numeric_id_and_default_flag() {
	ctx_obj := cdp_extract_obj('{"context":{"id":7,"auxData":{"isDefault":true,"frameId":"frame-a"}}}',
		'context')
	aux_data := cdp_extract_obj(ctx_obj, 'auxData')
	assert cdp_extract_int(ctx_obj, '"id":') == 7
	assert cdp_extract_bool(aux_data, 'isDefault')
	assert cdp_extract_str(aux_data, 'frameId') == 'frame-a'
}

fn test_runtime_execution_context_ids_track_create_destroy_and_clear() {
	mut sess := new_cdp_session(noop_send)
	sess.runtime_contexts = {
		7:  RuntimeExecutionContext{
			id:         7
			frame_id:   'frame-a'
			is_default: true
		}
		9:  RuntimeExecutionContext{
			id:         9
			frame_id:   'worker-a'
			is_default: false
		}
		11: RuntimeExecutionContext{
			id:         11
			frame_id:   'frame-b'
			is_default: true
		}
	}
	assert sess.default_execution_context_ids() == [7, 11]
	sess.runtime_contexts.delete(7)
	assert sess.default_execution_context_ids() == [11]
	sess.runtime_contexts.clear()
	assert sess.default_execution_context_ids().len == 0
}

fn test_matches_status_filter_exact() {
	assert matches_status_filter(200, '200')
	assert !matches_status_filter(404, '200')
	assert matches_status_filter(0, '')
}

fn test_matches_status_filter_wildcard() {
	assert matches_status_filter(200, '2xx')
	assert matches_status_filter(201, '2xx')
	assert !matches_status_filter(404, '2xx')
	assert matches_status_filter(404, '4xx')
	assert matches_status_filter(500, '5xx')
}

fn test_url_hostname_extracts_host() {
	assert url_hostname('https://api.example.com/path?q=1') == 'api.example.com'
	assert url_hostname('http://user:pass@host.com/') == 'host.com'
	assert url_hostname('https://example.com:8080/') == 'example.com'
	assert url_hostname('example.com/path') == 'example.com'
}

fn test_matches_network_filter_by_domain() {
	entry := TrackedNetworkRequest{
		url:    'https://api.example.com/data'
		method: 'GET'
	}
	assert matches_network_filter(entry, normalize_network_filter(NetworkFilter{
		domain: 'api.example'
	}))
	assert !matches_network_filter(entry, normalize_network_filter(NetworkFilter{
		domain: 'other.com'
	}))
}

fn test_matches_network_filter_by_status() {
	entry := TrackedNetworkRequest{
		url:    'https://example.com/'
		method: 'GET'
		status: 404
	}
	assert matches_network_filter(entry, normalize_network_filter(NetworkFilter{ status: '4xx' }))
	assert !matches_network_filter(entry, normalize_network_filter(NetworkFilter{ status: '2xx' }))
	assert matches_network_filter(entry, normalize_network_filter(NetworkFilter{ status: '404' }))
}

fn test_matches_network_filter_by_type() {
	entry := TrackedNetworkRequest{
		url:           'https://example.com/api'
		method:        'POST'
		resource_type: 'XHR'
	}
	assert matches_network_filter(entry, normalize_network_filter(NetworkFilter{ rtype: 'xhr' }))
	assert !matches_network_filter(entry, normalize_network_filter(NetworkFilter{ rtype: 'fetch' }))
}

fn test_parse_cli_to_ipc_network_requests_all_filters() {
	cmd, params := parse_cli_to_ipc('network', ['requests', '--filter', 'api', '--mime',
		'application/json', '--status', '2xx', '--domain', 'example.com', '--type', 'XHR'], false)
	assert cmd == 'network'
	assert params.contains('"action":"requests"')
	assert params.contains('"filter":"api"')
	assert params.contains('"mime":"application/json"')
	assert params.contains('"status":"2xx"')
	assert params.contains('"domain":"example.com"')
	assert params.contains('"type":"XHR"')
}

fn test_parse_cli_to_ipc_network_hook_all_frames() {
	cmd, params := parse_cli_to_ipc('network', ['hook', 'start', '--all-frames'], false)
	assert cmd == 'network'
	assert params.contains('"subaction":"start"')
	assert params.contains('"allFrames":"true"')
}

fn test_save_network_images_uses_candidate_set_for_matching() {
	mut candidate_urls := map[string]bool{}
	candidate_urls['https://pbs.twimg.com/media/HDxhU9RWQAAw-2P?format=jpg&name=medium'] = true
	entry := TrackedNetworkRequest{
		request_id:    'media-1'
		url:           'https://pbs.twimg.com/media/HDxhU9RWQAAw-2P?format=jpg&name=medium'
		resource_type: 'Image'
	}
	assert entry.url in candidate_urls
	assert network_image_output_name(1, entry) == '01-HDxhU9RWQAAw-2P.jpg'
}

fn test_network_requests_json_respects_limit() {
	mut sess := new_cdp_session(noop_send)
	for i in 0 .. 5 {
		sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"req-${i}","type":"XHR","request":{"url":"https://api.example.com/v${i}","method":"GET"}}}}')
	}
	all := sess.network_requests_json(NetworkFilter{}, 0)
	limited := sess.network_requests_json(NetworkFilter{}, 2)
	assert all.contains('"req-4"')
	// limited 应只有 2 条记录
	count := limited.split('"requestId"').len - 1
	assert count == 2
}

fn test_get_response_body_uses_cached_text_without_cdp_fetch() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_network_body_mock_send(mut sess, mut sent, '', network_body_result_json('', false))
	sess.network_requests['req-1'] = TrackedNetworkRequest{
		request_id:           'req-1'
		finished:             true
		response_body:        '{"ok":true}'
		response_body_raw:    '{"ok":true}'
		response_body_cached: true
	}
	body := sess.get_response_body('req-1') or { panic(err) }
	assert body == '{"ok":true}'
	assert sent.len == 0
}

fn test_get_response_body_bytes_decodes_cached_base64_body() {
	mut sess := new_cdp_session(noop_send)
	sess.network_requests['req-1'] = TrackedNetworkRequest{
		request_id:           'req-1'
		finished:             true
		response_body:        '[base64-encoded body cached]'
		response_body_raw:    base64.encode('PNG'.bytes())
		response_body_base64: true
		response_body_cached: true
	}
	body := sess.get_response_body_bytes('req-1') or { panic(err) }
	assert body.bytestr() == 'PNG'
}

fn test_get_response_body_returns_clear_error_before_request_finishes() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_network_body_mock_send(mut sess, mut sent, 'req-1', network_body_result_json('{"late":true}',
		false))
	sess.network_requests['req-1'] = TrackedNetworkRequest{
		request_id: 'req-1'
		finished:   false
	}
	_ := sess.get_response_body('req-1') or {
		assert err.msg().contains('until request finishes')
		assert sent.len == 0
		return
	}
	assert false
}

fn test_cache_response_body_payload_populates_cache_fields() {
	mut sess := new_cdp_session(noop_send)
	sess.network_requests['req-1'] = TrackedNetworkRequest{
		request_id: 'req-1'
		finished:   true
	}
	entry := sess.cache_response_body_payload('req-1', 'hello world', false) or { panic(err) }
	assert entry.response_body_cached
	assert entry.response_body_raw == 'hello world'
	assert entry.response_body == 'hello world'
	snapshot := sess.network_requests['req-1'] or { panic('missing request') }
	assert snapshot.response_body_cached
	assert snapshot.response_body_raw == 'hello world'
}

fn test_save_network_response_uses_cached_body_without_extra_cdp_fetch() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_network_body_mock_send(mut sess, mut sent, '', network_body_result_json('', false))
	sess.network_requests['req-1'] = TrackedNetworkRequest{
		request_id:           'req-1'
		url:                  'https://example.com/image.png'
		finished:             true
		response_headers:     '{"content-type":"image/png"}'
		response_body:        '[base64-encoded body cached]'
		response_body_raw:    base64.encode_str('image-data')
		response_body_base64: true
		response_body_cached: true
	}
	tmp_dir := os.join_path(os.temp_dir(),
		'v-browser-network-save-${os.getpid()}-${time.now().unix_milli()}')
	os.mkdir_all(tmp_dir) or { panic(err) }
	defer { os.rmdir_all(tmp_dir) or {} }
	out_path := os.join_path(tmp_dir, 'image.bin')
	saved_path, mime_type := save_network_response(mut sess, 'req-1', out_path) or { panic(err) }
	assert saved_path == out_path
	assert mime_type == 'image/png'
	assert (os.read_file(saved_path) or { panic(err) }) == 'image-data'
	assert sent.len == 0
}

fn test_network_hook_records_json_filters_by_status() {
	// 直接测过滤逻辑（避免触发 sync_network_hook_records 的 CDP 轮询）
	record_ok := HookRecord{
		record_id: '1'
		raw_json:  '{"recordId":"1","method":"GET","url":"https://api.example.com/ok","status":200,"responseHeaders":{"content-type":"application/json"},"requestHeaders":{}}'
	}
	record_fail := HookRecord{
		record_id: '2'
		raw_json:  '{"recordId":"2","method":"POST","url":"https://api.example.com/fail","status":404,"responseHeaders":{},"requestHeaders":{}}'
	}
	view_ok := hook_record_view_from_raw(record_ok)
	view_fail := hook_record_view_from_raw(record_fail)
	assert view_ok.response_status == 200
	assert view_fail.response_status == 404
	// 4xx 过滤：只有 404 匹配
	assert !matches_status_filter(view_ok.response_status, '4xx')
	assert matches_status_filter(view_fail.response_status, '4xx')
	// 2xx 过滤：只有 200 匹配
	assert matches_status_filter(view_ok.response_status, '2xx')
	assert !matches_status_filter(view_fail.response_status, '2xx')
	// domain 过滤
	assert url_hostname(view_ok.url) == 'api.example.com'
	// mime 过滤（response_headers 是 JSON 对象字符串）
	assert view_ok.response_headers.to_lower().contains('application/json')
	// source rtype 过滤（hook records 默认 source 为空或 unknown，不含 "xhr"）
	assert !view_ok.source.to_lower().contains('xhr')
}

fn test_network_inspect_merges_hook_and_cdp() {
	mut sess := new_cdp_session(noop_send)
	// CDP 记录
	sess.on_message('{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"cdp-1","type":"XHR","request":{"url":"https://api.example.com/data","method":"GET"}}}}')
	// Hook 记录（不同 URL）
	sess.hook_records['h1'] = HookRecord{
		record_id: '1'
		raw_json:  '{"recordId":"1","source":"fetch","method":"POST","url":"https://api.example.com/submit","status":201,"responseHeaders":{},"requestHeaders":{}}'
	}
	sess.hook_record_order = ['h1']
	f := NetworkFilter{}
	res := network_inspect_records_json(mut sess, f, 0)
	assert res.contains('"source":"hook"')
	assert res.contains('"source":"cdp"')
	assert res.contains('/submit')
	assert res.contains('/data')
}

fn test_network_inspect_keeps_extra_cdp_entries_for_repeated_signature() {
	mut sess := new_cdp_session(noop_send)
	sess.hook_records['hook-1'] = HookRecord{
		record_id: 'hook-1'
		raw_json:  '{"recordId":"hook-1","source":"fetch","method":"GET","url":"https://api.example.com/poll","status":200,"requestBody":"","responseHeaders":{},"requestHeaders":{}}'
	}
	sess.hook_record_order = ['hook-1']
	sess.network_requests = {
		'req-1': TrackedNetworkRequest{
			request_id:   'req-1'
			method:       'GET'
			url:          'https://api.example.com/poll'
			status:       200
			request_body: ''
		}
		'req-2': TrackedNetworkRequest{
			request_id:   'req-2'
			method:       'GET'
			url:          'https://api.example.com/poll'
			status:       200
			request_body: ''
		}
	}
	sess.network_request_order = ['req-1', 'req-2']
	res := network_inspect_records_json(mut sess, NetworkFilter{}, 0)
	assert res.contains('"recordId":"hook-1"')
	assert !res.contains('"requestId":"req-1"')
	assert res.contains('"requestId":"req-2"')
}

// ─── #8: cmd_click/dblclick/hover 双路径回退应该合并错误信息 ──────────

// helper: 把 send_command 包装的 forwardCDPCommand 信封拆开取内层 CDP method。
// bridge 命令（listTabs / createTab / attachToTab / ...）没有内层 method，
// 此时直接返回外层 method。
fn inner_cdp_method(data string) string {
	outer := cdp_extract_str(data, 'method')
	if outer == 'forwardCDPCommand' {
		params_obj := cdp_extract_obj_key(data, '"params":')
		return cdp_extract_str(params_obj, 'method')
	}
	return outer
}

// mock: Runtime.evaluate 返回 boolean false（元素找不到），其它 CDP 命令报错。
// run_element_action 看到 false 会返回 error，pointer_action_for_selector
// 路径下所有 CDP 命令（包括 Runtime.evaluate 和 Input.dispatchMouseEvent）都失败。
fn attach_pointer_paths_failing_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			// 注意：必须用 boolean 类型而不是 string 'false'，否则
			// `cdp_extract_value_from_result` 会返回 '"false"'（带引号），
			// `run_element_action` 里的 `result == 'false'` 比较不通过。
			sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":false}}}')
		} else {
			sess.on_message('{"id":${id},"error":{"message":"forced CDP failure"}}')
		}
	}
}

// mock: 所有 Runtime.evaluate 返回 boolean true，其它 CDP 命令成功。
// 让 run_element_action 一路走通返回 ok=true，pointer_action_for_selector
// 顺利 resolve + mouse click。
fn attach_pointer_paths_succeeding_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			sess.on_message('{"id":${id},"result":{"result":{"type":"boolean","value":true}}}')
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

fn test_cmd_click_rejects_empty_selector() {
	mut sess := new_cdp_session(noop_send)
	res := cmd_click(mut sess, '{}')
	assert res == 'ERROR:missing selector'
}

fn test_cmd_click_returns_null_when_dom_path_succeeds() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_pointer_paths_succeeding_send(mut sess, mut sent)
	res := cmd_click(mut sess, '{"selector":"#btn"}')
	assert res == 'null'
}

fn test_cmd_click_combines_dom_and_mouse_errors_when_both_fail() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_pointer_paths_failing_send(mut sess, mut sent)
	res := cmd_click(mut sess, '{"selector":"#missing"}')
	// 修复前：只回报 mouse 路径的 error（甚至可能被 swallow 成 'null'）
	// 修复后：必须包含两条错误，方便定位根因
	assert res.starts_with('ERROR:click failed for selector #missing:')
	assert res.contains('dom: element not found')
	assert res.contains('mouse:')
}

fn test_cmd_dblclick_combines_errors_when_both_paths_fail() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_pointer_paths_failing_send(mut sess, mut sent)
	res := cmd_dblclick(mut sess, '{"selector":"#missing"}')
	assert res.starts_with('ERROR:dblclick failed for selector #missing:')
	assert res.contains('dom:')
	assert res.contains('mouse:')
}

fn test_cmd_hover_combines_errors_when_both_paths_fail() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_pointer_paths_failing_send(mut sess, mut sent)
	res := cmd_hover(mut sess, '{"selector":"#missing"}')
	assert res.starts_with('ERROR:hover failed for selector #missing:')
	assert res.contains('dom:')
	assert res.contains('mouse:')
}

fn test_dispatch_pointer_action_rejects_unknown_action() {
	mut sess := new_cdp_session(noop_send)
	res := dispatch_pointer_action(mut sess, '#btn', 'scroll')
	assert res == 'ERROR:unknown pointer action: scroll'
}

// ─── #9: tab 切换时 reject pending 请求 ─────────────────────────────

fn test_reject_pending_reqs_clears_map_and_signals_channels() {
	mut sess := new_cdp_session(noop_send)
	// 模拟两个在飞的请求：每个请求对应一个 channel。
	// 故意不响应（不调用 sess.on_message），让它们持续 pending。
	ch1 := chan ProtocolResponse{cap: 1}
	ch2 := chan ProtocolResponse{cap: 1}
	sess.pending_mu.@lock()
	sess.pending[10] = ch1
	sess.pending[20] = ch2
	sess.pending_mu.unlock()

	sess.reject_pending_reqs('tab switched away')

	// pending map 应该被清空
	sess.pending_mu.@lock()
	assert sess.pending.len == 0
	sess.pending_mu.unlock()

	// 每个 channel 都应收到带 reason 的错误响应
	resp1 := <-ch1
	assert resp1.id == 10
	assert resp1.err == 'tab switched away'
	resp2 := <-ch2
	assert resp2.id == 20
	assert resp2.err == 'tab switched away'
}

fn test_activate_tab_context_rejects_pending_when_switching_tabs() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// 第一次 attach 到 tab 1（建立 tab context）
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }
	assert sess.current_tab_id == 1

	// 注入一个模拟在飞的 CDP 请求
	ch := chan ProtocolResponse{cap: 1}
	sess.pending_mu.@lock()
	sess.pending[99] = ch
	sess.pending_mu.unlock()

	// 切到 tab 2 — 应该触发 reject_pending_reqs
	sess.activate_tab_context_from_result('{"tabId":2}') or { panic(err) }
	assert sess.current_tab_id == 2

	// 旧 tab 1 的 pending 应该被清空，channel 收到 'tab switched away'
	sess.pending_mu.@lock()
	assert sess.pending.len == 0
	sess.pending_mu.unlock()

	resp := <-ch
	assert resp.id == 99
	assert resp.err == 'tab switched away'
}

fn test_activate_tab_context_does_not_reject_pending_on_same_tab_refresh() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// 第一次 attach 到 tab 1
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }

	// 注入一个在飞的请求
	ch := chan ProtocolResponse{cap: 1}
	sess.pending_mu.@lock()
	sess.pending[77] = ch
	sess.pending_mu.unlock()

	// 再次 attach 同一个 tab（模拟 attachToTab 后再 attach 一次），
	// 不应该 reject pending 请求（不是真正的切换）
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }

	sess.pending_mu.@lock()
	assert sess.pending.len == 1
	sess.pending_mu.unlock()
}

fn test_reject_pending_reqs_with_empty_map_is_noop() {
	mut sess := new_cdp_session(noop_send)
	// 没东西要 reject 时调用不应该出错
	sess.reject_pending_reqs('noop')
	sess.pending_mu.@lock()
	assert sess.pending.len == 0
	sess.pending_mu.unlock()
}

// ─── #10: tab 切换时清空 event_subs ─────────────────────────────

fn test_clear_event_subs_empties_subscriptions() {
	mut sess := new_cdp_session(noop_send)
	// 模拟已有两个订阅
	_ := sess.subscribe('Page.loadEventFired')
	_ := sess.subscribe('Runtime.consoleAPICalled')
	sess.event_mu.@lock()
	assert sess.event_subs.len == 2
	sess.event_mu.unlock()

	sess.clear_event_subs()
	sess.event_mu.@lock()
	assert sess.event_subs.len == 0
	sess.event_mu.unlock()
}

fn test_activate_tab_context_clears_event_subs_on_switch() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// attach 到 tab 1
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }

	// 在 tab 1 上下文订阅几个事件
	_ = sess.subscribe('Page.loadEventFired')
	_ = sess.subscribe('Runtime.consoleAPICalled')

	sess.event_mu.@lock()
	assert sess.event_subs.len == 2
	sess.event_mu.unlock()

	// 切到 tab 2 — event_subs 应当被清空
	sess.activate_tab_context_from_result('{"tabId":2}') or { panic(err) }
	sess.event_mu.@lock()
	subs_after := sess.event_subs.len
	sess.event_mu.unlock()
	assert subs_after == 0
}

fn test_activate_tab_context_does_not_clear_event_subs_on_same_tab_refresh() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// attach 到 tab 1
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }
	_ = sess.subscribe('Page.loadEventFired')
	sess.event_mu.@lock()
	assert sess.event_subs.len == 1
	sess.event_mu.unlock()

	// 再次 attach 同一个 tab（不是真正的切换），订阅应保留
	sess.activate_tab_context_from_result('{"tabId":1}') or { panic(err) }
	sess.event_mu.@lock()
	subs_after := sess.event_subs.len
	sess.event_mu.unlock()
	assert subs_after == 1
}

// ─── #11: network route goroutine 泄漏 ─────────────────────────────

fn test_stop_route_clears_route_state() {
	mut sess := new_cdp_session(noop_send)
	// 模拟当前已有 active route
	sess.route_ch = chan ProtocolResponse{cap: 32}
	sess.route_stop_ch = chan bool{cap: 1}
	sess.has_route = true

	sess.stop_route()

	assert sess.has_route == false
}

fn test_stop_route_is_noop_when_no_active_route() {
	mut sess := new_cdp_session(noop_send)
	// 没 active route 时调用 stop_route 不应 panic
	sess.stop_route()
	assert sess.has_route == false
}

fn test_close_stops_route() {
	mut sess := new_cdp_session(noop_send)
	sess.route_ch = chan ProtocolResponse{cap: 32}
	sess.route_stop_ch = chan bool{cap: 1}
	sess.has_route = true

	sess.close()

	// close() 应该同时把 route 也停掉（#11）
	assert sess.has_route == false
}

fn test_cmd_network_unroute_calls_stop_route() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// 启动一个 route
	cmd_network(mut sess, '{"action":"route","url":"*example*"}')
	assert sess.has_route == true

	// 停止它
	res := cmd_network(mut sess, '{"action":"unroute"}')
	assert res == 'null'
	assert sess.has_route == false
}

fn test_cmd_network_route_can_be_replaced_by_second_route() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_runtime_mock_send(mut sess, mut sent, 'ok')

	// 第一次 route
	cmd_network(mut sess, '{"action":"route","url":"*a*"}')
	first_stop_ch := sess.route_stop_ch
	assert sess.has_route == true

	// 第二次 route — 应该替换掉第一次，旧 stop_ch 收到信号
	cmd_network(mut sess, '{"action":"route","url":"*b*"}')
	second_stop_ch := sess.route_stop_ch
	assert sess.has_route == true
	// 新旧 channel 是不同的实例（goroutine 已替换）
	assert first_stop_ch != second_stop_ch
}

// ─── #26: relay 拒绝非 loopback 连接 ───────────────────────────────

fn test_is_loopback_ip_accepts_loopback_addresses() {
	// IPv4 loopback 127.0.0.0/8
	assert is_loopback_ip('127.0.0.1')
	assert is_loopback_ip('127.0.0.42')
	assert is_loopback_ip('127.255.255.254')
	// IPv6 loopback
	assert is_loopback_ip('::1')
}

fn test_is_loopback_ip_rejects_non_loopback_addresses() {
	assert !is_loopback_ip('192.168.1.1')
	assert !is_loopback_ip('10.0.0.1')
	assert !is_loopback_ip('8.8.8.8')
	assert !is_loopback_ip('172.16.0.1')
	// 形似但不是 loopback 的 IPv6
	assert !is_loopback_ip('::2')
	assert !is_loopback_ip('fe80::1')
}

fn test_is_loopback_ip_handles_edge_cases() {
	// 短字符串不能误判为 loopback
	assert !is_loopback_ip('')
	assert !is_loopback_ip('127')        // 缺小数点
	assert !is_loopback_ip('127x0.0.1')  // 不是数字
	// IPv6 full address 不应误判
	assert !is_loopback_ip('2001:db8::1')
}

// ─── #36: cmd_get box 不存在元素应返回 ERROR ─────────────────────────

// box 不存在元素时，build_rect_query_js 会让 Runtime.evaluate 返回
// {"type":"object","subtype":"null"}。Mock 返回这个，让 cmd_get 走 box 分支。
fn attach_box_null_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			sess.on_message('{"id":${id},"result":{"result":{"type":"object","subtype":"null"}}}')
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

fn test_cmd_get_box_returns_error_when_element_missing() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_box_null_send(mut sess, mut sent)
	res := cmd_get(mut sess, '{"property":"box","selector":"#missing"}')
	// 修复前：返回字符串 "null"
	// 修复后：返回明确的 ERROR，跟 cmd_click 等保持一致
	assert res == 'ERROR:element not found: #missing'
}

fn test_cmd_get_box_returns_error_when_selector_empty() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_box_null_send(mut sess, mut sent)
	res := cmd_get(mut sess, '{"property":"box"}')
	assert res == 'ERROR:missing selector'
}

// ─── #39: wait --load 不带值应默认走 'load' 状态 ──────────────────

fn test_cmd_wait_load_no_value_treats_true_as_load() {
	// #39: CLI 解析把 --load（无值）设为 'true'，server 端要把这个当作
	// 'load' 的别名，否则返回 'unknown load state: true'。
	mut sess := new_cdp_session(noop_send)

	// cmd_wait 会同步调用 wait_load，后者订阅 Page.loadEventFired 并 select。
	// 我们 spawn 后 sleep 50ms 让 subscribe 完成，再 dispatch event 解除阻塞。
	result_ch := chan string{cap: 1}
	spawn fn [mut sess, result_ch] () {
		r := cmd_wait(mut sess, '{"load":"true"}')
		result_ch <- r
	}()
	time.sleep(50 * time.millisecond)

	// 触发 Page.loadEventFired 让 wait_load 解除阻塞
	sess.dispatch_event('Page.loadEventFired', ProtocolResponse{
		method: 'Page.loadEventFired'
		params: '{}'
	})

	// 收集结果
	select {
		r := <-result_ch {
			// 修复前：返回 'ERROR:unknown load state: true'
			// 修复后：'true' 被映射成 'load'，正常返回 'null'
			assert r == 'null'
		}
		2 * time.second {
			panic('cmd_wait --load (no value) timed out')
		}
	}
}

fn test_cmd_wait_load_explicit_load_still_works() {
	// 回归测试：--load load 写法（带值）必须仍然走 'load' 状态
	mut sess := new_cdp_session(noop_send)

	result_ch := chan string{cap: 1}
	spawn fn [mut sess, result_ch] () {
		r := cmd_wait(mut sess, '{"load":"load"}')
		result_ch <- r
	}()
	time.sleep(50 * time.millisecond)

	sess.dispatch_event('Page.loadEventFired', ProtocolResponse{
		method: 'Page.loadEventFired'
		params: '{}'
	})

	select {
		r := <-result_ch {
			assert r == 'null'
		}
		2 * time.second {
			panic('cmd_wait --load load timed out')
		}
	}
}

fn test_cmd_wait_load_domcontentloaded_still_works() {
	// 回归测试：--load domcontentloaded 仍然走 domContentEventFired
	mut sess := new_cdp_session(noop_send)

	result_ch := chan string{cap: 1}
	spawn fn [mut sess, result_ch] () {
		r := cmd_wait(mut sess, '{"load":"domcontentloaded"}')
		result_ch <- r
	}()
	time.sleep(50 * time.millisecond)

	sess.dispatch_event('Page.domContentEventFired', ProtocolResponse{
		method: 'Page.domContentEventFired'
		params: '{}'
	})

	select {
		r := <-result_ch {
			assert r == 'null'
		}
		2 * time.second {
			panic('cmd_wait --load domcontentloaded timed out')
		}
	}
}

// ─── #35: cdp_parse_message 用 json.decode 替代 substring 扫描 ──────

fn test_cdp_parse_message_extracts_id_method_result_params() {
	// 正常 CDP 响应：id + result
	raw1 := '{"id":42,"result":{"frameTree":{"frame":{"id":"main"}}}}'
	resp := cdp_parse_message(raw1)
	assert resp.id == 42
	assert resp.method == ''
	assert resp.err == ''
	// result 字段保留为 JSON 字符串，下游 cdp_extract_* 可继续解析
	assert resp.result.contains('"frameTree"')
	assert resp.result.contains('"main"')
	assert resp.params == ''
}

fn test_cdp_parse_message_extracts_method_and_params() {
	// CDP 事件：method + params（没有 id）
	raw := '{"method":"Page.loadEventFired","params":{"timestamp":1234.5}}'
	resp := cdp_parse_message(raw)
	assert resp.id == 0
	assert resp.method == 'Page.loadEventFired'
	assert resp.err == ''
	// params 也保留为 JSON 字符串
	assert resp.params.contains('"timestamp"')
	assert resp.params.contains('1234.5')
}

fn test_cdp_parse_message_extracts_error_message_from_object() {
	// CDP 错误响应：error 字段是 {code, message}
	raw := '{"id":7,"error":{"code":-32000,"message":"boom"}}'
	resp := cdp_parse_message(raw)
	assert resp.id == 7
	assert resp.err == 'boom'
	assert resp.method == ''
}

fn test_cdp_parse_message_extracts_error_string() {
	// error 字段也可能直接是字符串
	raw := '{"id":8,"error":"simple error"}'
	resp := cdp_parse_message(raw)
	assert resp.id == 8
	assert resp.err == 'simple error'
}

fn test_cdp_parse_message_handles_invalid_json() {
	// 损坏的 JSON 应该返回 err 字段，非 panic
	resp := cdp_parse_message('not json {{{')
	assert resp.err != ''
	assert resp.err.contains('invalid JSON')
	assert resp.id == 0
}

fn test_cdp_parse_message_handles_empty_input() {
	resp := cdp_parse_message('')
	assert resp.id == 0
	assert resp.method == ''
	assert resp.result == ''
	assert resp.params == ''
	assert resp.err != ''
}

fn test_cdp_parse_message_preserves_nested_params_for_forward_cdp_event() {
	// forwardCDPEvent 是最常见的消息类型，inner 字段需要完整保留
	raw := '{"method":"forwardCDPEvent","params":{"method":"Network.requestWillBeSent","params":{"requestId":"r1","request":{"url":"https://example.com","method":"GET"},"timestamp":12345.6,"type":"Document"}}}'
	resp := cdp_parse_message(raw)
	assert resp.method == 'forwardCDPEvent'
	// params 应该完整保留，下游 cdp_extract_str(resp.params, 'method') 才能拿到 'Network.requestWillBeSent'
	inner_method := cdp_extract_str(resp.params, 'method')
	assert inner_method == 'Network.requestWillBeSent'
	inner_params := cdp_extract_obj(resp.params, 'params')
	assert inner_params.contains('"requestId":"r1"')
	assert inner_params.contains('"url":"https://example.com"')
}

// ─── #21: eval 去 base64 round-trip ───────────────────────────────

// mock: Runtime.evaluate 立即把传进来的 expression 反向解出来执行，返回结果
// 简单起见，我们让 mock 返回 'ok' 字面量；真正的 eval 行为靠对比传出去的 expression
// 来验证（看 JSON.parse 路径走没走对）。
fn attach_eval_capture_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			// 返回一个 string 结果，Runtime.evaluate 的 returnByValue 形式
			sess.on_message('{"id":${id},"result":{"result":{"type":"string","value":"ok"}}}')
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

fn test_eval_scoped_expression_sends_json_parsed_expression() {
	// #21: 验证 V 端发送出去的 expression 走的是 JSON.parse(json_str(expr)) 路径
	// 而不是 base64+atob+TextDecoder 路径
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_eval_capture_send(mut sess, mut sent)

	// 含特殊字符的表达式：引号 + 换行 + 中文
	expr := 'console.log("hello\nworld \\"escaped\\" 中文")'
	result := eval_scoped_expression(mut sess, expr, false) or { panic(err) }
	assert result == 'ok'

	// 检查 sent 里有没有包含 base64 痕迹（不应有）
	joined := sent.join('\n')
	assert !joined.contains('window.atob')
	assert !joined.contains('TextDecoder')

	// 检查 sent 里有 JSON.parse 路径
	assert joined.contains('eval(JSON.parse(')
}

fn test_eval_scoped_expression_handles_quotes_correctly() {
	// JSON.parse + eval 能正确处理字符串内的引号
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_eval_capture_send(mut sess, mut sent)

	expr := 'return "she said \\"hi\\" and left"'
	result := eval_scoped_expression(mut sess, expr, false) or { panic(err) }
	assert result == 'ok'

	// sent 里应该看到经过 json_str 转义后的字符串
	joined := sent.join('\n')
	// json_str("return \"she said \\\"hi\\\" and left\"") 会输出
	// "return \"she said \\\"hi\\\" and left\""
	assert joined.contains('she said')
	assert joined.contains('hi')
}

fn test_eval_scoped_expression_handles_unicode_and_newlines() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_eval_capture_send(mut sess, mut sent)

	expr := 'return "中文 🚀 \n  newline test"'
	result := eval_scoped_expression(mut sess, expr, false) or { panic(err) }
	assert result == 'ok'

	joined := sent.join('\n')
	// 中文和 emoji 在 json_str 里会被原样保留（不被 escape 成 \uXXXX）
	// （V 的 json_str 默认保留 unicode 字符）
	assert joined.contains('中文')
}

fn test_eval_scoped_expression_short_uses_same_path() {
	// 短超时版本应该走完全相同的 JSON.parse 路径
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_eval_capture_send(mut sess, mut sent)

	expr := 'document.title'
	eval_scoped_expression_short(mut sess, expr) or { panic(err) }

	joined := sent.join('\n')
	assert !joined.contains('window.atob')
	assert joined.contains('eval(JSON.parse(')
}

fn test_eval_scoped_expression_short_sets_await_promise_false() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_eval_capture_send(mut sess, mut sent)

	expr := 'somePromise'
	eval_scoped_expression_short(mut sess, expr) or { panic(err) }

	joined := sent.join('\n')
	// 短超时版本 awaitPromise 必须是 false（避免 3s 内阻塞）
	assert joined.contains('"awaitPromise":false')
}

// ─── #22: pointer_action_for_selector 单次 resolve ─────────────────

// mock: Runtime.evaluate 返回 {x, y, width, height} 对象（action_point 查询结果）
fn attach_action_point_send(mut sess CdpSession, mut sent []string, x f64, y f64, w f64, h f64) {
	sess.send_fn = fn [mut sess, mut sent, x, y, w, h] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			resp := '{"id":${id},"result":{"result":{"type":"object","value":{"x":${x},"y":${y},"width":${w},"height":${h}}}}}'
			sess.on_message(resp)
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

// mock: Runtime.evaluate 返回 null（元素不可点击）
fn attach_action_point_null_send(mut sess CdpSession, mut sent []string) {
	sess.send_fn = fn [mut sess, mut sent] (data string) ! {
		sent << data
		id := cdp_extract_int(data, '"id":')
		method := inner_cdp_method(data)
		if method == 'Runtime.evaluate' {
			sess.on_message('{"id":${id},"result":{"result":{"type":"object","subtype":"null"}}}')
		} else {
			sess.on_message('{"id":${id},"result":{}}')
		}
	}
}

fn test_pointer_action_for_selector_uses_single_resolve() {
	// #22: pointer_action_for_selector 现在只发 1 次 Runtime.evaluate，
	// 不再走 resolve → scrollIntoViewIfNeeded → resolve 三件套
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_action_point_send(mut sess, mut sent, 100.0, 200.0, 50.0, 30.0)

	pointer_action_for_selector(mut sess, '#btn', 'click') or { panic(err) }

	// 统计 Runtime.evaluate 调用次数
	joined := sent.join('\n')
	eval_count := joined.split('Runtime.evaluate').len - 1
	// 旧版本会有 2 次（resolve + re-resolve）+ 可能的 1 次 scrollIntoViewIfNeeded
	// 新版本只发 1 次 Runtime.evaluate
	assert eval_count == 1

	// 也不应该再有 DOM.scrollIntoViewIfNeeded（合并到 JS 里了）
	assert !joined.contains('scrollIntoViewIfNeeded')
}

fn test_pointer_action_for_selector_click_uses_returned_coords() {
	// 验证 click 用了第一次 resolve 返回的坐标
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_action_point_send(mut sess, mut sent, 250.0, 350.0, 100.0, 40.0)

	pointer_action_for_selector(mut sess, '#target', 'click') or { panic(err) }

	joined := sent.join('\n')
	// V 序列化 250.0 浮点数会保留 .0 小数位，所以匹配 "x":250.0,"y":350.0
	assert joined.contains('"x":250.0,"y":350.0')
	assert joined.contains('"type":"mousePressed"')
	assert joined.contains('"type":"mouseReleased"')
}

fn test_pointer_action_for_selector_hover_uses_returned_coords() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_action_point_send(mut sess, mut sent, 500.0, 600.0, 80.0, 20.0)

	pointer_action_for_selector(mut sess, '#h', 'hover') or { panic(err) }

	joined := sent.join('\n')
	assert joined.contains('"x":500.0,"y":600.0')
	// hover 只发 mouseMoved，不发 mousePressed / mouseReleased
	assert !joined.contains('"type":"mousePressed"')
	assert !joined.contains('"type":"mouseReleased"')
}

fn test_pointer_action_for_selector_returns_error_when_element_not_actionable() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_action_point_null_send(mut sess, mut sent)

	// pointer_action_for_selector 返回 !（void 或 error），用 or 捕获错误
	pointer_action_for_selector(mut sess, '#missing', 'click') or {
		assert err.msg().contains('element not actionable')
		return
	}
	panic('expected error but pointer_action_for_selector succeeded')
}

fn test_pointer_action_for_selector_dblclick_uses_count_2() {
	mut sent := []string{}
	mut sess := new_cdp_session(noop_send)
	attach_action_point_send(mut sess, mut sent, 100.0, 100.0, 50.0, 50.0)

	pointer_action_for_selector(mut sess, '#btn', 'dblclick') or { panic(err) }

	joined := sent.join('\n')
	// dblclick 应该发 2 次 mousePressed（clickCount=1, clickCount=2）
	pressed_count := joined.split('"type":"mousePressed"').len - 1
	assert pressed_count == 2
}
