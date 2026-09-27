"use strict";

const dns = require("dns");
const http = require("http");
const https = require("https");
const net = require("net");
const tls = require("tls");

const DEFAULT_TIMEOUT_MS = 20000;
const MAX_MODELS = 500;
const MAX_DOH_RESPONSE_BYTES = 1024 * 1024;
const MAX_API_RESPONSE_BYTES = 32 * 1024 * 1024;
const MAX_FALLBACK_ADDRESSES = 3;
const PUBLIC_DOH_ADDRESSES = ["1.1.1.1", "1.0.0.1"];
const PUBLIC_DOH_HOSTNAME = "cloudflare-dns.com";
const COMMON_LOCAL_HTTP_PROXY_PORTS = [7897, 7890, 10809];

function normalizeProtocol(value) {
  const protocol = String(value || "responses").trim().toLowerCase();
  if (protocol === "responses" || protocol === "chat") return protocol;
  throw new Error(`unsupported upstream protocol: ${protocol}`);
}

function buildEndpoint(baseUrl, resource) {
  const url = new URL(String(baseUrl || "").trim());
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error("Base URL must use http or https");
  }

  url.hash = "";
  let pathname = url.pathname.replace(/\/+$/, "");
  const knownSuffixes = ["/chat/completions", "/responses", "/models"];
  for (const suffix of knownSuffixes) {
    if (pathname.toLowerCase().endsWith(suffix)) {
      pathname = pathname.slice(0, -suffix.length);
      break;
    }
  }
  if (!pathname) pathname = "/v1";

  const suffix =
    resource === "models"
      ? "/models"
      : resource === "chat"
        ? "/chat/completions"
        : "/responses";
  url.pathname = `${pathname}${suffix}`.replace(/\/+/g, "/");
  return url.toString();
}

function requestHeaders(apiKey) {
  const headers = {
    Accept: "application/json",
    "Content-Type": "application/json",
    "User-Agent": "DockerCodexSuite/1.0 ProviderDoctor",
  };
  const key = String(apiKey || "").trim();
  if (key) headers.Authorization = `Bearer ${key}`;
  return headers;
}

function safePreview(value, limit = 500) {
  return String(value || "")
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, "Bearer [redacted]")
    .replace(/sk-[A-Za-z0-9_-]{8,}/g, "sk-[redacted]")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, limit);
}

function describeNetworkError(error) {
  const rootCause = error?.cause;
  const causes = Array.isArray(rootCause?.errors)
    ? rootCause.errors
    : rootCause
      ? [rootCause]
      : [error];
  const codes = [];
  const messages = [];
  for (const cause of causes) {
    const code = String(cause?.code || cause?.errno || "").trim();
    const message = String(cause?.message || "").trim();
    if (code && !codes.includes(code)) codes.push(code);
    if (message && !messages.includes(message)) messages.push(message);
  }
  const fallback = String(error?.message || error || "Network request failed");
  const message = messages.length > 0 ? messages.join("; ") : fallback;
  return {
    code: codes.join(","),
    message: safePreview(codes.length > 0 ? `${message} (${codes.join(", ")})` : message),
  };
}

function shouldRetryNetworkError(error) {
  const codes = describeNetworkError(error).code.split(",").filter(Boolean);
  return codes.some((code) =>
    ["UND_ERR_CONNECT_TIMEOUT", "ENOTFOUND", "EAI_AGAIN", "ECONNREFUSED"].includes(code),
  );
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function isFakeIpAddress(value) {
  const address = String(value || "").trim();
  if (!net.isIPv4(address)) return false;
  const octets = address.split(".").map(Number);
  return octets[0] === 198 && (octets[1] === 18 || octets[1] === 19);
}

function normalizeIpv4Addresses(value) {
  const entries = Array.isArray(value) ? value : value ? [value] : [];
  const seen = new Set();
  const addresses = [];
  for (const entry of entries) {
    const address = String(typeof entry === "string" ? entry : entry?.address || "").trim();
    if (!net.isIPv4(address) || seen.has(address)) continue;
    seen.add(address);
    addresses.push(address);
  }
  return addresses;
}

function parseHttpProxyCandidate(value) {
  const raw = String(value || "").trim();
  if (!raw) return null;
  try {
    const url = new URL(raw.includes("://") ? raw : `http://${raw}`);
    if (url.protocol !== "http:") return null;
    const hostname = url.hostname;
    const port = Number(url.port || 80);
    if (!hostname || !Number.isInteger(port) || port < 1 || port > 65535) return null;
    const username = decodeURIComponent(url.username || "");
    const password = decodeURIComponent(url.password || "");
    return {
      hostname,
      port,
      authorization:
        username || password
          ? `Basic ${Buffer.from(`${username}:${password}`, "utf8").toString("base64")}`
          : undefined,
    };
  } catch {
    return null;
  }
}

function collectHttpProxyCandidates(environment = process.env) {
  const candidates = [];
  const seen = new Set();
  const add = (candidate) => {
    if (!candidate) return;
    const key = `${candidate.hostname.toLowerCase()}:${candidate.port}`;
    if (seen.has(key)) return;
    seen.add(key);
    candidates.push(candidate);
  };

  const environmentEntries = Object.entries(environment || {});
  for (const name of ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"]) {
    const entry = environmentEntries.find(([key]) => key.toUpperCase() === name);
    if (entry) add(parseHttpProxyCandidate(entry[1]));
  }
  for (const port of COMMON_LOCAL_HTTP_PROXY_PORTS) {
    add({ hostname: "127.0.0.1", port });
  }
  return candidates;
}

async function lookupIpv4Addresses(hostname) {
  if (net.isIPv4(hostname)) return [hostname];
  const result = await dns.promises.lookup(hostname, {
    all: true,
    family: 4,
    verbatim: true,
  });
  return normalizeIpv4Addresses(result);
}

function requestBuffer(requestModule, requestOptions, body, timeoutMs, maxBytes) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let absoluteTimer = null;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      if (absoluteTimer) clearTimeout(absoluteTimer);
      if (error) reject(error);
      else resolve(result);
    };

    const request = requestModule.request(requestOptions, (response) => {
      const chunks = [];
      let totalBytes = 0;
      response.on("data", (chunk) => {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        totalBytes += buffer.length;
        if (totalBytes > maxBytes) {
          const error = new Error(`Response exceeded ${maxBytes} bytes`);
          error.code = "ERR_RESPONSE_TOO_LARGE";
          response.destroy(error);
          finish(error);
          return;
        }
        chunks.push(buffer);
      });
      response.once("error", (error) => finish(error));
      response.once("end", () => {
        finish(null, {
          statusCode: Number(response.statusCode) || 0,
          headers: response.headers,
          body: Buffer.concat(chunks),
        });
      });
    });

    request.once("error", (error) => finish(error));
    absoluteTimer = setTimeout(() => {
      const error = new Error(`Request timed out after ${timeoutMs} ms`);
      error.code = "ETIMEDOUT";
      request.destroy(error);
    }, timeoutMs);
    request.setTimeout(timeoutMs, () => {
      const error = new Error(`Request timed out after ${timeoutMs} ms`);
      error.code = "ETIMEDOUT";
      request.destroy(error);
    });
    if (body !== undefined && body !== null && body !== "") request.write(body);
    request.end();
  });
}

function collectDohIpv4Addresses(payload) {
  if (Number(payload?.Status) !== 0) {
    const error = new Error(`Public DNS returned status ${payload?.Status ?? "unknown"}`);
    error.code = "DOH_DNS_ERROR";
    throw error;
  }
  return normalizeIpv4Addresses(
    (Array.isArray(payload?.Answer) ? payload.Answer : [])
      .filter((answer) => Number(answer?.type) === 1)
      .map((answer) => answer?.data),
  ).filter((address) => !isFakeIpAddress(address));
}

async function resolvePublicIpv4WithDoh(
  hostname,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  requestBufferImpl = requestBuffer,
) {
  let lastError = null;
  for (const bootstrapAddress of PUBLIC_DOH_ADDRESSES) {
    try {
      const response = await requestBufferImpl(
        https,
        {
          hostname: bootstrapAddress,
          port: 443,
          method: "GET",
          path: `/dns-query?name=${encodeURIComponent(hostname)}&type=A`,
          servername: PUBLIC_DOH_HOSTNAME,
          rejectUnauthorized: true,
          agent: false,
          headers: {
            Accept: "application/dns-json",
            Host: PUBLIC_DOH_HOSTNAME,
            "User-Agent": "DockerCodexSuite/1.0 ProviderDoctor",
          },
        },
        null,
        timeoutMs,
        MAX_DOH_RESPONSE_BYTES,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        const error = new Error(`Public DNS returned HTTP ${response.statusCode}`);
        error.code = "DOH_HTTP_ERROR";
        throw error;
      }
      const addresses = collectDohIpv4Addresses(JSON.parse(response.body.toString("utf8")));
      if (addresses.length === 0) {
        const error = new Error("Public DNS did not return a usable IPv4 address");
        error.code = "DOH_EMPTY_ANSWER";
        throw error;
      }
      return addresses;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError || new Error("Public DNS lookup failed");
}

async function requestEndpointByAddress(endpoint, options, address, timeoutMs = DEFAULT_TIMEOUT_MS) {
  if (!net.isIPv4(address)) throw new Error(`Invalid fallback IPv4 address: ${address}`);
  const url = new URL(endpoint);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`Unsupported fallback protocol: ${url.protocol}`);
  }

  const body = options?.body;
  const headers = { ...(options?.headers || {}), Host: url.host };
  const hasContentLength = Object.keys(headers).some(
    (name) => name.toLowerCase() === "content-length",
  );
  if (body !== undefined && body !== null && !hasContentLength) {
    headers["Content-Length"] = Buffer.byteLength(body);
  }

  const requestOptions = {
    hostname: address,
    port: url.port || (url.protocol === "https:" ? 443 : 80),
    method: options?.method || "GET",
    path: `${url.pathname}${url.search}`,
    headers,
    agent: false,
  };
  if (url.protocol === "https:") {
    requestOptions.servername = url.hostname;
    requestOptions.rejectUnauthorized = true;
  }

  const response = await requestBuffer(
    url.protocol === "https:" ? https : http,
    requestOptions,
    body,
    timeoutMs,
    MAX_API_RESPONSE_BYTES,
  );
  return {
    ok: response.statusCode >= 200 && response.statusCode < 300,
    status: response.statusCode,
    headers: response.headers,
    text: async () => response.body.toString("utf8"),
  };
}

function formatProxyAddress(proxy) {
  const hostname = String(proxy?.hostname || "").trim();
  const displayHost = net.isIPv6(hostname) ? `[${hostname}]` : hostname;
  return `${displayHost}:${Number(proxy?.port) || 0}`;
}

function openHttpProxyTunnel(proxy, targetHostname, targetPort, timeoutMs) {
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer = null;
    const finish = (error, socket) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      if (error) reject(error);
      else resolve(socket);
    };
    const authority = `${targetHostname}:${targetPort}`;
    const headers = {
      Host: authority,
      "Proxy-Connection": "Keep-Alive",
      "User-Agent": "DockerCodexSuite/1.0 ProviderDoctor",
    };
    if (proxy.authorization) headers["Proxy-Authorization"] = proxy.authorization;

    const request = http.request({
      hostname: proxy.hostname,
      port: proxy.port,
      method: "CONNECT",
      path: authority,
      headers,
      agent: false,
    });
    request.once("connect", (response, socket, head) => {
      if (response.statusCode !== 200) {
        socket.destroy();
        const error = new Error(`HTTP proxy CONNECT returned ${response.statusCode}`);
        error.code = `PROXY_CONNECT_${response.statusCode || "ERROR"}`;
        finish(error);
        return;
      }
      if (head?.length) socket.unshift(head);
      finish(null, socket);
    });
    request.once("error", (error) => finish(error));
    timer = setTimeout(() => {
      const error = new Error(`HTTP proxy CONNECT timed out after ${timeoutMs} ms`);
      error.code = "PROXY_CONNECT_TIMEOUT";
      request.destroy(error);
    }, timeoutMs);
    request.end();
  });
}

function openTlsTunnel(socket, servername, timeoutMs) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const secureSocket = tls.connect({ socket, servername, rejectUnauthorized: true });
    const timer = setTimeout(() => {
      const error = new Error(`TLS handshake timed out after ${timeoutMs} ms`);
      error.code = "TLS_HANDSHAKE_TIMEOUT";
      secureSocket.destroy(error);
    }, timeoutMs);
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      secureSocket.removeListener("secureConnect", onSecureConnect);
      secureSocket.removeListener("error", onError);
      if (error) reject(error);
      else resolve(secureSocket);
    };
    const onSecureConnect = () => finish(null);
    const onError = (error) => finish(error);
    secureSocket.once("secureConnect", onSecureConnect);
    secureSocket.once("error", onError);
  });
}

async function requestEndpointThroughHttpProxy(
  endpoint,
  options,
  proxy,
  timeoutMs = DEFAULT_TIMEOUT_MS,
) {
  const url = new URL(endpoint);
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new Error(`Unsupported proxy fallback protocol: ${url.protocol}`);
  }
  if (!proxy?.hostname || !Number.isInteger(Number(proxy?.port))) {
    throw new Error("Invalid HTTP proxy candidate");
  }

  const body = options?.body;
  const headers = { ...(options?.headers || {}), Host: url.host };
  const hasContentLength = Object.keys(headers).some(
    (name) => name.toLowerCase() === "content-length",
  );
  if (body !== undefined && body !== null && !hasContentLength) {
    headers["Content-Length"] = Buffer.byteLength(body);
  }

  let response;
  if (url.protocol === "http:") {
    if (proxy.authorization) headers["Proxy-Authorization"] = proxy.authorization;
    response = await requestBuffer(
      http,
      {
        hostname: proxy.hostname,
        port: proxy.port,
        method: options?.method || "GET",
        path: url.toString(),
        headers,
        agent: false,
      },
      body,
      timeoutMs,
      MAX_API_RESPONSE_BYTES,
    );
  } else {
    const targetPort = Number(url.port || 443);
    const tunnel = await openHttpProxyTunnel(
      proxy,
      url.hostname,
      targetPort,
      Math.min(timeoutMs, 2000),
    );
    let secureSocket = null;
    try {
      secureSocket = await openTlsTunnel(tunnel, url.hostname, Math.min(timeoutMs, 5000));
      response = await requestBuffer(
        https,
        {
          hostname: url.hostname,
          port: targetPort,
          method: options?.method || "GET",
          path: `${url.pathname}${url.search}`,
          headers,
          servername: url.hostname,
          rejectUnauthorized: true,
          createConnection: () => secureSocket,
          agent: false,
        },
        body,
        timeoutMs,
        MAX_API_RESPONSE_BYTES,
      );
    } catch (error) {
      if (secureSocket) secureSocket.destroy();
      else tunnel.destroy();
      throw error;
    }
  }

  return {
    ok: response.statusCode >= 200 && response.statusCode < 300,
    status: response.statusCode,
    headers: response.headers,
    text: async () => response.body.toString("utf8"),
  };
}

function resolveDoctorDependencies(overrides = {}) {
  const hasProxyCandidates = Object.prototype.hasOwnProperty.call(overrides, "proxyCandidates");
  return {
    lookupHost: overrides.lookupHost || lookupIpv4Addresses,
    proxyCandidates: hasProxyCandidates ? overrides.proxyCandidates : collectHttpProxyCandidates(),
    proxyRequest: overrides.proxyRequest || requestEndpointThroughHttpProxy,
    resolvePublicIpv4: overrides.resolvePublicIpv4 || resolvePublicIpv4WithDoh,
    directRequest: overrides.directRequest || requestEndpointByAddress,
    delay: overrides.delay || delay,
  };
}

function collectModelIds(payload) {
  const candidates = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.data)
      ? payload.data
      : Array.isArray(payload?.models)
        ? payload.models
        : Array.isArray(payload?.result)
          ? payload.result
          : [];
  const seen = new Set();
  const models = [];
  for (const item of candidates) {
    const id =
      typeof item === "string"
        ? item
        : item && typeof item === "object"
          ? item.id || item.model || item.name
          : "";
    const normalized = String(id || "").trim();
    if (!normalized || seen.has(normalized)) continue;
    seen.add(normalized);
    models.push(normalized);
    if (models.length >= MAX_MODELS) break;
  }
  return models;
}

function responseText(payload, protocol) {
  if (protocol === "chat") {
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content === "string") return content;
    if (Array.isArray(content)) {
      return content.map((part) => part?.text || part?.content || "").join(" ");
    }
  }

  if (typeof payload?.output_text === "string") return payload.output_text;
  const output = Array.isArray(payload?.output) ? payload.output : [];
  const parts = [];
  for (const item of output) {
    for (const content of Array.isArray(item?.content) ? item.content : []) {
      if (typeof content?.text === "string") parts.push(content.text);
      else if (typeof content?.output_text === "string") parts.push(content.output_text);
    }
  }
  return parts.join(" ");
}

async function fetchWithTimeout(url, options, timeoutMs, fetchImpl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

async function readPayload(response) {
  const text = await response.text();
  if (!text) return { text: "", json: null };
  try {
    return { text, json: JSON.parse(text) };
  } catch {
    return { text, json: null };
  }
}

async function runDoctor(input, fetchImpl = globalThis.fetch, dependencyOverrides = {}) {
  const dependencies = resolveDoctorDependencies(dependencyOverrides);
  const action = String(input?.action || "").trim().toLowerCase();
  const protocol = normalizeProtocol(input?.protocol);
  const baseUrl = String(input?.baseUrl || "").trim();
  const apiKey = String(input?.apiKey || "").trim();
  const model = String(input?.model || "").trim();
  const timeoutMs = Math.max(1000, Number(input?.timeoutMs) || DEFAULT_TIMEOUT_MS);
  if (!baseUrl) throw new Error("Base URL is required");
  if (action !== "models" && action !== "test") {
    throw new Error(`unsupported doctor action: ${action}`);
  }
  if (action === "test" && !model) throw new Error("Model is required");

  const endpoint =
    action === "models"
      ? buildEndpoint(baseUrl, "models")
      : buildEndpoint(baseUrl, protocol === "chat" ? "chat" : "responses");
  const startedAt = Date.now();
  const options = {
    method: action === "models" ? "GET" : "POST",
    headers: requestHeaders(apiKey),
  };
  if (action === "test") {
    options.body = JSON.stringify(
      protocol === "chat"
        ? {
            model,
            messages: [{ role: "user", content: "Reply with OK." }],
            stream: false,
            max_tokens: 16,
          }
        : {
            model,
            input: [
              {
                role: "user",
                content: [{ type: "input_text", text: "Reply with OK." }],
              },
            ],
            stream: false,
            max_output_tokens: 16,
          },
    );
  }

  const endpointUrl = new URL(endpoint);
  const endpointHostname = endpointUrl.hostname;
  const canResolvePublicAddress = net.isIP(endpointHostname) === 0;
  const localLookupPromise = canResolvePublicAddress
    ? Promise.resolve()
        .then(() => dependencies.lookupHost(endpointHostname))
        .then(
          (result) => ({ addresses: normalizeIpv4Addresses(result), error: null }),
          (error) => ({ addresses: [], error }),
        )
    : Promise.resolve({ addresses: normalizeIpv4Addresses(endpointHostname), error: null });

  let response = null;
  let lastNetworkError = null;
  let localDnsAddresses = [];
  let localLookupObserved = false;
  let fakeIpDetected = false;
  let normalAttempts = 0;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    normalAttempts = attempt;
    try {
      response = await fetchWithTimeout(endpoint, options, timeoutMs, fetchImpl);
      break;
    } catch (error) {
      lastNetworkError = error;
      if (!localLookupObserved) {
        const localLookup = await localLookupPromise;
        localLookupObserved = true;
        localDnsAddresses = localLookup.addresses;
        fakeIpDetected = localDnsAddresses.some(isFakeIpAddress);
      }
      if (fakeIpDetected && canResolvePublicAddress) break;
      if (attempt >= 2 || error?.name === "AbortError" || !shouldRetryNetworkError(error)) {
        break;
      }
      await dependencies.delay(300);
    }
  }

  const normalNetworkFailure = describeNetworkError(lastNetworkError);
  let transport = "system-network";
  let proxyAddress;
  let resolvedAddress;
  let resolvedAddresses = [];
  let proxyAttempts = 0;
  let directAttempts = 0;
  const fallbackAttempts = [];

  if (!response && fakeIpDetected && canResolvePublicAddress) {
    const proxyCandidates = Array.isArray(dependencies.proxyCandidates)
      ? dependencies.proxyCandidates.slice(0, 5)
      : [];
    for (const proxy of proxyCandidates) {
      proxyAttempts += 1;
      const candidateAddress = formatProxyAddress(proxy);
      try {
        response = await dependencies.proxyRequest(endpoint, options, proxy, timeoutMs);
        transport = "local-proxy-fallback";
        proxyAddress = candidateAddress;
        fallbackAttempts.push({
          stage: "local-proxy",
          address: candidateAddress,
          ok: true,
          httpStatus: Number(response?.status) || 0,
        });
        break;
      } catch (error) {
        lastNetworkError = error;
        const failure = describeNetworkError(error);
        fallbackAttempts.push({
          stage: "local-proxy",
          address: candidateAddress,
          ok: false,
          error: failure.message,
          networkCode: failure.code || undefined,
        });
      }
    }

    if (!response) {
      transport = "public-dns-fallback";
      try {
        resolvedAddresses = normalizeIpv4Addresses(
          await dependencies.resolvePublicIpv4(endpointHostname, timeoutMs),
        )
          .filter((address) => !isFakeIpAddress(address))
          .slice(0, MAX_FALLBACK_ADDRESSES);
        if (resolvedAddresses.length === 0) {
          const error = new Error("Public DNS did not return a usable IPv4 address");
          error.code = "DOH_EMPTY_ANSWER";
          throw error;
        }
        fallbackAttempts.push({
          stage: "public-dns",
          ok: true,
          addresses: resolvedAddresses,
        });

        for (const address of resolvedAddresses) {
          directAttempts += 1;
          resolvedAddress = address;
          try {
            response = await dependencies.directRequest(endpoint, options, address, timeoutMs);
            fallbackAttempts.push({
              stage: "direct-request",
              address,
              ok: true,
              httpStatus: Number(response?.status) || 0,
            });
            break;
          } catch (error) {
            lastNetworkError = error;
            const failure = describeNetworkError(error);
            fallbackAttempts.push({
              stage: "direct-request",
              address,
              ok: false,
              error: failure.message,
              networkCode: failure.code || undefined,
            });
          }
        }
      } catch (error) {
        lastNetworkError = error;
        const failure = describeNetworkError(error);
        fallbackAttempts.push({
          stage: "public-dns",
          ok: false,
          error: failure.message,
          networkCode: failure.code || undefined,
        });
      }
    }
  }

  const attempts = normalAttempts + proxyAttempts + directAttempts;
  const networkMetadata = {
    transport,
    normalAttempts,
  };
  if (fakeIpDetected) {
    networkMetadata.fakeIpDetected = true;
    networkMetadata.localAddress = localDnsAddresses.find(isFakeIpAddress);
  }
  if (transport !== "system-network") {
    if (transport === "local-proxy-fallback") {
      networkMetadata.proxyAddress = proxyAddress;
    } else {
      networkMetadata.resolvedAddress = resolvedAddress;
      networkMetadata.resolvedAddresses = resolvedAddresses;
    }
    networkMetadata.fallbackAttempts = fallbackAttempts;
    networkMetadata.normalError = normalNetworkFailure.message;
    networkMetadata.normalNetworkCode = normalNetworkFailure.code || undefined;
  }

  if (!response) {
    const networkError = describeNetworkError(lastNetworkError);
    return {
      ok: false,
      action,
      protocol,
      endpoint,
      durationMs: Date.now() - startedAt,
      attempts,
      error: lastNetworkError?.name === "AbortError" ? "Request timed out" : networkError.message,
      networkCode: networkError.code || undefined,
      ...networkMetadata,
    };
  }

  const payload = await readPayload(response);
  const common = {
    ok: response.ok,
    action,
    protocol,
    endpoint,
    httpStatus: response.status,
    durationMs: Date.now() - startedAt,
    attempts,
    ...networkMetadata,
  };
  if (!response.ok) {
    return {
      ...common,
      error: `HTTP ${response.status}`,
      preview: safePreview(payload.text),
    };
  }

  if (action === "models") {
    const models = collectModelIds(payload.json);
    if (models.length === 0) {
      return {
        ...common,
        ok: false,
        error: "The upstream response did not contain a recognizable model list",
        preview: safePreview(payload.text),
      };
    }
    return { ...common, models, modelCount: models.length };
  }

  return {
    ...common,
    preview: safePreview(responseText(payload.json, protocol) || payload.text),
  };
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8").trim();
}

async function main() {
  try {
    const raw = await readStdin();
    const input = raw ? JSON.parse(raw) : {};
    const result = await runDoctor(input);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } catch (error) {
    process.stdout.write(
      `${JSON.stringify({ ok: false, error: String(error?.message || error) })}\n`,
    );
    process.exitCode = 1;
  }
}

module.exports = {
  buildEndpoint,
  collectHttpProxyCandidates,
  collectDohIpv4Addresses,
  collectModelIds,
  describeNetworkError,
  isFakeIpAddress,
  lookupIpv4Addresses,
  normalizeProtocol,
  requestEndpointByAddress,
  requestEndpointThroughHttpProxy,
  resolvePublicIpv4WithDoh,
  runDoctor,
  safePreview,
  shouldRetryNetworkError,
};

if (require.main === module) {
  main();
}
