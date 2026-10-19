import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

// 背景脚本运行在 service worker 里，测试环境没有 chrome / WebSocket，这里补最小实现。
class FakeWebSocket {
  static OPEN = 1;
  static CLOSED = 3;
  static instances: FakeWebSocket[] = [];

  readyState = 0;
  onopen: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onclose: (() => void) | null = null;
  sent: any[] = [];
  closeCalls = 0;

  constructor(public url: string) {
    FakeWebSocket.instances.push(this);
  }

  send(data: string) {
    this.sent.push(JSON.parse(data));
  }

  close() {
    this.closeCalls += 1;
    this.readyState = FakeWebSocket.CLOSED;
    setTimeout(() => this.onclose?.(), 0);
  }

  // 模拟握手完成。
  open() {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }
}

const chromeMock = {
  runtime: {
    id: "test-extension-id",
    onMessage: { addListener: vi.fn(), removeListener: vi.fn() },
    getManifest: vi.fn(() => ({ version: "1.0.0" })),
  },
  storage: { local: { get: vi.fn(async () => ({})) } },
  action: {
    onClicked: { addListener: vi.fn() },
    setBadgeText: vi.fn(async () => {}),
    setTitle: vi.fn(async () => {}),
    setBadgeBackgroundColor: vi.fn(async () => {}),
  },
  debugger: {
    onEvent: { addListener: vi.fn(), removeListener: vi.fn() },
    onDetach: { addListener: vi.fn(), removeListener: vi.fn() },
    attach: vi.fn(async () => {}),
    detach: vi.fn(async () => {}),
    sendCommand: vi.fn(async () => ({ targetInfo: { targetId: "target-1" } })),
  },
  tabs: {
    onRemoved: { addListener: vi.fn() },
    onUpdated: { addListener: vi.fn() },
    onActivated: { addListener: vi.fn() },
    query: vi.fn(async () => []),
    update: vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 })),
    create: vi.fn(async () => ({ id: 21, windowId: 1 })),
    remove: vi.fn(async () => {}),
    sendMessage: vi.fn(async () => {}),
  },
  windows: {
    update: vi.fn(async () => {}),
    create: vi.fn(async () => ({ id: 3, tabs: [{ id: 31, windowId: 3 }] })),
  },
};

// 让异步消息处理有机会跑完。
const flush = () => new Promise((resolve) => setTimeout(resolve, 5));

// 取出最近一次注册的 runtime.onMessage 监听器。
function lastMessageListener(): (
  message: any,
  sender: chrome.runtime.MessageSender,
  sendResponse: (response: any) => void,
) => any {
  const calls = chromeMock.runtime.onMessage.addListener.mock.calls;
  return calls[calls.length - 1][0];
}

function lastTabRemovedListener(): (tabId: number) => void {
  const calls = chromeMock.tabs.onRemoved.addListener.mock.calls;
  return calls[calls.length - 1][0];
}

describe("background 连接尝试代次", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    FakeWebSocket.instances = [];
    // 复位 mock 实现：clearAllMocks 不会清掉用例里替换过的实现。
    chromeMock.action.setBadgeText = vi.fn(async () => {});
    chromeMock.action.setTitle = vi.fn(async () => {});
    chromeMock.action.setBadgeBackgroundColor = vi.fn(async () => {});
    chromeMock.tabs.query = vi.fn(async () => []);
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    (globalThis as Record<string, unknown>).chrome = chromeMock;
    (globalThis as Record<string, unknown>).WebSocket = FakeWebSocket;
  });

  afterEach(() => {
    delete (globalThis as Record<string, unknown>).chrome;
    delete (globalThis as Record<string, unknown>).WebSocket;
  });

  it("握手中拒绝：不会建立 pending 连接，socket 被关掉", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    const sendResponse = vi.fn();
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:47978/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      sendResponse,
    );
    await flush();

    const socket = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    expect(socket).toBeDefined();

    // 握手中用户点了拒绝。
    listener(
      { type: "cancelPendingConnection" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();

    // 握手随后才完成。
    socket.open();
    await flush();

    // 取消之后不得再建立连接（RelayConnection 构造时才会注册 debugger 监听）。
    expect(chromeMock.debugger.onEvent.addListener).not.toHaveBeenCalled();
    expect(socket.closeCalls).toBeGreaterThan(0);
    expect(sendResponse).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
  });

  it("选择页关闭时握手中的连接尝试同样作废", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:47978/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();

    const socket = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];

    // 用户直接关掉了选择页。
    lastTabRemovedListener()(7);
    await flush();

    socket.open();
    await flush();

    expect(chromeMock.debugger.onEvent.addListener).not.toHaveBeenCalled();
    expect(socket.closeCalls).toBeGreaterThan(0);
  });

  it("连接中拒绝：pending 连接被销毁，不会变成 active 连接", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:47978/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();

    const socket = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socket.open();
    await flush();

    // pending 连接已经建立。
    expect(chromeMock.debugger.onEvent.addListener).toHaveBeenCalled();

    // 用户在连接过程中点了拒绝。
    listener(
      { type: "cancelPendingConnection" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();

    expect(socket.closeCalls).toBeGreaterThan(0);
    // 没有 active 连接被安装：badge 不会被设置。
    expect(chromeMock.action.setBadgeText).not.toHaveBeenCalled();
  });

  it("旧请求跨代次恢复时不得授权，也不得影响新代次", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    // A：建立 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketA = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketA.open();
    await flush();

    // A：授权流程暂停在浏览器 API（tabs.update）。
    let releaseUpdate: ((value: { id: number; windowId: number }) => void) | undefined;
    chromeMock.tabs.update = vi.fn(
      () =>
        new Promise<{ id: number; windowId: number }>((resolve) => {
          releaseUpdate = resolve;
        }),
    );
    chromeMock.tabs.query = vi.fn(async () => [
      { id: 99, windowId: 1, url: "https://example.com/" },
    ]);

    const responseA = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseA,
    );
    await flush();

    // B：同一个选择页开始新的握手，A 的代次就此作废。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketB = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketB.open();
    await flush();

    // 旧 pending 连接在替换尝试开始时就被关闭。
    expect(socketA.closeCalls).toBeGreaterThan(0);

    // A 恢复：代次已过期。
    releaseUpdate!({ id: 99, windowId: 1 });
    await flush();

    // A 不得被授权成 active：归属复查必须把这次授权拦下来。
    expect(responseA).toHaveBeenCalledWith(
      expect.objectContaining({ success: false, error: expect.stringContaining("cancelled") }),
    );
    expect(chromeMock.action.setBadgeText).not.toHaveBeenCalled();

    // A 的收尾不能作废 B 的尝试，也不能关掉 B 的连接。
    expect(socketB.closeCalls).toBe(0);

    // B 仍然可以正常完成授权。
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    const responseB = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseB,
    );
    await flush();

    expect(responseB).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    expect(chromeMock.action.setBadgeText).toHaveBeenCalled();
  });

  it("旧请求收尾时不会删掉新代次的 pending 条目或作废新代次", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    // A：建立 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketA = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketA.open();
    await flush();

    // A：授权流程推进到 badge 更新时挂起（此时 A 已经 setTabId）。
    let releaseBadge: (() => void) | undefined;
    let badgeCalls = 0;
    chromeMock.action.setBadgeText = vi.fn(() => {
      badgeCalls += 1;
      if (badgeCalls === 1) {
        return new Promise<void>((resolve) => {
          releaseBadge = resolve;
        });
      }
      return Promise.resolve();
    });
    chromeMock.tabs.query = vi.fn(async () => [
      { id: 99, windowId: 1, url: "https://example.com/" },
    ]);
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));

    const responseA = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseA,
    );
    await flush();

    // B：同一个选择页开始新的握手并成为新的 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketB = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketB.open();
    await flush();

    // A 恢复并收尾。
    releaseBadge!();
    await flush();

    expect(socketB.closeCalls).toBe(0);

    // B 的 pending 条目与尝试代次都没有被 A 的收尾破坏，仍能完成授权。
    const responseB = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseB,
    );
    await flush();

    expect(responseB).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    expect(socketB.closeCalls).toBe(0);
  });

  it("授权在 badge 更新期间被新尝试取代时不得报告成功", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    // A：建立 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketA = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketA.open();
    await flush();

    // A：授权推进到 badge / connectedTabId 更新时挂起。
    let releaseBadge: (() => void) | undefined;
    let badgeCalls = 0;
    chromeMock.action.setBadgeText = vi.fn(() => {
      badgeCalls += 1;
      if (badgeCalls === 1) {
        return new Promise<void>((resolve) => {
          releaseBadge = resolve;
        });
      }
      return Promise.resolve();
    });
    chromeMock.tabs.query = vi.fn(async () => [
      { id: 99, windowId: 1, url: "https://example.com/" },
    ]);
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));

    const responseA = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseA,
    );
    await flush();

    // B：同一个选择页开始新的握手，A 在 badge 更新期间被取代。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketB = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketB.open();
    await flush();

    // A 恢复：归属已经失效。
    releaseBadge!();
    await flush();

    // A 不能报告成功：它已经被新尝试取代。
    expect(responseA).toHaveBeenCalledWith(
      expect.objectContaining({ success: false, error: expect.stringContaining("cancelled") }),
    );
    // A 的连接必须被关闭清理，不能残留在 active 槽位里。
    expect(socketA.closeCalls).toBeGreaterThan(0);

    // B 的 pending / active 不受影响。
    expect(socketB.closeCalls).toBe(0);
    const responseB = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseB,
    );
    await flush();

    expect(responseB).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    expect(socketB.closeCalls).toBe(0);
    expect(chromeMock.action.setBadgeText).toHaveBeenLastCalledWith({
      tabId: 99,
      text: "✓",
    });
  });

  it("授权在 badge 更新期间被取消时回滚到之前的连接", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    chromeMock.tabs.query = vi.fn(async () => [
      { id: 99, windowId: 1, url: "https://example.com/" },
    ]);
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));

    // P：先建立一条成功的 active 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketP = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketP.open();
    await flush();
    const responseP = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseP,
    );
    await flush();
    expect(responseP).toHaveBeenCalledWith(expect.objectContaining({ success: true }));

    // Q：新的尝试在 badge 更新时挂起。
    let releaseBadge: (() => void) | undefined;
    let badgeCalls = 0;
    chromeMock.action.setBadgeText = vi.fn(() => {
      badgeCalls += 1;
      if (badgeCalls === 1) {
        return new Promise<void>((resolve) => {
          releaseBadge = resolve;
        });
      }
      return Promise.resolve();
    });

    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketQ = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketQ.open();
    await flush();

    const responseQ = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseQ,
    );
    await flush();

    // 用户在 Q 等待 badge 更新时取消。
    listener(
      { type: "cancelPendingConnection" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    releaseBadge!();
    await flush();

    // Q 必须报告失败。
    expect(responseQ).toHaveBeenCalledWith(
      expect.objectContaining({ success: false, error: expect.stringContaining("cancelled") }),
    );
    expect(socketQ.closeCalls).toBeGreaterThan(0);

    // 之前的 active 连接 P 仍然活着，并被恢复成当前连接。
    expect(socketP.closeCalls).toBe(0);
    expect(chromeMock.action.setBadgeText).toHaveBeenLastCalledWith({
      tabId: 99,
      text: "✓",
    });
  });

  it("旧请求失败时的清理不会关掉新代次的 pending 连接", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    // A：建立 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketA = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketA.open();
    await flush();

    // A：解析目标页挂起。
    let releaseQuery:
      | ((value: Array<{ id: number; windowId: number; url: string }>) => void)
      | undefined;
    chromeMock.tabs.query = vi.fn(
      () =>
        new Promise<Array<{ id: number; windowId: number; url: string }>>((resolve) => {
          releaseQuery = resolve;
        }),
    );

    const responseA = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseA,
    );
    await flush();

    // B：成为新的 pending 连接。
    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();
    const socketB = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socketB.open();
    await flush();

    // A 恢复：代次过期后失败。
    releaseQuery!([{ id: 99, windowId: 1, url: "https://example.com/" }]);
    await flush();

    expect(responseA).toHaveBeenCalledWith(
      expect.objectContaining({ success: false, error: expect.stringContaining("cancelled") }),
    );
    // 代次过期后不得再碰浏览器：失败的旧请求不能产生任何副作用。
    expect(chromeMock.tabs.update).not.toHaveBeenCalled();
    expect(chromeMock.windows.update).not.toHaveBeenCalled();
    // A 的失败清理不能关掉 B 的 pending 连接。
    expect(socketB.closeCalls).toBe(0);

    // B 仍然可以正常完成授权。
    chromeMock.tabs.query = vi.fn(async () => [
      { id: 99, windowId: 1, url: "https://example.com/" },
    ]);
    chromeMock.tabs.update = vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 }));
    const responseB = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:2/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      responseB,
    );
    await flush();

    expect(responseB).toHaveBeenCalledWith(expect.objectContaining({ success: true }));
    expect(chromeMock.action.setBadgeText).toHaveBeenCalled();
  });

  it("connectToTab 全链失败时清理对应的 pending 连接", async () => {
    const { TabShareExtension } = await import("./background");
    new TabShareExtension();
    const listener = lastMessageListener();

    listener(
      { type: "connectToMCPRelay", mcpRelayUrl: "ws://127.0.0.1:47978/relay" },
      { tab: { id: 7 } } as unknown as chrome.runtime.MessageSender,
      vi.fn(),
    );
    await flush();

    const socket = FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
    socket.open();
    await flush();
    expect(chromeMock.debugger.onEvent.addListener).toHaveBeenCalled();

    // 解析目标页失败：没有任何可用标签页。
    chromeMock.tabs.query = vi.fn(async () => []);
    const sendResponse = vi.fn();
    listener(
      { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:47978/relay" },
      { tab: { id: 7, windowId: 1, url: "chrome-extension://abc/connect.html" } } as unknown as chrome.runtime.MessageSender,
      sendResponse,
    );
    await flush();

    expect(sendResponse).toHaveBeenCalledWith(expect.objectContaining({ success: false }));
    // 失败之后 pending 连接必须被销毁，不能继续存活。
    expect(socket.closeCalls).toBeGreaterThan(0);
    expect(chromeMock.action.setBadgeText).not.toHaveBeenCalled();
  });
});
