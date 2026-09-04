// Astra-only conservative budgets, exercised against a local mock at real budget sizes.
// No provider calls: both gateway and upstream bind ephemeral localhost ports.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

let upstream;
let gateway;
let api;
let url;
let tmpHome;
let requests = [];
let mockCeiling = 0;

function filler(tokens) {
  return "word ".repeat(Math.ceil((tokens * 3.6) / 5));
}

before(async () => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "solgate-astra-bounds-"));
  upstream = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      if (req.url === "/v1/models") {
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({ data: [{ id: "gpt-6-astra" }, { id: "gpt-5.6-sol" }] }));
      }
      const body = JSON.parse(raw);
      requests.push(body);
      if (body.model === "gpt-6-astra" && mockCeiling && api.totalTokens(body.messages) > mockCeiling) {
        res.writeHead(400, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { code: "context_too_large" } }));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ model: body.model, choices: [{ message: { content: "MOCK-OK" } }] }));
    });
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  process.env.SOLGATE_UPSTREAM = `http://127.0.0.1:${upstream.address().port}`;
  process.env.SOLGATE_UPSTREAM_LUNA = process.env.SOLGATE_UPSTREAM;
  process.env.SOLGATE_HOME = tmpHome;
  process.env.SOLGATE_COMPACT_TRIGGER = "300000";
  process.env.SOLGATE_KEEP_RECENT = "200000";
  process.env.SOLGATE_HARD_CEILING = "330000";
  api = await import("../server.mjs");
  gateway = api.createServer();
  await new Promise((resolve) => gateway.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${gateway.address().port}`;
});

after(async () => {
  await Promise.all([gateway, upstream].filter(Boolean).map((server) => new Promise((resolve) => {
    server.closeAllConnections();
    server.close(resolve);
  })));
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

async function chat(body) {
  requests = [];
  return fetch(`${url}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "gpt-6-astra-1m", ...body }),
  });
}

test("Astra 220k 미만은 원문 그대로 실제 Astra에 전달", async () => {
  const messages = [{ role: "user", content: filler(180_000) }];
  const response = await chat({ messages });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).model, "gpt-6-astra");
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0].messages, messages);
});

test("Astra는 220k를 넘으면 300k 전에도 요약하고 tools 포함 240k 이하로 전달", async () => {
  const messages = [{ role: "system", content: "system" }];
  for (let i = 0; i < 8; i += 1) {
    messages.push({ role: "user", content: `u${i} ${filler(14_500)}` });
    messages.push({ role: "assistant", content: `a${i} ${filler(14_500)}` });
  }
  messages.push({ role: "user", content: "RECENT-ASTRA" });
  const tools = [{ type: "function", function: { name: "lookup", description: filler(20_000),
    parameters: { type: "object", properties: {} } } }];
  assert.ok(api.totalTokens(messages) > 220_000);
  assert.ok(api.totalTokens(messages) < 300_000);
  const response = await chat({ messages, tools });
  assert.equal(response.status, 200);
  await response.json();
  const summaries = requests.filter((body) => body.model !== "gpt-6-astra");
  assert.ok(summaries.length > 0, "must summarize before upstream at Astra threshold");
  assert.ok(summaries.every((body) => ["gpt-5.6-terra", "gpt-5.6-luna"].includes(body.model)));
  const main = requests.at(-1);
  assert.equal(main.model, "gpt-6-astra");
  assert.ok(api.totalTokens(main.messages) + api.estimateTokens(JSON.stringify(main.tools)) <= 240_000);
  assert.equal(main.messages.at(-1).content, "RECENT-ASTRA");
  assert.deepEqual(main.messages[0], messages[0]);
  assert.deepEqual(main.tools, tools);
});

test("Astra tools만 240k 초과이면 upstream 호출 없이 400 반환", async () => {
  const tools = [{ type: "function", function: { name: "huge", description: filler(250_000) } }];
  const response = await chat({ messages: [{ role: "user", content: "go" }], tools });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "context_too_large");
  assert.equal(requests.length, 0);
});

test("Astra 모델 설명은 실 profile의 220k 요약 시점을 표시", async () => {
  const models = await (await fetch(`${url}/v1/models`)).json();
  const astra = models.data.filter((model) => model.id === "gpt-6-astra-1m");
  assert.equal(astra.length, 1);
  assert.equal(astra[0].context_length, 1_000_000);
  assert.match(astra[0].description, /220000 estimated tokens/);
});

test("Astra 실제 상한이 추정보다 작으면 더 작은 입력으로 재시도하고 Astra를 유지", async () => {
  mockCeiling = 8_000;
  try {
    const messages = [{ role: "system", content: "system" }];
    for (let i = 0; i < 16; i += 1) {
      messages.push({ role: "user", content: `retry-u${i} ${filler(1_000)}` });
      messages.push({ role: "assistant", content: `retry-a${i} ${filler(1_000)}` });
    }
    const response = await chat({ messages });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).model, "gpt-6-astra");
    const main = requests.filter((body) => body.model === "gpt-6-astra");
    assert.ok(main.length > 1 && main.length <= 4);
    const sizes = main.map((body) => api.totalTokens(body.messages));
    for (let i = 1; i < sizes.length; i += 1) assert.ok(sizes[i] < sizes[i - 1]);
    assert.ok(sizes.at(-1) <= mockCeiling);
    assert.ok(requests.every((body) => ["gpt-6-astra", "gpt-5.6-terra", "gpt-5.6-luna"].includes(body.model)));
  } finally {
    mockCeiling = 0;
  }
});
