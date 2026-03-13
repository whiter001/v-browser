// axref.v — @eN 引用符 ↔ backendNodeId 映射
// snapshot 命令生成编号引用，后续命令通过引用符定位元素
module main

import sync

@[heap]
struct AxRefStore {
mut:
	refs map[string]AxRef // "@e1" → AxRef
	mu   sync.Mutex
}

struct AxRef {
	backend_node_id int
	node_id         int
	object_id       string // Runtime.RemoteObjectId（可选，click 时用坐标更可靠）
	selector        string
	role            string
	name            string
	// 元素在页面上的大致坐标（由 DOM.getBoxModel 查出，缓存在此）
	x          f64
	y          f64
	has_coords bool
}

fn axref_clear(mut store AxRefStore) {
	store.mu.@lock()
	store.refs.clear()
	store.mu.unlock()
}

// axref_set 设置引用
fn axref_set(mut store AxRefStore, key string, r AxRef) {
	store.mu.@lock()
	store.refs[key] = r
	store.mu.unlock()
}

// axref_get 查找引用，返回 Option
fn axref_get(store &AxRefStore, key string) ?AxRef {
	unsafe {
		mut mu := &store.mu
		mu.@lock()
		defer { mu.unlock() }
	}
	if r := store.refs[key] {
		return r
	}
	return none
}

// axref_is_ref 判断选择器是否为 @eN 格式
fn axref_is_ref(sel string) bool {
	if sel.len < 3 || !sel.starts_with('@') {
		return false
	}
	if sel[1] != `e` {
		return false
	}
	for c in sel[2..] {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}
