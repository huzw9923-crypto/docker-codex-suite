"use strict";

const assert = require("assert");
const vm = require("vm");
const { installMenu } = require("../src/controller/docker-codex-standalone-bridge.js");

function makeElement(kind) {
  return {
    kind,
    children: [],
    dataset: {},
    style: {},
    listeners: {},
    textContent: "",
    className: "",
    parentElement: null,
    setAttribute() {},
    addEventListener(name, fn) {
      if (!this.listeners[name]) this.listeners[name] = [];
      this.listeners[name].push(fn);
    },
    removeEventListener() {},
    appendChild(child) {
      this.children.push(child);
      child.parentElement = this;
    },
    remove() {},
    getBoundingClientRect() {
      return { width: 60, height: 20, top: 6, bottom: 26, left: 0 };
    },
  };
}

function makeDocument(labels) {
  const row = makeElement("div");
  const buttons = labels.map((text) => {
    const button = makeElement("button");
    button.textContent = text;
    button.className = "no-drag rounded-md";
    row.appendChild(button);
    return button;
  });
  return {
    body: makeElement("body"),
    head: makeElement("head"),
    createElement(kind) {
      return makeElement(kind);
    },
    querySelectorAll(selector) {
      if (selector === "button") return buttons;
      return [];
    },
    addEventListener() {},
    removeEventListener() {},
  };
}

function runInstall(labels) {
  const context = {
    document: makeDocument(labels),
    window: { addEventListener() {}, removeEventListener() {} },
    getComputedStyle: () => ({ display: "block", visibility: "visible" }),
    console: { info() {} },
    performance: { now: () => 0 },
  };
  return vm.runInNewContext(
    `(${installMenu.toString()})("M", "test-version", "test-session")`,
    context,
  );
}

async function main() {
  const zh = runInstall(["文件", "编辑", "视图", "帮助"]);
  assert.strictEqual(zh.status, "installed");
  assert.strictEqual(zh.placement, "menu-bar");

  const en = runInstall(["File", "Edit", "View", "Help"]);
  assert.strictEqual(en.status, "installed");
  assert.strictEqual(en.placement, "menu-bar");

  const ja = runInstall(["ファイル", "編集", "表示", "ヘルプ"]);
  assert.strictEqual(ja.status, "waiting");

  const sparse = runInstall(["File", "Edit"]);
  assert.strictEqual(sparse.status, "waiting");

  process.stdout.write("Bridge menu injection tests: PASS\n");
}

main().catch((error) => {
  process.stderr.write(`${error.stack || error.message}\n`);
  process.exitCode = 1;
});