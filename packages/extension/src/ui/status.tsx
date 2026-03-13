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

import React, { useState, useEffect } from "react";
import { createRoot } from "react-dom/client";
import { Button, TabItem } from "./tabItem";

import type { TabInfo } from "./tabItem";
import { AuthTokenSection, getOrCreateAuthToken } from "./authToken";

interface ConnectionStatus {
  isConnected: boolean;
  connectedTabId: number | null;
  connectedTab?: TabInfo;
  extensionId: string;
  browserName: string;
}

type SyncStatus =
  | { type: "idle" }
  | { type: "success"; message: string }
  | { type: "error"; message: string };

const StatusApp: React.FC = () => {
  const [status, setStatus] = useState<ConnectionStatus>({
    isConnected: false,
    connectedTabId: null,
    extensionId: chrome.runtime.id,
    browserName: detectBrowserName(),
  });
  const [syncStatus, setSyncStatus] = useState<SyncStatus>({ type: "idle" });

  useEffect(() => {
    void loadStatus();
  }, []);

  const loadStatus = async () => {
    // Get current connection status from background script
    const { connectedTabId, extensionId, browserName } = await chrome.runtime.sendMessage({
      type: "getConnectionStatus",
    });
    if (connectedTabId) {
      const tab = await chrome.tabs.get(connectedTabId);
      setStatus({
        isConnected: true,
        connectedTabId,
        extensionId,
        browserName,
        connectedTab: {
          id: tab.id!,
          windowId: tab.windowId!,
          title: tab.title!,
          url: tab.url!,
          favIconUrl: tab.favIconUrl,
        },
      });
    } else {
      setStatus({
        isConnected: false,
        connectedTabId: null,
        extensionId,
        browserName,
      });
    }
  };

  const syncExtensionInfo = async () => {
    setSyncStatus({ type: "idle" });
    const relayUrl = buildRelayRegistrationUrl(getOrCreateAuthToken());
    const response = await chrome.runtime.sendMessage({
      type: "syncExtensionRegistration",
      mcpRelayUrl: relayUrl,
    });
    if (response?.success) {
      setSyncStatus({
        type: "success",
        message: `Synchronized ${response.extensionId} to local server via ${response.via}.`,
      });
      await loadStatus();
      return;
    }
    setSyncStatus({
      type: "error",
      message: response?.error || "Failed to synchronize with local server.",
    });
  };

  const openConnectedTab = async () => {
    if (!status.connectedTabId) return;
    await chrome.tabs.update(status.connectedTabId, { active: true });
    chrome.tabs.getCurrent((tab) => {
      if (tab?.id) chrome.tabs.remove(tab.id);
    });
  };

  const disconnect = async () => {
    await chrome.runtime.sendMessage({ type: "disconnect" });
    chrome.tabs.getCurrent((tab) => {
      if (tab?.id) chrome.tabs.remove(tab.id);
    });
  };

  return (
    <div className="app-container">
      <div className="content-wrapper">
        <div className="info-grid">
          <div className="info-card">
            <div className="info-label">Extension ID</div>
            <div className="info-value info-code">{status.extensionId}</div>
          </div>
          <div className="info-card">
            <div className="info-label">Browser</div>
            <div className="info-value">{status.browserName}</div>
          </div>
        </div>

        <div className="manual-sync-section">
          <div className="manual-sync-copy">
            Push the current extension identity to the local v-browser server.
          </div>
          <Button variant="primary" onClick={syncExtensionInfo}>
            Sync To Local Server
          </Button>
        </div>

        {syncStatus.type !== "idle" && (
          <div className={`status-banner ${syncStatus.type === "error" ? "error" : "connected"}`}>
            {syncStatus.message}
          </div>
        )}

        {status.isConnected && status.connectedTab ? (
          <div>
            <div className="tab-section-title">Page with connected MCP client:</div>
            <div>
              <TabItem
                tab={status.connectedTab}
                button={
                  <Button variant="primary" onClick={disconnect}>
                    Disconnect
                  </Button>
                }
                onClick={openConnectedTab}
              />
            </div>
          </div>
        ) : (
          <div className="status-banner">No MCP clients are currently connected.</div>
        )}
        <AuthTokenSection />
      </div>
    </div>
  );
};

// Initialize the React app
const container = document.getElementById("root");
if (container) {
  const root = createRoot(container);
  root.render(<StatusApp />);
}

function buildRelayRegistrationUrl(token: string): string {
  return `ws://127.0.0.1:47978?token=${encodeURIComponent(token)}`;
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
