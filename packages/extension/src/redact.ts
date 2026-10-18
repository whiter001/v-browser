/**
 * 日志脱敏工具：service worker 控制台对用户可见，任何凭据（token、Cookie、
 * Authorization）都不能原样打进去，CDP 载荷同样可能夹带请求/响应体与页面内容。
 */

const REDACTED = "***";

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

// 递归深度上限，防止自引用或异常深的结构把日志处理拖垮。
const MAX_DEPTH = 8;
// 单个字符串的日志长度上限，避免大段页面内容/响应体塞进控制台。
const MAX_STRING_LENGTH = 512;
// 数组元素上限，同样是为了控制单条日志体积。
const MAX_ARRAY_LENGTH = 100;

const INVALID_URL_PLACEHOLDER = "<invalid url>";

// 只保留协议、主机和路径：query / userinfo / hash 都可能携带凭据，整体丢弃。
export function redactUrl(raw: string): string {
  try {
    const url = new URL(raw);
    return `${url.protocol}//${url.host}${url.pathname}`;
  } catch {
    // 解析失败时宁可什么都不打印，也不回退到原始字符串。
    return INVALID_URL_PLACEHOLDER;
  }
}

function isSensitiveKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");
  if (SENSITIVE_KEYS.has(normalized)) return true;
  return SENSITIVE_KEY_SUBSTRINGS.some((fragment) => normalized.includes(fragment));
}

function redactString(value: string): string {
  if (value.length <= MAX_STRING_LENGTH) return value;
  const omitted = value.length - MAX_STRING_LENGTH;
  return `${value.slice(0, MAX_STRING_LENGTH)}…[truncated ${omitted} chars]`;
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
        message: redactValue(value.message, depth + 1, seen),
        stack: redactString(String(value.stack ?? "")),
      };
    }

    const result: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(objectValue as Record<string, unknown>)) {
      result[key] = isSensitiveKey(key) ? REDACTED : redactValue(item, depth + 1, seen);
    }
    return result;
  } finally {
    seen.delete(objectValue);
  }
}

// 递归脱敏 CDP 的 params / 响应 / 消息体等任意结构化载荷。
export function redactPayload(value: unknown): unknown {
  return redactValue(value, 0, new WeakSet<object>());
}
