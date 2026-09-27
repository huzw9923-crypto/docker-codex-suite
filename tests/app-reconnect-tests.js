"use strict";

const assert = require("assert");
const vm = require("vm");
const {
  buildModelRefreshExpression,
  extractRemoteConnections,
  hostsMatch,
  isTransientTransportError,
  parseArgs,
  resolveRemoteHost,
  withTransientRetry,
} = require("../src/controller/docker-codex-app-reconnect.js");
const {
  buildModelObserverCompatibilityExpression,
  normalizeModelIds,
} = require("../src/controller/docker-codex-renderer-model-compat.js");

function connection(hostId, options = {}) {
  return {
    hostId,
    displayName: hostId.split(":").pop(),
    autoConnect: options.autoConnect ?? false,
    sshHost: options.sshHost || "127.0.0.1",
    sshPort: options.sshPort || 2223,
  };
}

function expectUnavailable(run, resolutionCode) {
  assert.throws(run, (error) => {
    assert.strictEqual(error.code, "UNAVAILABLE");
    assert.strictEqual(error.resolutionCode, resolutionCode);
    return true;
  });
}

async function testModelQueryRefresh() {
  const hostId = "remote-ssh-discovered:codex-docker-d";
  let remoteFetches = 0;
  let localFetches = 0;
  const remoteQuery = {
    queryKey: ["models", "list", hostId, "apikey", 100],
    async fetch() {
      remoteFetches += 1;
      return {
        data: [
          { id: "deepseek-v4-pro" },
          { id: "deepseek-v4-flash" },
        ],
        nextCursor: null,
      };
    },
  };
  const localQuery = {
    queryKey: ["models", "list", "local", "apikey", 100],
    async fetch() {
      localFetches += 1;
      return { data: [{ id: "gpt-local" }] };
    },
  };
  const queryClient = {
    getQueryCache() {
      return { getAll: () => [localQuery, remoteQuery] };
    },
    invalidateQueries() {},
  };
  const anchor = {};
  anchor["__reactFiber$test"] = {
    memoizedProps: {},
    memoizedState: null,
    dependencies: {
      firstContext: { memoizedValue: queryClient, next: null },
    },
    return: null,
  };
  const document = {
    querySelectorAll(selector) {
      return selector.includes("data-codex-intelligence-trigger") ? [anchor] : [];
    },
  };

  const result = await vm.runInNewContext(buildModelRefreshExpression(hostId), { document });
  assert.strictEqual(result.status, "refreshed");
  assert.strictEqual(result.queryCount, 1);
  assert.deepStrictEqual(Array.from(result.modelIds), ["deepseek-v4-pro", "deepseek-v4-flash"]);
  assert.strictEqual(remoteFetches, 1);
  assert.strictEqual(localFetches, 0);
}

async function testModelObserverCompatibility() {
  const hostId = "remote-ssh-discovered:codex-docker-d";
  const rawData = {
    data: [
      { id: "deepseek-v4-pro", model: "deepseek-v4-pro", hidden: false, isDefault: true },
      { id: "deepseek-v4-flash", model: "deepseek-v4-flash", hidden: false, isDefault: false },
    ],
    nextCursor: null,
  };
  let query;
  let currentResult = { data: { models: [], defaultModel: null } };
  const observer = {
    options: {
      select() {
        return { models: [], defaultModel: null };
      },
    },
    getCurrentResult() {
      return currentResult;
    },
    setOptions(options) {
      this.options = options;
      currentResult = { data: options.select(query.state.data) };
    },
  };
  query = {
    queryKey: ["models", "list", hostId, "apikey", 100],
    state: { data: rawData },
    observers: [observer],
    setData(data) {
      this.state.data = data;
      currentResult = { data: observer.options.select(data) };
    },
  };
  const queryClient = {
    getQueryCache() {
      return { getAll: () => [query] };
    },
    invalidateQueries() {},
  };
  const anchor = {};
  anchor["__reactFiber$test"] = {
    memoizedProps: {},
    memoizedState: null,
    dependencies: { firstContext: { memoizedValue: queryClient, next: null } },
    return: null,
  };
  const document = { querySelectorAll: () => [anchor] };

  assert.deepStrictEqual(normalizeModelIds([" a ", "a", "", null]), ["a"]);
  const installed = await vm.runInNewContext(
    buildModelObserverCompatibilityExpression(["deepseek-v4-pro", "deepseek-v4-flash"]),
    { document },
  );
  assert.strictEqual(installed.status, "ready");
  assert.strictEqual(installed.patchedObserverCount, 1);
  assert.deepStrictEqual(
    Array.from(currentResult.data.models, (model) => model.model),
    ["deepseek-v4-pro", "deepseek-v4-flash"],
  );
  assert.strictEqual(currentResult.data.defaultModel.model, "deepseek-v4-pro");

  const restored = await vm.runInNewContext(
    buildModelObserverCompatibilityExpression([]),
    { document },
  );
  assert.strictEqual(restored.restoredObserverCount, 1);
  assert.strictEqual(currentResult.data.models.length, 0);
}

async function testTransientTransportRetry() {
  const transportError = new Error(
    "Error invoking remote method 'codex_desktop:message-from-view': AppServerTransportConnectError: socket hang up",
  );
  assert.strictEqual(isTransientTransportError(transportError), true);
  assert.strictEqual(
    isTransientTransportError(new Error("AppServerTransportError: socket hung up")),
    true,
  );
  assert.strictEqual(isTransientTransportError(new Error("socket hang up")), true);
  assert.strictEqual(isTransientTransportError(new Error("Codex restart bridge is unavailable")), false);
  assert.strictEqual(isTransientTransportError(new Error("ECONNRESET")), true);

  let transportCalls = 0;
  const recovered = await withTransientRetry({ maxAttempts: 3, baseDelayMs: 1 }, async () => {
    transportCalls += 1;
    if (transportCalls < 3) throw transportError;
    return "connected";
  });
  assert.strictEqual(recovered, "connected");
  assert.strictEqual(transportCalls, 3);

  let fatalCalls = 0;
  await assert.rejects(
    withTransientRetry({ maxAttempts: 6, baseDelayMs: 1 }, async () => {
      fatalCalls += 1;
      throw new Error("Dynamic import failed");
    }),
    /Dynamic import failed/,
  );
  assert.strictEqual(fatalCalls, 1);
}

async function main() {
  const staleId = "remote-ssh-discovered:docker-codex-suite";
  const actualId = "remote-ssh-discovered:codex-docker-d";

  const exact = resolveRemoteHost(
    [
      connection(actualId, { autoConnect: true }),
      connection(staleId, { sshHost: "192.0.2.10", sshPort: 2200 }),
    ],
    staleId,
    "127.0.0.1",
    2223,
  );
  assert.strictEqual(exact.hostId, staleId);
  assert.strictEqual(exact.hostResolution, "configured-host-id");

  const uniqueEndpoint = resolveRemoteHost(
    [connection(actualId, { autoConnect: true })],
    staleId,
    "localhost",
    2223,
  );
  assert.strictEqual(uniqueEndpoint.hostId, actualId);
  assert.strictEqual(uniqueEndpoint.hostResolution, "unique-ssh-endpoint");

  const autoConnect = resolveRemoteHost(
    [
      connection("remote-ssh-discovered:first"),
      connection(actualId, { autoConnect: true }),
    ],
    staleId,
    "127.0.0.1",
    2223,
  );
  assert.strictEqual(autoConnect.hostId, actualId);
  assert.strictEqual(autoConnect.hostResolution, "auto-connect-ssh-endpoint");

  expectUnavailable(
    () =>
      resolveRemoteHost(
        [
          connection("remote-ssh-discovered:first", { autoConnect: true }),
          connection("remote-ssh-discovered:second", { autoConnect: true }),
        ],
        staleId,
        "127.0.0.1",
        2223,
      ),
    "AMBIGUOUS",
  );

  expectUnavailable(
    () =>
      resolveRemoteHost(
        [connection(actualId, { sshHost: "127.0.0.1", sshPort: 2200 })],
        staleId,
        "127.0.0.1",
        2223,
      ),
    "NO_MATCH",
  );

  const nested = extractRemoteConnections({
    connections: [connection(actualId), connection(actualId)],
  });
  assert.strictEqual(nested.length, 1);
  assert.strictEqual(hostsMatch("[::1]", "127.0.0.1"), true);

  const args = parseArgs([
    "--host-id",
    staleId,
    "--ssh-port",
    "2244",
    "--check-only",
  ]);
  assert.strictEqual(args.hostId, staleId);
  assert.strictEqual(args.sshPort, 2244);
  assert.strictEqual(args.checkOnly, true);

  await testModelQueryRefresh();
  await testModelObserverCompatibility();
  await testTransientTransportRetry();

  process.stdout.write("App reconnect tests: PASS\n");
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});
