import { describe, it, expect } from 'vitest';
import { redactPayload, redactUrl } from './redact';

describe('redactUrl', () => {
  it('drops the query string of a relay url', () => {
    const redacted = redactUrl('ws://127.0.0.1:47978/relay?token=deadbeefcafe');
    expect(redacted).toBe('ws://127.0.0.1:47978/relay');
    expect(redacted).not.toContain('deadbeefcafe');
  });

  it('drops userinfo and hash', () => {
    expect(redactUrl('https://user:pass@example.com/a?b=c#frag')).toBe(
      'https://example.com/a',
    );
  });

  it('never falls back to the raw string for invalid urls', () => {
    expect(redactUrl('not a url ?token=deadbeefcafe')).toBe('<invalid url>');
    expect(redactUrl('')).toBe('<invalid url>');
  });
});

describe('redactPayload', () => {
  it('masks credential headers case-insensitively', () => {
    const redacted = redactPayload({
      headers: { Authorization: 'Bearer abc123', Cookie: 'sid=xyz' },
    });
    expect(JSON.stringify(redacted)).not.toContain('abc123');
    expect(JSON.stringify(redacted)).not.toContain('sid=xyz');
    expect(redacted).toEqual({ headers: { Authorization: '***', Cookie: '***' } });
  });

  it('masks every listed sensitive key spelling', () => {
    const redacted = redactPayload({
      token: 't',
      authorization: 'a',
      cookie: 'c',
      'set-cookie': 'sc',
      password: 'p',
      passwd: 'pw',
      secret: 's',
      sessionId: 'sid',
      'session-id': 'sid2',
      'x-api-key': 'k',
      apiKey: 'ak',
      api_key: 'ak2',
      bearer: 'b',
      nested: [{ authToken: 'deep' }],
    }) as Record<string, unknown>;

    for (const [key, value] of Object.entries(redacted)) {
      if (key === 'nested') continue;
      expect(value).toBe('***');
    }
    expect(redacted.nested).toEqual([{ authToken: '***' }]);
  });

  it('keeps useful CDP fields visible', () => {
    const redacted = redactPayload({
      method: 'Page.navigate',
      params: { url: 'https://example.com' },
    });
    expect(redacted).toEqual({
      method: 'Page.navigate',
      params: { url: 'https://example.com' },
    });
  });

  it('caps recursion depth and survives cycles', () => {
    const deep: Record<string, unknown> = { value: 'leaf' };
    let cursor = deep;
    for (let i = 0; i < 20; i += 1) {
      const next: Record<string, unknown> = {};
      cursor.child = next;
      cursor = next;
    }
    const cyclic: Record<string, unknown> = { name: 'root' };
    cyclic.self = cyclic;

    expect(JSON.stringify(redactPayload(deep))).toContain('[max depth]');
    expect((redactPayload(cyclic) as any).self).toBe('[circular]');
  });

  it('truncates long strings', () => {
    const redacted = redactPayload({ expression: 'a'.repeat(2000) }) as Record<string, unknown>;
    expect((redacted.expression as string).length).toBeLessThan(700);
    expect(redacted.expression as string).toContain('[truncated');
  });
});
