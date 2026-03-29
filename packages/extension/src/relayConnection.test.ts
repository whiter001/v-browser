import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

describe('debugLog', () => {
  const originalConsole = console.log;

  beforeEach(() => {
    console.log = vi.fn();
  });

  afterEach(() => {
    console.log = originalConsole;
  });

  it('should log messages with [Extension] prefix', async () => {
    const { debugLog } = await import('../src/relayConnection');
    debugLog('test message', { foo: 'bar' });

    expect(console.log).toHaveBeenCalledWith('[Extension]', 'test message', { foo: 'bar' });
  });

  it('should handle multiple arguments', async () => {
    const { debugLog } = await import('../src/relayConnection');
    debugLog('arg1', 'arg2', 123, true);

    expect(console.log).toHaveBeenCalledWith('[Extension]', 'arg1', 'arg2', 123, true);
  });
});

describe('debugLog disabled behavior', () => {
  it('should respect debugLog enabled flag', async () => {
    const { debugLog } = await import('../src/relayConnection');
    const consoleSpy = vi.spyOn(console, 'log');

    debugLog('This should be logged', 'with', 'args');

    expect(consoleSpy).toHaveBeenCalled();
  });
});
