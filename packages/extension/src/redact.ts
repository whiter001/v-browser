/**
 * 日志脱敏工具：service worker 控制台对用户可见，任何凭据（token、Cookie、
 * Authorization）都不能原样打进去，CDP 载荷同样可能夹带请求/响应体与页面内容。
 */

const REDACTED = "***";
// 载荷类字段（页面内容、请求体、脚本）整体不可展示时的占位符。
const HIDDEN = "[hidden]";

const INVALID_URL_PLACEHOLDER = "<invalid url>";

// 规范化后精确匹配的敏感字段名（去掉非字母数字并小写，覆盖 x-api-key / api_key 等写法）。
const SENSITIVE_KEYS = new Set([
  "token",
  "accesstoken",
  "refreshtoken",
  "authtoken",
  "idtoken",
  "authorization",
  "proxyauthorization",
  "cookie",
  "cookies",
  "setcookie",
  "password",
  "passwd",
  "pwd",
  "secret",
  "clientsecret",
  "sessionid",
  "session",
  "xapikey",
  "apikey",
  "apisecret",
  "bearer",
  "jwt",
  "credential",
  "credentials",
  "privatekey",
]);

// 包含即视为敏感的片段，用于 authToken / myPassword 之类的组合字段名。
const SENSITIVE_KEY_SUBSTRINGS = [
  "token",
  "password",
  "passwd",
  "secret",
  "authorization",
  "cookie",
  "apikey",
  "credential",
];

// 头部容器：里面的值一律是凭据，只保留头部名。
const HEADER_KEYS = new Set([
  "headers",
  "requestheaders",
  "responseheaders",
  "extrahttpheaders",
  "headersarray",
  "requestheadersarray",
  "responseheadersarray",
]);

// 载荷类字段：可能装页面内容、请求体或脚本，默认整体隐藏。
const PAYLOAD_KEYS = new Set([
  "body",
  "postdata",
  "postdataentries",
  "expression",
  "data",
  "content",
  "text",
  "script",
  "code",
  "html",
  "snippet",
  "source",
  "arguments",
  "input",
]);

// 递归深度上限，防止自引用或异常深的结构把日志处理拖垮。
const MAX_DEPTH = 8;
// 单个字符串的日志长度上限，避免大段页面内容/响应体塞进控制台。
const MAX_STRING_LENGTH = 512;
// 数组元素上限，同样是为了控制单条日志体积。
const MAX_ARRAY_LENGTH = 100;

// 只保留协议、主机和路径：query / userinfo / hash 都可能携带凭据，整体丢弃。
export function redactUrl(raw: string): string {
  try {
    const url = new URL(raw);
    // 原始串没有显式路径时不要补 "/"，否则日志里的 URL 和输入对不上。
    const hasExplicitPath = /^[a-z][a-z0-9+.-]*:\/\/[^/?#]*\//.test(raw.trim());
    const path = hasExplicitPath ? url.pathname : "";
    return `${url.protocol}//${url.host}${path}`;
  } catch {
    // 解析失败时宁可什么都不打印，也不回退到原始字符串。
    return INVALID_URL_PLACEHOLDER;
  }
}

// 归一化键名：小写并去掉非字母数字。
function normalizeKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function isSensitiveKey(key: string): boolean {
  const normalized = normalizeKey(key);
  if (SENSITIVE_KEYS.has(normalized)) return true;
  return SENSITIVE_KEY_SUBSTRINGS.some((fragment) => normalized.includes(fragment));
}

function isPayloadKey(key: string): boolean {
  return PAYLOAD_KEYS.has(normalizeKey(key));
}

function isHeaderKey(key: string): boolean {
  return HEADER_KEYS.has(normalizeKey(key));
}

function redactString(value: string): string {
  if (value.length <= MAX_STRING_LENGTH) return value;
  const omitted = value.length - MAX_STRING_LENGTH;
  return `${value.slice(0, MAX_STRING_LENGTH)}…[truncated ${omitted} chars]`;
}

// 隐藏载荷内容，但保留长度信息：输出形态与截断一致，便于诊断时区分"很长"和"被隐藏"。
function hideString(value: string): string {
  return `[truncated ${value.length} chars, hidden]`;
}

// 头部值一律隐藏；{name,value} 形式只保留头部名。
export function redactHeaderValue(value: unknown): unknown {
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return REDACTED;
  if (Array.isArray(value)) {
    return value.slice(0, MAX_ARRAY_LENGTH).map((entry) => {
      if (entry && typeof entry === "object" && !Array.isArray(entry)) {
        const record = entry as Record<string, unknown>;
        if (typeof record.name === "string") {
          return { name: record.name, value: REDACTED };
        }
      }
      return REDACTED;
    });
  }
  if (typeof value === "object") {
    const result: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>)) {
      result[key] = REDACTED;
    }
    return result;
  }
  return REDACTED;
}

// Error.message / stack 里常混入凭据，这里做一次保守的字符串清洗。
const SECRET_PATTERNS: Array<[RegExp, string]> = [
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+/gi, "$1 ***"],
  [
    /((?:token|secret|password|passwd|api[_-]?key|apikey|auth[_-]?key|authorization|cookie|session[_-]?id|access[_-]?token|refresh[_-]?token)\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;"'&]+)/gi,
    "$1***",
  ],
  [/\b[A-Fa-f0-9]{32,}\b/g, REDACTED],
  [/\b[A-Za-z0-9_-]{40,}\b/g, REDACTED],
];

// 文本里出现的 URL：query 段经常夹带重置 token、邮箱之类的凭据，
// 关键词黑名单覆盖不到（?key=...&email=... 里的参数名可以任意取），
// 因此这里统一按 redactUrl 裁掉 query / userinfo / hash。
const URL_IN_TEXT = /\b(?:https?|wss?|ftp):\/\/[^\s"'<>]+/gi;

export function scrubSecrets(text: string): string {
  if (!text) return text;
  let result = text.replace(URL_IN_TEXT, (match) => redactUrl(match));
  for (const [pattern, replacement] of SECRET_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

function redactValue(value: unknown, depth: number, seen: WeakSet<object>): unknown {
  if (value === null || value === undefined) return value;

  const type = typeof value;
  if (type === "string") return redactString(value as string);
  if (type === "number" || type === "boolean" || type === "bigint") return value;
  if (type === "function" || type === "symbol") return `[${type}]`;

  if (depth >= MAX_DEPTH) return "[max depth]";

  const objectValue = value as object;
  if (seen.has(objectValue)) return "[circular]";
  seen.add(objectValue);

  try {
    if (Array.isArray(value)) {
      const items = value
        .slice(0, MAX_ARRAY_LENGTH)
        .map((item) => redactValue(item, depth + 1, seen));
      if (value.length > MAX_ARRAY_LENGTH) items.push(`[truncated ${value.length - MAX_ARRAY_LENGTH} items]`);
      return items;
    }

    // Error 的 message/stack 不在可枚举属性里，单独取出来再脱敏。
    if (value instanceof Error) {
      return {
        name: value.name,
        message: scrubSecrets(redactString(value.message)),
        stack: scrubSecrets(redactString(String(value.stack ?? ""))),
      };
    }

    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(objectValue as Record<string, unknown>)) {
      result[key] = redactEntry(key, item, depth + 1, seen);
    }
    return result;
  } finally {
    seen.delete(objectValue);
  }
}

// 单个字段的脱敏：敏感键、头部、URL、载荷各有各的处理方式。
function redactEntry(key: string, item: unknown, depth: number, seen: WeakSet<object>): unknown {
  if (isSensitiveKey(key)) return REDACTED;
  // {name,value} 形式的请求头在这里被统一处理：值永远不显示。
  if (normalizeKey(key) === "value") return REDACTED;
  if (isHeaderKey(key)) return redactHeaderValue(item);
  // URL 只接受字符串：数组 / 对象形态的 url 整体隐藏，
  // 否则里面的 query（可能带重置 token）会被原样保留下来。
  if (normalizeKey(key) === "url") {
    return typeof item === "string" ? redactUrl(item) : HIDDEN;
  }
  if (isPayloadKey(key)) {
    return typeof item === "string" ? hideString(item) : HIDDEN;
  }
  return redactValue(item, depth, seen);
}

// 递归脱敏 CDP 的 params / 响应 / 消息体等任意结构化载荷。
export function redactPayload(value: unknown): unknown {
  return redactValue(value, 0, new WeakSet<object>());
}

// 诊断日志里默认允许出现的 CDP 字段：只有 URL（脱敏后，且必须是字符串）。
const DEFAULT_CDP_VISIBLE_KEYS = new Set(["url"]);

// 少数常用 method 额外允许出现的字段，以及这些字段的预期类型。
// 白名单只放行"预期形态"的值：类型不符一律整体隐藏（fail-closed）。
const CDP_METHOD_VISIBLE_KEYS: Record<string, Record<string, string>> = {
  "Page.navigate": { transitionType: "string", referrerPolicy: "string", frameId: "string" },
  "Page.reload": { ignoreCache: "boolean", loaderId: "string" },
  "Runtime.evaluate": {
    contextId: "number",
    returnByValue: "boolean",
    awaitPromise: "boolean",
    userGesture: "boolean",
  },
  "Runtime.callFunctionOn": {
    objectId: "string",
    returnByValue: "boolean",
    awaitPromise: "boolean",
  },
  "DOM.getDocument": { depth: "number", pierce: "boolean" },
  "Target.getTargetInfo": {},
  "Target.getTargets": {},
};

// 白名单字段的类型校验：形态不符就整体隐藏。
function matchesExpectedType(value: unknown, expected: string): boolean {
  if (expected === "string") return typeof value === "string";
  if (expected === "number") return typeof value === "number" && Number.isFinite(value);
  if (expected === "boolean") return typeof value === "boolean";
  return false;
}

// 按 CDP method 结构化脱敏：白名单字段才可见，URL 走 redactUrl，
// body/expression/任意 value 默认隐藏，headers 只保留头部名。
export function redactCdpParams(method: string, params: unknown): unknown {
  if (params === null || params === undefined) return HIDDEN;
  if (typeof params !== "object") return HIDDEN;
  // 根是数组时整体隐藏：CDP 参数是对象形态，
  // 数组里的字符串会绕过字段级规则被原样打印出来。
  if (Array.isArray(params)) return HIDDEN;

  const visible: Record<string, string> = {};
  for (const key of DEFAULT_CDP_VISIBLE_KEYS) visible[key] = "string";
  for (const [key, expected] of Object.entries(CDP_METHOD_VISIBLE_KEYS[method] ?? {})) {
    visible[normalizeKey(key)] = expected;
  }
  return redactCdpValue(params, 0, new WeakSet<object>(), visible);
}

function redactCdpValue(
  value: unknown,
  depth: number,
  seen: WeakSet<object>,
  visible: Record<string, string>,
): unknown {
  if (value === null || value === undefined) return value;

  const type = typeof value;
  if (type === "string") return redactString(value as string);
  if (type === "number" || type === "boolean" || type === "bigint") return value;
  if (type === "function" || type === "symbol") return `[${type}]`;

  if (depth >= MAX_DEPTH) return "[max depth]";

  const objectValue = value as object;
  if (seen.has(objectValue)) return "[circular]";
  seen.add(objectValue);

  try {
    if (Array.isArray(value)) {
      const items = value
        .slice(0, MAX_ARRAY_LENGTH)
        .map((item) => redactCdpValue(item, depth + 1, seen, visible));
      if (value.length > MAX_ARRAY_LENGTH) {
        items.push(`[truncated ${value.length - MAX_ARRAY_LENGTH} items]`);
      }
      return items;
    }

    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(objectValue as Record<string, unknown>)) {
      const normalized = normalizeKey(key);
      if (isHeaderKey(key)) {
        result[key] = redactHeaderValue(item);
        continue;
      }
      if (normalized === "url") {
        // URL 必须是字符串：数组 / 对象形态的 url 整体隐藏，
        // 绝不能让里面的 query（可能带重置 token）原样保留。
        result[key] = typeof item === "string" ? redactUrl(item) : HIDDEN;
        continue;
      }
      const expected = visible[normalized];
      if (!expected) {
        result[key] = HIDDEN;
        continue;
      }
      if (!matchesExpectedType(item, expected)) {
        result[key] = HIDDEN;
        continue;
      }
      result[key] = redactCdpValue(item, depth + 1, seen, visible);
    }
    return result;
  } finally {
    seen.delete(objectValue);
  }
}
