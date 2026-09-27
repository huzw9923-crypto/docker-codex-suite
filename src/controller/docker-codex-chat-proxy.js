"use strict";

const fs = require("fs");
const http = require("http");

const MAX_REQUEST_BYTES = 16 * 1024 * 1024;
const UPSTREAM_TIMEOUT_MS = 120000;

function normalizeBaseUrl(value) {
  return String(value || "").trim().replace(/#$/, "").replace(/\/+$/, "");
}

function hasVersionSuffix(baseUrl) {
  return /\/v\d+(?:alpha|beta)?$/i.test(baseUrl);
}

function buildUpstreamEndpoint(baseUrl, kind) {
  const base = normalizeBaseUrl(baseUrl);
  if (!base) throw new Error("Chat proxy upstream Base URL is empty");

  const suffix =
    kind === "models" ? "models" : kind === "responses" ? "responses" : "chat/completions";
  if (base.toLowerCase().endsWith(`/${suffix}`)) return base;

  let root = base;
  for (const ending of ["/chat/completions", "/responses", "/models"]) {
    if (root.toLowerCase().endsWith(ending)) {
      root = root.slice(0, -ending.length).replace(/\/+$/, "");
      break;
    }
  }

  const parsed = new URL(root);
  const originOnly = parsed.pathname === "" || parsed.pathname === "/";
  const version = originOnly && !hasVersionSuffix(root) ? "/v1" : "";
  return `${root}${version}/${suffix}`.replace(/\/v1\/v1\//gi, "/v1/");
}

const PROVIDER_TOOL_NAME_PATTERN = /^[a-zA-Z0-9_-]+$/;

function stableNameHash(value) {
  let hash = 2166136261;
  for (const character of String(value || "")) {
    hash ^= character.codePointAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
}

function isProviderToolName(value) {
  return PROVIDER_TOOL_NAME_PATTERN.test(String(value || ""));
}

function sanitizeResponsesRequest(body) {
  const normalized = JSON.parse(JSON.stringify(body || {}));
  const usedNames = new Set();
  const replacements = new Map();

  const getToolName = (tool) => {
    if (!tool || typeof tool !== "object") return "";
    return String(tool.name || tool.function?.name || "");
  };

  const collectValidNames = (tool) => {
    if (!tool || typeof tool !== "object") return;
    if (tool.type === "namespace" && Array.isArray(tool.tools)) {
      for (const child of tool.tools) collectValidNames(child);
      return;
    }
    const name = getToolName(tool);
    if (isProviderToolName(name)) usedNames.add(name);
  };

  for (const tool of Array.isArray(normalized.tools) ? normalized.tools : []) {
    collectValidNames(tool);
  }

  const normalizeName = (value) => {
    const original = String(value || "");
    if (isProviderToolName(original)) {
      usedNames.add(original);
      return original;
    }
    if (replacements.has(original)) return replacements.get(original);

    const base =
      original.replace(/[^A-Za-z0-9_-]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 48) ||
      "legacy_tool";
    const candidate = `${base}_${stableNameHash(original)}`.slice(0, 64);
    const normalizedName = sanitizeToolName(candidate, usedNames);
    replacements.set(original, normalizedName);
    return normalizedName;
  };

  const normalizeTool = (tool) => {
    if (!tool || typeof tool !== "object") return;
    if (tool.type === "namespace" && Array.isArray(tool.tools)) {
      for (const child of tool.tools) normalizeTool(child);
      return;
    }
    if (tool.function && typeof tool.function === "object" && tool.function.name !== undefined) {
      tool.function.name = normalizeName(tool.function.name);
    } else if (tool.name !== undefined) {
      tool.name = normalizeName(tool.name);
    }
  };

  for (const tool of Array.isArray(normalized.tools) ? normalized.tools : []) {
    normalizeTool(tool);
  }
  for (const item of Array.isArray(normalized.input) ? normalized.input : []) {
    if (!item || typeof item !== "object") continue;
    if (["function_call", "custom_tool_call"].includes(item.type) && item.name !== undefined) {
      item.name = normalizeName(item.name);
    }
    if (item.type === "tool_search_output" && Array.isArray(item.tools)) {
      for (const tool of item.tools) normalizeTool(tool);
    }
  }
  if (normalized.tool_choice && typeof normalized.tool_choice === "object") {
    if (normalized.tool_choice.name !== undefined) {
      normalized.tool_choice.name = normalizeName(normalized.tool_choice.name);
    }
    if (normalized.tool_choice.function?.name !== undefined) {
      normalized.tool_choice.function.name = normalizeName(normalized.tool_choice.function.name);
    }
  }

  return {
    body: normalized,
    changed: replacements.size > 0,
    replacements: Object.fromEntries(replacements),
  };
}

function canonicalJson(value) {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value ?? {});
  } catch {
    return "{}";
  }
}

function parseJsonObject(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return value;
  try {
    const parsed = JSON.parse(String(value || "{}"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function sanitizeToolName(value, usedNames) {
  const base =
    String(value || "tool")
      .replace(/[^A-Za-z0-9_-]+/g, "_")
      .replace(/^_+|_+$/g, "")
      .slice(0, 64) || "tool";
  let selected = base;
  let index = 2;
  while (usedNames.has(selected)) {
    const suffix = `_${index}`;
    selected = `${base.slice(0, 64 - suffix.length)}${suffix}`;
    index += 1;
  }
  usedNames.add(selected);
  return selected;
}

function normalizeParameters(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { type: "object", properties: {}, additionalProperties: true };
  }
  const result = structuredClone(value);
  if (!result.type) result.type = "object";
  if (result.type === "object" && !result.properties) result.properties = {};
  return result;
}

function buildToolContext(tools) {
  const usedNames = new Set();
  const byChatName = new Map();
  const byOriginalName = new Map();
  const chatTools = [];

  function addTool(tool, namespace = "") {
    if (!tool || typeof tool !== "object") return;
    const type = String(tool.type || (tool.function ? "function" : ""));
    if (type === "tool_search") {
      const originalName = "tool_search";
      if (byOriginalName.has(originalName)) return;
      const chatName = sanitizeToolName(originalName, usedNames);
      const spec = {
        kind: "tool_search",
        originalName,
        qualifiedName: originalName,
        chatName,
        namespace: "",
        execution: String(tool.execution || "client"),
      };
      byChatName.set(chatName, spec);
      byOriginalName.set(originalName, spec);
      chatTools.push({
        type: "function",
        function: {
          name: chatName,
          description: String(tool.description || "Search for deferred tools."),
          parameters: normalizeParameters(tool.parameters),
        },
      });
      return;
    }
    if (type !== "function" && type !== "custom") return;
    const originalName = String(tool.name || tool.function?.name || "tool");
    const qualifiedName = namespace ? `${namespace}.${originalName}` : originalName;
    if (byOriginalName.has(qualifiedName)) return;
    const chatName = sanitizeToolName(namespace ? `${namespace}_${originalName}` : originalName, usedNames);
    const kind = type === "custom" ? "custom" : "function";
    const description = String(tool.description || tool.function?.description || "");
    const parameters =
      kind === "custom"
        ? {
            type: "object",
            properties: { input: { type: "string", description: description || "Tool input" } },
            required: ["input"],
            additionalProperties: false,
          }
        : normalizeParameters(tool.parameters || tool.function?.parameters);
    const spec = { kind, originalName, qualifiedName, chatName, namespace };
    byChatName.set(chatName, spec);
    byOriginalName.set(qualifiedName, spec);
    byOriginalName.set(originalName, spec);
    chatTools.push({
      type: "function",
      function: {
        name: chatName,
        description: description || `Call ${qualifiedName}`,
        parameters,
      },
    });
  }

  for (const tool of Array.isArray(tools) ? tools : []) {
    if (tool?.type === "namespace" && Array.isArray(tool.tools)) {
      for (const child of tool.tools) addTool(child, String(tool.name || "namespace"));
    } else {
      addTool(tool);
    }
  }
  return { byChatName, byOriginalName, chatTools };
}

function collectRequestTools(body) {
  const tools = [...(Array.isArray(body.tools) ? body.tools : [])];
  for (const item of Array.isArray(body.input) ? body.input : []) {
    if (item?.type === "tool_search_output" && Array.isArray(item.tools)) {
      tools.push(...item.tools);
    }
  }
  return tools;
}

function textFromPart(part) {
  if (typeof part === "string") return part;
  if (!part || typeof part !== "object") return "";
  if (["input_text", "output_text", "text"].includes(part.type)) {
    return String(part.text || "");
  }
  return "";
}

function contentToChat(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return textFromPart(content);

  const parts = [];
  for (const part of content) {
    const text = textFromPart(part);
    if (text) {
      parts.push({ type: "text", text });
      continue;
    }
    if (part?.type === "input_image") {
      const url = String(part.image_url || part.url || "");
      if (url) {
        parts.push({
          type: "image_url",
          image_url: { url, ...(part.detail ? { detail: part.detail } : {}) },
        });
      }
    }
  }
  if (parts.length === 0) return "";
  if (parts.every((part) => part.type === "text")) {
    return parts.map((part) => part.text).join("\n");
  }
  return parts;
}

function instructionText(value) {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(textFromPart).filter(Boolean).join("\n");
  return textFromPart(value);
}

function customArguments(input) {
  return JSON.stringify({ input: typeof input === "string" ? input : canonicalJson(input) });
}

function appendInputItem(messages, item, toolContext) {
  if (typeof item === "string") {
    messages.push({ role: "user", content: item });
    return;
  }
  if (!item || typeof item !== "object") return;

  if (item.type === "message" || item.role) {
    let role = String(item.role || "user").toLowerCase();
    if (role === "developer") role = "system";
    if (!new Set(["system", "user", "assistant", "tool"]).has(role)) role = "user";
    messages.push({ role, content: contentToChat(item.content) });
    return;
  }

  if (item.type === "tool_search_call") {
    const spec = toolContext.byOriginalName.get("tool_search");
    messages.push({
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: String(item.call_id || item.id || `call_${messages.length}`),
          type: "function",
          function: {
            name: spec?.chatName || "tool_search",
            arguments: canonicalJson(item.arguments),
          },
        },
      ],
    });
    return;
  }

  if (item.type === "tool_search_output") {
    messages.push({
      role: "tool",
      tool_call_id: String(item.call_id || item.id || `call_${messages.length}`),
      content: canonicalJson(Array.isArray(item.tools) ? item.tools : []),
    });
    return;
  }

  if (item.type === "function_call" || item.type === "custom_tool_call") {
    const originalName = String(item.name || "tool");
    const spec = toolContext.byOriginalName.get(originalName);
    const name = spec?.chatName || sanitizeToolName(originalName, new Set());
    const callId = String(item.call_id || item.id || `call_${messages.length}`);
    const args =
      item.type === "custom_tool_call"
        ? customArguments(item.input)
        : canonicalJson(item.arguments);
    messages.push({
      role: "assistant",
      content: null,
      tool_calls: [{ id: callId, type: "function", function: { name, arguments: args } }],
    });
    return;
  }

  if (item.type === "function_call_output" || item.type === "custom_tool_call_output") {
    messages.push({
      role: "tool",
      tool_call_id: String(item.call_id || item.id || `call_${messages.length}`),
      content: typeof item.output === "string" ? item.output : canonicalJson(item.output),
    });
  }
}

function mergeAdjacentAssistantToolCalls(messages) {
  const result = [];
  for (const message of messages) {
    const previous = result[result.length - 1];
    if (
      previous?.role === "assistant" &&
      message.role === "assistant" &&
      Array.isArray(previous.tool_calls) &&
      Array.isArray(message.tool_calls)
    ) {
      previous.tool_calls.push(...message.tool_calls);
      continue;
    }
    result.push(message);
  }
  return result;
}

function mapToolChoice(toolChoice, toolContext) {
  if (typeof toolChoice === "string") {
    if (["auto", "none", "required"].includes(toolChoice)) return toolChoice;
    const spec = toolContext.byOriginalName.get(toolChoice);
    return spec ? { type: "function", function: { name: spec.chatName } } : undefined;
  }
  if (!toolChoice || typeof toolChoice !== "object") return undefined;
  const originalName = String(toolChoice.name || toolChoice.function?.name || "");
  const spec = toolContext.byOriginalName.get(originalName);
  if (!spec) return undefined;
  return { type: "function", function: { name: spec.chatName } };
}

function responsesToChatCompletions(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("Responses request body must be an object");
  }

  const toolContext = buildToolContext(collectRequestTools(body));
  const messages = [];
  const instructions = instructionText(body.instructions);
  if (instructions) messages.push({ role: "system", content: instructions });

  if (typeof body.input === "string") {
    messages.push({ role: "user", content: body.input });
  } else if (Array.isArray(body.input)) {
    for (const item of body.input) appendInputItem(messages, item, toolContext);
  }
  if (messages.length === 0) messages.push({ role: "user", content: "" });

  const result = {
    model: body.model,
    messages: mergeAdjacentAssistantToolCalls(messages),
    stream: body.stream === true,
  };
  if (toolContext.chatTools.length > 0) result.tools = toolContext.chatTools;

  const toolChoice = mapToolChoice(body.tool_choice, toolContext);
  if (toolChoice !== undefined) result.tool_choice = toolChoice;
  if (body.parallel_tool_calls !== undefined) result.parallel_tool_calls = body.parallel_tool_calls;
  if (body.max_output_tokens !== undefined) result.max_tokens = body.max_output_tokens;
  for (const key of ["temperature", "top_p", "seed", "stop", "user"]) {
    if (body[key] !== undefined) result[key] = body[key];
  }
  if (body.reasoning?.effort) result.reasoning_effort = body.reasoning.effort;
  if (result.stream) result.stream_options = { include_usage: true };
  return { body: result, toolContext };
}

function responseId(chatId) {
  const id = String(chatId || `compat_${Date.now()}`);
  return id.startsWith("resp_") ? id : `resp_${id}`;
}

function unwrapCustomInput(argumentsText) {
  try {
    const value = JSON.parse(String(argumentsText || "{}"));
    if (typeof value.input === "string") return value.input;
  } catch {
    // Preserve malformed tool arguments for the caller to inspect.
  }
  return String(argumentsText || "");
}

function splitReasoningContent(message) {
  let reasoning = String(message?.reasoning_content || message?.reasoning || "");
  let content = typeof message?.content === "string" ? message.content : "";
  const match = content.match(/^\s*<think>([\s\S]*?)<\/think>\s*([\s\S]*)$/i);
  if (match) {
    reasoning = reasoning || match[1];
    content = match[2];
  }
  return { reasoning, content };
}

function usageToResponses(usage) {
  const inputTokens = Number(usage?.prompt_tokens) || 0;
  const outputTokens = Number(usage?.completion_tokens) || 0;
  return {
    input_tokens: inputTokens,
    input_tokens_details: {
      cached_tokens: Number(usage?.prompt_cache_hit_tokens || usage?.prompt_tokens_details?.cached_tokens) || 0,
    },
    output_tokens: outputTokens,
    output_tokens_details: {
      reasoning_tokens: Number(usage?.completion_tokens_details?.reasoning_tokens) || 0,
    },
    total_tokens: Number(usage?.total_tokens) || inputTokens + outputTokens,
  };
}

function toolCallToResponseItem(toolCall, toolContext) {
  const callId = String(toolCall?.id || `call_${Date.now()}`);
  const name = String(toolCall?.function?.name || "unknown_tool");
  const argumentsText = String(toolCall?.function?.arguments || "");
  const spec = toolContext.byChatName.get(name);
  if (spec?.kind === "tool_search") {
    return {
      id: `tsc_${callId}`,
      type: "tool_search_call",
      status: "completed",
      call_id: callId,
      execution: spec.execution,
      arguments: parseJsonObject(argumentsText),
    };
  }
  if (spec?.kind === "custom") {
    return {
      id: `ctc_${callId}`,
      type: "custom_tool_call",
      status: "completed",
      call_id: callId,
      name: spec.originalName,
      input: unwrapCustomInput(argumentsText),
    };
  }
  return {
    id: `fc_${callId}`,
    type: "function_call",
    status: "completed",
    call_id: callId,
    name: spec?.originalName || name,
    ...(spec?.namespace ? { namespace: spec.namespace } : {}),
    arguments: argumentsText,
  };
}

function baseResponse(request, id, model, createdAt, status, output, usage) {
  return {
    id,
    object: "response",
    created_at: createdAt,
    status,
    background: false,
    error: null,
    incomplete_details: status === "incomplete" ? { reason: "max_output_tokens" } : null,
    instructions: request.instructions ?? null,
    max_output_tokens: request.max_output_tokens ?? null,
    model: model || request.model || "",
    output,
    parallel_tool_calls: request.parallel_tool_calls ?? true,
    previous_response_id: request.previous_response_id ?? null,
    reasoning: request.reasoning ?? null,
    store: request.store ?? false,
    temperature: request.temperature ?? null,
    text: request.text ?? { format: { type: "text" } },
    tool_choice: request.tool_choice ?? "auto",
    tools: request.tools ?? [],
    top_p: request.top_p ?? null,
    truncation: request.truncation ?? "disabled",
    usage,
    user: request.user ?? null,
    metadata: request.metadata ?? {},
  };
}

function chatCompletionToResponse(chatBody, originalRequest, toolContext) {
  const choice = Array.isArray(chatBody?.choices) ? chatBody.choices[0] || {} : {};
  const message = choice.message || {};
  const id = responseId(chatBody?.id);
  const createdAt = Number(chatBody?.created) || Math.floor(Date.now() / 1000);
  const status = choice.finish_reason === "length" ? "incomplete" : "completed";
  const output = [];
  const { reasoning, content } = splitReasoningContent(message);
  if (reasoning) {
    output.push({
      id: `rs_${id}`,
      type: "reasoning",
      status: "completed",
      reasoning_content: reasoning,
      summary: [{ type: "summary_text", text: reasoning }],
    });
  }
  if (content) {
    output.push({
      id: `${id}_msg`,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [{ type: "output_text", text: content, annotations: [] }],
    });
  }
  for (const toolCall of Array.isArray(message.tool_calls) ? message.tool_calls : []) {
    output.push(toolCallToResponseItem(toolCall, toolContext));
  }
  const response = baseResponse(
    originalRequest,
    id,
    chatBody?.model,
    createdAt,
    status,
    output,
    usageToResponses(chatBody?.usage),
  );
  response.output_text = content;
  return response;
}

function writeSse(response, event, payload) {
  response.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

class ChatStreamConverter {
  constructor(response, request, toolContext) {
    this.response = response;
    this.request = request;
    this.toolContext = toolContext;
    this.sequence = 0;
    this.id = "resp_compat";
    this.model = String(request.model || "");
    this.createdAt = Math.floor(Date.now() / 1000);
    this.started = false;
    this.completed = false;
    this.nextOutputIndex = 0;
    this.output = [];
    this.reasoning = { added: false, done: false, text: "", outputIndex: -1, itemId: "" };
    this.text = { added: false, done: false, text: "", outputIndex: -1, itemId: "" };
    this.tools = new Map();
    this.usage = usageToResponses(null);
    this.finishReason = null;
  }

  emit(type, payload) {
    this.sequence += 1;
    writeSse(this.response, type, { type, sequence_number: this.sequence, ...payload });
  }

  currentResponse(status, output = this.output) {
    return baseResponse(
      this.request,
      this.id,
      this.model,
      this.createdAt,
      status,
      output,
      this.usage,
    );
  }

  ensureStarted() {
    if (this.started) return;
    this.started = true;
    this.emit("response.created", { response: this.currentResponse("in_progress", []) });
    this.emit("response.in_progress", { response: this.currentResponse("in_progress", []) });
  }

  pushReasoning(delta) {
    if (!delta) return;
    this.ensureStarted();
    if (!this.reasoning.added) {
      this.reasoning.added = true;
      this.reasoning.outputIndex = this.nextOutputIndex++;
      this.reasoning.itemId = `rs_${this.id}`;
      this.emit("response.output_item.added", {
        output_index: this.reasoning.outputIndex,
        item: {
          id: this.reasoning.itemId,
          type: "reasoning",
          status: "in_progress",
          reasoning_content: "",
          summary: [],
        },
      });
      this.emit("response.reasoning_summary_part.added", {
        item_id: this.reasoning.itemId,
        output_index: this.reasoning.outputIndex,
        summary_index: 0,
        part: { type: "summary_text", text: "" },
      });
    }
    this.reasoning.text += delta;
    this.emit("response.reasoning_summary_text.delta", {
      item_id: this.reasoning.itemId,
      output_index: this.reasoning.outputIndex,
      summary_index: 0,
      delta,
    });
  }

  finishReasoning() {
    if (!this.reasoning.added || this.reasoning.done) return;
    this.reasoning.done = true;
    const item = {
      id: this.reasoning.itemId,
      type: "reasoning",
      status: "completed",
      reasoning_content: this.reasoning.text,
      summary: [{ type: "summary_text", text: this.reasoning.text }],
    };
    this.output.push(item);
    this.emit("response.reasoning_summary_text.done", {
      item_id: this.reasoning.itemId,
      output_index: this.reasoning.outputIndex,
      summary_index: 0,
      text: this.reasoning.text,
    });
    this.emit("response.reasoning_summary_part.done", {
      item_id: this.reasoning.itemId,
      output_index: this.reasoning.outputIndex,
      summary_index: 0,
      part: { type: "summary_text", text: this.reasoning.text },
    });
    this.emit("response.output_item.done", {
      output_index: this.reasoning.outputIndex,
      item,
    });
  }

  pushText(delta) {
    if (!delta) return;
    this.finishReasoning();
    this.ensureStarted();
    if (!this.text.added) {
      this.text.added = true;
      this.text.outputIndex = this.nextOutputIndex++;
      this.text.itemId = `${this.id}_msg`;
      this.emit("response.output_item.added", {
        output_index: this.text.outputIndex,
        item: {
          id: this.text.itemId,
          type: "message",
          status: "in_progress",
          role: "assistant",
          content: [],
        },
      });
      this.emit("response.content_part.added", {
        item_id: this.text.itemId,
        output_index: this.text.outputIndex,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] },
      });
    }
    this.text.text += delta;
    this.emit("response.output_text.delta", {
      item_id: this.text.itemId,
      output_index: this.text.outputIndex,
      content_index: 0,
      delta,
      logprobs: [],
    });
  }

  pushToolDelta(toolCall) {
    this.finishReasoning();
    this.ensureStarted();
    const index = Number(toolCall?.index) || 0;
    const state = this.tools.get(index) || {
      callId: "",
      name: "",
      arguments: "",
      added: false,
      outputIndex: -1,
      itemId: "",
    };
    if (toolCall?.id) state.callId = String(toolCall.id);
    if (toolCall?.function?.name) state.name = String(toolCall.function.name);
    const delta = String(toolCall?.function?.arguments || "");
    state.arguments += delta;
    if (!state.added && (state.callId || state.name)) {
      state.added = true;
      state.callId ||= `call_${index}`;
      state.name ||= "unknown_tool";
      state.outputIndex = this.nextOutputIndex++;
      const spec = this.toolContext.byChatName.get(state.name);
      const itemPrefix = spec?.kind === "custom" ? "ctc" : spec?.kind === "tool_search" ? "tsc" : "fc";
      state.itemId = `${itemPrefix}_${state.callId}`;
      this.emit("response.output_item.added", {
        output_index: state.outputIndex,
        item:
          spec?.kind === "custom"
            ? {
                id: state.itemId,
                type: "custom_tool_call",
                status: "in_progress",
                call_id: state.callId,
                name: spec.originalName,
                input: "",
              }
            : spec?.kind === "tool_search"
              ? {
                  id: state.itemId,
                  type: "tool_search_call",
                  status: "in_progress",
                  call_id: state.callId,
                  execution: spec.execution,
                  arguments: {},
                }
            : {
                id: state.itemId,
                type: "function_call",
                status: "in_progress",
                call_id: state.callId,
                name: spec?.originalName || state.name,
                arguments: "",
              },
      });
    }
    const spec = this.toolContext.byChatName.get(state.name);
    if (delta && state.added && spec?.kind !== "custom" && spec?.kind !== "tool_search") {
      this.emit("response.function_call_arguments.delta", {
        item_id: state.itemId,
        output_index: state.outputIndex,
        delta,
      });
    }
    this.tools.set(index, state);
  }

  handleChunk(chunk) {
    if (chunk?.id) this.id = responseId(chunk.id);
    if (chunk?.model) this.model = String(chunk.model);
    if (chunk?.created) this.createdAt = Number(chunk.created);
    if (chunk?.usage) this.usage = usageToResponses(chunk.usage);
    this.ensureStarted();

    const choice = Array.isArray(chunk?.choices) ? chunk.choices[0] : null;
    if (!choice) return;
    const delta = choice.delta || {};
    const reasoning = String(delta.reasoning_content || delta.reasoning || "");
    if (reasoning) this.pushReasoning(reasoning);
    if (typeof delta.content === "string" && delta.content) this.pushText(delta.content);
    for (const toolCall of Array.isArray(delta.tool_calls) ? delta.tool_calls : []) {
      this.pushToolDelta(toolCall);
    }
    if (choice.finish_reason) this.finishReason = String(choice.finish_reason);
  }

  finishText() {
    if (!this.text.added || this.text.done) return;
    this.text.done = true;
    const item = {
      id: this.text.itemId,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [{ type: "output_text", text: this.text.text, annotations: [] }],
    };
    this.output.push(item);
    this.emit("response.output_text.done", {
      item_id: this.text.itemId,
      output_index: this.text.outputIndex,
      content_index: 0,
      text: this.text.text,
      logprobs: [],
    });
    this.emit("response.content_part.done", {
      item_id: this.text.itemId,
      output_index: this.text.outputIndex,
      content_index: 0,
      part: item.content[0],
    });
    this.emit("response.output_item.done", { output_index: this.text.outputIndex, item });
  }

  finishTools() {
    for (const state of this.tools.values()) {
      if (!state.added) continue;
      const spec = this.toolContext.byChatName.get(state.name);
      const item = toolCallToResponseItem(
        {
          id: state.callId,
          function: { name: state.name, arguments: state.arguments },
        },
        this.toolContext,
      );
      if (spec?.kind === "custom") {
        this.emit("response.custom_tool_call_input.delta", {
          item_id: state.itemId,
          call_id: state.callId,
          output_index: state.outputIndex,
          delta: item.input,
        });
      } else if (spec?.kind !== "tool_search") {
        this.emit("response.function_call_arguments.done", {
          item_id: state.itemId,
          output_index: state.outputIndex,
          arguments: state.arguments,
        });
      }
      this.output.push(item);
      this.emit("response.output_item.done", { output_index: state.outputIndex, item });
    }
  }

  finish() {
    if (this.completed) return;
    this.ensureStarted();
    this.finishReasoning();
    this.finishText();
    this.finishTools();
    const status = this.finishReason === "length" ? "incomplete" : "completed";
    this.emit("response.completed", { response: this.currentResponse(status) });
    this.response.write("data: [DONE]\n\n");
    this.completed = true;
  }
}

function parseSseBlock(block) {
  const data = block
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart())
    .join("\n");
  return data;
}

async function pipeChatStreamToResponses(upstream, response, requestBody, toolContext) {
  response.writeHead(200, {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache, no-transform",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });
  response.flushHeaders?.();

  const converter = new ChatStreamConverter(response, requestBody, toolContext);
  const decoder = new TextDecoder();
  let buffer = "";
  for await (const chunk of upstream.body) {
    buffer += decoder.decode(chunk, { stream: true });
    while (true) {
      const match = buffer.match(/\r?\n\r?\n/);
      if (!match || match.index === undefined) break;
      const block = buffer.slice(0, match.index);
      buffer = buffer.slice(match.index + match[0].length);
      const data = parseSseBlock(block);
      if (!data || data === "[DONE]") continue;
      const value = JSON.parse(data);
      if (value.error) throw new Error(value.error.message || "Chat upstream stream failed");
      converter.handleChunk(value);
    }
  }
  buffer += decoder.decode();
  const finalData = parseSseBlock(buffer);
  if (finalData && finalData !== "[DONE]") converter.handleChunk(JSON.parse(finalData));
  converter.finish();
  response.end();
}

function loadProxyConfig(configPath) {
  try {
    const parsed = JSON.parse(fs.readFileSync(configPath, "utf8"));
    const upstreamBaseUrl = normalizeBaseUrl(parsed.upstreamBaseUrl);
    return {
      enabled: parsed.enabled === true && Boolean(upstreamBaseUrl),
      profileId: String(parsed.profileId || ""),
      profileName: String(parsed.profileName || ""),
      protocol: parsed.protocol === "responses" ? "responses" : "chat",
      upstreamBaseUrl,
      userAgent: String(parsed.userAgent || "DockerCodexSuite/ChatProxy"),
    };
  } catch {
    return {
      enabled: false,
      profileId: "",
      profileName: "",
      protocol: "chat",
      upstreamBaseUrl: "",
      userAgent: "DockerCodexSuite/ChatProxy",
    };
  }
}

function sendJson(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

async function pipeUpstreamResponse(upstream, response) {
  const headers = {};
  for (const name of ["cache-control", "content-type", "retry-after"]) {
    const value = upstream.headers.get(name);
    if (value) headers[name] = value;
  }
  response.writeHead(upstream.status, headers);
  if (!upstream.body) {
    response.end();
    return;
  }
  for await (const chunk of upstream.body) {
    response.write(Buffer.from(chunk));
  }
  response.end();
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_REQUEST_BYTES) {
        reject(new Error("Request body is too large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    request.on("error", reject);
  });
}

function upstreamHeaders(request, config) {
  const headers = {
    Accept: "application/json, text/event-stream",
    "Content-Type": "application/json",
    "User-Agent": config.userAgent,
  };
  for (const name of ["authorization", "x-api-key", "api-key"]) {
    const value = request.headers[name];
    if (value) headers[name] = value;
  }
  return headers;
}

async function fetchUpstream(url, options) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function proxyModels(request, response, config) {
  const upstream = await fetchUpstream(buildUpstreamEndpoint(config.upstreamBaseUrl, "models"), {
    method: "GET",
    headers: upstreamHeaders(request, config),
  });
  const body = Buffer.from(await upstream.arrayBuffer());
  response.writeHead(upstream.status, {
    "Content-Type": upstream.headers.get("content-type") || "application/json; charset=utf-8",
    "Content-Length": body.length,
  });
  response.end(body);
}

async function proxyNativeResponses(request, response, config) {
  const rawBody = await readRequestBody(request);
  const originalRequest = JSON.parse(rawBody || "{}");
  const normalized = sanitizeResponsesRequest(originalRequest);
  const upstream = await fetchUpstream(
    buildUpstreamEndpoint(config.upstreamBaseUrl, "responses"),
    {
      method: "POST",
      headers: upstreamHeaders(request, config),
      body: JSON.stringify(normalized.body),
    },
  );
  await pipeUpstreamResponse(upstream, response);
}

async function proxyResponses(request, response, config) {
  if (config.protocol === "responses") {
    await proxyNativeResponses(request, response, config);
    return;
  }
  const rawBody = await readRequestBody(request);
  const originalRequest = JSON.parse(rawBody || "{}");
  const converted = responsesToChatCompletions(originalRequest);
  const upstream = await fetchUpstream(
    buildUpstreamEndpoint(config.upstreamBaseUrl, "chat"),
    {
      method: "POST",
      headers: upstreamHeaders(request, config),
      body: JSON.stringify(converted.body),
    },
  );

  if (!upstream.ok) {
    const errorBody = Buffer.from(await upstream.arrayBuffer());
    response.writeHead(upstream.status, {
      "Content-Type": upstream.headers.get("content-type") || "application/json; charset=utf-8",
      "Content-Length": errorBody.length,
    });
    response.end(errorBody);
    return;
  }

  if (converted.body.stream) {
    await pipeChatStreamToResponses(upstream, response, originalRequest, converted.toolContext);
    return;
  }

  const chatBody = await upstream.json();
  sendJson(
    response,
    200,
    chatCompletionToResponse(chatBody, originalRequest, converted.toolContext),
  );
}

function createChatProxyServer(options) {
  const host = options.host || "127.0.0.1";
  const port = options.port === 0 ? 0 : Number(options.port) || 38119;
  const configPath = options.configPath;
  const onEvent = typeof options.onEvent === "function" ? options.onEvent : () => {};
  const server = http.createServer(async (request, response) => {
    const config = loadProxyConfig(configPath);
    const url = new URL(request.url || "/", `http://${host}:${port}`);
    try {
      if (request.method === "GET" && url.pathname === "/health") {
        sendJson(response, 200, {
          service: "docker-codex-chat-proxy",
          status: "ok",
          enabled: config.enabled,
          profileId: config.profileId,
          protocol: config.protocol,
        });
        return;
      }
      if (!config.enabled) {
        sendJson(response, 503, {
          error: { type: "chat_proxy_not_configured", message: "Chat proxy is not configured" },
        });
        return;
      }
      if (request.method === "GET" && /\/(?:v1\/)?models$/.test(url.pathname)) {
        await proxyModels(request, response, config);
        return;
      }
      if (
        request.method === "POST" &&
        /\/(?:v1\/)?responses(?:\/compact)?$/.test(url.pathname)
      ) {
        await proxyResponses(request, response, config);
        return;
      }
      sendJson(response, 404, { error: { type: "not_found", message: "Not found" } });
    } catch (error) {
      onEvent("chat_proxy_error", {
        profileId: config.profileId,
        message: error.message,
      });
      if (!response.headersSent) {
        sendJson(response, 502, {
          error: { type: "chat_proxy_error", message: error.message },
        });
      } else {
        response.destroy(error);
      }
    }
  });

  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, host, () => {
      onEvent("chat_proxy_started", { host, port });
      resolve(server);
    });
  });
}

module.exports = {
  ChatStreamConverter,
  buildToolContext,
  buildUpstreamEndpoint,
  chatCompletionToResponse,
  createChatProxyServer,
  loadProxyConfig,
  sanitizeResponsesRequest,
  responsesToChatCompletions,
  toolCallToResponseItem,
  usageToResponses,
};
