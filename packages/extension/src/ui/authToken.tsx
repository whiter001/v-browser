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

import React, { useCallback, useState } from "react";
import { CopyToClipboard } from "./copyToClipboard";
import * as icons from "./icons";
import "./authToken.css";

const authTokenStorageKey = "auth-token";

// 本地 token 与 daemon 侧的凭据是同一份，单独在扩展里轮换会让已配对的客户端全部失效，
// 因此暂时禁用重新生成按钮，等 daemon 侧轮换协议落地后再恢复。
const TOKEN_REGENERATION_ENABLED = false;

// URL 带来的 token 是否可以直接信任。
export type AuthTokenApproval =
  | { kind: "trusted"; token: string }
  | { kind: "confirm"; token: string; reason: "first-pairing" | "credential-change" };

// 判断 URL 里的 token 能否自动放行：只有和本地已存凭据一致时才算可信。
// 其余情况（首次配对 / 凭据变更）必须走显式确认，且确认之前不能落盘。
export function decideAuthToken(urlToken: string, storedToken: string): AuthTokenApproval {
  const normalized = (urlToken || "").trim();
  if (!normalized) {
    // URL 没带 token：沿用本地凭据，不涉及外部输入。
    return { kind: "trusted", token: (storedToken || "").trim() };
  }
  if (storedToken && normalized === storedToken) {
    return { kind: "trusted", token: storedToken };
  }
  return {
    kind: "confirm",
    token: normalized,
    reason: storedToken ? "credential-change" : "first-pairing",
  };
}

// 展示和管理本地扩展 token，方便用户复制到 MCP 客户端配置中。
export const AuthTokenSection: React.FC<{}> = ({}) => {
  // 直接读当前持久化的值：配对确认后落盘的是新凭据，这里必须同步显示。
  const authToken = getOrCreateAuthToken();
  const [isExampleExpanded, setIsExampleExpanded] = useState<boolean>(false);

  const onRegenerateToken = useCallback(() => {
    // 暂时不可用：轮换必须由 daemon 侧统一发起，扩展单方面改会和 daemon 凭据脱节。
  }, []);

  const toggleExample = useCallback(() => {
    setIsExampleExpanded(!isExampleExpanded);
  }, [isExampleExpanded]);

  return (
    <div className="auth-token-section">
      <div className="auth-token-description">
        Set this environment variable to bypass the connection dialog:
      </div>
      <div className="auth-token-container">
        <code className="auth-token-code">{authTokenCode(authToken)}</code>
        <button
          className="auth-token-refresh"
          title={
            TOKEN_REGENERATION_ENABLED
              ? "Generate new token"
              : "Regenerating the token is disabled: it is managed by the local v-browser server"
          }
          aria-label="Generate new token"
          disabled={!TOKEN_REGENERATION_ENABLED}
          onClick={onRegenerateToken}
        >
          {icons.refresh()}
        </button>
        <CopyToClipboard value={authTokenCode(authToken)} />
      </div>
      {!TOKEN_REGENERATION_ENABLED && (
        <div className="auth-token-description">
          Token regeneration is temporarily disabled: the credential is owned by the local
          v-browser server, so rotating it here would desynchronize both sides.
        </div>
      )}

      <div className="auth-token-example-section">
        <button
          className="auth-token-example-toggle"
          onClick={toggleExample}
          aria-expanded={isExampleExpanded}
          title={isExampleExpanded ? "Hide example config" : "Show example config"}
        >
          <span className={`auth-token-chevron ${isExampleExpanded ? "expanded" : ""}`}>
            {icons.chevronDown()}
          </span>
          Example MCP server configuration
        </button>

        {isExampleExpanded && (
          <div className="auth-token-example-content">
            <div className="auth-token-example-description">
              Add this configuration to your MCP client (e.g., VS Code) to connect to the Playwright
              MCP Bridge:
            </div>
            <div className="auth-token-example-config">
              <code className="auth-token-example-code">{exampleConfig(authToken)}</code>
              <CopyToClipboard value={exampleConfig(authToken)} />
            </div>
          </div>
        )}
      </div>
    </div>
  );
};

// 生成可直接复制的环境变量写法。
function authTokenCode(authToken: string) {
  return `PLAYWRIGHT_MCP_EXTENSION_TOKEN=${authToken}`;
}

// 生成 MCP 客户端示例配置。
function exampleConfig(authToken: string) {
  return `{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest", "--extension"],
      "env": {
        "PLAYWRIGHT_MCP_EXTENSION_TOKEN":
          "${authToken}"
      }
    }
  }
}`;
}

// 生成可用于扩展认证的随机 token。
function generateAuthToken(): string {
  // Generate a cryptographically secure random token
  const array = new Uint8Array(32);
  crypto.getRandomValues(array);
  // Convert to base64 and make it URL-safe
  return btoa(String.fromCharCode.apply(null, Array.from(array))).replace(/[+/=]/g, (match) => {
    switch (match) {
      case "+":
        return "-";
      case "/":
        return "_";
      case "=":
        return "";
      default:
        return match;
    }
  });
}

// 读取本地 token；若不存在则创建并持久化。
export const getOrCreateAuthToken = (): string => {
  let token = getStoredAuthToken();
  if (!token) {
    token = generateAuthToken();
    localStorage.setItem(authTokenStorageKey, token);
  }
  return token;
};

// 只读取本地保存的 token，不触发创建。
export const getStoredAuthToken = (): string => {
  return localStorage.getItem(authTokenStorageKey) || "";
};

// 持久化已经通过 relay 校验的凭据：验证通过之前不允许写入新凭据。
export const persistAuthToken = (token: string): void => {
  const normalized = (token || "").trim();
  if (!normalized) return;
  localStorage.setItem(authTokenStorageKey, normalized);
};
