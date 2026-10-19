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

import React, { useCallback, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button, TabItem } from "./tabItem";
import {
  AuthTokenSection,
  decideAuthToken,
  getOrCreateAuthToken,
  getStoredAuthToken,
  persistAuthToken,
} from "./authToken";

import type { TabInfo } from "./tabItem";
import { redactUrl } from "../redact";

type Status =
  | { type: "connecting"; message: string }
  | { type: "connected"; message: string }
  | { type: "error"; message: string }
  | { type: "error"; versionMismatch: { extensionVersion: string } };

const SUPPORTED_PROTOCOL_VERSION = 1;

// 连接流程闸门：用户拒绝（或页面关闭）之后，
// 所有在途的异步流程都必须立即作废：
// 不能再落盘凭据，也不能再发起授权连接。
export class ConnectionFlow {
  private _flowId = 0;
  private _cancelled = false;

  // 开始一个新流程，返回流程 id。
  begin(): number {
    this._flowId += 1;
    return this._flowId;
  }

  // 取消当前流程：所有在途流程立即作废。
  cancel(): void {
    this._cancelled = true;
    this._flowId += 1;
  }

  // 当前流程 id（用于没有显式流程 id 的入口）。
  currentFlowId(): number {
    return this._flowId;
  }

  // 复查某个流程是否仍然有效（每个 await 之后都要调用）。
  isActive(flowId: number): boolean {
    return !this._cancelled && this._flowId === flowId;
  }
}

// 授权流程：relay 校验通过之前不落盘凭据，校验之后才允许继续授权连接。
// 每一步之前都复查流程状态：用户在握手中拒绝时，后续动作一律不再执行。
export async function runApprovalFlow(options: {
  flow: ConnectionFlow;
  flowId: number;
  connectToRelay: () => Promise<boolean>;
  persistToken: () => void;
  authorize: () => Promise<void>;
}): Promise<boolean> {
  const connected = await options.connectToRelay();
  if (!connected) return false;
  if (!options.flow.isActive(options.flowId)) return false;
  options.persistToken();
  if (!options.flow.isActive(options.flowId)) return false;
  await options.authorize();
  return options.flow.isActive(options.flowId);
}

// 加载标签页列表：失败是终止性失败，必须走 reject，
// 否则后台的 pending 连接会一直存活。
export async function loadTabsForConnect(options: {
  flow: ConnectionFlow;
  flowId: number;
  sendMessage: (message: any) => Promise<any>;
  onTabs: (tabs: TabInfo[]) => void;
  onReject: (message: string) => void;
}): Promise<boolean> {
  try {
    const response = await options.sendMessage({ type: "getTabs" });
    if (!options.flow.isActive(options.flowId)) return false;
    if (response?.success) {
      options.onTabs(response.tabs ?? []);
      return true;
    }
    options.onReject("Failed to load tabs: " + (response?.error || "unknown error"));
    return false;
  } catch {
    if (!options.flow.isActive(options.flowId)) return false;
    options.onReject("Failed to load tabs.");
    return false;
  }
}

// 授权连接：失败同样是终止性失败，必须走 reject。
export async function connectTabForConnect(options: {
  flow: ConnectionFlow;
  flowId: number;
  sendMessage: (message: any) => Promise<any>;
  request: {
    type: "connectToTab";
    mcpRelayUrl: string;
    tabId?: number;
    windowId?: number;
  };
  onConnected: () => void;
  onReject: (message: string) => void;
}): Promise<boolean> {
  try {
    const response = await options.sendMessage(options.request);
    // 连接期间用户可能已经拒绝：这时不改状态。
    if (!options.flow.isActive(options.flowId)) return false;
    if (response?.success) {
      options.onConnected();
      return true;
    }
    options.onReject(response?.error || "Failed to connect to the MCP relay.");
    return false;
  } catch {
    if (!options.flow.isActive(options.flowId)) return false;
    options.onReject("Failed to connect to the MCP relay.");
    return false;
  }
}

// 连接页主界面：负责接收 relay 地址、展示 tab 列表并完成连接。
const ConnectApp: React.FC = () => {
  const [tabs, setTabs] = useState<TabInfo[]>([]);
  const [status, setStatus] = useState<Status | null>(null);
  const [showButtons, setShowButtons] = useState(true);
  const [showTabList, setShowTabList] = useState(true);
  const [clientInfo, setClientInfo] = useState("unknown");
  const [mcpRelayUrl, setMcpRelayUrl] = useState("");
  const [rawRelayUrl, setRawRelayUrl] = useState("");
  const [newTab, setNewTab] = useState<boolean>(false);
  // URL 带来的凭据与本地不一致时，必须先由用户显式确认。
  const [pendingApproval, setPendingApproval] = useState<{
    token: string;
    reason: "first-pairing" | "credential-change";
  } | null>(null);
  // 流程闸门：拒绝之后，所有在途的 await 都会在恢复时发现流程已作废。
  const flow = useMemo(() => new ConnectionFlow(), []);

  // 页面加载后根据 URL 参数完成连接流程。
  useEffect(() => {
    const runAsync = async () => {
      const flowId = flow.begin();
      const params = new URLSearchParams(window.location.search);
      const relayUrl = params.get("mcpRelayUrl");

      if (!relayUrl) {
        handleReject("Missing mcpRelayUrl parameter in URL.");
        return;
      }

      try {
        const host = new URL(relayUrl).hostname;
        if (host !== "127.0.0.1" && host !== "[::1]") {
          handleReject(
            `MCP extension only allows loopback connections (127.0.0.1 or [::1]). Received host: ${host}`,
          );
          return;
        }
      } catch (e) {
        handleReject(`Invalid mcpRelayUrl parameter in URL: ${redactUrl(relayUrl)}. ${e}`);
        return;
      }

      let clientInfoValue = "unknown";

      try {
        const clientStr = params.get("client") || "{}";
        console.log("[Extension] client param:", clientStr);
        const client = JSON.parse(clientStr);
        clientInfoValue = `${client.name}/${client.version}`;
        console.log("[Extension] parsed client info:", clientInfoValue);
        setClientInfo(clientInfoValue);
        setStatus({
          type: "connecting",
          message: `🎭 Playwright MCP started from  "${clientInfoValue}" is trying to connect. Do you want to continue?`,
        });
      } catch (e) {
        setStatus({ type: "error", message: "Failed to parse client version." });
        return;
      }

      const parsedVersion = parseInt(params.get("protocolVersion") ?? "", 10);
      const requiredVersion = isNaN(parsedVersion) ? 1 : parsedVersion;
      if (requiredVersion > SUPPORTED_PROTOCOL_VERSION) {
        const extensionVersion = chrome.runtime.getManifest().version;
        setShowButtons(false);
        setShowTabList(false);
        setStatus({
          type: "error",
          versionMismatch: {
            extensionVersion,
          },
        });
        return;
      }

      const urlToken = params.get("token")?.trim() || "";
      const storedToken = getStoredAuthToken();
      const approval = decideAuthToken(urlToken, storedToken);
      // 未经确认的新凭据不落盘：只有 relay 校验通过之后才允许持久化。
      const expectedToken = approval.token || getOrCreateAuthToken();
      const relayUrlWithToken = appendTokenToRelayUrl(relayUrl, expectedToken);
      setRawRelayUrl(relayUrl);
      setMcpRelayUrl(relayUrlWithToken);

      if (approval.kind === "confirm") {
        // 首次配对或凭据变更：必须由用户显式确认后才能继续。
        setPendingApproval({ token: approval.token, reason: approval.reason });
        setStatus({
          type: "connecting",
          message:
            approval.reason === "credential-change"
              ? `🎭 Playwright MCP ("${clientInfoValue}") wants to replace the local authentication token. Confirm to continue.`
              : `🎭 Playwright MCP ("${clientInfoValue}") wants to pair with a new authentication token. Confirm to continue.`,
        });
        return;
      }

      const connected = await connectToMCPRelay(relayUrlWithToken, flowId);
      if (!connected) return;
      // 握手期间用户可能已经拒绝：后续动作一律不再执行。
      if (!flow.isActive(flowId)) return;

      if (urlToken) {
        await handleConnectToTab(undefined, relayUrlWithToken, clientInfoValue, flowId);
        return;
      }

      // If this is a browser_navigate command, hide the tab list and show simple allow/reject
      if (params.get("newTab") === "true") {
        setNewTab(true);
        setShowTabList(false);
      } else {
        await loadTabs(flowId);
      }
    };
    void runAsync();
  }, []);

  // 统一处理用户拒绝或流程失败时的错误状态。
  const handleReject = useCallback(
    (message: string) => {
      // 取消当前流程：握手中的连接和后续的授权动作都会作废。
      flow.cancel();
      setShowButtons(false);
      setShowTabList(false);
      setStatus({ type: "error", message });
      // 显式让后台销毁尚未授权的 pending 连接，避免未授权连接继续存活。
      try {
        void chrome.runtime.sendMessage({ type: "cancelPendingConnection" }).catch(() => {});
      } catch {
        // 后台不可用时忽略：连接本来就没建立起来。
      }
    },
    [flow],
  );

  // 连接到本地 relay，为后续 tab 附加建立通道。
  // 返回明确的成败，失败时调用方必须立即退出后续流程。
  const connectToMCPRelay = useCallback(
    async (relayUrl: string, flowId: number): Promise<boolean> => {
      try {
        const response = await chrome.runtime.sendMessage({
          type: "connectToMCPRelay",
          mcpRelayUrl: relayUrl,
        });
        // 握手期间用户可能已经拒绝：这时不改状态，直接退出。
        if (!flow.isActive(flowId)) return false;
        if (!response?.success) {
          handleReject(response?.error || "Failed to connect to the MCP relay.");
          return false;
        }
        return true;
      } catch {
        if (!flow.isActive(flowId)) return false;
        handleReject("Failed to connect to the MCP relay.");
        return false;
      }
    },
    [flow, handleReject],
  );

  // 加载当前窗口中可连接的标签页列表。
  const loadTabs = useCallback(
    async (flowId: number) => {
      await loadTabsForConnect({
        flow,
        flowId,
        sendMessage: (message) => chrome.runtime.sendMessage(message),
        onTabs: (loaded) => setTabs(loaded),
        // 终止性失败统一走 handleReject：pending 连接必须一起销毁。
        onReject: handleReject,
      });
    },
    [flow, handleReject],
  );

  // 让用户选择的标签页与 relay 建立关联。
  const handleConnectToTab = useCallback(
    async (
      tab?: TabInfo,
      relayUrlOverride?: string,
      clientInfoOverride?: string,
      flowId?: number,
    ) => {
      setShowButtons(false);
      setShowTabList(false);

      const currentClientInfo = clientInfoOverride || clientInfo;
      // 没带流程 id 时按当前流程处理（用户直接点某个标签页的 Connect）。
      const activeFlowId = flowId ?? flow.currentFlowId();

      await connectTabForConnect({
        flow,
        flowId: activeFlowId,
        sendMessage: (message) => chrome.runtime.sendMessage(message),
        request: {
          type: "connectToTab",
          mcpRelayUrl: relayUrlOverride || mcpRelayUrl,
          tabId: tab?.id,
          windowId: tab?.windowId,
        },
        onConnected: () => {
          setStatus({ type: "connected", message: `MCP client "${currentClientInfo}" connected.` });
          // Close the tab immediately
          console.log("[Extension] Requesting background to close current tab");
          chrome.runtime.sendMessage({ type: "closeTabFromConnect" });
        },
        // 终止性失败统一走 handleReject：pending 连接必须一起销毁。
        onReject: handleReject,
      });
    },
    [clientInfo, mcpRelayUrl, flow, handleReject],
  );

  // 用户确认新的认证凭据后才继续连接；relay 校验通过前不持久化新凭据。
  const approvePendingToken = useCallback(async () => {
    if (!pendingApproval) return;
    const token = pendingApproval.token;
    setPendingApproval(null);
    const relayUrlWithToken = appendTokenToRelayUrl(rawRelayUrl, token);
    // 授权走独立的流程代次：握手中被拒绝时不会落盘凭据，也不会再授权连接。
    const flowId = flow.begin();
    await runApprovalFlow({
      flow,
      flowId,
      connectToRelay: () => connectToMCPRelay(relayUrlWithToken, flowId),
      // relay 已经校验过这个凭据，这时才可以落盘。
      persistToken: () => persistAuthToken(token),
      authorize: () => handleConnectToTab(undefined, relayUrlWithToken, clientInfo, flowId),
    });
  }, [
    pendingApproval,
    rawRelayUrl,
    clientInfo,
    flow,
    connectToMCPRelay,
    handleConnectToTab,
  ]);

  // 监听后台发来的超时通知，及时关闭连接流程。
  useEffect(() => {
    const listener = (message: any) => {
      if (message.type === "connectionTimeout") handleReject("Connection timed out.");
    };
    chrome.runtime.onMessage.addListener(listener);
    return () => {
      chrome.runtime.onMessage.removeListener(listener);
    };
  }, [handleReject]);

  return (
    <div className="app-container">
      <div className="content-wrapper">
        {status && (
          <div className="status-container">
            <StatusBanner status={status} />
            {showButtons && (
              <div className="button-container">
                {pendingApproval ? (
                  <>
                    <Button variant="primary" onClick={() => void approvePendingToken()}>
                      Allow
                    </Button>
                    <Button
                      variant="reject"
                      onClick={() => handleReject("Connection rejected. This tab can be closed.")}
                    >
                      Reject
                    </Button>
                  </>
                ) : newTab ? (
                  <>
                    <Button variant="primary" onClick={() => handleConnectToTab()}>
                      Allow
                    </Button>
                    <Button
                      variant="reject"
                      onClick={() => handleReject("Connection rejected. This tab can be closed.")}
                    >
                      Reject
                    </Button>
                  </>
                ) : (
                  <Button
                    variant="reject"
                    onClick={() => handleReject("Connection rejected. This tab can be closed.")}
                  >
                    Reject
                  </Button>
                )}
              </div>
            )}
          </div>
        )}

        {status?.type === "connecting" && <AuthTokenSection />}

        {showTabList && (
          <div>
            <div className="tab-section-title">Select page to expose to MCP server:</div>
            <div>
              {tabs.map((tab) => (
                <TabItem
                  key={tab.id}
                  tab={tab}
                  button={
                    <Button variant="primary" onClick={() => handleConnectToTab(tab)}>
                      Connect
                    </Button>
                  }
                />
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

// 版本不兼容时显示的替代说明页。
const VersionMismatchError: React.FC<{ extensionVersion: string }> = ({ extensionVersion }) => {
  const readmeUrl = "https://github.com/microsoft/playwright-mcp/blob/main/extension/README.md";
  const latestReleaseUrl = "https://github.com/microsoft/playwright-mcp/releases/latest";
  return (
    <div>
      Playwright MCP version trying to connect requires newer extension version (current version:{" "}
      {extensionVersion}). <a href={latestReleaseUrl}>Click here</a> to download latest version of
      the extension, then drag and drop it into the Chrome Extensions page. See{" "}
      <a href={readmeUrl} target="_blank" rel="noopener noreferrer">
        installation instructions
      </a>{" "}
      for more details.
    </div>
  );
};

const StatusBanner: React.FC<{ status: Status }> = ({ status }) => {
  return (
    <div className={`status-banner ${status.type}`}>
      {"versionMismatch" in status ? (
        <VersionMismatchError extensionVersion={status.versionMismatch.extensionVersion} />
      ) : (
        status.message
      )}
    </div>
  );
};

// Initialize the React app
// 测试环境（node）里没有 document，这里必须先判断再挂载。
if (typeof document !== "undefined") {
  const container = document.getElementById("root");
  if (container) {
    const root = createRoot(container);
    root.render(<ConnectApp />);
  }
}

function appendTokenToRelayUrl(relayUrl: string, token: string): string {
  const url = new URL(relayUrl);
  if (token) url.searchParams.set("token", token);
  return url.toString();
}
