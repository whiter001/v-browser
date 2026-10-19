import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { redactCdpParams, redactPayload, scrubSecrets } from "./redact";

describe("redactPayload 覆盖 CDP 载荷", () => {
  it("URL 里的 query token 不会漏出去", () => {
    const redacted = redactPayload({
      url: "https://example.com/feed?token=deadbeefcafe&user=bob",
    });
    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
    expect(JSON.stringify(redacted)).not.toContain("user=bob");
  });

  it("Runtime.evaluate 的 expression 默认隐藏", () => {
    const redacted = redactPayload({
      expression: "fetch('https://example.com/?token=deadbeefcafe')",
    });
    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
  });

  it("请求体 / postData 默认隐藏", () => {
    const redacted = redactPayload({
      postData: "password=hunter2",
      body: "password=hunter2",
    });
    expect(JSON.stringify(redacted)).not.toContain("hunter2");
  });

  it("{name,value} 形式的请求头只保留头部名", () => {
    const redacted = redactPayload({
      headers: [
        { name: "Authorization", value: "Bearer abc123" },
        { name: "Cookie", value: "sid=xyz" },
      ],
    });
    const printed = JSON.stringify(redacted);
    expect(printed).not.toContain("abc123");
    expect(printed).not.toContain("sid=xyz");
    expect(printed).toContain("Authorization");
  });

  it("Error.message 里的秘密会被清洗", () => {
    const redacted = redactPayload(
      new Error("failed to connect ws://127.0.0.1:47978?token=deadbeefcafe"),
    ) as Record<string, unknown>;
    expect(String(redacted.message)).not.toContain("deadbeefcafe");
  });

  it("scrubSecrets 清洗常见凭据写法", () => {
    expect(scrubSecrets("Authorization: Bearer abc.def.ghi")).not.toContain("abc.def.ghi");
    expect(scrubSecrets("token=abc123")).not.toContain("abc123");
    expect(scrubSecrets("api_key: 0123456789abcdef0123456789abcdef")).not.toContain(
      "0123456789abcdef0123456789abcdef",
    );
  });
});

describe("redactCdpParams 按 method 结构化脱敏", () => {
  it("Runtime.evaluate 隐藏 expression，只保留安全的上下文字段", () => {
    const redacted = redactCdpParams("Runtime.evaluate", {
      expression: "document.cookie",
      contextId: 3,
      returnByValue: true,
    }) as Record<string, unknown>;

    expect(redacted.expression).toBe("[hidden]");
    expect(redacted.contextId).toBe(3);
    expect(redacted.returnByValue).toBe(true);
  });

  it("Page.navigate 的 URL 走 redactUrl", () => {
    const redacted = redactCdpParams("Page.navigate", {
      url: "https://example.com/page?token=deadbeefcafe",
      transitionType: "typed",
    }) as Record<string, unknown>;

    expect(String(redacted.url)).toBe("https://example.com/page");
    expect(String(redacted.url)).not.toContain("deadbeefcafe");
    expect(redacted.transitionType).toBe("typed");
  });

  it("未列入白名单的字段默认隐藏", () => {
    const redacted = redactCdpParams("Some.UnknownMethod", {
      url: "https://example.com/",
      secretish: "value",
    }) as Record<string, unknown>;

    expect(redacted.url).toBe("https://example.com/");
    expect(redacted.secretish).toBe("[hidden]");
  });

  it("请求头只保留头部名", () => {
    const redacted = redactCdpParams("Network.enable", {
      headers: { Authorization: "Bearer abc123" },
    }) as Record<string, unknown>;

    expect(JSON.stringify(redacted)).not.toContain("abc123");
  });
});

describe("redactCdpParams 必须 fail-closed", () => {
  it("根是数组时整体隐藏", () => {
    const redacted = redactCdpParams("Runtime.evaluate", [
      "https://example.com/?token=deadbeefcafe",
    ]);

    expect(redacted).toBe("[hidden]");
    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
  });

  it("url 是数组时整体隐藏，query 不会原样保留", () => {
    const redacted = redactCdpParams("Page.navigate", {
      url: ["https://example.com/page?token=deadbeefcafe"],
    }) as Record<string, unknown>;

    expect(redacted.url).toBe("[hidden]");
    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
  });

  it("url 是对象时整体隐藏", () => {
    const redacted = redactCdpParams("Page.navigate", {
      url: { href: "https://example.com/page?token=deadbeefcafe" },
    }) as Record<string, unknown>;

    expect(redacted.url).toBe("[hidden]");
    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
  });

  it("白名单字段类型不符时整体隐藏", () => {
    const redacted = redactCdpParams("Runtime.evaluate", {
      contextId: "3",
      returnByValue: "yes",
    }) as Record<string, unknown>;

    expect(redacted.contextId).toBe("[hidden]");
    expect(redacted.returnByValue).toBe("[hidden]");
  });

  it("白名单字段类型正确时仍然可见", () => {
    const redacted = redactCdpParams("Runtime.evaluate", {
      contextId: 3,
      returnByValue: true,
    }) as Record<string, unknown>;

    expect(redacted.contextId).toBe(3);
    expect(redacted.returnByValue).toBe(true);
  });
});

describe("scrubSecrets 必须是 fail-closed", () => {
  it("文本里的 URL query 会被裁掉", () => {
    const scrubbed = scrubSecrets(
      "Cannot navigate to https://example.com/reset?key=abc123&email=bob@example.com",
    );

    expect(scrubbed).not.toContain("abc123");
    expect(scrubbed).not.toContain("bob@example.com");
    expect(scrubbed).toContain("https://example.com/reset");
  });

  it("redactPayload 里的非字符串 url 整体隐藏", () => {
    const redacted = redactPayload({
      url: ["https://example.com/feed?token=deadbeefcafe"],
    });

    expect(JSON.stringify(redacted)).not.toContain("deadbeefcafe");
  });
});

describe("诊断日志白名单", () => {
  const originalConsole = console.log;
  const globalScope = globalThis as Record<string, unknown>;

  const chromeMock = {
    runtime: { id: "test-extension-id" },
    storage: { local: { get: vi.fn(async () => ({})) } },
    debugger: {
      onEvent: { addListener: vi.fn(), removeListener: vi.fn() },
      onDetach: { addListener: vi.fn(), removeListener: vi.fn() },
      attach: vi.fn(async () => {}),
      detach: vi.fn(async () => {}),
      sendCommand: vi.fn(async () => ({ targetInfo: {} })),
    },
    tabs: {
      query: vi.fn(async () => []),
      update: vi.fn(async (tabId: number) => ({ id: tabId, windowId: 1 })),
      create: vi.fn(async () => ({ id: 21, windowId: 1 })),
      remove: vi.fn(async () => {}),
    },
    windows: { update: vi.fn(async () => {}), create: vi.fn(async () => ({})) },
  };

  beforeEach(() => {
    console.log = vi.fn();
    globalScope.__V_BROWSER_DEBUG_LOGGING__ = true;
    globalScope.chrome = chromeMock;
  });

  afterEach(() => {
    console.log = originalConsole;
    delete globalScope.__V_BROWSER_DEBUG_LOGGING__;
    delete globalScope.chrome;
  });

  it("转发 CDP 命令时不会打印表达式和请求体里的秘密", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const sent: any[] = [];
    const socket = {
      readyState: 1,
      close: vi.fn(),
      send: vi.fn((data: string) => sent.push(JSON.parse(data))),
      onmessage: null as ((event: { data: string }) => void) | null,
      onclose: null,
    };

    const connection = new RelayConnection(socket as unknown as WebSocket);
    connection.setTabId(42);
    socket.onmessage!({
      data: JSON.stringify({
        id: 3,
        method: "forwardCDPCommand",
        params: {
          method: "Runtime.evaluate",
          params: { expression: "fetch('https://example.com/?token=deadbeefcafe')" },
        },
      }),
    });
    await new Promise((resolve) => setTimeout(resolve, 5));

    const printed = JSON.stringify((console.log as any).mock.calls);
    expect(printed).not.toContain("deadbeefcafe");
    // 白名单字段仍然可见，方便排查问题。
    expect(printed).toContain("Runtime.evaluate");
  });

  it("诊断日志只输出 id / method / 耗时 / 状态", async () => {
    const { RelayConnection } = await import("./relayConnection");
    const sent: any[] = [];
    const socket = {
      readyState: 1,
      close: vi.fn(),
      send: vi.fn((data: string) => sent.push(JSON.parse(data))),
      onmessage: null as ((event: { data: string }) => void) | null,
      onclose: null,
    };

    new RelayConnection(socket as unknown as WebSocket);
    socket.onmessage!({ data: JSON.stringify({ id: 9, method: "listTabs" }) });
    await new Promise((resolve) => setTimeout(resolve, 5));

    const printed = JSON.stringify((console.log as any).mock.calls);
    expect(printed).toContain('"id":9');
    expect(printed).toContain('"method":"listTabs"');
    expect(printed).toContain("durationMs");
  });
});
