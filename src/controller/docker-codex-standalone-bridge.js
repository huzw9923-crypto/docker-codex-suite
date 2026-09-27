"use strict";

const fs = require("fs");
const http = require("http");
const path = require("path");
const { spawn } = require("child_process");
const { createChatProxyServer } = require("./docker-codex-chat-proxy.js");
const {
  buildModelObserverCompatibilityExpression,
  normalizeModelIds,
} = require("./docker-codex-renderer-model-compat.js");

const BASE_DIR = __dirname;
const SETTINGS_PATH = path.join(BASE_DIR, "settings.json");
const SYSTEM_ROOT = process.env.SystemRoot || "C:\\Windows";
const POWERSHELL_PATH = path.join(
  SYSTEM_ROOT,
  "System32",
  "WindowsPowerShell",
  "v1.0",
  "powershell.exe",
);
const POWERSHELL = fs.existsSync(POWERSHELL_PATH) ? POWERSHELL_PATH : "powershell.exe";

function loadSettings() {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS_PATH, "utf8"));
  } catch {
    return {};
  }
}

function resolveConfiguredPath(value, fallback) {
  const selected = typeof value === "string" && value.trim() ? value.trim() : fallback;
  const expanded = selected.replace(/%([^%]+)%/g, (_, name) => process.env[name] || `%${name}%`);
  return path.resolve(BASE_DIR, expanded);
}

const settings = loadSettings();
const HOST = "127.0.0.1";
const HEALTH_PORT = Math.max(1, Number(settings.bridgePort) || 38118);
const CHAT_PROXY_PORT = Math.max(1, Number(settings.chatProxyPort) || 38119);
const DEBUG_PORT = Math.max(1, Number(settings.debugPort) || 9229);
const DEBUG_URL = process.env.CODEX_DEBUG_URL || `http://127.0.0.1:${DEBUG_PORT}`;
const MENU_VERSION = "1.3.0";
const COMMAND_MARKER = "__DOCKER_CODEX_STANDALONE_ACTION__";
const BRIDGE_SESSION = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
const PROTOCOL_SCRIPT = path.join(BASE_DIR, "docker-codex-api-switch-protocol.ps1");
const DATA_DIR = resolveConfiguredPath(settings.dataDir, "data");
const LOG_PATH = path.join(DATA_DIR, "bridge.log");
const CHAT_PROXY_CONFIG_PATH = resolveConfiguredPath(
  settings.chatProxyConfigPath,
  path.join(DATA_DIR, "chat-proxy.json"),
);
const COMPOSE_DIR = resolveConfiguredPath(
  settings.composeDir,
  path.join(process.env.USERPROFILE || BASE_DIR, "DockerCodex"),
);
const MODEL_CATALOG_PATH = path.join(COMPOSE_DIR, "codex-home", "model-catalog.docker-api.json");

fs.mkdirSync(DATA_DIR, { recursive: true });

const ACTION_URIS = {
  gui: "docker-codex-switch://gui",
  status: "docker-codex-switch://status",
  reconnect: "docker-codex-switch://reconnect",
  host: "docker-codex-switch://use-host",
  docker: "docker-codex-switch://use-docker",
  update: "docker-codex-switch://check-update",
};

const runtime = {
  status: "starting",
  cdp: "waiting",
  menu: "pending",
  targetId: "",
  chatProxy: "starting",
  lastConnectedAt: "",
  lastInjectedAt: "",
  lastAction: "",
  lastError: "",
  modelCompatibility: "pending",
  modelCatalogModelCount: 0,
};

const processedNonces = new Set();

function claimNonce(nonce) {
  if (processedNonces.has(nonce)) return false;
  processedNonces.add(nonce);
  if (processedNonces.size > 500) {
    processedNonces.delete(processedNonces.values().next().value);
  }
  return true;
}

function log(event, detail = {}) {
  const line = `${new Date().toISOString()} ${event} ${JSON.stringify(detail)}\n`;
  try {
    fs.appendFileSync(LOG_PATH, line, "utf8");
  } catch {
    // Logging must never break the bridge.
  }
}

function sendJson(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

function loadCatalogModelIds() {
  try {
    const catalog = JSON.parse(fs.readFileSync(MODEL_CATALOG_PATH, "utf8"));
    return normalizeModelIds(
      (Array.isArray(catalog?.models) ? catalog.models : []).map(
        (model) => model?.slug || model?.model || model?.id,
      ),
    );
  } catch {
    return [];
  }
}

function readJsonBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 16384) {
        reject(new Error("request body is too large"));
        request.destroy();
      }
    });
    request.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function launchAction(action, source = "menu") {
  const uri = ACTION_URIS[action];
  if (!uri) throw new Error(`unknown action: ${action}`);
  if (!fs.existsSync(PROTOCOL_SCRIPT)) {
    throw new Error(`missing protocol handler: ${PROTOCOL_SCRIPT}`);
  }

  const child = spawn(
    POWERSHELL,
    [
      "-NoProfile",
      "-NoLogo",
      "-NonInteractive",
      "-WindowStyle",
      "Hidden",
      "-Sta",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      PROTOCOL_SCRIPT,
      "-Uri",
      uri,
    ],
    {
      cwd: BASE_DIR,
      detached: false,
      stdio: "ignore",
      windowsHide: true,
    },
  );
  runtime.lastAction = action;
  child.on("error", (error) => {
    runtime.lastError = error.message;
    log("action_child_error", { action, source, message: error.message });
  });
  child.on("exit", (code, signal) => {
    log("action_child_exit", { action, source, code, signal });
  });
  log("action_launched", { action, source, uri, pid: child.pid });
  return child.pid;
}

async function fetchJson(url, timeoutMs = 2000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function openCdpSocket(url, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error("CDP WebSocket connection timed out"));
    }, timeoutMs);
    socket.addEventListener(
      "open",
      () => {
        clearTimeout(timer);
        resolve(socket);
      },
      { once: true },
    );
    socket.addEventListener(
      "error",
      () => {
        clearTimeout(timer);
        reject(new Error("CDP WebSocket connection failed"));
      },
      { once: true },
    );
  });
}

function createCdpClient(socket, onEvent) {
  let nextId = 0;
  const pending = new Map();

  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (message.id) {
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error) {
        entry.reject(new Error(message.error.message || "CDP request failed"));
      } else {
        entry.resolve(message.result || {});
      }
      return;
    }
    onEvent(message.method, message.params || {});
  });

  socket.addEventListener("close", () => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("CDP WebSocket closed"));
    }
    pending.clear();
  });

  return {
    send(method, params = {}, timeoutMs = 5000) {
      return new Promise((resolve, reject) => {
        const id = ++nextId;
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`${method} timed out`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params }));
      });
    },
  };
}

function installMenu(commandMarker, version, session) {
  const current = window.__dockerCodexStandaloneMenuState;
  if (
    current &&
    current.version === version &&
    current.session === session &&
    !current.disposed &&
    current.trigger?.isConnected
  ) {
    return { status: "ready", version, placement: current.placement };
  }
  if (current && typeof current.dispose === "function") {
    current.dispose();
  }

  const legacy = window.__dockerCodexApiLauncherState;
  if (legacy && typeof legacy.dispose === "function" && !legacy.disposed) {
    legacy.dispose();
  }

  document
    .querySelectorAll(
      '[data-docker-api-trigger="true"], #docker-codex-api-launcher-menu, #docker-codex-standalone-style',
    )
    .forEach((element) => element.remove());

  const isVisible = (element) => {
    const rect = element.getBoundingClientRect();
    const style = getComputedStyle(element);
    return (
      rect.width > 0 &&
      rect.height > 0 &&
      rect.top < 48 &&
      style.display !== "none" &&
      style.visibility !== "hidden"
    );
  };
  const nativeLabelGroups = [
    ["文件", "编辑", "视图", "帮助"],
    ["File", "Edit", "View", "Help"],
  ];
  let menuRow = null;
  let menuButtons = [];
  for (const labels of nativeLabelGroups) {
    const labelSet = new Set(labels);
    const nativeButtons = [...document.querySelectorAll("button")].filter(
      (button) => labelSet.has(String(button.textContent || "").trim()) && isVisible(button),
    );
    const grouped = new Map();
    for (const button of nativeButtons) {
      if (!button.parentElement) continue;
      const items = grouped.get(button.parentElement) || [];
      items.push(button);
      grouped.set(button.parentElement, items);
    }
    const match = [...grouped.entries()].sort((left, right) => right[1].length - left[1].length)[0];
    if (!match || match[1].length < 3) continue;
    [menuRow, menuButtons] = match;
    break;
  }
  if (!menuRow) {
    return { status: "waiting", version, message: "native menu row was not found" };
  }

  const reference =
    menuButtons.find((button) =>
      ["帮助", "Help"].includes(String(button.textContent || "").trim()),
    ) || menuButtons[menuButtons.length - 1];
  const trigger = document.createElement("button");
  trigger.type = "button";
  trigger.className = reference.className;
  trigger.textContent = "Docker API";
  trigger.dataset.dockerApiTrigger = "true";
  trigger.dataset.placement = "menu-bar";
  trigger.setAttribute("aria-haspopup", "menu");
  trigger.setAttribute("aria-expanded", "false");
  trigger.title = "Docker Codex API 独立切换器";

  const style = document.createElement("style");
  style.id = "docker-codex-standalone-style";
  style.textContent = `
    #docker-codex-api-launcher-menu {
      position: fixed;
      display: none;
      width: 210px;
      box-sizing: border-box;
      padding: 6px;
      z-index: 2147483647;
      color-scheme: light dark;
      color: CanvasText;
      background: Canvas;
      border: 0;
      border-radius: 10px;
      box-shadow: 0 10px 28px rgb(0 0 0 / 18%), 0 2px 6px rgb(0 0 0 / 10%);
      -webkit-app-region: no-drag;
      app-region: no-drag;
      pointer-events: auto;
      font: 12px/1.35 ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    }
    #docker-codex-api-launcher-menu[data-open="true"] { display: block; }
    #docker-codex-api-launcher-menu .docker-api-action {
      display: block;
      width: 100%;
      min-height: 34px;
      box-sizing: border-box;
      padding: 8px 10px;
      color: inherit;
      background: transparent;
      border: 0;
      border-radius: 7px;
      outline: 0;
      text-align: left;
      font: inherit;
      -webkit-app-region: no-drag;
      app-region: no-drag;
      pointer-events: auto;
      touch-action: manipulation;
      user-select: none;
      cursor: pointer;
    }
    #docker-codex-api-launcher-menu .docker-api-action:hover,
    #docker-codex-api-launcher-menu .docker-api-action:focus-visible {
      background: color-mix(in srgb, CanvasText 9%, transparent);
    }
  `;
  document.head.appendChild(style);

  const panel = document.createElement("div");
  panel.id = "docker-codex-api-launcher-menu";
  panel.className = "docker-api-menu-panel";
  panel.setAttribute("role", "menu");
  panel.setAttribute("aria-label", "Docker API");

  const actions = [
    ["打开完整切换器", "gui"],
    ["查看状态窗口", "status"],
    ["立即重连 Docker Codex", "reconnect"],
    ["切换为主空间 API", "host"],
    ["切换为 Docker API", "docker"],
    ["检查更新", "update"],
  ];
  const dispatchAction = (action) => {
    closeMenu();
    const nonce = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const command = { action, nonce, source: "renderer-menu", session };
    console.info(`${commandMarker}${JSON.stringify(command)}`);
  };
  for (const [label, action] of actions) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "docker-api-action";
    button.setAttribute("role", "menuitem");
    button.textContent = label;
    let lastPointerActivation = 0;
    button.addEventListener("pointerup", (event) => {
      if (event.button !== 0 || event.isPrimary === false) return;
      event.preventDefault();
      event.stopPropagation();
      lastPointerActivation = performance.now();
      dispatchAction(action);
    });
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.detail > 0 && performance.now() - lastPointerActivation < 1000) return;
      dispatchAction(action);
    });
    panel.appendChild(button);
  }

  let open = false;
  const positionPanel = () => {
    const rect = trigger.getBoundingClientRect();
    const width = 210;
    const left = Math.max(8, Math.min(rect.left + 6, window.innerWidth - width - 8));
    panel.style.left = `${left}px`;
    panel.style.top = `${Math.max(8, rect.bottom + 6)}px`;
  };
  const closeMenu = () => {
    if (!open) return;
    open = false;
    panel.dataset.open = "false";
    trigger.setAttribute("aria-expanded", "false");
  };
  const openMenu = () => {
    positionPanel();
    open = true;
    panel.dataset.open = "true";
    trigger.setAttribute("aria-expanded", "true");
  };
  const onDocumentPointerDown = (event) => {
    if (!open) return;
    if (panel.contains(event.target) || trigger.contains(event.target)) return;
    closeMenu();
  };
  const onDocumentKeyDown = (event) => {
    if (event.key === "Escape") closeMenu();
  };
  const onWindowBlur = () => closeMenu();
  const onWindowLayout = () => closeMenu();

  trigger.addEventListener("click", (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (open) closeMenu();
    else openMenu();
  });
  document.addEventListener("pointerdown", onDocumentPointerDown, true);
  document.addEventListener("keydown", onDocumentKeyDown, true);
  window.addEventListener("blur", onWindowBlur);
  window.addEventListener("resize", onWindowLayout);
  window.addEventListener("scroll", onWindowLayout, true);

  menuRow.appendChild(trigger);
  document.body.appendChild(panel);

  const state = {
    version,
    session,
    disposed: false,
    placement: "menu-bar",
    trigger,
    dispose() {
      if (state.disposed) return;
      state.disposed = true;
      document.removeEventListener("pointerdown", onDocumentPointerDown, true);
      document.removeEventListener("keydown", onDocumentKeyDown, true);
      window.removeEventListener("blur", onWindowBlur);
      window.removeEventListener("resize", onWindowLayout);
      window.removeEventListener("scroll", onWindowLayout, true);
      trigger.remove();
      panel.remove();
      style.remove();
    },
  };
  window.__dockerCodexStandaloneMenuState = state;
  return { status: "installed", version, placement: state.placement };
}

const MENU_EXPRESSION = `(${installMenu.toString()})(${JSON.stringify(COMMAND_MARKER)}, ${JSON.stringify(MENU_VERSION)}, ${JSON.stringify(BRIDGE_SESSION)})`;

function processConsoleEvent(params) {
  for (const argument of params.args || []) {
    const value = argument.value;
    if (typeof value !== "string" || !value.startsWith(COMMAND_MARKER)) continue;
    let command;
    try {
      command = JSON.parse(value.slice(COMMAND_MARKER.length));
    } catch (error) {
      log("command_parse_failed", { message: error.message });
      continue;
    }
    const action = String(command.action || "");
    const nonce = String(command.nonce || `${Date.now()}:${action}`);
    if (action !== "probe" && command.session !== BRIDGE_SESSION) {
      log("command_session_ignored", { action, nonce });
      continue;
    }
    if ((action !== "probe" && !ACTION_URIS[action]) || !claimNonce(nonce)) continue;
    if (action === "probe") {
      runtime.lastAction = "probe";
      log("command_probe_received", { nonce });
      continue;
    }
    try {
      launchAction(action, "cdp-menu");
    } catch (error) {
      runtime.lastError = error.message;
      log("command_failed", { action, message: error.message });
    }
  }
}

async function findCodexTarget() {
  const targets = await fetchJson(`${DEBUG_URL}/json`);
  return targets.find(
    (target) =>
      target.type === "page" &&
      target.url === "app://-/index.html" &&
      target.webSocketDebuggerUrl,
  );
}

async function injectMenu(client) {
  const catalogModelIds = loadCatalogModelIds();
  runtime.modelCatalogModelCount = catalogModelIds.length;
  try {
    const compatibilityResult = await client.send(
      "Runtime.evaluate",
      {
        expression: buildModelObserverCompatibilityExpression(catalogModelIds),
        returnByValue: true,
        awaitPromise: true,
      },
      8000,
    );
    if (compatibilityResult.exceptionDetails) {
      throw new Error(
        compatibilityResult.exceptionDetails.exception?.description ||
          compatibilityResult.exceptionDetails.text ||
          "model compatibility injection failed",
      );
    }
    const compatibility = compatibilityResult.result?.value || {};
    runtime.modelCompatibility = compatibility.status || "unknown";
  } catch (error) {
    runtime.modelCompatibility = "failed";
  }

  const result = await client.send(
    "Runtime.evaluate",
    { expression: MENU_EXPRESSION, returnByValue: true, awaitPromise: true },
    8000,
  );
  if (result.exceptionDetails) {
    throw new Error(
      result.exceptionDetails.exception?.description ||
        result.exceptionDetails.text ||
        "menu injection failed",
    );
  }
  const value = result.result?.value || {};
  runtime.menu = value.status || "unknown";
  runtime.lastInjectedAt = new Date().toISOString();
  if (value.status === "installed") log("menu_installed", value);
  return value;
}

async function runCdpSession(target) {
  const socket = await openCdpSocket(target.webSocketDebuggerUrl);
  runtime.cdp = "connected";
  runtime.status = "running";
  runtime.targetId = target.id;
  runtime.lastConnectedAt = new Date().toISOString();
  runtime.lastError = "";
  log("cdp_connected", { targetId: target.id, url: target.url });

  const client = createCdpClient(socket, (method, params) => {
    if (method === "Runtime.consoleAPICalled") processConsoleEvent(params);
    if (method === "Runtime.executionContextCreated") {
      setTimeout(() => injectMenu(client).catch(() => {}), 500);
    }
  });
  await client.send("Runtime.enable");
  await injectMenu(client);

  const timer = setInterval(() => {
    injectMenu(client).catch((error) => {
      runtime.lastError = error.message;
    });
  }, 2000);

  await new Promise((resolve) => {
    socket.addEventListener("close", resolve, { once: true });
    socket.addEventListener("error", resolve, { once: true });
  });
  clearInterval(timer);
  runtime.cdp = "disconnected";
  runtime.menu = "pending";
  runtime.targetId = "";
  log("cdp_disconnected");
}

async function runCdpLoop() {
  let lastWaitingError = "";
  while (true) {
    try {
      const target = await findCodexTarget();
      if (!target) throw new Error("Codex renderer target is not available");
      lastWaitingError = "";
      await runCdpSession(target);
    } catch (error) {
      runtime.status = "waiting";
      runtime.cdp = "waiting";
      runtime.lastError = error.message;
      if (error.message !== lastWaitingError) {
        lastWaitingError = error.message;
        log("cdp_waiting", { message: error.message });
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
}

function createHealthServer() {
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", `http://${HOST}:${HEALTH_PORT}`);
      if (request.method === "GET" && url.pathname === "/health") {
        sendJson(response, 200, {
          service: "docker-codex-standalone",
          version: MENU_VERSION,
          pid: process.pid,
          installDir: BASE_DIR,
          ...runtime,
        });
        return;
      }
      if (request.method === "POST" && url.pathname === "/action") {
        const body = await readJsonBody(request);
        const action = String(body.action || "");
        const nonce = String(body.nonce || `${Date.now()}:${action}:http`);
        if (!ACTION_URIS[action]) throw new Error(`unknown action: ${action}`);
        const source = body.source === "renderer-menu" ? "renderer-menu" : "http-test";
        if (source === "renderer-menu" && body.session !== BRIDGE_SESSION) {
          sendJson(response, 409, { status: "stale-session", action });
          return;
        }
        if (!claimNonce(nonce)) {
          sendJson(response, 200, { status: "duplicate", action });
          return;
        }
        const pid = launchAction(action, source);
        sendJson(response, 200, { status: "ok", action, pid });
        return;
      }
      sendJson(response, 404, { status: "failed", message: "not found" });
    } catch (error) {
      sendJson(response, 500, { status: "failed", message: error.message });
    }
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(HEALTH_PORT, HOST, () => resolve(server));
  });
}

async function main() {
  try {
    await createHealthServer();
  } catch (error) {
    if (error.code === "EADDRINUSE") {
      try {
        const health = await fetchJson(`http://${HOST}:${HEALTH_PORT}/health`);
        if (health.service === "docker-codex-standalone") process.exit(0);
      } catch {
        // Report the original port conflict below.
      }
    }
    throw error;
  }
  try {
    await createChatProxyServer({
      host: HOST,
      port: CHAT_PROXY_PORT,
      configPath: CHAT_PROXY_CONFIG_PATH,
      onEvent: log,
    });
    runtime.chatProxy = "ready";
  } catch (error) {
    runtime.chatProxy = "unavailable";
    log("chat_proxy_unavailable", { port: CHAT_PROXY_PORT, message: error.message });
  }
  log("bridge_started", {
    pid: process.pid,
    debugUrl: DEBUG_URL,
    port: HEALTH_PORT,
    chatProxyPort: CHAT_PROXY_PORT,
  });
  await runCdpLoop();
}

module.exports = {
  installMenu,
};

if (require.main === module) {
  main().catch((error) => {
    runtime.status = "failed";
    runtime.lastError = error.message;
    log("bridge_failed", { message: error.message, stack: error.stack });
    process.stderr.write(`${error.stack || error.message}\n`);
    process.exitCode = 1;
  });
}
