"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");

const {
  ChatStreamConverter,
  chatCompletionToResponse,
  responsesToChatCompletions,
} = require("../src/controller/docker-codex-chat-proxy.js");

const toolSearch = {
  type: "tool_search",
  execution: "client",
  description: "Search deferred tools.",
  parameters: {
    type: "object",
    properties: {
      query: { type: "string" },
      limit: { type: "number" },
    },
    required: ["query"],
    additionalProperties: false,
  },
};

test("converts Responses tool_search into a named Chat Completions function", () => {
  const converted = responsesToChatCompletions({
    model: "test-model",
    input: [{ role: "user", content: "Find create_thread" }],
    tools: [toolSearch, { type: "web_search" }],
  });

  assert.deepEqual(
    converted.body.tools.map((tool) => tool.function.name),
    ["tool_search"],
  );
  assert.equal(converted.body.tools[0].function.description, toolSearch.description);
  assert.deepEqual(converted.body.tools[0].function.parameters, toolSearch.parameters);
  assert.equal(converted.toolContext.byChatName.get("tool_search").kind, "tool_search");
});

test("restores a non-streaming tool search call as tool_search_call", () => {
  const converted = responsesToChatCompletions({
    model: "test-model",
    input: "Find create_thread",
    tools: [toolSearch],
  });
  const response = chatCompletionToResponse(
    {
      id: "chat_1",
      model: "test-model",
      choices: [
        {
          finish_reason: "tool_calls",
          message: {
            tool_calls: [
              {
                id: "call_search",
                type: "function",
                function: {
                  name: "tool_search",
                  arguments: '{"query":"create_thread","limit":5}',
                },
              },
            ],
          },
        },
      ],
    },
    { model: "test-model", tools: [toolSearch] },
    converted.toolContext,
  );

  assert.deepEqual(response.output, [
    {
      id: "tsc_call_search",
      type: "tool_search_call",
      status: "completed",
      call_id: "call_search",
      execution: "client",
      arguments: { query: "create_thread", limit: 5 },
    },
  ]);
});

test("preserves tool search call and output history across turns", () => {
  const converted = responsesToChatCompletions({
    model: "test-model",
    tools: [toolSearch],
    input: [
      {
        type: "tool_search_call",
        call_id: "call_search",
        execution: "client",
        arguments: { query: "create_thread", limit: 5 },
      },
      {
        type: "tool_search_output",
        call_id: "call_search",
        execution: "client",
        status: "completed",
        tools: [
          {
            type: "namespace",
            name: "multi_agent_v1",
            description: "Subagent tools.",
            tools: [
              {
                type: "function",
                name: "spawn_agent",
                description: "Spawn a subagent.",
                defer_loading: true,
                parameters: {
                  type: "object",
                  properties: { message: { type: "string" } },
                },
              },
            ],
          },
        ],
      },
    ],
  });

  assert.deepEqual(converted.body.messages, [
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_search",
          type: "function",
          function: {
            name: "tool_search",
            arguments: '{"query":"create_thread","limit":5}',
          },
        },
      ],
    },
    {
      role: "tool",
      tool_call_id: "call_search",
      content:
        '[{"type":"namespace","name":"multi_agent_v1","description":"Subagent tools.","tools":[{"type":"function","name":"spawn_agent","description":"Spawn a subagent.","defer_loading":true,"parameters":{"type":"object","properties":{"message":{"type":"string"}}}}]}]',
    },
  ]);
  assert.deepEqual(
    converted.body.tools.map((tool) => tool.function.name),
    ["tool_search", "multi_agent_v1_spawn_agent"],
  );
});

test("deduplicates tools returned by repeated searches", () => {
  const discovered = {
    type: "namespace",
    name: "multi_agent_v1",
    tools: [
      {
        type: "function",
        name: "spawn_agent",
        parameters: { type: "object", properties: {} },
      },
    ],
  };
  const converted = responsesToChatCompletions({
    model: "test-model",
    tools: [toolSearch],
    input: [
      { type: "tool_search_output", call_id: "a", tools: [discovered] },
      { type: "tool_search_output", call_id: "b", tools: [discovered] },
    ],
  });

  assert.deepEqual(
    converted.body.tools.map((tool) => tool.function.name),
    ["tool_search", "multi_agent_v1_spawn_agent"],
  );
});

test("restores a streaming tool search call without function-call delta events", () => {
  const converted = responsesToChatCompletions({
    model: "test-model",
    input: "Find create_thread",
    stream: true,
    tools: [toolSearch],
  });
  const writes = [];
  const response = {
    write(value) {
      writes.push(String(value));
      return true;
    },
  };
  const converter = new ChatStreamConverter(
    response,
    { model: "test-model", tools: [toolSearch] },
    converted.toolContext,
  );

  converter.handleChunk({
    id: "chat_stream",
    model: "test-model",
    choices: [
      {
        delta: {
          tool_calls: [
            {
              index: 0,
              id: "call_stream",
              function: {
                name: "tool_search",
                arguments: '{"query":"create_thread"}',
              },
            },
          ],
        },
        finish_reason: "tool_calls",
      },
    ],
  });
  converter.finish();

  const stream = writes.join("");
  assert.doesNotMatch(stream, /response\.function_call_arguments/);
  assert.match(stream, /"type":"tool_search_call"/);
  assert.match(stream, /"arguments":\{"query":"create_thread"\}/);
  assert.match(stream, /"id":"tsc_call_stream"/);
});

test("keeps ordinary namespaced functions working", () => {
  const converted = responsesToChatCompletions({
    model: "test-model",
    input: "Run it",
    tools: [
      {
        type: "namespace",
        name: "codex_app",
        tools: [
          {
            type: "function",
            name: "create_thread",
            description: "Create a thread.",
            parameters: { type: "object", properties: {} },
          },
        ],
      },
    ],
  });

  assert.equal(converted.body.tools[0].function.name, "codex_app_create_thread");
});

