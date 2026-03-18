module main

// hex_char_to_int 将十六进制字符转换为整数
fn hex_char_to_int(c u8) int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a` + 10)
	}
	if c >= `A` && c <= `F` {
		return int(c - `A` + 10)
	}
	return 0
}

fn format_output(result string, json_output bool) string {
	if !json_output {
		return result
	}
	return '{"ok":true,"result":' + json_value_or_string(result) + '}'
}

// decode_json_string 解码 JSON 字符串，去掉转义字符
// 用于 CLI 模式自动解码 JSON 编码的输出
fn decode_json_string(s string) string {
	trimmed := s.trim_space()
	// 如果是 JSON 包装格式，提取 result 字段
	if trimmed.starts_with('{"ok":true,"result":') {
		result := cdp_extract_obj_key(trimmed, '"result":')
		if result.starts_with('"') {
			return decode_json_string_literal(result)
		}
		return result
	}
	// 尝试直接解析为 JSON 字符串
	if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len > 1 {
		return decode_json_string_literal(trimmed)
	}
	return s
}

fn print_error(message string, json_output bool) {
	if json_output {
		code := error_code(message)
		suggestion := error_suggestion(message)
		mut error_json := '{"code":' + json_str(code) + ',"message":' + json_str(message)
		if suggestion != '' {
			error_json += ',"suggestion":' + json_str(suggestion)
		}
		error_json += '}'
		println('{"ok":false,"error":' + error_json + '}')
		return
	}
	eprintln('Error: ${message}')
	suggestion := error_suggestion(message)
	if suggestion != '' {
		eprintln('Hint: ${suggestion}')
	}
}

fn json_value_or_string(value string) string {
	trimmed := value.trim_space()
	if trimmed == '' {
		return 'null'
	}
	if is_json_literal(trimmed) {
		return trimmed
	}
	return json_str(value)
}

fn is_json_literal(value string) bool {
	if value.len == 0 {
		return false
	}
	if value.starts_with('{') || value.starts_with('[') || value.starts_with('"') {
		return true
	}
	if value == 'true' || value == 'false' || value == 'null' || value == 'undefined' {
		return true
	}
	first := value[0]
	return (first >= `0` && first <= `9`) || first == `-`
}

fn error_code(message string) string {
	msg := message.to_lower()
	if msg.contains('unknown command') {
		return 'UNKNOWN_COMMAND'
	}
	if msg.contains('missing ') || msg.contains('requires ') || msg.contains('invalid ') {
		return 'INVALID_ARGUMENT'
	}
	if msg.contains('not found') || msg.contains('no target tab available') || msg.contains('no tab is currently accessible') {
		return 'NOT_FOUND'
	}
	if msg.contains('debugger conflict') || msg.contains('another debugger is already attached') {
		return 'DEBUGGER_CONFLICT'
	}
	if msg.contains('ambiguous text match') || msg.contains('multiple candidates') {
		return 'AMBIGUOUS_MATCH'
	}
	if msg.contains('no extension connected') || msg.contains('no tab is connected') {
		return 'NOT_CONNECTED'
	}
	if msg.contains('invalid token') {
		return 'AUTH_FAILED'
	}
	if msg.contains('timeout') || msg.contains('timed out') {
		return 'TIMEOUT'
	}
	if msg.contains('verification failed') {
		return 'VERIFY_FAILED'
	}
	if msg.contains('failed to start') || msg.contains('did not become ready') {
		return 'STARTUP_FAILED'
	}
	if msg.contains('cannot connect') || msg.contains('connection') {
		return 'CONNECTION_FAILED'
	}
	return 'COMMAND_FAILED'
}

fn error_suggestion(message string) string {
	msg := message.to_lower()
	if msg.contains('debugger conflict') || msg.contains('another debugger is already attached') {
		return 'Close any other CDP sessions (Chrome DevTools, other automation tools) attached to the same tab, then run v-browser connect again.'
	}
	if msg.contains('no available tab') || msg.contains('no tab is currently accessible') || msg.contains('no target tab available') {
		return 'Switch to a normal webpage tab (not the extension page), then run v-browser connect again.'
	}
	if msg.contains('no extension connected') || msg.contains('no tab is connected') {
		return 'Run v-browser connect after syncing the extension id. If the extension page is already open, switch to a normal webpage tab before reconnecting.'
	}
	if msg.contains('not found') {
		return 'Check the selector or target tab. Use v-browser snapshot to inspect the current page, or use find --list / find --debug to review semantic candidates.'
	}
	if msg.contains('ambiguous text match') || msg.contains('multiple candidates') {
		return 'Use find --index to select a specific candidate, or add --name / --exact to narrow the match.'
	}
	if msg.contains('timeout') || msg.contains('timed out') {
		return 'Wait for the page to finish loading, or increase the command timeout if the page is expected to take longer.'
	}
	if msg.contains('verification failed') {
		return 'Check whether the target element actually changed. If the page is dynamic, increase --verify-timeout or verify a more stable state.'
	}
	if msg.contains('failed to start') || msg.contains('did not become ready') {
		return 'Check the server log, then try v-browser server restart or v-browser status to verify the daemon is healthy.'
	}
	if msg.contains('cannot connect') || msg.contains('connection') {
		return 'Verify the relay server and extension are running, then run v-browser connect again.'
	}
	if msg.contains('invalid ') || msg.contains('missing ') || msg.contains('requires ') {
		return 'Check the command arguments and try again. Use v-browser --help or the command reference if the syntax is unclear.'
	}
	return ''
}
