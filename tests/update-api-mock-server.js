"use strict";

const http = require("http");

function createMockServer(options = {}) {
  const suiteTag = options.suiteTag || "v9.9.9";
  const codexTag = options.codexTag || "rust-v0.151.0";
  const assetName = options.assetName || `DockerCodexSuite-Setup-${suiteTag.replace(/^v/, "")}-win-x64.exe`;
  const downloadBytes = Buffer.from("FAKE-SETUP-BYTES");

  const server = http.createServer((request, response) => {
    const url = new URL(request.url || "/", "http://127.0.0.1");
    if (url.pathname.endsWith("/suite/latest")) {
      const body = JSON.stringify({
        tag_name: suiteTag,
        name: suiteTag,
        assets: [
          {
            name: "SHA256SUMS.txt",
            browser_download_url: "http://127.0.0.1/download/sha256sums.txt",
          },
          {
            name: assetName,
            browser_download_url: "http://127.0.0.1/download/setup.exe",
          },
        ],
      });
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(body);
      return;
    }
    if (url.pathname.endsWith("/codex/latest")) {
      const body = JSON.stringify({
        tag_name: codexTag,
        name: codexTag,
      });
      response.writeHead(200, { "Content-Type": "application/json" });
      response.end(body);
      return;
    }
    if (url.pathname === "/download/setup.exe") {
      response.writeHead(200, { "Content-Type": "application/octet-stream" });
      response.end(downloadBytes);
      return;
    }
    response.writeHead(404, { "Content-Type": "application/json" });
    response.end(JSON.stringify({ message: "not found", path: url.pathname }));
  });

  return {
    server,
    start() {
      return new Promise((resolve) => {
        server.listen(0, "127.0.0.1", () => resolve(server.address().port));
      });
    },
    stop() {
      return new Promise((resolve) => server.close(resolve));
    },
    get baseUrl() {
      const address = server.address();
      return `http://127.0.0.1:${address.port}`;
    },
  };
}

if (require.main === module) {
  const mock = createMockServer({
    suiteTag: process.env.MOCK_SUITE_TAG || "v9.9.9",
    codexTag: process.env.MOCK_CODEX_TAG || "rust-v0.151.0",
  });
  mock.start().then(() => {
    console.log(`MOCK_PORT=${mock.server.address().port}`);
    if (process.env.MOCK_PORT_FILE) {
      require("fs").writeFileSync(process.env.MOCK_PORT_FILE, String(mock.server.address().port), "utf8");
    }
  });
}

module.exports = { createMockServer };