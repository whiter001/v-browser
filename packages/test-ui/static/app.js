const state = {
  status: null,
};

const els = {
  serverBinary: document.getElementById("serverBinary"),
  serverBinaryState: document.getElementById("serverBinaryState"),
  serverRunning: document.getElementById("serverRunning"),
  extensionConnected: document.getElementById("extensionConnected"),
  extensionId: document.getElementById("extensionId"),
  extensionStatusLink: document.getElementById("extensionStatusLink"),
  tokenValue: document.getElementById("tokenValue"),
  ipcPort: document.getElementById("ipcPort"),
  hintText: document.getElementById("hintText"),
  vBrowserHome: document.getElementById("vBrowserHome"),
  commandOutput: document.getElementById("commandOutput"),
  serverLog: document.getElementById("serverLog"),
  lastCommandLabel: document.getElementById("lastCommandLabel"),
  connectExtensionId: document.getElementById("connectExtensionId"),
  openUrl: document.getElementById("openUrl"),
  evalExpression: document.getElementById("evalExpression"),
  customCommand: document.getElementById("customCommand"),
};

async function fetchStatus() {
  const response = await fetch("/api/status");
  const status = await response.json();
  state.status = status;
  renderStatus(status);
}

async function runAction(payload) {
  setCommandState("running", "Running…");
  try {
    const response = await fetch("/api/run", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    const result = await response.json();
    renderCommandResult(result);
    if (result.status) renderStatus(result.status);
  } catch (error) {
    renderCommandResult({
      ok: false,
      invoked: payload.action,
      error: String(error),
      stdout: "",
      stderr: "",
      exit_code: -1,
      duration_ms: 0,
      status: state.status,
    });
  }
}

function renderStatus(status) {
  els.serverBinary.textContent = status.server_binary || "-";
  els.serverBinaryState.textContent = status.binary_exists ? "binary ready" : "binary missing";
  els.serverRunning.textContent = status.server_running ? "reachable" : "offline";
  els.extensionConnected.textContent = status.extension_connected
    ? "extension connected"
    : "extension disconnected";
  els.extensionId.textContent = status.stored_extension_id || "not synced yet";
  els.tokenValue.textContent = status.token || "not generated yet";
  els.ipcPort.textContent = status.ipc_port ? `IPC port ${status.ipc_port}` : "no ipc port";
  els.hintText.textContent = status.hint || "-";
  els.vBrowserHome.textContent = status.v_browser_home || "-";
  els.serverLog.textContent = status.server_log_tail || "No server log output yet.";

  if (status.extension_status_url) {
    els.extensionStatusLink.href = status.extension_status_url;
    els.extensionStatusLink.classList.remove("hidden");
  } else {
    els.extensionStatusLink.href = "#";
    els.extensionStatusLink.classList.add("hidden");
  }
}

function renderCommandResult(result) {
  const sections = [
    `invoked: ${result.invoked || "-"}`,
    `exit_code: ${result.exit_code}`,
    `duration_ms: ${result.duration_ms}`,
  ];

  if (result.error) sections.push(`error:\n${result.error}`);
  if (result.stdout) sections.push(`stdout:\n${result.stdout.trim()}`);
  if (result.stderr) sections.push(`stderr:\n${result.stderr.trim()}`);

  els.commandOutput.textContent = sections.join("\n\n");
  setCommandState(result.ok ? "ok" : "error", result.ok ? "success" : "failed");
}

function setCommandState(kind, label) {
  els.lastCommandLabel.textContent = label;
  els.lastCommandLabel.classList.toggle("error", kind === "error");
}

document.getElementById("refreshStatus").addEventListener("click", () => {
  void fetchStatus();
});

document.getElementById("buildServer").addEventListener("click", () => {
  void runAction({ action: "build" });
});

document.getElementById("connectButton").addEventListener("click", () => {
  void runAction({
    action: "connect",
    extension_id: els.connectExtensionId.value.trim(),
  });
});

document.getElementById("openButton").addEventListener("click", () => {
  void runAction({
    action: "open",
    value: els.openUrl.value.trim(),
  });
});

document.getElementById("evalButton").addEventListener("click", () => {
  void runAction({
    action: "eval",
    value: els.evalExpression.value,
  });
});

document.getElementById("customRunButton").addEventListener("click", () => {
  void runAction({
    action: "custom",
    command: els.customCommand.value,
  });
});

document.querySelectorAll(".quick-action").forEach((button) => {
  button.addEventListener("click", () => {
    void runAction({ action: button.dataset.action });
  });
});

void fetchStatus();
