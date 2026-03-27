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
    };

function isConnectableTabUrl(url: string): boolean {
  return ![
    "chrome-extension:",
    "chrome:",
    "edge:",
    "devtools:",
  ].some((scheme) => url.startsWith(scheme));
}

class TabShareExtension {
  private _activeConnection: RelayConnection | undefined;
  private _connectedTabId: number | null = null;
  private _pendingTabSelection = new Map<
    number,
    { connection: RelayConnection; timerId?: number }
  >();

  constructor() {
    chrome.tabs.onRemoved.addListener(this._onTabRemoved.bind(this));
    chrome.tabs.onUpdated.addListener(this._onTabUpdated.bind(this));
    chrome.tabs.onActivated.addListener(this._onTabActivated.bind(this));
    chrome.runtime.onMessage.addListener(this._onMessage.bind(this));
    chrome.action.onClicked.addListener(this._onActionClicked.bind(this));
  }

  // Promise-based message handling is not supported in Chrome: https://issues.chromium.org/issues/40753031
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
      case "connectToTab":
        this._resolveTargetTab(sender, message.tabId, message.windowId)
          .then(({ tabId, windowId }) =>
            this._connectTab(sender.tab?.id || tabId, tabId, windowId, message.mcpRelayUrl!),
          )
          .then(
            () => sendResponse({ success: true }),
            (error: any) => sendResponse({ success: false, error: error.message }),
          );
        return true; // Return true to indicate that the response will be sent asynchronously
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
    }
    return false;
  }

  private async _connectToRelay(selectorTabId: number, mcpRelayUrl: string): Promise<void> {
    try {
      debugLog(`Connecting to relay at ${mcpRelayUrl}`);
      const socket = new WebSocket(mcpRelayUrl);
      await new Promise<void>((resolve, reject) => {
        socket.onopen = () => resolve();
        socket.onerror = () => reject(new Error("WebSocket error"));
        setTimeout(() => reject(new Error("Connection timeout")), 5000);
      });

      const connection = new RelayConnection(socket);
      connection.onclose = () => {
        debugLog("Connection closed");
        this._pendingTabSelection.delete(selectorTabId);
        // TODO: show error in the selector tab?
      };
      this._pendingTabSelection.set(selectorTabId, { connection });
      debugLog(`Connected to MCP relay`);
    } catch (error: any) {
      const message = `Failed to connect to MCP relay: ${error.message}`;
      debugLog(message);
      throw new Error(message);
    }
  }

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

  private async _connectTab(
    selectorTabId: number,
    tabId: number,
    windowId: number,
    mcpRelayUrl: string,
  ): Promise<void> {
    try {
      debugLog(`Connecting tab ${tabId} to relay at ${mcpRelayUrl}`);
      const previousConnection = this._activeConnection;
      const nextConnection = this._pendingTabSelection.get(selectorTabId)?.connection;
      if (!nextConnection) throw new Error("No active MCP relay connection");

      nextConnection.onTabIdChanged = (nextTabId) => {
        void this._setConnectedTabId(nextTabId);
      };

      await Promise.all([
        chrome.tabs.update(tabId, { active: true }),
        chrome.windows.update(windowId, { focused: true }),
      ]);

      nextConnection.setTabId(tabId);
      this._installActiveConnection(nextConnection);
      await this._setConnectedTabId(tabId);

      if (previousConnection) {
        try {
          previousConnection.close("Another connection is requested");
        } catch (error: any) {
          debugLog(`Error closing previous connection:`, error);
        }
      }

      this._pendingTabSelection.delete(selectorTabId);

      debugLog(`Connected to MCP bridge`);
    } catch (error: any) {
      const pendingConnection = this._pendingTabSelection.get(selectorTabId)?.connection;
      if (pendingConnection) {
        try {
          pendingConnection.close("Connection switch failed");
        } catch (closeError: any) {
          debugLog(`Error closing pending connection after failed switch:`, closeError);
        }
        this._pendingTabSelection.delete(selectorTabId);
      }
      debugLog(`Failed to connect tab ${tabId}:`, error.message);
      throw error;
    }
  }

  private _installActiveConnection(connection: RelayConnection): void {
    this._activeConnection = connection;
    connection.onclose = () => {
      if (this._activeConnection !== connection) return;
      debugLog("MCP connection closed");
      this._activeConnection = undefined;
      void this._setConnectedTabId(null);
    };
  }

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

  private async _onTabRemoved(tabId: number): Promise<void> {
    const pendingConnection = this._pendingTabSelection.get(tabId)?.connection;
    if (pendingConnection) {
      this._pendingTabSelection.delete(tabId);
      pendingConnection.close("Browser tab closed");
      return;
    }
    if (this._connectedTabId !== tabId) return;
    this._activeConnection?.close("Browser tab closed");
    this._activeConnection = undefined;
    this._connectedTabId = null;
  }

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
          const existed = this._pendingTabSelection.delete(tabId);
          if (existed) {
            pending.connection.close("Tab has been inactive for 30 seconds");
            chrome.tabs.sendMessage(tabId, { type: "connectionTimeout" });
          }
        }, 30000);
        return;
      }
    }
  }

  private _onTabUpdated(
    tabId: number,
    _changeInfo: chrome.tabs.TabChangeInfo,
    _tab: chrome.tabs.Tab,
  ) {
    if (this._connectedTabId === tabId) void this._setConnectedTabId(tabId);
  }

  private async _getTabs(): Promise<chrome.tabs.Tab[]> {
    const tabs = await chrome.tabs.query({});
    return tabs.filter(
      (tab) => tab.url !== undefined && isConnectableTabUrl(tab.url),
    );
  }

  private async _onActionClicked(): Promise<void> {
    await chrome.tabs.create({
      url: chrome.runtime.getURL("status.html"),
      active: true,
    });
  }

  private async _disconnect(): Promise<void> {
    this._activeConnection?.close("User disconnected");
    this._activeConnection = undefined;
    await this._setConnectedTabId(null);
  }

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

    const socket = new WebSocket(relayUrl);
    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const timeoutId = setTimeout(() => {
        if (settled) return;
        settled = true;
        try {
          socket.close();
        } catch {}
        reject(new Error("Connection timeout"));
      }, 5000);

      socket.onopen = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        resolve();
      };

      socket.onerror = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeoutId);
        reject(new Error("WebSocket error"));
      };
    });

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
