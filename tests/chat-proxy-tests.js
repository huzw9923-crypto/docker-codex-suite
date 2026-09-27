"use strict";

const assert = require("assert");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const {
  ChatStreamConverter,
  buildUpstreamEndpoint,
  chatCompletionToResponse,
  createChatProxyServer,
  responsesToChatCompletions,
} = require("../src/controller/docker-codex-chat-proxy.js");

function listen(server) {
  return new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
}

function close(server) {
  return new Promise((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

function parseEvents(text) {
  return text
    .split(/\r?\n\r?\n/)
    .map((block) => {
      const event = block
        .split(/\r?\n/)
        .find((line) => line.startsWith("event:"))
        ?.slice(6)
        .trim();
      const data = block
        .split(/\r?\n/)
        .find((line) => line.startsWith("data:"))
        ?.slice(5)
        .trim();
      if (!event || !data || data === "[DONE]") return null;
      return { event, data: JSON.parse(data) };
    })
    .filter(Boolean);
}

async function main() {
  assert.strictEqual(
    buildUpstreamEndpoint("https://api.deepseek.com", "chat"),
    "https://api.deepseek.com/v1/chat/completions",
  );
  assert.strictEqual(
    buildUpstreamEndpoint("https://example.com/v1/", "models"),
    "https://example.com/v1/models",
  );

  const request = {
    model: "deepseek-v4-pro",
    instructions: "Be precise.",
    input: [
      { role: "user", content: [{ type: "input_text", text: "Update the file" }] },
      { type: "custom_tool_call", call_id: "old-call", name: "apply_patch", input: "*** Begin Patch" },
      { type: "custom_tool_call_output", call_id: "old-call", output: "Done" },
    ],
    tools: [
      { type: "custom", name: "apply_patch", description: "Apply a patch" },
      {
        type: "function",
        name: "read_file",
        description: "Read a file",
        parameters: {
          type: "object",
          properties: { path: { type: "string" } },
          required: ["path"],
        },
      },
    ],
    stream: false,
    max_output_tokens: 1234,
  };
  const converted = responsesToChatCompletions(request);
  assert.strictEqual(converted.body.model, "deepseek-v4-pro");
  assert.strictEqual(converted.body.messages[0].role, "system");
  assert.strictEqual(converted.body.messages[1].role, "user");
  assert.strictEqual(converted.body.messages[2].tool_calls[0].function.name, "apply_patch");
  assert.strictEqual(JSON.parse(converted.body.messages[2].tool_calls[0].function.arguments).input, "*** Begin Patch");
  assert.strictEqual(converted.body.messages[3].role, "tool");
  assert.strictEqual(converted.body.tools.length, 2);
  assert.strictEqual(converted.body.max_tokens, 1234);

  const chatResponse = {
    id: "chatcmpl-test",
    model: "deepseek-v4-pro",
    created: 123,
    choices: [
      {
        finish_reason: "tool_calls",
        message: {
          reasoning_content: "Need a patch.",
          content: "",
          tool_calls: [
            {
              id: "call-1",
              type: "function",
              function: { name: "apply_patch", arguments: '{"input":"*** Begin Patch\\n*** End Patch"}' },
            },
          ],
        },
      },
    ],
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
  };
  const response = chatCompletionToResponse(chatResponse, request, converted.toolContext);
  assert.strictEqual(response.status, "completed");
  assert.strictEqual(response.output[0].type, "reasoning");
  assert.strictEqual(response.output[1].type, "custom_tool_call");
  assert.strictEqual(response.output[1].name, "apply_patch");
  assert(response.output[1].input.includes("*** Begin Patch"));
  assert.strictEqual(response.usage.total_tokens, 15);

  const chunks = [];
  const memoryResponse = { write(value) { chunks.push(value); } };
  const stream = new ChatStreamConverter(memoryResponse, { ...request, stream: true }, converted.toolContext);
  stream.handleChunk({
    id: "chatcmpl-stream",
    model: "deepseek-v4-pro",
    created: 456,
    choices: [{ delta: { reasoning_content: "Think." }, finish_reason: null }],
  });
  stream.handleChunk({
    id: "chatcmpl-stream",
    choices: [{ delta: { content: "Answer." }, finish_reason: null }],
  });
  stream.handleChunk({
    id: "chatcmpl-stream",
    choices: [
      {
        delta: {
          tool_calls: [
            {
              index: 0,
              id: "call-stream",
              function: { name: "apply_patch", arguments: '{"input":"patch"}' },
            },
          ],
        },
        finish_reason: "tool_calls",
      },
    ],
    usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 },
  });
  stream.finish();
  const events = parseEvents(chunks.join(""));
  const eventNames = events.map((entry) => entry.event);
  assert(eventNames.includes("response.reasoning_summary_text.delta"));
  assert(eventNames.includes("response.output_text.delta"));
  assert(eventNames.includes("response.custom_tool_call_input.delta"));
  assert.strictEqual(eventNames[eventNames.length - 1], "response.completed");
  const completed = events.findLast((entry) => entry.event === "response.completed");
  assert.strictEqual(completed.data.response.usage.total_tokens, 5);

  const upstreamRequests = [];
  const upstream = http.createServer((incoming, outgoing) => {
    const body = [];
    incoming.on("data", (chunk) => body.push(chunk));
    incoming.on("end", () => {
      upstreamRequests.push({
        url: incoming.url,
        authorization: incoming.headers.authorization,
        body: JSON.parse(Buffer.concat(body).toString("utf8") || "{}"),
      });
      outgoing.setHeader("Content-Type", "application/json");
      outgoing.end(
        JSON.stringify({
          id: "chatcmpl-integration",
          model: "deepseek-v4-flash",
          created: 789,
          choices: [{ finish_reason: "stop", message: { content: "proxy-ok" } }],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        }),
      );
    });
  });
  await listen(upstream);
  const upstreamAddress = upstream.address();
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "docker-codex-chat-proxy-"));
  const configPath = path.join(tempRoot, "chat-proxy.json");
  fs.writeFileSync(
    configPath,
    JSON.stringify({
      enabled: true,
      profileId: "codexpp-deepseek",
      upstreamBaseUrl: `http://127.0.0.1:${upstreamAddress.port}`,
    }),
  );
  let proxy;
  try {
    proxy = await createChatProxyServer({ host: "127.0.0.1", port: 0, configPath });
    const proxyAddress = proxy.address();
    const health = await (await fetch(`http://127.0.0.1:${proxyAddress.port}/health`)).json();
    assert.strictEqual(health.enabled, true);
    assert.strictEqual(health.profileId, "codexpp-deepseek");
    assert(!JSON.stringify(health).includes("127.0.0.1:" + upstreamAddress.port));

    const proxied = await fetch(`http://127.0.0.1:${proxyAddress.port}/v1/responses`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer test-secret" },
      body: JSON.stringify({ model: "deepseek-v4-flash", input: "ping", stream: false }),
    });
    assert.strictEqual(proxied.status, 200);
    const proxiedBody = await proxied.json();
    assert.strictEqual(proxiedBody.output_text, "proxy-ok");
    assert.strictEqual(upstreamRequests.length, 1);
    assert.strictEqual(upstreamRequests[0].url, "/v1/chat/completions");
    assert.strictEqual(upstreamRequests[0].authorization, "Bearer test-secret");
    assert.strictEqual(upstreamRequests[0].body.messages[0].content, "ping");
  } finally {
    if (proxy) await close(proxy);
    await close(upstream);
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }

  process.stdout.write("Chat proxy tests: PASS\n");
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
