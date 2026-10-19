/**
 * Copyright (c) Microsoft Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { RelayConnection, debugLog } from "./relayConnection";
import { redactUrl } from "./redact";

type PageMessage =
  | {
      type: "connectToMCPRelay";
      mcpRelayUrl: string;
    }
  | {
      type: "getTabs";
    }
  | {
      type: "connectToTab";
      tabId?: number;
      windowId?: number;
      mcpRelayUrl: string;
    }
  | {
      type: "getConnectionStatus";
    }
  | {
      type: "syncExtensionRegistration";
      mcpRelayUrl?: string;
    }
  | {
      type: "disconnect";
    }
  | {
      type: "closeTabFromConnect";
      tabId?: number;
    }
  | {
      type: "cancelPendingConnection";
    };

// 过滤掉扩展页和浏览器内置页，只允许连接普通网页标签。
function isConnectableTabUrl(url: string): boolean {
  return ![
    "chrome-extension:",
    "chrome:",
    "edge:",
    "devtools:",
  ].some((scheme) => url.startsWith(scheme));
}

// 关闭 socket，忽略已断开时的异常。
function closeSocket(socket: WebSocket): void {
  try {
    socket.close();
  } catch {
    // socket 已经断了就无所谓。
  }
}

// 建立 relay WebSocket：超时或失败都要关掉 socket 并清掉定时器，
// 成功路径同样清掉定时器，避免留下悬挂的 socket。
function openRelaySocket(url: string, timeoutMs = 5000): Promise<WebSocket> {
  const socket = new WebSocket(url);
  return new Promise<WebSocket>((resolve, reject) => {
    let settled = false;
    const timeoutId = setTimeout(() => {
      if (settled) return;
      settled = true;
      closeSocket(socket);
      reject(new Error("Connection timeout"));
    }, timeoutMs);

    socket.onopen = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      resolve(socket);
    };

    socket.onerror = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeoutId);
      closeSocket(socket);
      reject(new Error("WebSocket error"));
    };
  });
}

// pending 连接条目：attempt 与 connection 必须成对保存，
// 授权与清理都按这对身份判断“谁拥有这份资源”。
type PendingSelection = {
  connection: RelayConnection;
  attempt: number;
  timerId?: ReturnType<typeof setTimeout>;
};

// 一次连接请求拥有的资源身份：代次 + 连接。
type PendingOwner = { attempt: number; connection: RelayConnection };

// 背景脚本：管理 relay 连接、目标 tab 选择和 badge 状态。
export class TabShareExtension {
  private _activeConnection: RelayConnection | undefined;
  private _connectedTabId: number | null = null;
  private _pendingTabSelection = new Map<number, PendingSelection>();
  // 连接尝试代次：每个选择页的每一次连接尝试都有一个递增代次。
  // 取消 / 被新连接替换 / 标签页关闭都会让当前代次作废，
  // 握手中的连接在代次作废后不得再建立。
  private _attempts = new Map<number, number>();
  private _attemptCounter = 0;

  constructor() {
    chrome.tabs.onRemoved.addListener(this._onTabRemoved.bind(this));
    chrome.tabs.onUpdated.addListener(this._onTabUpdated.bind(this));
    chrome.tabs.onActivated.addListener(this._onTabActivated.bind(this));
    chrome.runtime.onMessage.addListener(this._onMessage.bind(this));
    chrome.action.onClicked.addListener(this._onActionClicked.bind(this));
  }

  // Chrome 仍然不支持直接返回 Promise 的消息处理器。
  private _onMessage(
    message: PageMessage,
    sender: chrome.runtime.MessageSender,
    sendResponse: (response: any) => void,
  ) {
    switch (message.type) {
      case "connectToMCPRelay":
        this._connectToRelay(sender.tab!.id!, message.mcpRelayUrl).then(
          () => sendResponse({ success: true }),
          (error: any) => sendResponse({ success: false, error: error.message }),
        );
        return true;
      case "getTabs":
        this._getTabs().then(
          (tabs) => sendResponse({ success: true, tabs, currentTabId: sender.tab?.id }),
          (error: any) => sendResponse({ success: false, error: error.message }),
        );
        return true;
      case "connectToTab": {
        const selectorTabId = sender.tab?.id;
        // 本次请求拥有的资源：attempt 与 connection 必须成对取自同一条 pending 条目，
        // 否则失败清理时可能误伤别的代次。
        const pending =
          selectorTabId === undefined ? undefined : this._pendingTabSelection.get(selectorTabId);
        const owner: PendingOwner | undefined = pending
          ? { attempt: pending.attempt, connection: pending.connection }
          : undefined;

        this._resolveTargetTab(sender, message.tabId, message.windowId)
          .then(({ tabId, windowId }) => {
            if (selectorTabId === undefined || !owner) {
              throw new Error("No active MCP relay connection");
            }
            // 解析目标页是异步的：期间用户可能已经拒绝，
            // 或者同一页开始了新的尝试，这时不得再把旧连接转成 authorized。
            this._assertAttemptOwned(selectorTabId, owner);
            return this._connectTab(
              selectorTabId,
              tabId,
              windowId,
              message.mcpRelayUrl!,
              owner,
            );
          })
          .then(
            () => sendResponse({ success: true }),
            (error: any) => {
              // 全链失败：只清理本次请求自己拥有的资源，
              // 不能把新代次已经建立的 pending 连接一起关掉。
              if (selectorTabId !== undefined && owner) {
                this._cancelPendingConnection(selectorTabId, "Connection failed", owner);
              }
              sendResponse({ success: false, error: error.message });
            },
          );
        return true; // Return true to indicate that the response will be sent asynchronously
      }
      case "getConnectionStatus":
        sendResponse({
          connectedTabId: this._connectedTabId,
          extensionId: chrome.runtime.id,
          browserName: detectBrowserName(),
        });
        return false;
      case "syncExtensionRegistration":
        this._syncExtensionRegistration(message.mcpRelayUrl).then(
          (result) => sendResponse({ success: true, ...result }),
          (error: any) => sendResponse({ success: false, error: error.message }),
        );
        return true;
      case "disconnect":
        this._disconnect().then(
          () => sendResponse({ success: true }),
          (error: any) => sendResponse({ success: false, error: error.message }),
        );
        return true;
      case "closeTabFromConnect":
        // Close the tab that sent the message (sender.tab is the connect page)
        if (sender.tab && sender.tab.id) {
          console.log("[Background] Closing tab from connect:", sender.tab.id);
          chrome.tabs.remove(sender.tab.id);
        }
        sendResponse({ success: true });
        return false;
      case "cancelPendingConnection":
        // 用户拒绝/取消：必须显式销毁尚未授权的 pending 连接。
        if (sender.tab?.id !== undefined) {
          this._cancelPendingConnection(sender.tab.id, "Connection rejected by user");
        }
        sendResponse({ success: true });
        return false;
    }
    return false;
  }

  // 登记一次连接尝试：同一个选择页的旧尝试立即作废。
  private _beginAttempt(selectorTabId: number): number {
    this._attemptCounter += 1;
    const attempt = this._attemptCounter;
    this._attempts.set(selectorTabId, attempt);
    // 新尝试取代旧尝试：旧 pending 连接必须立刻关闭，
    // 否则旧请求在恢复之后还能继续把旧连接授权成 active。
    this._closePendingConnection(selectorTabId, "Replaced by a new relay connection");
    return attempt;
  }

  // 连接尝试是否仍然是该选择页的当前尝试。
  private _isAttemptCurrent(selectorTabId: number, attempt: number): boolean {
    return this._attempts.get(selectorTabId) === attempt;
  }

  // 让某个选择页当前的连接尝试作废（取消 / 替换 / 标签页关闭）。
  private _invalidateAttempt(selectorTabId: number): void {
    this._attemptCounter += 1;
    this._attempts.delete(selectorTabId);
  }

  // 确认本次请求仍然拥有当前尝试和对应的 pending 连接。
  // 跨越 await 之后必须复查：否则旧代次的请求会在新代次接管后继续生效。
  private _assertAttemptOwned(selectorTabId: number, owner: PendingOwner): void {
    if (!this._isAttemptCurrent(selectorTabId, owner.attempt)) {
      throw new Error("Connection attempt was cancelled");
    }
    const entry = this._pendingTabSelection.get(selectorTabId);
    if (!entry || entry.attempt !== owner.attempt || entry.connection !== owner.connection) {
      throw new Error("Connection attempt was cancelled");
    }
  }

  // 关闭并移除某个选择页的 pending 连接（不改变尝试代次）。
  private _closePendingConnection(selectorTabId: number, reason: string): void {
    const entry = this._pendingTabSelection.get(selectorTabId);
    if (!entry) return;
    if (entry.timerId) {
      clearTimeout(entry.timerId);
      entry.timerId = undefined;
    }
    this._pendingTabSelection.delete(selectorTabId);
    this._closeConnection(entry.connection, reason);
  }

  // 先连上 relay，但暂不绑定 tab，等待用户选择或自动选择目标页。
  private async _connectToRelay(selectorTabId: number, mcpRelayUrl: string): Promise<void> {
    // 握手开始就登记代次：握手期间用户可能已经拒绝或关掉了页面。
    const attempt = this._beginAttempt(selectorTabId);
    try {
      debugLog(`Connecting to relay at ${redactUrl(mcpRelayUrl)}`);
      const socket = await openRelaySocket(mcpRelayUrl);

      // 握手返回后必须复查代次：代次作废说明用户已经拒绝，
      // 这时只能关掉 socket，绝不能建立 pending 连接。
      if (!this._isAttemptCurrent(selectorTabId, attempt)) {
        closeSocket(socket);
        throw new Error("Connection attempt was cancelled");
      }

      const connection = new RelayConnection(socket);
      connection.onclose = () => {
        debugLog("Connection closed");
        const entry = this._pendingTabSelection.get(selectorTabId);
        // 旧连接的关闭回调不能删掉新连接的条目。
        if (!entry || entry.connection !== connection || entry.attempt !== attempt) return;
        if (entry.timerId) {
          clearTimeout(entry.timerId);
          entry.timerId = undefined;
        }
        this._pendingTabSelection.delete(selectorTabId);
        // TODO: show error in the selector tab?
      };

      // pending 条目带上 attempt：后面的授权与清理都按这对身份判断所有权。
      // 旧 pending 连接已经在 _beginAttempt 里关闭，这里直接挂上新的。
      this._pendingTabSelection.set(selectorTabId, { connection, attempt });

      debugLog(`Connected to MCP relay`);
    } catch (error: any) {
      // 不记录原始错误文本：里面可能混着 relay 地址里的凭据。
      debugLog("Failed to connect to MCP relay");
      throw new Error(
        error?.message === "Connection attempt was cancelled"
          ? "Connection attempt was cancelled"
          : "Failed to connect to MCP relay",
      );
    }
  }

  // 显式销毁某个选择页的 pending 连接。
  // owner 为空表示“用户主动取消当前尝试”：可以把当前的一切都清掉。
  // owner 非空表示“某个请求失败”：只能清理该请求自己拥有的资源，
  // 不能动新代次已经建立的 pending 连接。
  private _cancelPendingConnection(
    selectorTabId: number,
    reason: string,
    owner?: PendingOwner,
  ): void {
    const entry = this._pendingTabSelection.get(selectorTabId);
    if (owner) {
      // 旧请求失败：pending 条目已经不属于本次请求，直接放弃。
      if (!entry || entry.attempt !== owner.attempt || entry.connection !== owner.connection) {
        return;
      }
    }
    // 只有本次尝试仍然是当前尝试时才作废代次：
    // 旧请求的收尾不能反过来作废新开始的尝试。
    if (!owner || this._isAttemptCurrent(selectorTabId, owner.attempt)) {
      this._invalidateAttempt(selectorTabId);
    }
    this._closePendingConnection(selectorTabId, reason);
  }

  // 根据显式参数、当前窗口和发送者 tab 解析最终目标页。
  private async _resolveTargetTab(
    sender: chrome.runtime.MessageSender,
    requestedTabId?: number,
    requestedWindowId?: number,
  ): Promise<{ tabId: number; windowId: number }> {
    if (requestedTabId && requestedWindowId)
      return { tabId: requestedTabId, windowId: requestedWindowId };

    const tabs = await chrome.tabs.query({ lastFocusedWindow: true });
    const candidate = tabs.findLast((tab) => {
      if (!tab.id || !tab.windowId || !tab.url) return false;
      if (tab.id === sender.tab?.id) return false;
      return isConnectableTabUrl(tab.url);
    });
    if (candidate?.id && candidate.windowId)
      return { tabId: candidate.id, windowId: candidate.windowId };

    if (
      sender.tab?.id &&
      sender.tab.windowId &&
      sender.tab.url &&
      isConnectableTabUrl(sender.tab.url)
    )
      return { tabId: sender.tab.id, windowId: sender.tab.windowId };

    throw new Error("No target tab available for extension connection");
  }

  // 将 relay 连接切换到选中的 tab，并更新当前 badge 状态。
  // owner 是本次请求拥有的 attempt + connection：所有跨越 await 的动作都要复查它，
  // 免得旧代次的请求在新代次接管之后继续授权，或清掉别人的资源。
  private async _connectTab(
    selectorTabId: number,
    tabId: number,
    windowId: number,
    mcpRelayUrl: string,
    owner: PendingOwner,
  ): Promise<void> {
    try {
      debugLog(`Connecting tab ${tabId} to relay at ${redactUrl(mcpRelayUrl)}`);
      const previousConnection = this._activeConnection;
      // 之前 active 连接对应的 tab：回滚时要把 badge 恢复到它上面。
      const previousConnectedTabId = this._connectedTabId;
      const nextConnection = owner.connection;

      nextConnection.onTabIdChanged = (nextTabId) => {
        void this._setConnectedTabId(nextTabId);
      };

      await Promise.all([
        chrome.tabs.update(tabId, { active: true }),
        chrome.windows.update(windowId, { focused: true }),
      ]);
      // 浏览器 API 之后必须复查：期间可能已经开始了新的尝试，
      // 这时旧连接不能再被授权。
      this._assertAttemptOwned(selectorTabId, owner);

      nextConnection.setTabId(tabId);
      this._installActiveConnection(nextConnection);
      await this._setConnectedTabId(tabId);

      // badge / connectedTabId 更新期间连接可能已经被取消，或者被新尝试取代：
      // 此时旧连接已经 setTabId 并装进了 active 槽位，
      // 必须回滚掉，既不能对外报告成功，也不能让它残留在 active 槽位里。
      try {
        this._assertAttemptOwned(selectorTabId, owner);
      } catch (error) {
        this._rollbackActiveConnection(
          nextConnection,
          previousConnection,
          previousConnectedTabId,
        );
        throw error;
      }

      if (previousConnection) {
        try {
          previousConnection.close("Another connection is requested");
        } catch {
          debugLog("Error closing previous connection");
        }
      }

      // pending 条目转正：只清理本次请求自己拥有的条目，
      // 免得把新代次的 pending 连接删掉。
      const pendingEntry = this._pendingTabSelection.get(selectorTabId);
      if (
        pendingEntry &&
        pendingEntry.attempt === owner.attempt &&
        pendingEntry.connection === owner.connection
      ) {
        if (pendingEntry.timerId) clearTimeout(pendingEntry.timerId);
        this._pendingTabSelection.delete(selectorTabId);
      }
      // 只有本次尝试仍然是当前尝试时才结束代次：
      // 旧请求的收尾不能反过来作废新开始的尝试。
      if (this._isAttemptCurrent(selectorTabId, owner.attempt)) {
        this._invalidateAttempt(selectorTabId);
      }

      debugLog(`Connected to MCP bridge`);
    } catch (error: any) {
      // 失败时只清理本次请求自己拥有的 pending 连接与尝试代次。
      this._cancelPendingConnection(selectorTabId, "Connection switch failed", owner);
      debugLog(`Failed to connect tab ${tabId}`);
      throw error;
    }
  }

  // 回滚：刚装进 active 槽位的旧连接必须从槽位移除并关闭，
  // 之前的 active 连接还活着就恢复回去，
  // 避免已 setTabId 的旧连接残留成"看起来还连着"的僵尸状态。
  private _rollbackActiveConnection(
    connection: RelayConnection,
    previousConnection: RelayConnection | undefined,
    previousConnectedTabId: number | null,
  ): void {
    const active = this._activeConnection;
    if (active && active !== connection) {
      // active 槽位已经被别的连接接管：不能动它，只关掉这个旧连接。
      this._closeConnection(connection, "Connection attempt was cancelled");
      return;
    }
    if (active === connection) {
      this._activeConnection = undefined;
    }
    this._closeConnection(connection, "Connection attempt was cancelled");

    if (
      previousConnection &&
      previousConnection !== connection &&
      previousConnection.state !== "closed"
    ) {
      this._installActiveConnection(previousConnection);
      void this._setConnectedTabId(previousConnectedTabId ?? null);
    } else {
      void this._setConnectedTabId(null);
    }
  }

  // 关闭连接，忽略关闭过程中的异常。
  private _closeConnection(connection: RelayConnection, reason: string): void {
    try {
      connection.close(reason);
    } catch {
      debugLog("Error closing connection");
    }
  }

  // 记录当前激活的 relay 连接，并接管关闭回调。
  private _installActiveConnection(connection: RelayConnection): void {
    this._activeConnection = connection;
    connection.onclose = () => {
      if (this._activeConnection !== connection) return;
      debugLog("MCP connection closed");
      this._activeConnection = undefined;
      void this._setConnectedTabId(null);
    };
  }

  // 同步当前已连接 tab，并更新扩展图标角标。
  private async _setConnectedTabId(tabId: number | null): Promise<void> {
    const oldTabId = this._connectedTabId;
    this._connectedTabId = tabId;
    if (oldTabId && oldTabId !== tabId) await this._updateBadge(oldTabId, { text: "" });
    if (tabId)
      await this._updateBadge(tabId, {
        text: "✓",
        color: "#4CAF50",
        title: "Connected to MCP client",
      });
  }

  // 更新扩展图标上的 badge 和 tooltip。
  private async _updateBadge(
    tabId: number,
    { text, color, title }: { text: string; color?: string; title?: string },
  ): Promise<void> {
    try {
      await chrome.action.setBadgeText({ tabId, text });
      await chrome.action.setTitle({ tabId, title: title || "" });
      if (color) await chrome.action.setBadgeBackgroundColor({ tabId, color });
    } catch (_error: any) {
      // Ignore errors as the tab may be closed already.
    }
  }

  // 目标 tab 被关闭时，清理 pending/active 连接。
  private async _onTabRemoved(tabId: number): Promise<void> {
    // 标签页关闭：正在握手的连接尝试同样必须作废。
    this._invalidateAttempt(tabId);
    if (this._pendingTabSelection.has(tabId)) {
      this._cancelPendingConnection(tabId, "Browser tab closed");
      return;
    }
    if (this._connectedTabId !== tabId) return;
    this._activeConnection?.close("Browser tab closed");
    this._activeConnection = undefined;
    this._connectedTabId = null;
  }

  // 只允许短时间内保持待选 tab，避免用户长时间无操作。
  private _onTabActivated(activeInfo: chrome.tabs.TabActiveInfo) {
    for (const [tabId, pending] of this._pendingTabSelection) {
      if (tabId === activeInfo.tabId) {
        if (pending.timerId) {
          clearTimeout(pending.timerId);
          pending.timerId = undefined;
        }
        continue;
      }
      if (!pending.timerId) {
        pending.timerId = setTimeout(() => {
          const entry = this._pendingTabSelection.get(tabId);
          // 条目已经被新连接替换时，不能关掉新连接。
          if (!entry || entry.connection !== pending.connection) return;
          this._cancelPendingConnection(tabId, "Tab has been inactive for 30 seconds");
          chrome.tabs.sendMessage(tabId, { type: "connectionTimeout" }).catch(() => {});
        }, 30000);
        return;
      }
    }
  }

  // 当前已连接 tab 更新时，重新刷新 badge 状态。
  private _onTabUpdated(
    tabId: number,
    _changeInfo: chrome.tabs.TabChangeInfo,
    _tab: chrome.tabs.Tab,
  ) {
    if (this._connectedTabId === tabId) void this._setConnectedTabId(tabId);
  }

  // 获取可连接的普通网页标签列表。
  private async _getTabs(): Promise<chrome.tabs.Tab[]> {
    const tabs = await chrome.tabs.query({});
    return tabs.filter(
      (tab) => tab.url !== undefined && isConnectableTabUrl(tab.url),
    );
  }

  // 点击扩展图标时打开状态页。
  private async _onActionClicked(): Promise<void> {
    await chrome.tabs.create({
      url: chrome.runtime.getURL("status.html"),
      active: true,
    });
  }

  // 主动断开当前连接并清空连接状态。
  private async _disconnect(): Promise<void> {
    this._activeConnection?.close("User disconnected");
    this._activeConnection = undefined;
    await this._setConnectedTabId(null);
  }

  // 将扩展身份同步到本地 server，兼容主动连接和手动同步两种路径。
  private async _syncExtensionRegistration(mcpRelayUrl?: string): Promise<{
    extensionId: string;
    browserName: string;
    via: "active-connection" | "direct-connect";
  }> {
    const browserName = detectBrowserName();
    if (this._activeConnection) {
      this._activeConnection.sendExtensionRegistration({ browserName });
      return {
        extensionId: chrome.runtime.id,
        browserName,
        via: "active-connection",
      };
    }

    const relayUrl = mcpRelayUrl?.trim();
    if (!relayUrl) throw new Error("Missing relay URL for manual sync");

    const socket = await openRelaySocket(relayUrl);

    socket.send(
      JSON.stringify({
        method: "registerExtension",
        params: {
          extensionId: chrome.runtime.id,
          browserName,
        },
      }),
    );
    await new Promise((resolve) => setTimeout(resolve, 100));
    socket.close(1000, "Extension registration synced");

    return {
      extensionId: chrome.runtime.id,
      browserName,
      via: "direct-connect",
    };
  }
}

// 从 userAgent / UA-CH 中推断浏览器名称。
function detectBrowserName(): string {
  const navigatorWithBrands = navigator as Navigator & {
    userAgentData?: {
      brands?: Array<{ brand: string; version: string }>;
    };
  };
  const brands = navigatorWithBrands.userAgentData?.brands || [];
  const brandMatch = brands.find((brand) => !brand.brand.includes("Not"));
  if (brandMatch?.brand) return brandMatch.brand;

  const userAgent = navigator.userAgent;
  if (userAgent.includes("Edg/")) return "Microsoft Edge";
  if (userAgent.includes("Chromium/")) return "Chromium";
  if (userAgent.includes("Chrome/")) return "Google Chrome";
  if (userAgent.includes("Safari/")) return "Safari";
  return "Unknown browser";
}

new TabShareExtension();
