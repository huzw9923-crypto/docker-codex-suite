"use strict";

const fs = require("fs");
const path = require("path");
const {
  buildModelObserverCompatibilityExpression,
} = require("./docker-codex-renderer-model-compat.js");

const BASE_DIR = __dirname;
let settings = {};
try {
  settings = JSON.parse(fs.readFileSync(path.join(BASE_DIR, "settings.json"), "utf8"));
} catch {
  settings = {};
}

const DEFAULT_HOST_ID = settings.remoteHostId || "remote-ssh-discovered:docker-codex-suite";
const DEFAULT_SSH_HOST = settings.sshHost || "127.0.0.1";
const DEFAULT_SSH_PORT = Number(settings.sshPort) || 2223;
const DEFAULT_DEBUG_URL = `http://127.0.0.1:${Number(settings.debugPort) || 9229}`;
const DATA_DIR = path.resolve(BASE_DIR, settings.dataDir || "data");
const LOG_PATH = path.join(DATA_DIR, "reconnect.log");

function parseArgs(argv) {
  const result = {
    hostId: DEFAULT_HOST_ID,
    sshHost: DEFAULT_SSH_HOST,
    sshPort: DEFAULT_SSH_PORT,
    debugUrl: DEFAULT_DEBUG_URL,
    timeoutMs: 90000,
    checkOnly: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    const value = argv[index + 1];
    if (name === "--host-id" && value) {
      result.hostId = value;
      index += 1;
    } else if (name === "--ssh-host" && value) {
      result.sshHost = value;
      index += 1;
    } else if (name === "--ssh-port" && value) {
      result.sshPort = Math.max(1, Number(value) || result.sshPort);
      index += 1;
    } else if (name === "--debug-url" && value) {
      result.debugUrl = value.replace(/\/$/, "");
      index += 1;
    } else if (name === "--timeout-ms" && value) {
      result.timeoutMs = Math.max(5000, Number(value) || result.timeoutMs);
      index += 1;
    } else if (name === "--check-only") {
      result.checkOnly = true;
    }
  }

  return result;
}

function log(event, detail = {}) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const line = `${new Date().toISOString()} ${event} ${JSON.stringify(detail)}\n`;
  fs.appendFileSync(LOG_PATH, line, "utf8");
}

function writeResult(payload, exitCode = 0) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  process.exitCode = exitCode;
}

function createUnavailableError(message, detail = {}) {
  const error = new Error(message);
  error.code = "UNAVAILABLE";
  Object.assign(error, detail);
  return error;
}

function getConnectionHostId(connection) {
  return String(connection?.hostId || connection?.id || "").trim();
}

function getConnectionHost(connection) {
  return String(
    connection?.sshHost ||
      connection?.sshHostName ||
      connection?.hostname ||
      connection?.hostName ||
      connection?.address ||
      connection?.host ||
      "",
  ).trim();
}

function getConnectionPort(connection) {
  const value =
    connection?.sshPort ?? connection?.port ?? connection?.hostPort ?? connection?.remotePort;
  const port = Number(value);
  return Number.isFinite(port) ? port : 0;
}

function normalizeHost(host) {
  return String(host || "")
    .trim()
    .toLowerCase()
    .replace(/^\[|\]$/g, "")
    .replace(/\.$/, "");
}

function isLoopbackHost(host) {
  const normalized = normalizeHost(host);
  return normalized === "127.0.0.1" || normalized === "localhost" || normalized === "::1";
}

function hostsMatch(left, right) {
  const normalizedLeft = normalizeHost(left);
  const normalizedRight = normalizeHost(right);
  if (!normalizedLeft || !normalizedRight) return false;
  if (isLoopbackHost(normalizedLeft) && isLoopbackHost(normalizedRight)) return true;
  return normalizedLeft === normalizedRight;
}

function isAutoConnectEnabled(connection) {
  return connection?.autoConnect === true || String(connection?.autoConnect).toLowerCase() === "true";
}

function extractRemoteConnections(snapshot) {
  const found = [];
  const visited = new WeakSet();

  function visit(value, depth) {
    if (!value || typeof value !== "object" || depth > 4 || visited.has(value)) return;
    visited.add(value);

    if (Array.isArray(value)) {
      for (const item of value) visit(item, depth + 1);
      return;
    }

    if (getConnectionHostId(value)) {
      found.push(value);
      return;
    }

    for (const key of ["connections", "items", "value", "remoteConnections"]) {
      if (Object.prototype.hasOwnProperty.call(value, key)) {
        visit(value[key], depth + 1);
      }
    }

    if (depth === 0 && found.length === 0) {
      for (const item of Object.values(value)) visit(item, depth + 1);
    }
  }

  visit(snapshot, 0);

  const byHostId = new Map();
  for (const connection of found) {
    const hostId = getConnectionHostId(connection);
    if (!byHostId.has(hostId)) byHostId.set(hostId, connection);
  }
  return [...byHostId.values()];
}

function resolveRemoteHost(snapshot, configuredHostId, sshHost, sshPort) {
  const connections = extractRemoteConnections(snapshot);
  const exact = connections.find(
    (connection) => getConnectionHostId(connection) === String(configuredHostId || "").trim(),
  );
  if (exact) {
    return {
      connection: exact,
      hostId: getConnectionHostId(exact),
      hostResolution: "configured-host-id",
    };
  }

  const endpointMatches = connections.filter(
    (connection) =>
      hostsMatch(getConnectionHost(connection), sshHost) &&
      getConnectionPort(connection) === Number(sshPort),
  );

  if (endpointMatches.length === 1) {
    return {
      connection: endpointMatches[0],
      hostId: getConnectionHostId(endpointMatches[0]),
      hostResolution: "unique-ssh-endpoint",
    };
  }

  if (endpointMatches.length > 1) {
    const autoConnectMatches = endpointMatches.filter(isAutoConnectEnabled);
    if (autoConnectMatches.length === 1) {
      return {
        connection: autoConnectMatches[0],
        hostId: getConnectionHostId(autoConnectMatches[0]),
        hostResolution: "auto-connect-ssh-endpoint",
      };
    }

    throw createUnavailableError(
      `Multiple Codex SSH connections match ${sshHost}:${sshPort}; automatic selection was refused`,
      {
        configuredHostId,
        hostId: null,
        hostResolution: "ambiguous-ssh-endpoint",
        resolutionCode: "AMBIGUOUS",
      },
    );
  }

  throw createUnavailableError(
    `Codex has no registered SSH connection for ${sshHost}:${sshPort}`,
    {
      configuredHostId,
      hostId: null,
      hostResolution: "no-matching-ssh-endpoint",
      resolutionCode: "NO_MATCH",
    },
  );
}

async function fetchJson(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json();
  } finally {
    clearTimeout(timer);
  }
}

function openWebSocket(url, timeoutMs) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error("DevTools WebSocket connection timed out"));
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
        reject(new Error("DevTools WebSocket connection failed"));
      },
      { once: true },
    );
  });
}

function createCdpClient(socket) {
  let nextId = 0;
  const pending = new Map();

  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    clearTimeout(entry.timer);
    entry.resolve(message);
  });

  socket.addEventListener("close", () => {
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error("DevTools WebSocket closed"));
    }
    pending.clear();
  });

  return {
    send(method, params, timeoutMs) {
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

async function findRendererPage(options) {
  let pages;
  try {
    pages = await fetchJson(`${options.debugUrl}/json`, 3000);
  } catch (error) {
    throw createUnavailableError(`Codex DevTools is unavailable: ${error.message}`);
  }

  const page = pages.find(
    (item) =>
      item.type === "page" &&
      item.webSocketDebuggerUrl &&
      item.url === "app://-/index.html",
  );
  if (!page) throw createUnavailableError("Codex main renderer was not found");
  return page;
}

async function withRendererClient(options, action) {
  const page = await findRendererPage(options);
  const socket = await openWebSocket(page.webSocketDebuggerUrl, 5000);
  try {
    return await action(createCdpClient(socket));
  } finally {
    socket.close();
  }
}

async function evaluateExpression(client, expression, timeoutMs) {
  const response = await client.send(
    "Runtime.evaluate",
    {
      expression,
      awaitPromise: true,
      returnByValue: true,
    },
    timeoutMs,
  );

  if (response.error) {
    throw new Error(response.error.message || "Runtime.evaluate failed");
  }
  if (response.result?.exceptionDetails) {
    const detail = response.result.exceptionDetails;
    throw new Error(detail.exception?.description || detail.text || "Codex renderer request failed");
  }
  return response.result?.result?.value;
}

function buildModelRefreshExpression(hostId) {
  return `
    (async () => {
      const anchors = [
        ...document.querySelectorAll('[data-codex-intelligence-trigger="true"]'),
        ...document.querySelectorAll('[data-app-action-sidebar-thread-row]'),
      ];
      if (anchors.length === 0) {
        return { status: "unavailable", message: "Codex React anchors were not found" };
      }

      const clients = [];
      const seenClients = new Set();
      const consider = (value) => {
        if (
          value &&
          typeof value === "object" &&
          typeof value.getQueryCache === "function" &&
          typeof value.invalidateQueries === "function" &&
          !seenClients.has(value)
        ) {
          seenClients.add(value);
          clients.push(value);
        }
      };

      for (const anchor of anchors) {
        const fiberKey = Object.keys(anchor).find((key) => key.startsWith("__reactFiber"));
        let fiber = fiberKey ? anchor[fiberKey] : null;
        for (let fiberIndex = 0; fiber && fiberIndex < 180; fiberIndex += 1, fiber = fiber.return) {
          const props = fiber.memoizedProps;
          consider(props);
          consider(props?.client);
          consider(props?.value);
          consider(props?.queryClient);

          let context = fiber.dependencies?.firstContext;
          for (
            let contextIndex = 0;
            context && contextIndex < 40;
            contextIndex += 1, context = context.next
          ) {
            consider(context.memoizedValue);
          }

          let hook = fiber.memoizedState;
          for (let hookIndex = 0; hook && hookIndex < 120; hookIndex += 1, hook = hook.next) {
            const value = hook.memoizedState;
            consider(value);
            if (Array.isArray(value)) consider(value[0]);
            consider(value?.client);
            consider(value?.value);
            consider(value?.queryClient);
          }
        }
        if (clients.length > 0) break;
      }

      if (clients.length === 0) {
        return { status: "unavailable", message: "Codex query client was not found" };
      }

      const matchesHostModelQuery = (query) =>
        query.queryKey?.[0] === "models" &&
        query.queryKey?.[1] === "list" &&
        query.queryKey?.[2] === ${JSON.stringify(hostId)};
      const getModelIds = (data) => {
        const models = Array.isArray(data?.data)
          ? data.data
          : Array.isArray(data?.models)
            ? data.models
            : [];
        return models
          .map((model) => model?.id || model?.model || model?.slug || null)
          .filter(Boolean);
      };

      const matchingQueries = clients.flatMap((client) =>
        client.getQueryCache().getAll().filter(matchesHostModelQuery),
      );
      if (matchingQueries.length === 0) {
        return { status: "not-cached", queryCount: 0, modelIds: [] };
      }

      const results = [];
      for (const query of matchingQueries) {
        try {
          const data = await query.fetch();
          results.push({ status: "success", modelIds: getModelIds(data) });
        } catch (error) {
          results.push({ status: "failed", message: String(error?.message || error) });
        }
      }
      const failed = results.filter((result) => result.status === "failed");
      if (failed.length > 0) {
        return {
          status: "failed",
          queryCount: matchingQueries.length,
          modelIds: [],
          message: failed.map((result) => result.message).join("; "),
        };
      }
      return {
        status: "refreshed",
        queryCount: matchingQueries.length,
        modelIds: [...new Set(results.flatMap((result) => result.modelIds))],
      };
    })()
  `;
}

async function refreshRendererModelQueries(options, hostId) {
  const value = await withRendererClient(options, (client) =>
    evaluateExpression(
      client,
      buildModelRefreshExpression(hostId),
      Math.min(options.timeoutMs, 15000),
    ),
  );
  if (!value || !value.status) {
    throw createUnavailableError("Codex model query refresh returned no result");
  }
  let compatibility = { status: "not-requested" };
  if (Array.isArray(value.modelIds) && value.modelIds.length > 0) {
    compatibility = await withRendererClient(options, (client) =>
      evaluateExpression(
        client,
        buildModelObserverCompatibilityExpression(value.modelIds),
        Math.min(options.timeoutMs, 15000),
      ),
    );
  }
  return {
    ...value,
    compatibilityStatus: compatibility?.status || "unavailable",
    compatibilityPatchedObservers: Number(compatibility?.patchedObserverCount) || 0,
    compatibilityVisibleModelIds: Array.isArray(compatibility?.visibleCatalogModelIds)
      ? compatibility.visibleCatalogModelIds
      : [],
  };
}

function buildRemoteRequestExpression(requestName, params) {
  const requestOptions = params === undefined ? undefined : { params };
  return `
    (async () => {
      const mainScriptUrl = Array.from(document.scripts, (script) => script.src)
        .find((url) => url && url.endsWith(".js"));
      if (!mainScriptUrl) {
        return { status: "unavailable", message: "Codex main script was not found" };
      }

      const mainSource = await (await fetch(mainScriptUrl)).text();
      const moduleMatch = mainSource.match(/vscode-api-[A-Za-z0-9_-]+\\.js/);
      if (!moduleMatch) {
        return { status: "unavailable", message: "Codex remote request module was not found" };
      }

      const requestModule = await import(new URL(moduleMatch[0], mainScriptUrl).href);
      if (typeof requestModule.n !== "function") {
        return { status: "unavailable", message: "Codex remote request helper was not found" };
      }

      setTimeout(() => {
        Promise.resolve(
          requestModule.n(${JSON.stringify(requestName)}, ${JSON.stringify(requestOptions)}),
        ).catch(() => {});
      }, 75);
      return { status: "scheduled" };
    })()
  `;
}

async function scheduleRemoteRequest(options, requestName, params) {
  const value = await withRendererClient(options, (client) =>
    evaluateExpression(
      client,
      buildRemoteRequestExpression(requestName, params),
      Math.min(options.timeoutMs, 10000),
    ),
  );
  if (!value || value.status !== "scheduled") {
    throw createUnavailableError(value?.message || `Codex request ${requestName} is unavailable`);
  }
  return true;
}

async function readRemoteConnections(options) {
  const value = await withRendererClient(options, (client) =>
    evaluateExpression(
      client,
      `
        (() => {
          const bridge = window.electronBridge;
          if (!bridge || typeof bridge.getSharedObjectSnapshotValue !== "function") {
            return { status: "unavailable", message: "Codex remote connection snapshot is unavailable" };
          }
          return {
            status: "available",
            connections: bridge.getSharedObjectSnapshotValue("remote_ssh_connections")
          };
        })()
      `,
      Math.min(options.timeoutMs, 10000),
    ),
  );
  if (!value || value.status !== "available") {
    throw createUnavailableError(value?.message || "Codex remote connection snapshot is unavailable");
  }
  return value.connections;
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function isTransientTransportError(error) {
  const message = String(error?.message || error || "");
  return (
    message.includes("AppServerTransportConnectError") ||
    message.includes("AppServerTransportError") ||
    /socket hang up/i.test(message) ||
    message.includes("ECONNRESET")
  );
}

async function withTransientRetry(options, action) {
  const maxAttempts = options.maxAttempts || 6;
  const baseDelayMs = options.baseDelayMs || 2000;
  const maxDelayMs = options.maxDelayMs || 15000;

  for (let attempt = 1; ; attempt += 1) {
    try {
      return await action();
    } catch (error) {
      if (!isTransientTransportError(error) || attempt >= maxAttempts) {
        throw error;
      }
      const waitMs = Math.min(baseDelayMs * attempt, maxDelayMs);
      if (require.main === module) {
        log("transport_retry", { attempt, waitMs, message: error.message });
      }
      await delay(waitMs);
    }
  }
}

async function resolveRegisteredHost(options) {
  let refreshRequested = false;
  let refreshMessage = "";
  try {
    refreshRequested = await scheduleRemoteRequest(options, "refresh-remote-connections");
  } catch (error) {
    refreshMessage = error.message;
  }

  const deadline = Date.now() + 5000;
  let lastError;
  await delay(250);
  do {
    try {
      const connections = await readRemoteConnections(options);
      const resolution = resolveRemoteHost(
        connections,
        options.hostId,
        options.sshHost,
        options.sshPort,
      );
      return { ...resolution, refreshRequested, refreshMessage };
    } catch (error) {
      lastError = error;
      if (error.resolutionCode === "AMBIGUOUS" || error.code !== "UNAVAILABLE") throw error;
    }
    if (Date.now() < deadline) await delay(350);
  } while (Date.now() < deadline);

  if (lastError) {
    lastError.refreshRequested = refreshRequested;
    lastError.refreshMessage = refreshMessage;
    throw lastError;
  }
  throw createUnavailableError("Codex remote connection could not be resolved");
}

async function restartRemoteCodex(options) {
  const resolved = await withTransientRetry({ maxAttempts: 6, baseDelayMs: 2000 }, () =>
    resolveRegisteredHost(options),
  );
  const metadata = {
    configuredHostId: options.hostId,
    hostId: resolved.hostId,
    hostResolution: resolved.hostResolution,
    refreshRequested: resolved.refreshRequested,
  };

  if (options.checkOnly) return { status: "available", ...metadata };

  let autoConnectRequested = false;
  if (!isAutoConnectEnabled(resolved.connection)) {
    autoConnectRequested = await scheduleRemoteRequest(
      options,
      "set-remote-connection-auto-connect",
      { hostId: resolved.hostId, autoConnect: true },
    );
    await delay(250);
  }

  try {
    const value = await withTransientRetry({ maxAttempts: 4, baseDelayMs: 3000 }, async () =>
      withRendererClient(options, (client) =>
        evaluateExpression(
          client,
          `
          (async () => {
            const bridge = window.electronBridge;
            if (!bridge || typeof bridge.sendMessageFromView !== "function") {
              return { status: "unavailable", message: "electronBridge is unavailable" };
            }
            await bridge.sendMessageFromView({
              type: "codex-app-server-restart",
              hostId: ${JSON.stringify(resolved.hostId)},
              killCodexProcess: true
            });
            return { status: "connected" };
          })()
        `,
          options.timeoutMs,
        ),
      ),
    );

    if (!value || value.status !== "connected") {
      throw createUnavailableError(value?.message || "Codex restart bridge is unavailable");
    }
    await delay(350);
    let modelRefresh;
    try {
      modelRefresh = await refreshRendererModelQueries(options, resolved.hostId);
    } catch (error) {
      modelRefresh = { status: "unavailable", message: error.message };
    }
    return {
      status: "connected",
      ...metadata,
      autoConnectRequested,
      modelRefreshStatus: modelRefresh.status,
      modelRefreshQueryCount: Number(modelRefresh.queryCount) || 0,
      modelRefreshModelIds: Array.isArray(modelRefresh.modelIds) ? modelRefresh.modelIds : [],
      modelRefreshMessage: modelRefresh.message || "",
      modelCompatibilityStatus: modelRefresh.compatibilityStatus || "not-requested",
      modelCompatibilityPatchedObservers:
        Number(modelRefresh.compatibilityPatchedObservers) || 0,
      modelCompatibilityVisibleIds: Array.isArray(modelRefresh.compatibilityVisibleModelIds)
        ? modelRefresh.compatibilityVisibleModelIds
        : [],
    };
  } catch (error) {
    if (/Connection for host ID .* not found/i.test(error.message)) {
      throw createUnavailableError(error.message, metadata);
    }
    throw error;
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const startedAt = Date.now();
  log(options.checkOnly ? "availability_check_requested" : "restart_requested", {
    configuredHostId: options.hostId,
    sshHost: options.sshHost,
    sshPort: options.sshPort,
  });

  try {
    const result = await restartRemoteCodex(options);
    const payload = { ...result, durationMs: Date.now() - startedAt };
    log(options.checkOnly ? "availability_check_succeeded" : "restart_connected", payload);
    writeResult(payload);
  } catch (error) {
    const status =
      error.code === "UNAVAILABLE" || isTransientTransportError(error)
        ? "unavailable"
        : "failed";
    const payload = {
      status,
      configuredHostId: options.hostId,
      hostId: error.hostId || null,
      hostResolution: error.hostResolution || "unresolved",
      message: error.message,
      durationMs: Date.now() - startedAt,
    };
    log("restart_failed", payload);
    writeResult(payload, status === "unavailable" ? 2 : 3);
  }
}

module.exports = {
  buildModelRefreshExpression,
  extractRemoteConnections,
  hostsMatch,
  isTransientTransportError,
  parseArgs,
  refreshRendererModelQueries,
  resolveRemoteHost,
  restartRemoteCodex,
  withTransientRetry,
};

if (require.main === module) {
  main();
}
