"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const {
  createChatProxyServer,
  sanitizeResponsesRequest,
} = require("../src/controller/docker-codex-chat-proxy.js");

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

test("normalizes invalid historical Responses tool names deterministically", () => {
  const request = {
    tools: [{ type: "function", name: "valid_tool", parameters: { type: "object" } }],
    input: [
      {
        type: "function_call",
        call_id: "legacy-call",
        name: "multi_agent_v1.spawn_agent",
        arguments: "{}",
      },
      {
        type: "function_call_output",
        call_id: "legacy-call",
        output: "SUBAGENT_OK",
      },
    ],
  };

  const first = sanitizeResponsesRequest(request);
  const second = sanitizeResponsesRequest(request);
  const firstName = first.body.input[0].name;
  assert.match(firstName, /^[a-zA-Z0-9_-]+$/);
  assert.equal(firstName, second.body.input[0].name);
  assert.notEqual(firstName, "multi_agent_v1.spawn_agent");
  assert.equal(first.body.input[1].call_id, "legacy-call");
  assert.equal(first.body.input[1].output, "SUBAGENT_OK");
  assert.equal(first.changed, true);
});

test("Responses proxy sanitizes history and preserves non-streaming payloads", async () => {
  const requests = [];
  const upstream = http.createServer((request, response) => {
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      requests.push(body);
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({ id: "resp-upstream", output: [{ type: "message" }] }));
    });
  });
  await listen(upstream);
  const upstreamAddress = upstream.address();
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "docker-codex-responses-proxy-"));
  const configPath = path.join(tempRoot, "proxy.json");
  fs.writeFileSync(
    configPath,
    JSON.stringify({
      enabled: true,
      protocol: "responses",
      profileId: "gpt-profile",
      upstreamBaseUrl: `http://127.0.0.1:${upstreamAddress.port}/v1`,
    }),
  );

  let proxy;
  try {
    proxy = await createChatProxyServer({ host: "127.0.0.1", port: 0, configPath });
    const proxyAddress = proxy.address();
    const response = await fetch(`http://127.0.0.1:${proxyAddress.port}/v1/responses`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: "gpt-test",
        input: [
          { type: "function_call", call_id: "legacy", name: "总指挥.spawn_agent", arguments: "{}" },
          { type: "function_call_output", call_id: "legacy", output: "SUBAGENT_OK" },
        ],
      }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { id: "resp-upstream", output: [{ type: "message" }] });
    assert.equal(requests.length, 1);
    assert.match(requests[0].input[0].name, /^[a-zA-Z0-9_-]+$/);
    assert.equal(requests[0].input[1].call_id, "legacy");
  } finally {
    if (proxy) await close(proxy);
    await close(upstream);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("Responses proxy preserves streaming events", async () => {
  const upstream = http.createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    response.end('event: response.completed\ndata: {"type":"response.completed"}\n\ndata: [DONE]\n\n');
  });
  await listen(upstream);
  const upstreamAddress = upstream.address();
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "docker-codex-responses-stream-"));
  const configPath = path.join(tempRoot, "proxy.json");
  fs.writeFileSync(
    configPath,
    JSON.stringify({
      enabled: true,
      protocol: "responses",
      profileId: "gpt-stream",
      upstreamBaseUrl: `http://127.0.0.1:${upstreamAddress.port}/v1`,
    }),
  );

  let proxy;
  try {
    proxy = await createChatProxyServer({ host: "127.0.0.1", port: 0, configPath });
    const proxyAddress = proxy.address();
    const response = await fetch(`http://127.0.0.1:${proxyAddress.port}/v1/responses`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: "gpt-test", input: "ping", stream: true }),
    });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), 'event: response.completed\ndata: {"type":"response.completed"}\n\ndata: [DONE]\n\n');
  } finally {
    if (proxy) await close(proxy);
    await close(upstream);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});
