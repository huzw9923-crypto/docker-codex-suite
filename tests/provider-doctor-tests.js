"use strict";

const assert = require("assert");
const http = require("http");
const {
  buildEndpoint,
  collectHttpProxyCandidates,
  collectModelIds,
  describeNetworkError,
  isFakeIpAddress,
  requestEndpointByAddress,
  resolvePublicIpv4WithDoh,
  runDoctor,
  safePreview,
  shouldRetryNetworkError,
} = require("../src/controller/docker-codex-provider-doctor.js");

const regularNetwork = {
  lookupHost: async () => [{ address: "93.184.216.34", family: 4 }],
  delay: async () => {},
};

async function withServer(run) {
  const requests = [];
  const server = http.createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8");
      requests.push({ method: request.method, url: request.url, headers: request.headers, body });
      response.setHeader("Content-Type", "application/json");
      if (request.url === "/v1/models") {
        response.end(JSON.stringify({ data: [{ id: "model-a" }, { id: "model-b" }] }));
      } else if (request.url === "/v1/responses") {
        response.end(JSON.stringify({ output_text: "OK responses" }));
      } else if (request.url === "/v1/chat/completions") {
        response.end(JSON.stringify({ choices: [{ message: { content: "OK chat" } }] }));
      } else {
        response.statusCode = 404;
        response.end(JSON.stringify({ error: "not found" }));
      }
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    await run(`http://127.0.0.1:${address.port}/v1`, requests);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function main() {
  assert.strictEqual(buildEndpoint("https://example.com", "models"), "https://example.com/v1/models");
  assert.strictEqual(buildEndpoint("https://example.com/v1/", "responses"), "https://example.com/v1/responses");
  assert.strictEqual(
    buildEndpoint("https://example.com/v1/chat/completions", "models"),
    "https://example.com/v1/models",
  );
  assert.strictEqual(isFakeIpAddress("198.18.0.0"), true);
  assert.strictEqual(isFakeIpAddress("198.19.255.255"), true);
  assert.strictEqual(isFakeIpAddress("198.20.0.1"), false);
  assert.strictEqual(isFakeIpAddress("104.26.0.141"), false);
  const proxyCandidates = collectHttpProxyCandidates({
    HTTPS_PROXY: "http://proxy-user:proxy-pass@127.0.0.1:8899",
  });
  assert.strictEqual(proxyCandidates[0].hostname, "127.0.0.1");
  assert.strictEqual(proxyCandidates[0].port, 8899);
  assert(proxyCandidates[0].authorization.startsWith("Basic "));
  assert.deepStrictEqual(collectModelIds({ models: ["a", { name: "b" }, { id: "a" }] }), ["a", "b"]);
  assert(!safePreview("Bearer secret-token sk-abcdefghijk").includes("secret-token"));
  const socketError = new TypeError("fetch failed", {
    cause: Object.assign(new Error("socket disconnected before TLS"), { code: "ECONNRESET" }),
  });
  assert.strictEqual(describeNetworkError(socketError).code, "ECONNRESET");
  assert(describeNetworkError(socketError).message.includes("socket disconnected before TLS"));
  assert.strictEqual(shouldRetryNetworkError(socketError), false);

  const failed = await runDoctor(
    { action: "models", protocol: "responses", baseUrl: "https://example.com/v1" },
    async () => {
      throw socketError;
    },
    regularNetwork,
  );
  assert.strictEqual(failed.ok, false);
  assert.strictEqual(failed.networkCode, "ECONNRESET");

  const connectTimeout = new TypeError("fetch failed", {
    cause: Object.assign(new Error("Connect Timeout Error"), { code: "UND_ERR_CONNECT_TIMEOUT" }),
  });
  let retryCalls = 0;
  const retried = await runDoctor(
    { action: "models", protocol: "responses", baseUrl: "https://example.com/v1" },
    async () => {
      retryCalls += 1;
      if (retryCalls === 1) throw connectTimeout;
      return new Response(JSON.stringify({ data: [{ id: "retried-model" }] }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    },
    regularNetwork,
  );
  assert.strictEqual(retried.ok, true);
  assert.strictEqual(retried.attempts, 2);
  assert.deepStrictEqual(retried.models, ["retried-model"]);

  const dohCalls = [];
  const dohAddresses = await resolvePublicIpv4WithDoh(
    "api.example.test",
    1000,
    async (_requestModule, options, body, timeoutMs, maxBytes) => {
      dohCalls.push({ options, body, timeoutMs, maxBytes });
      return {
        statusCode: 200,
        headers: { "content-type": "application/dns-json" },
        body: Buffer.from(
          JSON.stringify({
            Status: 0,
            Answer: [
              { type: 5, data: "edge.example.test." },
              { type: 1, data: "104.26.0.141" },
              { type: 1, data: "104.26.1.141" },
            ],
          }),
        ),
      };
    },
  );
  assert.deepStrictEqual(dohAddresses, ["104.26.0.141", "104.26.1.141"]);
  assert.strictEqual(dohCalls.length, 1);
  assert.strictEqual(dohCalls[0].options.hostname, "1.1.1.1");
  assert.strictEqual(dohCalls[0].options.servername, "cloudflare-dns.com");
  assert.strictEqual(dohCalls[0].options.headers.Host, "cloudflare-dns.com");

  let proxyFallbackCalls = 0;
  let unexpectedPublicDnsCalls = 0;
  const proxyFallback = await runDoctor(
    {
      action: "models",
      protocol: "responses",
      baseUrl: "https://api.example.test/v1",
      apiKey: "proxy-fallback-secret",
    },
    async () => {
      throw connectTimeout;
    },
    {
      lookupHost: async () => ["198.18.1.122"],
      proxyCandidates: [{ hostname: "127.0.0.1", port: 7897 }],
      proxyRequest: async (endpoint, options, proxy) => {
        proxyFallbackCalls += 1;
        assert.strictEqual(endpoint, "https://api.example.test/v1/models");
        assert.strictEqual(options.headers.Authorization, "Bearer proxy-fallback-secret");
        assert.deepStrictEqual(proxy, { hostname: "127.0.0.1", port: 7897 });
        return new Response(JSON.stringify({ data: [{ id: "proxy-model" }] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      },
      resolvePublicIpv4: async () => {
        unexpectedPublicDnsCalls += 1;
        return ["104.26.0.141"];
      },
    },
  );
  assert.strictEqual(proxyFallback.ok, true);
  assert.strictEqual(proxyFallbackCalls, 1);
  assert.strictEqual(unexpectedPublicDnsCalls, 0);
  assert.strictEqual(proxyFallback.transport, "local-proxy-fallback");
  assert.strictEqual(proxyFallback.proxyAddress, "127.0.0.1:7897");
  assert.strictEqual(proxyFallback.attempts, 2);
  assert.deepStrictEqual(proxyFallback.models, ["proxy-model"]);
  assert(!JSON.stringify(proxyFallback).includes("proxy-fallback-secret"));

  let fallbackFetchCalls = 0;
  let fallbackDirectCalls = 0;
  const fallback = await runDoctor(
    {
      action: "models",
      protocol: "responses",
      baseUrl: "https://api.example.test/v1",
      apiKey: "fallback-secret",
    },
    async () => {
      fallbackFetchCalls += 1;
      throw connectTimeout;
    },
    {
      lookupHost: async () => [{ address: "198.18.1.122", family: 4 }],
      proxyCandidates: [],
      resolvePublicIpv4: async (hostname) => {
        assert.strictEqual(hostname, "api.example.test");
        return ["104.26.0.141", "104.26.1.141"];
      },
      directRequest: async (endpoint, options, address) => {
        fallbackDirectCalls += 1;
        assert.strictEqual(endpoint, "https://api.example.test/v1/models");
        assert.strictEqual(options.headers.Authorization, "Bearer fallback-secret");
        assert.strictEqual(address, "104.26.0.141");
        return new Response(JSON.stringify({ data: [{ id: "fallback-model" }] }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      },
      delay: async () => {},
    },
  );
  assert.strictEqual(fallback.ok, true);
  assert.strictEqual(fallbackFetchCalls, 1);
  assert.strictEqual(fallbackDirectCalls, 1);
  assert.strictEqual(fallback.transport, "public-dns-fallback");
  assert.strictEqual(fallback.fakeIpDetected, true);
  assert.strictEqual(fallback.localAddress, "198.18.1.122");
  assert.strictEqual(fallback.resolvedAddress, "104.26.0.141");
  assert.strictEqual(fallback.attempts, 2);
  assert.strictEqual(fallback.normalAttempts, 1);
  assert.strictEqual(fallback.fallbackAttempts.length, 2);
  assert.deepStrictEqual(fallback.models, ["fallback-model"]);
  assert(!JSON.stringify(fallback).includes("fallback-secret"));

  await withServer(async (baseUrl, requests) => {
    const models = await runDoctor({ action: "models", protocol: "responses", baseUrl, apiKey: "test-key" });
    assert.strictEqual(models.ok, true);
    assert.deepStrictEqual(models.models, ["model-a", "model-b"]);

    const responses = await runDoctor({
      action: "test",
      protocol: "responses",
      baseUrl,
      apiKey: "test-key",
      model: "model-a",
    });
    assert.strictEqual(responses.ok, true);
    assert.strictEqual(responses.preview, "OK responses");

    const chat = await runDoctor({
      action: "test",
      protocol: "chat",
      baseUrl,
      apiKey: "test-key",
      model: "model-b",
    });
    assert.strictEqual(chat.ok, true);
    assert.strictEqual(chat.preview, "OK chat");

    assert.strictEqual(requests.length, 3);
    assert.strictEqual(requests[0].headers.authorization, "Bearer test-key");
    const responsesBody = JSON.parse(requests[1].body);
    assert(Array.isArray(responsesBody.input));
    assert(Array.isArray(responsesBody.input[0].content));
    const chatBody = JSON.parse(requests[2].body);
    assert(Array.isArray(chatBody.messages));

    const directUrl = new URL(baseUrl);
    directUrl.hostname = "provider.example.test";
    const directResponse = await requestEndpointByAddress(
      `${directUrl.toString()}/models`,
      { method: "GET", headers: { Accept: "application/json" } },
      "127.0.0.1",
      2000,
    );
    assert.strictEqual(directResponse.status, 200);
    assert.strictEqual(requests.length, 4);
    assert.strictEqual(requests[3].headers.host, `provider.example.test:${directUrl.port}`);
  });

  process.stdout.write("Provider doctor tests: PASS\n");
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
