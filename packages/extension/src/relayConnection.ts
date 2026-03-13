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

export function debugLog(...args: unknown[]): void {
  const enabled = true;
  if (enabled) {
    // eslint-disable-next-line no-console
    console.log("[Extension]", ...args);
  }
}

type ProtocolCommand = {
  id: number;
  method: string;
  params?: any;
};

type ProtocolResponse = {
  id?: number;
  method?: string;
  params?: any;
  result?: any;
  error?: string;
};

export class RelayConnection {
  private _debuggee: chrome.debugger.Debuggee;
  private _ws: WebSocket;
  private _eventListener: (
    source: chrome.debugger.DebuggerSession,
    method: string,
    params: any,
  ) => void;
  private _detachListener: (source: chrome.debugger.Debuggee, reason: string) => void;
  private _tabPromise: Promise<void>;
  private _tabPromiseResolve!: () => void;
  private _closed = false;
  private _isAttached = false;

  onclose?: () => void;
  onTabIdChanged?: (tabId: number, previousTabId: number | null) => void | Promise<void>;

  constructor(ws: WebSocket) {
    this._debuggee = {};
    this._tabPromise = new Promise((resolve) => (this._tabPromiseResolve = resolve));
    this._ws = ws;
    this.sendExtensionRegistration();
    this._ws.onmessage = this._onMessage.bind(this);
    this._ws.onclose = () => this._onClose();
    // Store listeners for cleanup
    this._eventListener = this._onDebuggerEvent.bind(this);
    this._detachListener = this._onDebuggerDetach.bind(this);
    chrome.debugger.onEvent.addListener(this._eventListener);
    chrome.debugger.onDetach.addListener(this._detachListener);
  }

  // Either setTabId or close is called after creating the connection.
  setTabId(tabId: number): void {
    this._debuggee = { tabId };
    this._tabPromiseResolve();
  }

  sendExtensionRegistration(extraParams?: Record<string, unknown>): void {
    this._sendMessage({
      method: "registerExtension",
      params: {
        extensionId: chrome.runtime.id,
        ...extraParams,
      },
    });
  }

  close(message: string): void {
    this._ws.close(1000, message);
    // ws.onclose is called asynchronously, so we call it here to avoid forwarding
    // CDP events to the closed connection.
    this._onClose();
  }

  private _onClose() {
    if (this._closed) return;
    this._closed = true;
    chrome.debugger.onEvent.removeListener(this._eventListener);
    chrome.debugger.onDetach.removeListener(this._detachListener);
    chrome.debugger.detach(this._debuggee).catch(() => {});
    this._isAttached = false;
    this.onclose?.();
  }

  private _onDebuggerEvent(
    source: chrome.debugger.DebuggerSession,
    method: string,
    params: any,
  ): void {
    if (source.tabId !== this._debuggee.tabId) return;
    debugLog("Forwarding CDP event:", method, params);
    const sessionId = source.sessionId;
    this._sendMessage({
      method: "forwardCDPEvent",
      params: {
        sessionId,
        method,
        params,
      },
    });
  }

  private _onDebuggerDetach(source: chrome.debugger.Debuggee, reason: string): void {
    if (source.tabId !== this._debuggee.tabId) return;
    this._isAttached = false;
    this.close(`Debugger detached: ${reason}`);
    this._debuggee = {};
  }

  private _onMessage(event: MessageEvent): void {
    this._onMessageAsync(event).catch((e) => debugLog("Error handling message:", e));
  }

  private async _onMessageAsync(event: MessageEvent): Promise<void> {
    let message: ProtocolCommand;
    try {
      message = JSON.parse(event.data);
    } catch (error: any) {
      debugLog("Error parsing message:", error);
      this._sendError(-32700, `Error parsing message: ${error.message}`);
      return;
    }

    debugLog("Received message:", message);

    const response: ProtocolResponse = {
      id: message.id,
    };
    try {
      response.result = await this._handleCommand(message);
    } catch (error: any) {
      debugLog("Error handling command:", error);
      response.error = error.message;
    }
    debugLog("Sending response:", response);
    this._sendMessage(response);
  }

  private async _handleCommand(message: ProtocolCommand): Promise<any> {
    if (message.method === "attachToTab") {
      await this._tabPromise;
      return await this._attachDebuggerToTab(this._debuggee.tabId!);
    }
    if (message.method === "listTabs") {
      const tabs = await chrome.tabs.query({});
      return tabs
        .filter(
          (tab) =>
            tab.id &&
            tab.windowId &&
            tab.url &&
            !["chrome:", "edge:", "devtools:"].some((scheme) => tab.url!.startsWith(scheme)),
        )
        .map((tab) => ({
          id: tab.id,
          windowId: tab.windowId,
          title: tab.title || "",
          url: tab.url || "",
          active: !!tab.active,
        }));
    }
    if (message.method === "createTab") {
      const url = message.params?.url || "about:blank";
      const tab = await chrome.tabs.create({ url, active: true });
      if (!tab.id || !tab.windowId) throw new Error("Created tab is missing tab identifiers");
      const attached = await this._attachDebuggerToTab(tab.id, tab.windowId);
      return {
        tab: {
          id: tab.id,
          windowId: tab.windowId,
          title: tab.title || "",
          url: tab.url || "",
          active: !!tab.active,
        },
        ...attached,
      };
    }
    if (message.method === "createWindow") {
      const url = message.params?.url || "about:blank";
      const created = await chrome.windows.create({ url, focused: true });
      const tab = created.tabs?.[0];
      if (!created.id || !tab?.id) throw new Error("Created window is missing tab identifiers");
      const attached = await this._attachDebuggerToTab(tab.id, created.id);
      return {
        windowId: created.id,
        tab: {
          id: tab.id,
          windowId: created.id,
          title: tab.title || "",
          url: tab.url || "",
          active: !!tab.active,
        },
        ...attached,
      };
    }
    if (message.method === "switchToTab") {
      const tabId = Number(message.params?.tabId || 0);
      const windowId = Number(message.params?.windowId || 0) || undefined;
      if (!tabId) throw new Error("switchToTab requires tabId");
      return await this._attachDebuggerToTab(tabId, windowId);
    }
    if (message.method === "closeTab") {
      const tabId = Number(message.params?.tabId || this._debuggee.tabId || 0);
      if (!tabId) throw new Error("closeTab requires tabId");
      if (this._debuggee.tabId === tabId && this._isAttached) {
        await chrome.debugger.detach(this._debuggee).catch(() => {});
        this._isAttached = false;
      }
      await chrome.tabs.remove(tabId);
      if (this._debuggee.tabId === tabId) this._debuggee = {};
      return { closedTabId: tabId };
    }
    if (!this._debuggee.tabId)
      throw new Error(
        "No tab is connected. Please go to the Playwright MCP extension and select the tab you want to connect to.",
      );
    if (message.method === "forwardCDPCommand") {
      const { sessionId, method, params } = message.params;
      debugLog("CDP command:", method, params);
      const debuggerSession: chrome.debugger.DebuggerSession = {
        ...this._debuggee,
        sessionId,
      };
      // Forward CDP command to chrome.debugger
      return await chrome.debugger.sendCommand(debuggerSession, method, params);
    }
    throw new Error(`Unknown relay command: ${message.method}`);
  }

  private async _attachDebuggerToTab(tabId: number, windowId?: number): Promise<any> {
    const previousTabId = this._debuggee.tabId || null;
    if (previousTabId && previousTabId !== tabId && this._isAttached)
      await chrome.debugger.detach(this._debuggee).catch(() => {});

    this._debuggee = { tabId };
    if (!this._isAttached || previousTabId !== tabId) {
      debugLog("Attaching debugger to tab:", this._debuggee);
      await chrome.debugger.attach(this._debuggee, "1.3");
      this._isAttached = true;
    }

    const updatedTab = await chrome.tabs.update(tabId, { active: true });
    const resolvedWindowId = windowId || updatedTab?.windowId;
    if (resolvedWindowId) await chrome.windows.update(resolvedWindowId, { focused: true });

    if (previousTabId !== tabId) await this.onTabIdChanged?.(tabId, previousTabId);

    const result: any = await chrome.debugger.sendCommand(this._debuggee, "Target.getTargetInfo");
    return {
      tabId,
      windowId: resolvedWindowId,
      targetInfo: result?.targetInfo,
    };
  }

  private _sendError(code: number, message: string): void {
    this._sendMessage({
      error: {
        code,
        message,
      },
    });
  }

  private _sendMessage(message: any): void {
    if (this._ws.readyState === WebSocket.OPEN) this._ws.send(JSON.stringify(message));
  }
}
