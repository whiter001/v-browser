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
		// 提取 result 部分
		start := trimmed.index('"result":') or { return s }
		rest := trimmed[start + 9..] // 跳过 "result": 这9个字符
		// 找到值的开始位置
		if rest.starts_with('"') {
			// 这是一个字符串，需要解码
			mut result := ''
			for i := 1; i < rest.len; i++ {
				c := rest[i]
				if c == `\\` && i + 1 < rest.len {
					// 转义字符
					next := rest[i + 1]
					match next {
						`n` { result += '\n' }
						`r` { result += '\r' }
						`t` { result += '\t' }
						`"` { result += '"' }
						`\\` { result += '\\' }
						`/` { result += '/' }
						`b` { result += '\b' }
						`f` { result += '\f' }
						`u` {
							// Unicode 转义序列 \uXXXX
							if i + 5 < rest.len {
								hex_str := rest[i + 2..i + 6]
								if hex_str.len == 4 {
									mut code := u16(0)
									for j := 0; j < 4; j++ {
										code = code << 4 | u16(hex_char_to_int(hex_str[j]))
									}
									result += rune(code).str()
									i += 4
									continue
								}
							}
							// 无效的 Unicode 转义，保留原样
							result += '\\u'
						}
						else {
							// 未知转义字符，保留反斜杠和字符
							result += '\\'
							result += rest[i + 1].ascii_str()
						}
					}
					i++
				} else if c == `"` {
					return result
				} else {
					result += rest[i].ascii_str()
				}
			}
		}
	}
	// 尝试直接解析为 JSON 字符串
	if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len > 1 {
		mut result := ''
		for i := 1; i < trimmed.len - 1; i++ {
			if trimmed[i] == `\\` && i + 1 < trimmed.len - 1 {
				next := trimmed[i + 1]
				match next {
					`n` { result += '\n' }
					`r` { result += '\r' }
					`t` { result += '\t' }
					`"` { result += '"' }
					`\\` { result += '\\' }
					`/` { result += '/' }
					`b` { result += '\b' }
					`f` { result += '\f' }
					`u` {
						// Unicode 转义序列 \uXXXX
						if i + 5 < trimmed.len - 1 {
							hex_str := trimmed[i + 2..i + 6]
							if hex_str.len == 4 {
								mut code := u16(0)
								for j := 0; j < 4; j++ {
									code = code << 4 | u16(hex_char_to_int(hex_str[j]))
								}
								result += rune(code).str()
								i += 4
								continue
							}
						}
						// 无效的 Unicode 转义，保留原样
						result += '\\u'
					}
					else {
						// 未知转义字符，保留反斜杠和字符
						result += '\\'
						result += trimmed[i + 1].ascii_str()
					}
				}
				i++
			} else {
				result += trimmed[i].ascii_str()
			}
		}
		return result
	}
	return s
}

fn print_error(message string, json_output bool) {
	if json_output {
		code := error_code(message)
		println('{"ok":false,"error":{"code":' + json_str(code) + ',"message":' +
			json_str(message) + '}}')
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
