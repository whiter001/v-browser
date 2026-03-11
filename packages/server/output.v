module main

fn format_output(result string, json_output bool) string {
	if !json_output {
		return result
	}
	return '{"ok":true,"result":' + json_value_or_string(result) + '}'
}

fn print_error(message string, json_output bool) {
	if json_output {
		code := error_code(message)
		println('{"ok":false,"error":{"code":' + json_str(code) + ',"message":' + json_str(message) + '}}')
		return
	}
	eprintln('Error: ${message}')
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
	if msg.contains('not found') || msg.contains('no target tab available') {
		return 'NOT_FOUND'
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
	if msg.contains('failed to start') || msg.contains('did not become ready') {
		return 'STARTUP_FAILED'
	}
	if msg.contains('cannot connect') || msg.contains('connection') {
		return 'CONNECTION_FAILED'
	}
	return 'COMMAND_FAILED'
}