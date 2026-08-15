# Draft: upstream issue for vlang/v

> ✅ 已提交：<https://github.com/vlang/v/issues/28091>
> 以下为提交时的正文（去除标题行）。在 v-browser 项目排查并发崩溃时定位到此根因，
> 最小复现已在本机验证。

---

**Title:** `sync.Mutex` used as a zero-value struct field silently provides NO mutual exclusion on macOS

**Environment:**

- V version: `V 0.5.2 1d0d86d`
- OS: macOS (Apple Silicon, arm64)
- C compiler: Apple clang

**Summary**

When a `sync.Mutex` is embedded as a struct field and the struct is created with
a plain literal (`&Store{}`), the mutex is never initialized — there is no
`init_with` support yet (the source even carries a TODO for it). On **Linux**
this happens to work because an all-zero `pthread_mutex_t` equals
`PTHREAD_MUTEX_INITIALIZER`. On **macOS**, however, Darwin's static initializer
contains a non-zero signature, so an all-zero mutex is invalid and
`pthread_mutex_lock()` fails **silently** — no error, no panic, and _no mutual
exclusion at all_.

Every critical section guarded by such a mutex runs unprotected. In a real
project this produced transient map lookup misses, lost writes, and occasional
segfaults inside `map_set` / `DenseArray_delete` / `Channel_try_push_priv` —
symptoms that looked like a map or channel runtime bug, but were actually
genuinely unsynchronized concurrent access.

**Minimal reproducer**

```v
module main

import sync
import time

@[heap]
struct Store {
mut:
	mu   sync.Mutex
	a    int
	b    int
	done bool
}

fn main() {
	mut s := &Store{}
	// NOTE: s.mu is never initialized. `sync.new_mutex()` would call .init(),
	// but a struct field cannot go through new_mutex().
	spawn fn [mut s] () {
		for {
			s.mu.@lock()
			a := s.a
			b := s.b
			done := s.done
			s.mu.unlock()
			if a != b {
				eprintln('TORN: a=${a} b=${b}')
			}
			if done {
				return
			}
		}
	}()
	for i in 0 .. 200000 {
		s.mu.@lock()
		s.a = i
		s.b = i
		s.mu.unlock()
	}
	s.mu.@lock()
	s.done = true
	s.mu.unlock()
	time.sleep(100 * time.millisecond)
	println('done')
}
```

**Observed (macOS arm64):** every run prints many `TORN: a=63 b=66` lines —
the reader observes torn state even though both threads use the same mutex
(same address verified) and generated C correctly calls
`pthread_mutex_lock(&s->mu.mutex)`.

**On Linux:** no torn reads (zeroed mutex is a valid static initializer there),
which is why this stays hidden in CI / Linux dev machines.

**With `s.mu.init()` added** before spawning: zero torn reads across 3 × 200k
iterations.

**Why it fails on Darwin**

`sync_darwin.c.v` declares:

```v
@[typedef]
pub struct C.pthread_mutex_t {}

@[heap]
pub struct Mutex {
	mutex C.pthread_mutex_t
}
```

and `Mutex.lock()` is just `C.pthread_mutex_lock(&m.mutex)`. A zeroed struct
field therefore yields a zeroed `pthread_mutex_t`, whose signature does not
match `_PTHREAD_MUTEX_SIG` — Darwin's libpthread rejects the lock call
(returns `EINVAL`), and V discards the return value, so the failure is
invisible.

**Suggested fixes (any of)**

1. Implement the long-standing `[init_with=new_mutex]` struct attribute so
   fields of such types are automatically constructed.
2. Give `Mutex` a lazy-init path like `RwMutex` already has (`inited` atomic +
   `lazy_init()` in `lock()`), making the zero value safe on every platform.
3. Short-term: check the return value of `pthread_mutex_lock` in debug builds
   (`should_be_zero`-style), and document prominently that `Mutex` fields must
   be `.init()`-ed explicitly.

**Workaround**

Call `.init()` on every `sync.Mutex` struct field in the constructor.
