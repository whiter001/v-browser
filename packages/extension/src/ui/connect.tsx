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

import React, { useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { Button, TabItem } from "./tabItem";
import {
  AuthTokenSection,
  getOrCreateAuthToken,
  getStoredAuthToken,
  seedAuthToken,
} from "./authToken";

import type { TabInfo } from "./tabItem";

type Status =
  | { type: "connecting"; message: string }
  | { type: "connected"; message: string }
  | { type: "error"; message: string }
  | { type: "error"; versionMismatch: { extensionVersion: string } };

const SUPPORTED_PROTOCOL_VERSION = 1;

// 连接页主界面：负责接收 relay 地址、展示 tab 列表并完成连接。
const ConnectApp: React.FC = () => {
  const [tabs, setTabs] = useState<TabInfo[]>([]);
  const [status, setStatus] = useState<Status | null>(null);
  const [showButtons, setShowButtons] = useState(true);
  const [showTabList, setShowTabList] = useState(true);
  const [clientInfo, setClientInfo] = useState("unknown");
  const [mcpRelayUrl, setMcpRelayUrl] = useState("");
  const [newTab, setNewTab] = useState<boolean>(false);

  // 页面加载后根据 URL 参数完成连接流程。
  useEffect(() => {
    const runAsync = async () => {
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
        handleReject(`Invalid mcpRelayUrl parameter in URL: ${relayUrl}. ${e}`);
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
      let expectedToken = storedToken;
      if (urlToken && urlToken !== storedToken) {
        expectedToken = seedAuthToken(urlToken);
      } else if (!storedToken) {
        expectedToken = getOrCreateAuthToken();
      }
      const relayUrlWithToken = appendTokenToRelayUrl(relayUrl, expectedToken);
      setMcpRelayUrl(relayUrlWithToken);

      if (urlToken) {
        await connectToMCPRelay(relayUrlWithToken);
        await handleConnectToTab(undefined, relayUrlWithToken, clientInfoValue);
        return;
      }

      await connectToMCPRelay(relayUrlWithToken);

      // If this is a browser_navigate command, hide the tab list and show simple allow/reject
      if (params.get("newTab") === "true") {
        setNewTab(true);
        setShowTabList(false);
      } else {
        await loadTabs();
      }
    };
    void runAsync();
  }, []);

  // 统一处理用户拒绝或流程失败时的错误状态。
  const handleReject = useCallback((message: string) => {
    setShowButtons(false);
    setShowTabList(false);
    setStatus({ type: "error", message });
  }, []);

  // 连接到本地 relay，为后续 tab 附加建立通道。
  const connectToMCPRelay = useCallback(
    async (mcpRelayUrl: string) => {
      const response = await chrome.runtime.sendMessage({ type: "connectToMCPRelay", mcpRelayUrl });
      if (!response.success) handleReject(response.error);
    },
    [handleReject],
  );

  // 加载当前窗口中可连接的标签页列表。
  const loadTabs = useCallback(async () => {
    const response = await chrome.runtime.sendMessage({ type: "getTabs" });
    if (response.success) setTabs(response.tabs);
    else setStatus({ type: "error", message: "Failed to load tabs: " + response.error });
  }, []);

  // 让用户选择的标签页与 relay 建立关联。
  const handleConnectToTab = useCallback(
    async (tab?: TabInfo, relayUrlOverride?: string, clientInfoOverride?: string) => {
      setShowButtons(false);
      setShowTabList(false);

      const currentClientInfo = clientInfoOverride || clientInfo;

      try {
        const relayUrl = relayUrlOverride || mcpRelayUrl;
        const response = await chrome.runtime.sendMessage({
          type: "connectToTab",
          mcpRelayUrl: relayUrl,
          tabId: tab?.id,
          windowId: tab?.windowId,
        });

        if (response?.success) {
          setStatus({ type: "connected", message: `MCP client "${currentClientInfo}" connected.` });
          // Close the tab immediately
          console.log("[Extension] Requesting background to close current tab");
          chrome.runtime.sendMessage({ type: "closeTabFromConnect" });
        } else {
          setStatus({
            type: "error",
            message: response?.error || `MCP client "${currentClientInfo}" failed to connect.`,
          });
        }
      } catch (e) {
        setStatus({
          type: "error",
          message: `MCP client "${currentClientInfo}" failed to connect: ${e}`,
        });
      }
    },
    [clientInfo, mcpRelayUrl],
  );

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
                {newTab ? (
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
const container = document.getElementById("root");
if (container) {
  const root = createRoot(container);
  root.render(<ConnectApp />);
}

function appendTokenToRelayUrl(relayUrl: string, token: string): string {
  const url = new URL(relayUrl);
  if (token) url.searchParams.set("token", token);
  return url.toString();
}
