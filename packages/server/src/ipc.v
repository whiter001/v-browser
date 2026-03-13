// ipc.v — CLI ↔ Server IPC 协议（JSON 行协议，127.0.0.1:47979）
module main

// IpcRequest CLI 发给 server 的请求
struct IpcRequest {
	id     int
	method string
	params string // raw JSON object
}

// IpcResponse server 回给 CLI 的响应
struct IpcResponse {
	id     int
	result string // raw JSON（成功时）
	err    string // 错误消息（失败时）
}

fn ipc_encode_request(req IpcRequest) string {
	p := if req.params == '' { '{}' } else { req.params }
	return '{"id":${req.id},"method":${json_str(req.method)},"params":${p}}\n'
}

fn ipc_encode_response(resp IpcResponse) string {
	if resp.err != '' {
		return '{"id":${resp.id},"error":${json_str(resp.err)}}\n'
	}
	result := if resp.result == '' { 'null' } else { resp.result }
	return '{"id":${resp.id},"result":${result}}\n'
}

fn ipc_decode_request(line string) !IpcRequest {
	t := line.trim_space()
	if t.len == 0 {
		return error('empty line')
	}
	mut id := 0
	mut method := ''
	mut params := '{}'

	if idx := t.index('"id":') {
		rest := t[idx + 5..].trim_left(' ')
		mut end := 0
		for end < rest.len && rest[end] in [`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `-`] {
			end++
		}
		if end > 0 {
			id = rest[..end].int()
		}
	}
	if idx := t.index('"method":') {
		rest := t[idx + 9..].trim_left(' ')
		if rest.starts_with('"') {
			end := rest.index_after_('"', 1)
			if end > 0 {
				method = rest[1..end]
			}
		}
	}
	if idx := t.index('"params":') {
		params = cdp_extract_value(t[idx + 9..].trim_left(' '))
	}
	if method == '' {
		return error('missing method field')
	}
	return IpcRequest{
		id:     id
		method: method
		params: params
	}
}

fn ipc_decode_response(line string) !IpcResponse {
	t := line.trim_space()
	if t.len == 0 {
		return error('empty line')
	}
	mut id := 0
	mut result := ''
	mut err_str := ''

	if idx := t.index('"id":') {
		rest := t[idx + 5..].trim_left(' ')
		mut end := 0
		for end < rest.len && rest[end] in [`0`, `1`, `2`, `3`, `4`, `5`, `6`, `7`, `8`, `9`, `-`] {
			end++
		}
		if end > 0 {
			id = rest[..end].int()
		}
	}
	if idx := t.index('"result":') {
		result = cdp_extract_value(t[idx + 9..].trim_left(' '))
	}
	if idx := t.index('"error":') {
		err_str = cdp_extract_value(t[idx + 8..].trim_left(' ')).trim('"')
	}
	return IpcResponse{
		id:     id
		result: result
		err:    err_str
	}
}
