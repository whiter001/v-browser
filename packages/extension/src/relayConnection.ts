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

import { redactCdpParams, redactPayload, scrubSecrets } from "./redact";

const DEBUG_LOGGING_STORAGE_KEY = "debugLogging";
const DEBUG_LOGGING_GLOBAL_KEY = "__V_BROWSER_DEBUG_LOGGING__";

let _debugLogging: boolean | undefined;

function readDebugLogging(): boolean {
  // 构建期/测试期的显式开关，优先于 storage。
  const globalOverride = (globalThis as Record<string, unknown>)[DEBUG_LOGGING_GLOBAL_KEY];
  if (typeof globalOverride === "boolean") return globalOverride;

  if (_debugLogging !== undefined) return _debugLogging;

  _debugLogging = false; // 默认关闭：诊断日志会打印 CDP 载荷，价值不足以换取泄露风险。
  try {
    if (typeof chrome !== "undefined" && chrome.storage?.local) {
      void chrome.storage.local
        .get(DEBUG_LOGGING_STORAGE_KEY)
        .then((result) => {
          if (typeof result?.[DEBUG_LOGGING_STORAGE_KEY] === "boolean") {
            _debugLogging = result[DEBUG_LOGGING_STORAGE_KEY];
          }
        })
        .catch(() => {});
    }
  } catch {
    // storage 不可用时保持关闭。
  }
  return _debugLogging;
}

export function isDebugLoggingEnabled(): boolean {
  return readDebugLogging();
}

export function debugLog(...args: unknown[]): void {
  if (!readDebugLogging()) return;
  // 兜底：即使调用点漏改，结构化参数也不会带着凭据进控制台；
  // 字符串参数统一走 scrubSecrets，URL 里的 query 会被裁掉。
  // eslint-disable-next-line no-console
  console.log(
    "[Extension]",
    ...args.map((arg) => {
      if (typeof arg === "object" && arg !== null) return redactPayload(arg);
      if (typeof arg === "string") return scrubSecrets(arg);
      return arg;
    }),
  );
}

// 连接生命周期：pending 表示还没完成用户选择，authorized 表示已绑定用户选中的标签页。
type ConnectionState = "pending" | "authorized" | "closed";

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

// relay 协议命令白名单：外部消息只接受这些 method。
const RELAY_COMMAND_NAMES = [
  "attachToTab",
  "listTabs",
  "createTab",
  "createWindow",
  "switchToTab",
  "closeTab",
  "forwardCDPCommand",
] as const;

const RELAY_COMMANDS = new Set<string>(RELAY_COMMAND_NAMES);

// 诊断日志里允许出现的 CDP 完整名称集合（命令与事件都在里面）。
// 只校验域名前缀是不够的：伪造一个"合法域 + 任意后缀"的方法名
// （例如 Runtime.arbitrary-private-content）就能把任意文本带进日志，
// 因此这里必须按完整名称精确匹配，未知一律记成 unknown。
const KNOWN_CDP_NAMES: Record<string, string[]> = {
  Page: [
    "enable",
    "disable",
    "navigate",
    "reload",
    "close",
    "captureScreenshot",
    "printToPDF",
    "addScriptToEvaluateOnNewDocument",
    "removeScriptToEvaluateOnNewDocument",
    "getResourceContent",
    "getResourceTree",
    "setDownloadBehavior",
    "stopLoading",
    "handleJavaScriptDialog",
    "setInterceptFileChooserDialog",
    "setLifecycleEventsEnabled",
    "crash",
    "createIsolatedWorld",
    "getFrameTree",
    "getNavigationHistory",
    "resetNavigationHistory",
    "getAppManifest",
    "getInstallabilityErrors",
    "setBypassCSP",
    "setDocumentContent",
    "setAdBlockingEnabled",
    "setBypassServiceWorker",
    "setFontFamilies",
    "setFontSizes",
    "startScreencast",
    "stopScreencast",
    "bringToFront",
    "getLayoutMetrics",
    "setWebLifecycleState",
    "generateTestReport",
    "frameAttached",
    "frameNavigated",
    "frameDetached",
    "frameStartedLoading",
    "frameStoppedLoading",
    "frameRequestedNavigation",
    "frameResized",
    "frameStartedNavigating",
    "lifecycleEvent",
    "loadEventFired",
    "domContentEventFired",
    "javascriptDialogOpening",
    "javascriptDialogClosed",
    "screencastFrame",
    "screencastVisibilityChanged",
    "interstitialShown",
    "interstitialHidden",
    "windowOpen",
    "compilationCacheProduced",
    "navigatedWithinDocument",
    "downloadProgress",
    "downloadWillBegin",
    "fileChooserOpened",
  ],
  Runtime: [
    "enable",
    "disable",
    "evaluate",
    "callFunctionOn",
    "awaitPromise",
    "releaseObject",
    "releaseObjectGroup",
    "getProperties",
    "globalLexicalScopeNames",
    "addBinding",
    "removeBinding",
    "compileScript",
    "runScript",
    "getExceptionDetails",
    "getHeapUsage",
    "getIsolateId",
    "runIfWaitingForDebugger",
    "setAsyncCallStackDepth",
    "queryObjects",
    "setCustomObjectFormatterEnabled",
    "terminateExecution",
    "executionContextCreated",
    "executionContextDestroyed",
    "executionContextsCleared",
    "inspectRequested",
    "bindingCalled",
    "consoleAPICalled",
    "exceptionRevoked",
    "exceptionThrown",
  ],
  Network: [
    "enable",
    "disable",
    "clearBrowserCache",
    "clearBrowserCookies",
    "deleteCookies",
    "getCookies",
    "getAllCookies",
    "setCookie",
    "setExtraHTTPHeaders",
    "getRequestPostData",
    "setCacheDisabled",
    "setUserAgentOverride",
    "emulateNetworkConditions",
    "emulateNetworkConditionsByRule",
    "getResponseBody",
    "getResponseBodyForInterception",
    "setRequestInterception",
    "continueInterceptedRequest",
    "continueInterceptedRequestWithAuth",
    "setBypassServiceWorker",
    "getCertificate",
    "setCookieControls",
    "setAcceptedEncodings",
    "setAttachDebugStack",
    "setExtraHTTPHeaders",
    "clearAcceptedEncodingsOverride",
    "setRequestedWithCache",
    "takeResponseBodyForInterceptionAsStream",
    "requestWillBeSent",
    "responseReceived",
    "dataReceived",
    "loadingFinished",
    "loadingFailed",
    "requestServedFromCache",
    "webSocketCreated",
    "webSocketWillSendHandshakeRequest",
    "webSocketHandshakeResponseReceived",
    "webSocketFrameSent",
    "webSocketFrameReceived",
    "webSocketClosed",
    "webSocketFrameError",
    "webSocketWillReceiveHandshakeResponse",
    "eventSourceMessageReceived",
    "policyUpdated",
    "reportingApiReportAdded",
    "reportingApiReportUpdated",
    "resourceChangedPriority",
    "signedExchangeReceived",
    "subresourceWebBundleInnerResponseError",
    "subresourceWebBundleInnerResponseParsed",
    "subresourceWebBundleMetadataError",
    "subresourceWebBundleMetadataReceived",
    "trustTokenOperationDone",
    "policyUpdated",
  ],
  DOM: [
    "enable",
    "disable",
    "getDocument",
    "querySelector",
    "querySelectorAll",
    "getBoxModel",
    "getOuterHTML",
    "setOuterHTML",
    "describeNode",
    "hideHighlight",
    "highlightNode",
    "scrollIntoViewIfNeeded",
    "getAttributes",
    "setAttributeValue",
    "removeAttribute",
    "requestNode",
    "requestChildNodes",
    "releaseNode",
    "getFlattenedDocument",
    "focus",
    "getFrameOwner",
    "getContainerForNode",
    "getQueryingDescendantsForContainer",
    "getAnchorElement",
    "getElementByRelation",
    "getFileInfo",
    "getNodeStackTraces",
    "performSearch",
    "getSearchResults",
    "discardSearchResults",
    "getNodeForLocation",
    "getContentQuads",
    "moveTo",
    "moveToFront",
    "getTopLayerElements",
    "getElementByRelation",
    "attributeModified",
    "attributeRemoved",
    "characterDataModified",
    "childNodeCountUpdated",
    "childNodeInserted",
    "childNodeRemoved",
    "distributedNodesUpdated",
    "documentUpdated",
    "inlineStyleInvalidated",
    "pseudoElementAdded",
    "pseudoElementRemoved",
    "setChildNodes",
    "shadowRootPushed",
    "shadowRootPopped",
    "topLayerElementsUpdated",
    "scrollableFlagUpdated",
  ],
  Target: [
    "activateTarget",
    "attachToTarget",
    "closeTarget",
    "createBrowserContext",
    "createTarget",
    "detachFromTarget",
    "disposeBrowserContext",
    "getBrowserContexts",
    "getTargetInfo",
    "getTargets",
    "setAutoAttach",
    "setDiscoverTargets",
    "setRemoteLocations",
    "sendMessageToTarget",
    "autoAttachRelated",
    "attachedToTarget",
    "detachedFromTarget",
    "receivedMessageFromTarget",
    "targetCreated",
    "targetDestroyed",
    "targetInfoChanged",
    "targetCrashed",
  ],
  Input: [
    "dispatchKeyEvent",
    "dispatchMouseEvent",
    "dispatchTouchEvent",
    "insertText",
    "setIgnoreInputEvents",
    "emulateTouchFromMouseEvent",
    "synthesizeScrollGesture",
    "synthesizePinchGesture",
    "dispatchDragEvent",
    "setInterceptDrags",
    "dragEnter",
    "dragOver",
    "drop",
    "dragIntercepted",
  ],
  Storage: [
    "clearDataForOrigin",
    "clearDataForStorageKey",
    "getCookies",
    "setCookies",
    "getUsageAndQuota",
    "getStorageKeyForFrame",
    "getTrustTokens",
    "clearTrustTokens",
    "getInterestGroupDetails",
    "setInterestGroupTracking",
    "setSharedStorageEntry",
    "setSharedStorageTracking",
    "deleteSharedStorageEntry",
    "deleteStorageBucket",
    "trackCacheStorageForOrigin",
    "untrackCacheStorageForOrigin",
    "trackIndexedDBForOrigin",
    "untrackIndexedDBForOrigin",
    "overrideQuotaForOrigin",
    "getRelatedWebsiteSets",
    "getAffectedUrlsForThirdParty",
    "trackRelatedWebsiteSets",
    "untrackRelatedWebsiteSets",
    "setAttributionReportingLocalTestingMode",
    "setAttributionReportingTracking",
    "interestGroupAccessed",
    "interestGroupAuctionEventOccurred",
    "interestGroupAuctionNetworkRequestCreated",
    "sharedStorageAccessed",
    "storageBucketCreatedOrUpdated",
    "storageBucketDeleted",
    "cacheStorageContentUpdated",
    "indexedDBContentUpdated",
    "interestGroupAccessDetails",
    "sharedStorageAccessDetails",
  ],
  Fetch: [
    "enable",
    "disable",
    "fulfillRequest",
    "failRequest",
    "continueRequest",
    "continueWithAuth",
    "continueResponse",
    "getResponseBody",
    "takeResponseBodyAsStream",
    "requestPaused",
    "authRequired",
  ],
  Log: [
    "enable",
    "disable",
    "clear",
    "startViolationsReport",
    "stopViolationsReport",
    "addEntry",
    "entryAdded",
  ],
  Security: [
    "enable",
    "disable",
    "setIgnoreCertificateErrors",
    "handleCertificateError",
    "setAllowUnsafe",
    "setOverrideCertificateErrors",
    "setIgnoreCertificateErrors",
    "certificateError",
    "securityStateChanged",
    "visibleSecurityStateChanged",
  ],
  Emulation: [
    "setDeviceMetricsOverride",
    "clearDeviceMetricsOverride",
    "setUserAgentOverride",
    "setGeolocationOverride",
    "clearGeolocationOverride",
    "setLocaleOverride",
    "setTimezoneOverride",
    "setHardwareConcurrencyOverride",
    "setVirtualTimePolicy",
    "setScriptExecutionDisabled",
    "setScrollbarsHidden",
    "setDefaultBackgroundColorOverride",
    "setPageScaleFactor",
    "setDeviceOrientationOverride",
    "setTouchEmulationEnabled",
    "setEmitTouchEventsForMouse",
    "setFocusEmulationEnabled",
    "setIdleOverride",
    "setCPUThrottlingRate",
    "setDisabledImageTypes",
    "setDocumentCookieDisabled",
    "setAutomationOverrideEnabled",
    "canEmulate",
  ],
  Debugger: [
    "enable",
    "disable",
    "setBreakpointByUrl",
    "setBreakpoint",
    "removeBreakpoint",
    "setBreakpointActive",
    "setPauseOnExceptions",
    "setAsyncCallStackDepth",
    "getScriptSource",
    "getPossibleBreakpoints",
    "setScriptSource",
    "resume",
    "stepInto",
    "stepOver",
    "stepOut",
    "pause",
    "evaluateOnCallFrame",
    "setOverlayMessage",
    "setBlackboxPatterns",
    "setBlackboxedRanges",
    "scriptParsed",
    "scriptFailedToParse",
    "globalObjectCleared",
    "breakpointResolved",
    "paused",
    "resumed",
  ],
  Performance: ["enable", "disable", "getMetrics", "setTimeDomain"],
  Accessibility: [
    "enable",
    "disable",
    "getFullAXTree",
    "getPartialAXTree",
    "getRootAXNode",
    "getChildAXNodes",
    "getAXNodeAndAncestors",
    "queryAXTree",
    "loadComplete",
    "nodesUpdated",
  ],
  CSS: [
    "enable",
    "disable",
    "getMatchedStylesForNode",
    "getInlineStylesForNode",
    "getComputedStyleForNode",
    "getAllStyleSheets",
    "getStyleSheetText",
    "getStyleSheet",
    "getSourceMapText",
    "createPseudoStyleSheet",
    "setStyleSheetText",
    "setStyleSheetEnabled",
    "trackComputedStyleProperties",
    "takeComputedStyleUpdates",
    "forcePseudoState",
    "getPlatformFontsForNode",
    "getLayerTree",
    "getContainerQueryContainer",
    "cssStyleSheetChanged",
    "styleSheetChanged",
    "styleSheetRemoved",
  ],
  IO: ["read", "close", "resolveBlob"],
  HeapProfiler: [
    "enable",
    "disable",
    "takeHeapSnapshot",
    "startTrackingHeapObjects",
    "stopTrackingHeapObjects",
    "collectGarbage",
    "addInspectedHeapObject",
    "getHeapObjectId",
    "getObjectByHeapObjectId",
    "getHeapObjectStackTrace",
    "getSamplingProfile",
    "startSampling",
    "stopSampling",
    "getAllocationProfile",
    "getRuntimeCallStats",
    "addHeapSnapshotChunk",
    "resetProfiles",
    "reportHeapSnapshotProgress",
    "heapProfilerObjectAdded",
    "heapProfilerObjectRemoved",
    "inspectHeapObject",
    "heapObjectUpdate",
  ],
  Tracing: [
    "start",
    "end",
    "getCategories",
    "requestMemoryDump",
    "dataCollected",
    "complete",
    "bufferUsage",
    "transferComplete",
  ],
  Browser: [
    "close",
    "grantPermissions",
    "resetPermissions",
    "setPermission",
    "getVersion",
    "getWindowForTarget",
    "getWindowBounds",
    "setWindowBounds",
    "setDockTile",
    "cancelDownload",
    "setDownloadBehavior",
    "getHistogram",
    "getHistograms",
    "getBrowserCommandLineArguments",
  ],
  ServiceWorker: [
    "enable",
    "disable",
    "unregister",
    "startWorker",
    "stopWorker",
    "dispatchWorkerEvent",
    "setForceUpdateOnPageLoad",
    "skipWaiting",
    "addRegistration",
    "stopAllWorkers",
    "deliverMessages",
    "setSkipWaiting",
    "inspectWorker",
    "workerErrorReported",
    "workerRegistrationUpdated",
    "workerVersionUpdated",
  ],
  Inspector: ["inspect", "hideHighlight"],
  Audits: ["enable", "disable"],
  Overlay: [
    "enable",
    "disable",
    "setInspectMode",
    "highlightNode",
    "hideHighlight",
    "setShowIsolatedElements",
    "setShowGridOverlays",
    "clearHighlights",
  ],
};

const KNOWN_CDP_NAME_SET = new Set(
  Object.entries(KNOWN_CDP_NAMES).flatMap(([domain, names]) =>
    names.map((name) => `${domain}.${name}`),
  ),
);

// JSON 协议错误码。
const PARSE_ERROR = -32700;
const INVALID_REQUEST_ERROR = -32600;

// 内部错误类别：诊断日志只记录这些固定标识，
// 不记录任何 Error.message / stack（里面可能混着页面内容和凭据）。
type RelayErrorCode =
  | "E_NOT_AUTHORIZED"
  | "E_CLOSED"
  | "E_INVALID_PARAMS"
  | "E_INVALID_REQUEST"
  | "E_UNSUPPORTED"
  | "E_INTERNAL";

class RelayError extends Error {
  readonly code: RelayErrorCode;
  constructor(code: RelayErrorCode, message: string) {
    super(message);
    this.name = "RelayError";
    this.code = code;
  }
}

// 判断 debugger attach 冲突是否来自已有调试会话。
function isAlreadyAttachedError(error: unknown): boolean {
  const message = String(
    (error as { message?: string } | undefined)?.message || error || "",
  ).toLowerCase();
  return message.includes("another debugger is already attached");
}

// 诊断日志里只保留完整的 CDP 名称：不在完整名称集合内一律记成 unknown。
function safeCdpMethod(method: unknown): string {
  if (typeof method !== "string") return "unknown";
  return KNOWN_CDP_NAME_SET.has(method) ? method : "unknown";
}

// debugger detach 的原因只取已知取值，其余一律记成 unknown。
function safeDetachReason(reason: unknown): string {
  if (typeof reason !== "string") return "unknown";
  return KNOWN_DETACH_REASONS.has(reason) ? reason : "unknown";
}

const KNOWN_DETACH_REASONS = new Set([
  "canceled_by_user",
  "replaced_with_devtools",
  "target_closed",
  "attached",
  "detached",
]);

// 外部消息按 unknown 严格校验：非空对象 + 白名单 method + 数字 id + 对象 params。
type ValidationResult =
  | { ok: true; command: ProtocolCommand }
  | { ok: false; id?: number; code: number; message: string };

function validateCommand(raw: unknown): ValidationResult {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
    return {
      ok: false,
      code: INVALID_REQUEST_ERROR,
      message: "Relay message must be a JSON object",
    };
  }

  const record = raw as Record<string, unknown>;
  const rawId = record.id;
  const id = typeof rawId === "number" && Number.isFinite(rawId) ? rawId : undefined;
  const method = record.method;

  if (typeof method !== "string" || !RELAY_COMMANDS.has(method)) {
    // 不回显原始 method：它完全由对端控制，原样带进日志就成了注入通道。
    return {
      ok: false,
      id,
      code: INVALID_REQUEST_ERROR,
      message: "Unknown relay command",
    };
  }
  if (id === undefined) {
    return {
      ok: false,
      code: INVALID_REQUEST_ERROR,
      message: "Relay message requires a numeric id",
    };
  }

  const params = record.params;
  if (params !== undefined && (params === null || typeof params !== "object" || Array.isArray(params))) {
    return {
      ok: false,
      id,
      code: INVALID_REQUEST_ERROR,
      message: "Relay message params must be an object",
    };
  }

  return { ok: true, command: { id, method, params } };
}

// RelayConnection 负责把 WebSocket relay 和 chrome.debugger 连接起来。
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
  private _tabPromiseReject!: (reason: Error) => void;
  private _tabActionQueue: Promise<void>;
  private _closed = false;
  private _isAttached = false;
  // 连接状态机：未完成用户选择前是 pending，setTabId 之后才是 authorized。
  private _state: ConnectionState = "pending";
  // 连接代次：关闭后递增，用来识别跨越生命周期边界的异步操作。
  private _generation = 0;

  onclose?: () => void;
  onTabIdChanged?: (tabId: number, previousTabId: number | null) => void | Promise<void>;

  constructor(ws: WebSocket) {
    this._debuggee = {};
    this._tabPromise = new Promise<void>((resolve, reject) => {
      this._tabPromiseResolve = resolve;
      this._tabPromiseReject = reject;
    });
    // 没有人等待这个 promise 时也不要产生 unhandled rejection。
    void this._tabPromise.catch(() => {});
    this._tabActionQueue = Promise.resolve();
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

  // 连接建立后必须尽快绑定目标 tab，或者由 close 主动释放。
  // setTabId 同时是"用户已完成选择"的授权信号：只有到这里才允许操作浏览器状态。
  setTabId(tabId: number): void {
    if (this._state === "closed") throw new RelayError("E_CLOSED", "Connection is closed");
    this._debuggee = { tabId };
    this._state = "authorized";
    this._tabPromiseResolve();
  }

  // 当前连接状态：pending 表示还没完成用户选择，authorized 表示已绑定用户选中的标签页。
  get state(): ConnectionState {
    return this._state;
  }

  // 连接是否已经关闭。
  private _isClosed(): boolean {
    return this._state === "closed";
  }

  // 向 relay 发送扩展注册消息，附带当前浏览器信息。
  sendExtensionRegistration(extraParams?: Record<string, unknown>): void {
    this._sendMessage({
      method: "registerExtension",
      params: {
        extensionId: chrome.runtime.id,
        ...extraParams,
      },
    });
  }

  // 主动关闭 relay，并同步执行清理逻辑。
  close(message: string): void {
    this._state = "closed";
    try {
      this._ws.close(1000, message);
    } catch {
      // socket 已经断了也无所谓，清理逻辑照常执行。
    }
    // ws.onclose is called asynchronously, so we call it here to avoid forwarding
    // CDP events to the closed connection.
    this._onClose();
  }

  // 统一处理连接关闭后的资源清理。
  private _onClose() {
    if (this._closed) return;
    this._closed = true;
    this._state = "closed";
    this._generation++;
    chrome.debugger.onEvent.removeListener(this._eventListener);
    chrome.debugger.onDetach.removeListener(this._detachListener);
    // 关闭时不能让等待用户选 tab 的操作一直挂着，立刻失败掉。
    this._tabPromiseReject(new Error("Connection closed before a tab was selected"));
    chrome.debugger.detach(this._debuggee).catch(() => {});
    this._isAttached = false;
    this.onclose?.();
  }

  // 关闭或代次变化后，排队中的动作必须作废。
  private _assertUsable(generation?: number): void {
    if (this._state === "closed") {
      throw new RelayError("E_CLOSED", "Connection is closed");
    }
    if (generation !== undefined && generation !== this._generation) {
      throw new RelayError("E_CLOSED", "Connection was closed while the operation was running");
    }
  }

  // 授权校验：用户完成选择前，所有会碰到浏览器状态的命令一律拒绝。
  private _assertAuthorized(method: string): void {
    this._assertUsable();
    if (this._state !== "authorized") {
      throw new RelayError(
        "E_NOT_AUTHORIZED",
        `Command "${method}" is rejected: the connection is not authorized yet. ` +
          `The user must select a tab in the extension page first.`,
      );
    }
  }

  // 将 chrome.debugger 事件转发给 relay 侧。
  private _onDebuggerEvent(
    source: chrome.debugger.DebuggerSession,
    method: string,
    params: any,
  ): void {
    if (this._isClosed()) return;
    if (source.tabId !== this._debuggee.tabId) return;
    // 诊断日志只记 method，不记事件载荷。
    debugLog("Forwarding CDP event:", safeCdpMethod(method));
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

  // 处理 debugger detach；目标页关闭时直接断开连接。
  private _onDebuggerDetach(source: chrome.debugger.Debuggee, reason: string): void {
    if (source.tabId !== this._debuggee.tabId) return;
    this._isAttached = false;
    if (reason === "target_closed") {
      this.close(`Debugger detached: ${reason}`);
      this._debuggee = {};
      return;
    }
    debugLog("Debugger detached, keeping relay open for reattach:", safeDetachReason(reason), {
      tabId: this._debuggee.tabId,
    });
  }

  private async _runExclusiveTabAction<T>(action: () => Promise<T>): Promise<T> {
    const previousAction = this._tabActionQueue;
    let release!: () => void;
    this._tabActionQueue = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previousAction;
    try {
      // 排队期间连接可能已经关闭：动作不能再执行。
      this._assertUsable();
      return await action();
    } finally {
      release();
    }
  }

  // WebSocket 收到消息时转入异步处理，避免阻塞事件循环。
  private _onMessage(event: MessageEvent): void {
    if (this._isClosed()) return;
    this._onMessageAsync(event).catch(() => debugLog("Error handling relay message"));
  }

  // 解析 relay 消息并分发到具体命令处理器。
  private async _onMessageAsync(event: MessageEvent): Promise<void> {
    if (this._isClosed()) return;

    if (typeof event.data !== "string") {
      this._sendError(INVALID_REQUEST_ERROR, "Relay message must be a text frame");
      return;
    }

    // 直接解析原始文本：预先删控制字符会把畸形消息"修好"成一条合法命令。
    let parsed: unknown;
    try {
      parsed = JSON.parse(event.data);
    } catch {
      debugLog("Rejected malformed relay message");
      this._sendError(PARSE_ERROR, "Invalid JSON in relay message");
      return;
    }

    const validation = validateCommand(parsed);
    if (!validation.ok) {
      // 消息内容不可信：日志里只留固定错误码和请求 id，不回显任何原始文本。
      debugLog("Rejected invalid relay message:", {
        id: validation.id,
        errorCode: "E_INVALID_REQUEST",
        protocolCode: validation.code,
      });
      // 能识别出请求 id 时回带 id，relay 侧才能把错误对应到原请求。
      this._sendError(validation.code, validation.message, validation.id);
      return;
    }

    const command = validation.command;
    if (this._isClosed()) return;

    // 诊断日志只输出 id 和 method 白名单。
    debugLog("Received relay command:", { id: command.id, method: command.method });

    const startedAt = Date.now();
    const response: ProtocolResponse = {
      id: command.id,
    };
    try {
      response.result = await this._handleCommand(command);
    } catch (error: any) {
      // 失败诊断只记内部错误类别：Error.message / stack 可能带着页面内容和凭据，
      // 一律不进日志（错误文本仍然按协议回给 relay，由 relay 决定怎么展示）。
      const errorCode = error instanceof RelayError ? error.code : "E_INTERNAL";
      debugLog("Relay command failed:", {
        id: command.id,
        method: command.method,
        errorCode,
        durationMs: Date.now() - startedAt,
      });
      response.error = error?.message ? String(error.message) : String(error);
    }
    debugLog("Sending relay response:", {
      id: command.id,
      method: command.method,
      ok: response.error === undefined,
      durationMs: Date.now() - startedAt,
    });
    this._sendMessage(response);
  }

  // 将 relay 命令翻译成 chrome.tabs / chrome.debugger 调用。
  private async _handleCommand(message: ProtocolCommand): Promise<any> {
    if (message.method === "listTabs") {
      // 标签页列表会带出完整 title / url（query 里可能有重置 token），
      // 选择页走扩展内部的 getTabs 消息，不需要 relay 拿列表：
      // 授权之前一律拒绝。
      this._assertAuthorized(message.method);
      const tabs = await chrome.tabs.query({});
      return tabs
        .filter(
          (tab) =>
            tab.id &&
            tab.windowId &&
            tab.url &&
            !["chrome:", "edge:", "devtools:", "chrome-extension:"].some((scheme) =>
              tab.url!.startsWith(scheme),
            ),
        )
        .map((tab) => ({
          id: tab.id,
          windowId: tab.windowId,
          title: tab.title || "",
          url: tab.url || "",
          active: !!tab.active,
        }));
    }
    if (message.method === "attachToTab") {
      // attachToTab 本身就是"等用户选 tab"的门闩：授权前不会碰任何标签页。
      return await this._runExclusiveTabAction(async () => {
        await this._waitForAuthorization();
        return await this._attachDebuggerToTab(this._debuggee.tabId!);
      });
    }
    if (message.method === "createTab") {
      this._assertAuthorized(message.method);
      return await this._runExclusiveTabAction(async () => {
        const url = message.params?.url || "about:blank";
        const tab = await chrome.tabs.create({ url, active: true });
        if (!tab.id || !tab.windowId) {
          throw new RelayError("E_INTERNAL", "Created tab is missing tab identifiers");
        }
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
      });
    }
    if (message.method === "createWindow") {
      this._assertAuthorized(message.method);
      return await this._runExclusiveTabAction(async () => {
        const url = message.params?.url || "about:blank";
        const created = await chrome.windows.create({ url, focused: true });
        const tab = created.tabs?.[0];
        if (!created.id || !tab?.id) {
          throw new RelayError("E_INTERNAL", "Created window is missing tab identifiers");
        }
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
      });
    }
    if (message.method === "switchToTab") {
      this._assertAuthorized(message.method);
      return await this._runExclusiveTabAction(async () => {
        const tabId = Number(message.params?.tabId || 0);
        const windowId = Number(message.params?.windowId || 0) || undefined;
        if (!tabId) throw new RelayError("E_INVALID_PARAMS", "switchToTab requires tabId");
        return await this._attachDebuggerToTab(tabId, windowId);
      });
    }
    if (message.method === "closeTab") {
      this._assertAuthorized(message.method);
      return await this._runExclusiveTabAction(async () => {
        // 动作开始时记下代次：detach 是异步的，期间连接可能已经被关闭。
        const generation = this._generation;
        const tabId = Number(message.params?.tabId || this._debuggee.tabId || 0);
        if (!tabId) throw new RelayError("E_INVALID_PARAMS", "closeTab requires tabId");
        if (this._debuggee.tabId === tabId && this._isAttached) {
          await chrome.debugger.detach(this._debuggee).catch(() => {});
          this._isAttached = false;
        }
        // detach 期间连接被关闭时，不能再关标签页。
        this._assertUsable(generation);
        await chrome.tabs.remove(tabId);
        if (this._debuggee.tabId === tabId) this._debuggee = {};
        return { closedTabId: tabId };
      });
    }
    if (message.method === "forwardCDPCommand") {
      this._assertAuthorized(message.method);
      const { sessionId, method, params } = message.params || {};
      // 内层参数严格校验：CDP 参数必须是对象，
      // 数组 / null / 原始值都拒绝，避免把整段负载直接塞进调试器。
      if (typeof method !== "string" || !method) {
        throw new RelayError("E_INVALID_PARAMS", "forwardCDPCommand requires a method name");
      }
      if (sessionId !== undefined && typeof sessionId !== "string") {
        throw new RelayError("E_INVALID_PARAMS", "forwardCDPCommand sessionId must be a string");
      }
      if (params !== undefined && (params === null || typeof params !== "object" || Array.isArray(params))) {
        throw new RelayError("E_INVALID_PARAMS", "forwardCDPCommand params must be an object");
      }
      // 诊断日志只输出 method 和结构化脱敏后的参数。
      debugLog("CDP command:", {
        method: safeCdpMethod(method),
        params: redactCdpParams(method, params),
      });
      const debuggerSession: chrome.debugger.DebuggerSession = {
        ...this._debuggee,
        sessionId,
      };
      // Forward CDP command to chrome.debugger
      return await chrome.debugger.sendCommand(debuggerSession, method, params);
    }
    throw new RelayError("E_UNSUPPORTED", `Unknown relay command: ${message.method}`);
  }

  // 等待用户完成 tab 选择；连接在此期间关闭则直接失败。
  private async _waitForAuthorization(): Promise<void> {
    this._assertUsable();
    await this._tabPromise;
    this._assertUsable();
  }

  private async _attachDebuggerToTab(tabId: number, windowId?: number): Promise<any> {
    const generation = this._generation;
    const previousTabId = this._debuggee.tabId || null;
    if (previousTabId && previousTabId !== tabId && this._isAttached)
      await chrome.debugger.detach(this._debuggee).catch(() => {});
    this._assertUsable(generation);

    this._debuggee = { tabId };
    if (!this._isAttached || previousTabId !== tabId) {
      debugLog("Attaching debugger to tab:", { tabId });
      try {
        await chrome.debugger.attach(this._debuggee, "1.3");
      } catch (error: any) {
        if (!isAlreadyAttachedError(error)) throw error;
        debugLog("Reusing existing debugger attachment for tab:", { tabId });
      }
      // attach 期间连接可能已经关闭：必须马上 detach，不能把调试器留在标签页上。
      if (this._isClosed() || generation !== this._generation) {
        await chrome.debugger.detach(this._debuggee).catch(() => {});
        throw new RelayError("E_CLOSED", "Connection was closed while attaching the debugger");
      }
      this._isAttached = true;
    }

    const updatedTab = await chrome.tabs.update(tabId, { active: true });
    this._assertUsable(generation);
    const resolvedWindowId = windowId || updatedTab?.windowId;
    if (resolvedWindowId) await chrome.windows.update(resolvedWindowId, { focused: true });
    this._assertUsable(generation);

    if (previousTabId !== tabId) await this.onTabIdChanged?.(tabId, previousTabId);
    this._assertUsable(generation);

    const result: any = await chrome.debugger.sendCommand(this._debuggee, "Target.getTargetInfo");
    this._assertUsable(generation);
    return {
      tabId,
      windowId: resolvedWindowId,
      targetInfo: result?.targetInfo,
    };
  }

  private _sendError(code: number, message: string, id?: number): void {
    this._sendMessage({
      ...(id === undefined ? {} : { id }),
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
