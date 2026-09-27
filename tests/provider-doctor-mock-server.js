"use strict";

const http = require("http");

const server = http.createServer((request, response) => {
  const chunks = [];
  request.on("data", (chunk) => chunks.push(chunk));
  request.on("end", () => {
    response.setHeader("Content-Type", "application/json");
    if (request.url === "/v1/models" && request.method === "GET") {
      response.end(JSON.stringify({ data: [{ id: "model-a" }, { id: "model-b" }] }));
      return;
    }
    if (request.url === "/v1/responses" && request.method === "POST") {
      response.end(JSON.stringify({ output_text: "OK responses" }));
      return;
    }
    if (request.url === "/v1/chat/completions" && request.method === "POST") {
      response.end(JSON.stringify({ choices: [{ message: { content: "OK chat" } }] }));
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not found" }));
  });
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  process.stdout.write(`MOCK_BASE_URL=http://127.0.0.1:${address.port}/v1\n`);
});

function close() {
  server.close(() => process.exit(0));
}

process.on("SIGINT", close);
process.on("SIGTERM", close);
