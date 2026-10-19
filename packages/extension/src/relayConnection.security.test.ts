import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// 扩展运行在 service worker 里，测试环境没有 chrome 全局，这里补一个最小实现。
type FakeSocket = {
  sent: any[];
  readyState: number;
  close: ReturnType<typeof vi.fn>;
  send: ReturnType<typeof vi.fn>;
  onmessage: ((event: { data: string }) => void) | null;
  onclose: (() => void) | null;
};

function createFakeSocket(): FakeSocket {
  const sent: any[] = [];
  const socket: FakeSocket = {
    sent,
    readyState: 1,
    close: vi.fn(() => {
      // 真实 WebSocket 的 close 是异步的：readyState 先变成已关闭，
      // onclose 事件之后才触发。
      socket.readyState = 3;
      setTimeout(() => socket.onclose?.(), 0);
    }),
    send: vi.fn((data: string) => {
      sent.push(JSON.parse(data));
    }),
    onmessage: null,
    onclose: null,
  };
  return socket;
}

const chromeMock = {
  runtime: { id: "test-extension-id" },
  storage: { local: { get: vi.fn(async () => ({})) } },
  debugger: {
    onEvent: { addListener: vi.fn(), removeListener: vi.fn() },
    onDetach: { addListener: vi.fn(), removeListener: vi.fn() },
    attach: vi.fn(async () => {}),
    detach: vi.fn(async () => {}),
    sendCommand: vi.fn(async () => ({ targetInfo: { targetId: "target-1" } })),
  },
  tabs: {
    query: vi.fn(async () => [
      {
        id: 11,
        windowId: 1,
        url: "https://example.com/",
        title: "Example",
        active: true,
      },
    ]),
    update: vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 })),
    create: vi.fn(async () => ({ id: 21, windowId: 1, url: "about:blank" })),
    remove: vi.fn(async () => {}),
  },
  windows: {
    update: vi.fn(async () => {}),
    create: vi.fn(async () => ({ id: 3, tabs: [{ id: 31, windowId: 3 }] })),
  },
};

// 让异步消息处理有机会跑完。
const flush = () => new Promise((resolve) => setTimeout(resolve, 5));

describe("RelayConnection 授权边界", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    chromeMock.debugger.attach = vi.fn(async () => {});
    chromeMock.debugger.detach = vi.fn(async () => {});
    chromeMock.debugger.sendCommand = vi.fn(async () => ({ targetInfo: { targetId: "target-1" } }));
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    (globalThis as Record<string, unknown>).chrome = chromeMock;
  });

  afterEach(() => {
    delete (globalThis as Record<string, unknown>).chrome;
  });

  it("未选择标签页时拒绝转发 CDP 命令", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({
      data: JSON.stringify({
        id: 1,
        method: "forwardCDPCommand",
        params: { method: "Runtime.evaluate", params: { expression: "1+1" } },
      }),
    });
    await flush();

    expect(chromeMock.debugger.attach).not.toHaveBeenCalled();
    expect(chromeMock.debugger.sendCommand).not.toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 1);
    expect(response.error).toMatch(/not authorized/i);
  });

  it("未选择标签页时拒绝 switchToTab / createTab / createWindow / closeTab", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    for (const [id, method, params] of [
      [1, "switchToTab", { tabId: 99 }],
      [2, "createTab", { url: "https://example.com" }],
      [3, "createWindow", { url: "https://example.com" }],
      [4, "closeTab", { tabId: 99 }],
    ] as const) {
      socket.onmessage!({ data: JSON.stringify({ id, method, params }) });
    }
    await flush();

    expect(chromeMock.debugger.attach).not.toHaveBeenCalled();
    expect(chromeMock.tabs.create).not.toHaveBeenCalled();
    expect(chromeMock.windows.create).not.toHaveBeenCalled();
    expect(chromeMock.tabs.remove).not.toHaveBeenCalled();
    for (const id of [1, 2, 3, 4]) {
      const response = socket.sent.find((message) => message.id === id);
      expect(response?.error).toMatch(/not authorized/i);
    }
  });

  it("未授权时拒绝 listTabs，不返回任何标签页标题或 URL", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({ data: JSON.stringify({ id: 7, method: "listTabs" }) });
    await flush();

    // 列表里带完整 title / url（query 里可能有重置 token），未授权时一律不给。
    expect(chromeMock.tabs.query).not.toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 7);
    expect(response?.error).toMatch(/not authorized/i);
    const printed = JSON.stringify(socket.sent);
    expect(printed).not.toContain("example.com");
    expect(printed).not.toContain("Example");
  });

  it("用户选择标签页后允许 listTabs", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    connection.setTabId(42);
    socket.onmessage!({ data: JSON.stringify({ id: 7, method: "listTabs" }) });
    await flush();

    expect(chromeMock.tabs.query).toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 7);
    expect(response.error).toBeUndefined();
    expect(Array.isArray(response.result)).toBe(true);
  });

  it("用户选择标签页后允许转发 CDP 命令", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    connection.setTabId(42);
    socket.onmessage!({
      data: JSON.stringify({
        id: 8,
        method: "forwardCDPCommand",
        params: { method: "Runtime.evaluate", params: { expression: "1+1" } },
      }),
    });
    await flush();

    expect(chromeMock.debugger.sendCommand).toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 8);
    expect(response.error).toBeUndefined();
  });
});

describe("RelayConnection 消息校验", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    chromeMock.debugger.attach = vi.fn(async () => {});
    chromeMock.debugger.detach = vi.fn(async () => {});
    chromeMock.debugger.sendCommand = vi.fn(async () => ({ targetInfo: { targetId: "target-1" } }));
    (globalThis as Record<string, unknown>).chrome = chromeMock;
  });

  afterEach(() => {
    delete (globalThis as Record<string, unknown>).chrome;
  });

  it("畸形 JSON 返回协议错误且不执行任何命令", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    new RelayConnection(socket as unknown as WebSocket);

    // 控制字符必须原样判为非法，不能被"清洗"成一条合法命令。
    socket.onmessage!({ data: '{"id":1,"method":"listTabs"\u0000}' });
    await flush();

    expect(chromeMock.tabs.query).not.toHaveBeenCalled();
    const error = socket.sent.find((message) => message.error?.code === -32700);
    expect(error).toBeDefined();
  });

  it("JSON null 不再被静默吞掉", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({ data: "null" });
    await flush();

    const error = socket.sent.find((message) => message.error?.code === -32600);
    expect(error).toBeDefined();
  });

  it("未知命令与缺少 id 的消息都会被拒绝", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({ data: JSON.stringify({ id: 5, method: "dropEverything" }) });
    socket.onmessage!({ data: JSON.stringify({ method: "listTabs" }) });
    await flush();

    const withId = socket.sent.find((message) => message.id === 5);
    expect(withId?.error?.code).toBe(-32600);
    const withoutId = socket.sent.find((message) => message.id === undefined && message.error);
    expect(withoutId?.error?.code).toBe(-32600);
    expect(chromeMock.tabs.query).not.toHaveBeenCalled();
  });

  it("参数类型错误也会被拒绝", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({ data: JSON.stringify({ id: 6, method: "listTabs", params: "nope" }) });
    await flush();

    const response = socket.sent.find((message) => message.id === 6);
    expect(response?.error?.code).toBe(-32600);
  });
});

describe("RelayConnection 生命周期", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    chromeMock.debugger.attach = vi.fn(async () => {});
    chromeMock.debugger.detach = vi.fn(async () => {});
    chromeMock.debugger.sendCommand = vi.fn(async () => ({ targetInfo: { targetId: "target-1" } }));
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    (globalThis as Record<string, unknown>).chrome = chromeMock;
  });

  afterEach(() => {
    delete (globalThis as Record<string, unknown>).chrome;
  });

  it("关闭时正在等待选 tab 的操作会失败", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    socket.onmessage!({ data: JSON.stringify({ id: 1, method: "attachToTab" }) });
    await flush();
    connection.close("closed by user");
    await flush();

    // socket 已经关闭：不会再有响应发出去，
    // 但等待中的操作必须以失败结束，不能再去 attach 任何标签页。
    expect(chromeMock.debugger.attach).not.toHaveBeenCalled();
    expect(connection.state).toBe("closed");
    expect(socket.sent.find((message) => message.id === 1)).toBeUndefined();
  });

  it("关闭期间完成的 attach 会立刻 detach", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    let releaseAttach: (() => void) | undefined;
    chromeMock.debugger.attach = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          releaseAttach = resolve;
        }),
    );

    connection.setTabId(42);
    socket.onmessage!({
      data: JSON.stringify({ id: 1, method: "switchToTab", params: { tabId: 7 } }),
    });
    await flush();

    connection.close("closed by user");
    chromeMock.debugger.detach.mockClear();

    releaseAttach!();
    await flush();

    expect(chromeMock.debugger.detach).toHaveBeenCalled();
  });

  it("关闭后排队中的操作不会再执行", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    let releaseUpdate: ((value: { id: number; windowId: number }) => void) | undefined;
    chromeMock.tabs.update = vi.fn(
      () =>
        new Promise<{ id: number; windowId: number }>((resolve) => {
          releaseUpdate = resolve;
        }),
    );

    connection.setTabId(42);
    socket.onmessage!({
      data: JSON.stringify({ id: 1, method: "switchToTab", params: { tabId: 7 } }),
    });
    await flush();
    socket.onmessage!({
      data: JSON.stringify({ id: 2, method: "switchToTab", params: { tabId: 8 } }),
    });
    await flush();

    connection.close("closed by user");
    releaseUpdate!({ id: 7, windowId: 1 });
    await flush();

    // 第二个命令不能再去 attach 另一个标签页。
    expect(chromeMock.debugger.attach).toHaveBeenCalledTimes(1);
    // 队列必须被释放：不会一直挂着，也不会产生额外的 Chrome 副作用。
    expect(chromeMock.tabs.update).toHaveBeenCalledTimes(1);
  });

  it("关闭后不再接收新消息", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    connection.close("closed by user");
    socket.onmessage!({ data: JSON.stringify({ id: 1, method: "listTabs" }) });
    await flush();

    expect(chromeMock.tabs.query).not.toHaveBeenCalled();
  });

  it("关闭会更新 socket 状态，之后不再有任何副作用", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    connection.setTabId(42);
    const sentBeforeClose = socket.sent.length;

    connection.close("closed by user");
    // 真实 socket 的 close 之后 readyState 变成已关闭。
    expect(socket.readyState).toBe(3);

    // onclose 是异步触发的：处理完之后不能再发任何消息。
    await flush();
    expect(socket.sent.length).toBe(sentBeforeClose);

    socket.onmessage!({ data: JSON.stringify({ id: 1, method: "listTabs" }) });
    await flush();
    expect(socket.sent.length).toBe(sentBeforeClose);
    expect(chromeMock.tabs.query).not.toHaveBeenCalled();
  });

  it("closeTab 在 detach 期间连接被关闭时不再关闭标签页", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);

    // 先挂到目标标签页上，closeTab 才会走 detach 分支。
    connection.setTabId(42);
    socket.onmessage!({
      data: JSON.stringify({ id: 1, method: "switchToTab", params: { tabId: 42 } }),
    });
    await flush();
    expect(chromeMock.debugger.attach).toHaveBeenCalled();

    let releaseDetach: (() => void) | undefined;
    // 所有 detach 调用共用同一个 promise：连接关闭时也会再 detach 一次，
    // 如果每次都新建 promise，测试就永远等不到真正挂起的那一次。
    const detachPromise = new Promise<void>((resolve) => {
      releaseDetach = resolve;
    });
    chromeMock.debugger.detach = vi.fn(() => detachPromise);

    socket.onmessage!({
      data: JSON.stringify({ id: 2, method: "closeTab", params: { tabId: 42 } }),
    });
    await flush();

    // detach 还没返回时连接被关闭。
    connection.close("closed by user");
    releaseDetach!();
    await flush();

    expect(chromeMock.tabs.remove).not.toHaveBeenCalled();
  });
});

describe("RelayConnection 参数校验与诊断日志", () => {
  const originalConsole = console.log;
  const globalScope = globalThis as Record<string, unknown>;

  beforeEach(() => {
    vi.clearAllMocks();
    console.log = vi.fn();
    globalScope.__V_BROWSER_DEBUG_LOGGING__ = true;
    chromeMock.debugger.attach = vi.fn(async () => {});
    chromeMock.debugger.detach = vi.fn(async () => {});
    chromeMock.debugger.sendCommand = vi.fn(async () => ({ targetInfo: { targetId: "target-1" } }));
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    globalScope.chrome = chromeMock;
  });

  afterEach(() => {
    console.log = originalConsole;
    delete globalScope.__V_BROWSER_DEBUG_LOGGING__;
    delete globalScope.chrome;
  });

  it("forwardCDPCommand 的内层 params 是数组时拒绝转发", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);
    connection.setTabId(42);

    socket.onmessage!({
      data: JSON.stringify({
        id: 3,
        method: "forwardCDPCommand",
        params: {
          method: "Runtime.evaluate",
          params: ["https://example.com/?token=deadbeefcafe"],
        },
      }),
    });
    await flush();

    expect(chromeMock.debugger.sendCommand).not.toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 3);
    expect(response?.error).toMatch(/params must be an object/i);
  });

  it("forwardCDPCommand 的内层 params 是 null 时拒绝转发", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);
    connection.setTabId(42);

    socket.onmessage!({
      data: JSON.stringify({
        id: 4,
        method: "forwardCDPCommand",
        params: { method: "Runtime.evaluate", params: null },
      }),
    });
    await flush();

    expect(chromeMock.debugger.sendCommand).not.toHaveBeenCalled();
    const response = socket.sent.find((message) => message.id === 4);
    expect(response?.error).toMatch(/params must be an object/i);
  });

  it("命令失败时日志里只有内部错误类别，不含错误原文", async () => {
    chromeMock.debugger.sendCommand = vi.fn(async () => {
      throw new Error(
        "Cannot navigate to https://example.com/reset?key=abc123&email=bob@example.com",
      );
    });
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);
    connection.setTabId(42);

    socket.onmessage!({
      data: JSON.stringify({
        id: 5,
        method: "forwardCDPCommand",
        params: { method: "Page.navigate", params: { url: "https://example.com/" } },
      }),
    });
    await flush();

    const printed = JSON.stringify((console.log as any).mock.calls);
    expect(printed).not.toContain("abc123");
    expect(printed).not.toContain("bob@example.com");
    expect(printed).not.toContain("key=");
    expect(printed).not.toContain("Cannot navigate to");
    // 只保留内部错误类别、请求 id、固定 method 和耗时。
    expect(printed).toContain("E_INTERNAL");
    expect(printed).toContain('"id":5');
    expect(printed).toContain("durationMs");
  });

  it("伪造合法域的 method 在日志里记成 unknown", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const socket = createFakeSocket();
    const connection = new RelayConnection(socket as unknown as WebSocket);
    connection.setTabId(42);

    socket.onmessage!({
      data: JSON.stringify({
        id: 6,
        method: "forwardCDPCommand",
        params: { method: "Runtime.arbitrary-private-content", params: {} },
      }),
    });
    await flush();

    const printed = JSON.stringify((console.log as any).mock.calls);
    expect(printed).toContain('"method":"unknown"');
    expect(printed).not.toContain("arbitrary-private-content");
  });
});
