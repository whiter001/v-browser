import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import net from 'net';
import { spawn } from 'child_process';
import { chromium, test, expect } from '@playwright/test';

const extensionPublicKey = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwRsUUO4mmbCi4JpmrIoIw31iVW9+xUJRZ6nSzya17PQkaUPDxe1IpgM+vpd/xB6mJWlJSyE1Lj95c0sbomGfVY1M0zUeKbaRVcAb+/a6m59gNR+ubFlmTX0nK9/8fE2FpRB9D+4N5jyeIPQuASW/0oswI2/ijK7hH5NTRX8gWc/ROMSgUj7rKhTAgBrICt/NsStgDPsxRTPPJnhJ/ViJtM1P5KsSYswE987DPoFnpmkFpq8g1ae0eYbQfXy55ieaacC4QWyJPj3daU2kMfBQw7MXnnk0H/WDxouMOIHnd8MlQxpEMqAihj7KpuONH+MUhuj9HEQo4df6bSaIuQ0b4QIDAQAB';
const extensionId = 'mmlmfjhmonkocbjadbfplnigmagldckm';

test('v-browser CLI smoke flow', async ({}, testInfo) => {
  test.skip(process.platform !== 'darwin', 'This smoke test currently targets local macOS Chromium extension loading.');

  const workspaceRoot = path.resolve(__dirname, '../../..');
  const extensionDist = path.join(workspaceRoot, 'packages/extension/dist');
  const serverDir = path.join(workspaceRoot, 'packages/server');
  const serverBinary = path.join(serverDir, 'v-browser');
  const testHome = await fs.mkdtemp(path.join(os.tmpdir(), 'v-browser-e2e-'));
  const extensionDir = path.join(testInfo.outputDir, 'extension');
  const userDataDir = path.join(testInfo.outputDir, 'user-data');
  const relayPort = await getFreePort();
  const ipcPort = await getFreePort();

  await fs.cp(extensionDist, extensionDir, { recursive: true });
  const manifestPath = path.join(extensionDir, 'manifest.json');
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  manifest.key = extensionPublicKey;
  await fs.writeFile(manifestPath, JSON.stringify(manifest, null, 2));

  const browserContext = await chromium.launchPersistentContext(userDataDir, {
    channel: 'chromium',
    headless: false,
    ignoreDefaultArgs: ['--enable-automation'],
    args: [
      `--disable-extensions-except=${extensionDir}`,
      `--load-extension=${extensionDir}`,
    ],
  });

  const serverProcess = spawn(serverBinary, ['server'], {
    cwd: serverDir,
    env: {
      ...process.env,
      HOME: testHome,
      V_BROWSER_HOME: testHome,
      V_BROWSER_RELAY_PORT: String(relayPort),
      V_BROWSER_IPC_PORT: String(ipcPort),
    },
    detached: true,
    stdio: 'ignore',
  });
  serverProcess.unref();

  try {
    await waitForFile(path.join(testHome, '.v-browser', 'server.sock'));
    const token = (await fs.readFile(path.join(testHome, '.v-browser', 'token'), 'utf8')).trim();

    const page = await browserContext.newPage();
    await page.goto('data:text/html,<title>v-browser e2e</title><h1>Hello E2E</h1>');

    const connectPage = await browserContext.newPage();
    const relayUrl = encodeURIComponent(`ws://127.0.0.1:${relayPort}`);
    const client = encodeURIComponent('{"name":"v-browser","version":"0.1.0"}');
    await connectPage.goto(`chrome-extension://${extensionId}/connect.html?mcpRelayUrl=${relayUrl}&client=${client}&protocolVersion=1&token=${token}`);

    await expect.poll(async () => {
      const status = await runCli(serverBinary, serverDir, testHome, ['status']);
      return status.trim();
    }, { timeout: 15000 }).toContain('"connected":true');

    const initialTabs = JSON.parse(await runCli(serverBinary, serverDir, testHome, ['tab', 'list']));
    const initialTarget = initialTabs.find((tab: { id: number, windowId: number, title?: string }) => tab.title === 'v-browser e2e');
    expect(initialTarget).toBeTruthy();

    const connectResult = await runCli(serverBinary, serverDir, testHome, ['connect', '--tab-id', String(initialTarget.id), '--window-id', String(initialTarget.windowId)]);
    expect(connectResult).toContain('targetInfo');

    const evalResult = await runCli(serverBinary, serverDir, testHome, ['eval', 'document.title']);
    expect(evalResult.trim()).toBe('v-browser e2e');

    const secondPage = await browserContext.newPage();
    await secondPage.goto('data:text/html,<title>v-browser second</title><h1>Second</h1>');

    const listedTabs = JSON.parse(await runCli(serverBinary, serverDir, testHome, ['tab', 'list']));
    expect(Array.isArray(listedTabs)).toBe(true);
    const secondTab = listedTabs.find((tab: { id: number, title?: string }) => tab.title === 'v-browser second');
    expect(secondTab).toBeTruthy();
    await runCli(serverBinary, serverDir, testHome, ['tab', 'switch', String(secondTab.id)]);

    const switchedTitle = await runCli(serverBinary, serverDir, testHome, ['eval', 'document.title']);
    expect(switchedTitle.trim()).toBe('v-browser second');

    await runCli(serverBinary, serverDir, testHome, ['set', 'device', 'iPhone 14']);
    const viewportResult = await runCli(serverBinary, serverDir, testHome, ['eval', 'JSON.stringify({ screenWidth: screen.width, ua: navigator.userAgent, touch: navigator.maxTouchPoints })']);
    expect(viewportResult).toContain('iPhone');
    expect(viewportResult).toContain('390');
    expect(viewportResult).toContain('5');

    const tracePath = path.join(testInfo.outputDir, 'smoke-trace.json');
    await runCli(serverBinary, serverDir, testHome, ['trace', 'start']);
    await page.click('body');
    await runCli(serverBinary, serverDir, testHome, ['trace', 'stop', '--path', tracePath]);
    const traceContent = await fs.readFile(tracePath, 'utf8');
    expect(traceContent.length).toBeGreaterThan(0);
    expect(traceContent).toContain('traceEvents');

    const jsonErrorText = await runCli(serverBinary, serverDir, testHome, ['--json', 'tab', 'switch', '999999']).catch(error => error.message);
    const jsonError = JSON.parse(jsonErrorText);
    expect(jsonError.ok).toBe(false);
    expect(jsonError.error.code).toBeTruthy();
  } finally {
    await browserContext.close();
    await fs.rm(testHome, { recursive: true, force: true }).catch(() => {});
  }
});

async function runCli(binary: string, cwd: string, home: string, args: string[]): Promise<string> {
  return await new Promise((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    const child = spawn(binary, args, {
      cwd,
      env: { ...process.env, HOME: home, V_BROWSER_HOME: home },
    });
    child.stdout.on('data', data => stdout += data.toString());
    child.stderr.on('data', data => stderr += data.toString());
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0)
        resolve(stdout);
      else
        reject(new Error(stderr || stdout || `CLI exited with code ${code}`));
    });
  });
}

async function getFreePort(): Promise<number> {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address === 'string') {
        server.close(() => reject(new Error('Failed to resolve free port')));
        return;
      }
      const { port } = address;
      server.close(error => {
        if (error)
          reject(error);
        else
          resolve(port);
      });
    });
  });
}

async function waitForFile(filePath: string): Promise<void> {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    try {
      await fs.access(filePath);
      return;
    } catch {
      await new Promise(resolve => setTimeout(resolve, 200));
    }
  }
  throw new Error(`Timed out waiting for ${filePath}`);
}