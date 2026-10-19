import { describe, it, expect, vi } from "vitest";
import {
  ConnectionFlow,
  connectTabForConnect,
  loadTabsForConnect,
  runApprovalFlow,
} from "./connect";

describe("ConnectionFlow 取消闸门", () => {
  it("取消之后所有在途流程都失效", () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    expect(flow.isActive(flowId)).toBe(true);

    flow.cancel();
    expect(flow.isActive(flowId)).toBe(false);
  });

  it("新流程会让旧流程失效", () => {
    const flow = new ConnectionFlow();
    const first = flow.begin();
    const second = flow.begin();

    expect(flow.isActive(first)).toBe(false);
    expect(flow.isActive(second)).toBe(true);
  });

  it("取消之后新流程同样不能继续", () => {
    const flow = new ConnectionFlow();
    flow.begin();
    flow.cancel();

    const flowId = flow.begin();
    expect(flow.isActive(flowId)).toBe(false);
  });
});

describe("runApprovalFlow 授权流程", () => {
  it("握手中拒绝：不落盘凭据，也不发起授权连接", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();

    let release: ((value: boolean) => void) | undefined;
    const connectToRelay = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          release = resolve;
        }),
    );
    const persistToken = vi.fn();
    const authorize = vi.fn(async () => {});

    const pending = runApprovalFlow({ flow, flowId, connectToRelay, persistToken, authorize });

    // 握手还没回来，用户就点了拒绝。
    flow.cancel();
    release!(true);

    expect(await pending).toBe(false);
    expect(persistToken).not.toHaveBeenCalled();
    expect(authorize).not.toHaveBeenCalled();
  });

  it("relay 校验失败时不落盘凭据", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();

    const persistToken = vi.fn();
    const authorize = vi.fn(async () => {});

    const result = await runApprovalFlow({
      flow,
      flowId,
      connectToRelay: async () => false,
      persistToken,
      authorize,
    });

    expect(result).toBe(false);
    expect(persistToken).not.toHaveBeenCalled();
    expect(authorize).not.toHaveBeenCalled();
  });

  it("正常流程会先落盘凭据再授权连接", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();

    const order: string[] = [];
    const persistToken = vi.fn(() => {
      order.push("persist");
    });
    const authorize = vi.fn(async () => {
      order.push("authorize");
    });

    const result = await runApprovalFlow({
      flow,
      flowId,
      connectToRelay: async () => true,
      persistToken,
      authorize,
    });

    expect(result).toBe(true);
    expect(order).toEqual(["persist", "authorize"]);
  });

  it("授权过程中被拒绝时不再继续", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();

    let release: (() => void) | undefined;
    const authorize = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          release = resolve;
        }),
    );

    const pending = runApprovalFlow({
      flow,
      flowId,
      connectToRelay: async () => true,
      persistToken: vi.fn(),
      authorize,
    });

    await Promise.resolve();
    await Promise.resolve();
    flow.cancel();
    release!();

    expect(await pending).toBe(false);
  });
});

describe("终止性失败必须走 reject", () => {
  it("getTabs 失败时调用 reject（后台据此销毁 pending 连接）", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onTabs = vi.fn();
    const onReject = vi.fn();

    const result = await loadTabsForConnect({
      flow,
      flowId,
      sendMessage: async () => ({ success: false, error: "boom" }),
      onTabs,
      onReject,
    });

    expect(result).toBe(false);
    expect(onReject).toHaveBeenCalledWith(expect.stringContaining("boom"));
    expect(onTabs).not.toHaveBeenCalled();
  });

  it("getTabs 抛异常时同样调用 reject", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onReject = vi.fn();

    await loadTabsForConnect({
      flow,
      flowId,
      sendMessage: async () => {
        throw new Error("runtime unavailable");
      },
      onTabs: vi.fn(),
      onReject,
    });

    expect(onReject).toHaveBeenCalled();
  });

  it("getTabs 成功时只更新列表", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onTabs = vi.fn();
    const onReject = vi.fn();

    const result = await loadTabsForConnect({
      flow,
      flowId,
      sendMessage: async () => ({ success: true, tabs: [{ id: 1, title: "a", url: "b" }] }),
      onTabs,
      onReject,
    });

    expect(result).toBe(true);
    expect(onTabs).toHaveBeenCalled();
    expect(onReject).not.toHaveBeenCalled();
  });

  it("connectToTab 失败时调用 reject", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onConnected = vi.fn();
    const onReject = vi.fn();

    const result = await connectTabForConnect({
      flow,
      flowId,
      sendMessage: async () => ({ success: false, error: "no target tab" }),
      request: { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      onConnected,
      onReject,
    });

    expect(result).toBe(false);
    expect(onReject).toHaveBeenCalledWith("no target tab");
    expect(onConnected).not.toHaveBeenCalled();
  });

  it("connectToTab 抛异常时调用 reject", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onReject = vi.fn();

    await connectTabForConnect({
      flow,
      flowId,
      sendMessage: async () => {
        throw new Error("runtime unavailable");
      },
      request: { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      onConnected: vi.fn(),
      onReject,
    });

    expect(onReject).toHaveBeenCalled();
  });

  it("已取消时不再调用 reject，也不改状态", async () => {
    const flow = new ConnectionFlow();
    const flowId = flow.begin();
    const onConnected = vi.fn();
    const onReject = vi.fn();

    const pending = connectTabForConnect({
      flow,
      flowId,
      sendMessage: async () => {
        flow.cancel();
        return { success: false, error: "no target tab" };
      },
      request: { type: "connectToTab", mcpRelayUrl: "ws://127.0.0.1:1/relay" },
      onConnected,
      onReject,
    });

    expect(await pending).toBe(false);
    expect(onReject).not.toHaveBeenCalled();
    expect(onConnected).not.toHaveBeenCalled();
  });
});
