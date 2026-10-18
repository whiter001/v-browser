import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

describe('debugLog', () => {
  const originalConsole = console.log;
  const globalScope = globalThis as Record<string, unknown>;

  beforeEach(() => {
    console.log = vi.fn();
    globalScope.__V_BROWSER_DEBUG_LOGGING__ = true;
  });

  afterEach(() => {
    console.log = originalConsole;
    delete globalScope.__V_BROWSER_DEBUG_LOGGING__;
  });

  it('should log messages with [Extension] prefix when enabled', async () => {
    const { debugLog } = await import('../src/relayConnection');
    debugLog('test message', { foo: 'bar' });

    expect(console.log).toHaveBeenCalledWith('[Extension]', 'test message', { foo: 'bar' });
  });

  it('should handle multiple arguments', async () => {
    const { debugLog } = await import('../src/relayConnection');
    debugLog('arg1', 'arg2', 123, true);

    expect(console.log).toHaveBeenCalledWith('[Extension]', 'arg1', 'arg2', 123, true);
  });

  it('should redact credentials in structured arguments', async () => {
    const { debugLog } = await import('../src/relayConnection');
    debugLog('CDP command:', 'Network.getAllCookies', {
      headers: { Authorization: 'Bearer abc123', Cookie: 'sid=xyz' },
    });

    const printed = JSON.stringify((console.log as any).mock.calls[0]);
    expect(printed).not.toContain('abc123');
    expect(printed).not.toContain('sid=xyz');
  });
});

describe('debugLog disabled behavior', () => {
  const originalConsole = console.log;
  const globalScope = globalThis as Record<string, unknown>;

  beforeEach(() => {
    console.log = vi.fn();
  });

  afterEach(() => {
    console.log = originalConsole;
    delete globalScope.__V_BROWSER_DEBUG_LOGGING__;
  });

  it('should not log by default', async () => {
    const { debugLog, isDebugLoggingEnabled } = await import('../src/relayConnection');
    delete globalScope.__V_BROWSER_DEBUG_LOGGING__;

    debugLog('This should not be logged');

    expect(isDebugLoggingEnabled()).toBe(false);
    expect(console.log).not.toHaveBeenCalled();
  });

  it('should log when the global switch is on', async () => {
    const { debugLog } = await import('../src/relayConnection');
    globalScope.__V_BROWSER_DEBUG_LOGGING__ = true;

    debugLog('This should be logged', 'with', 'args');

    expect(console.log).toHaveBeenCalledWith('[Extension]', 'This should be logged', 'with', 'args');
  });
});
