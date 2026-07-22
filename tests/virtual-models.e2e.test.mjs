// 3종 virtual 1M profile E2E — 정확한 physical base, rolling compression, sticky/fallback 검증.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MOCK_PORT = 8401;
const GATE_PORT = 8400;
const bases = new Map([
  ["gpt-5.6-sol-1m", "gpt-5.6-sol"],
  ["gpt-5.6-terra-1m", "gpt-5.6-terra"],
  ["gpt-5.6-luna-1m", "gpt-5.6-luna"],
]);
let mock;
let child;
let tmpHome;
let requests = [];

function filler(tokens) {
  return "word ".repeat(Math.ceil((tokens * 3.6) / 5));
}

function mockUpstream() {
  return http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", () => {
      if (req.url === "/v1/models") {
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({
          object: "list",
          data: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].map((id) => ({ id })),
        }));
      }
      const body = JSON.parse(raw || "{}");
      requests = [...requests, body];
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const isSummary = messages.length === 2 && messages[0]?.role === "system";
      if (isSummary) {
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({ choices: [{ message: { content: `SUMMARY-${body.model}` } }] }));
      }
      if (messages[0]?.content === "force-terra-limit") {
        res.writeHead(429, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { type: "model_cooldown", message: "sticky terra" } }));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ choices: [{ message: { content: `OK-${body.model}` } }] }));
    });
  });
}

before(async () => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "solgate-virtuals-"));
  mock = mockUpstream();
  await new Promise((resolve) => mock.listen(MOCK_PORT, "127.0.0.1", resolve));
  child = spawn(process.execPath, [new URL("../server.mjs", import.meta.url).pathname], {
    env: {
      ...process.env,
      SOLGATE_PORT: String(GATE_PORT),
      SOLGATE_UPSTREAM: `http://127.0.0.1:${MOCK_PORT}`,
      SOLGATE_UPSTREAM_LUNA: `http://127.0.0.1:${MOCK_PORT}`,
      SOLGATE_HOME: tmpHome,
      SOLGATE_COMPACT_TRIGGER: "10000",
      SOLGATE_HARD_CEILING: "11000",
      SOLGATE_KEEP_RECENT: "4000",
      SOLGATE_CHUNK_TOKENS: "2000",
    },
    stdio: "ignore",
  });
  for (let i = 0; i < 50; i += 1) {
    try {
      if ((await fetch(`http://127.0.0.1:${GATE_PORT}/healthz`)).ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("solgate virtual model test instance did not start");
});

after(() => {
  child?.kill();
  mock?.close();
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

async function chat(model, messages) {
  return fetch(`http://127.0.0.1:${GATE_PORT}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model, messages }),
  });
}

for (const [virtualId, baseModel] of bases) {
  test(`${virtualId}: rolling compression 뒤 physical base ${baseModel} 유지`, async () => {
    requests = [];
    const messages = [{ role: "system", content: "system" }];
    for (let i = 0; i < 8; i += 1) {
      messages.push({ role: "user", content: `u${i} ${filler(1000)}` });
      messages.push({ role: "assistant", content: `a${i} ${filler(1000)}` });
    }
    const response = await chat(virtualId, messages);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.choices[0].message.content, `OK-${baseModel}`);
    const main = requests.findLast((request) => request.messages?.length > 2);
    assert.equal(main.model, baseModel);
    const summaries = requests.filter((request) => request.messages?.length === 2 && request.messages[0]?.role === "system");
    assert.ok(summaries.length >= 1, "summary sidecall expected");
    assert.ok(summaries.every((request) => request.model !== baseModel && !request.model.endsWith("-1m")));
  });
}

test("terra-1m: physical terra sticky 오류를 그대로 반환", async () => {
  const response = await chat("gpt-5.6-terra-1m", [{ role: "user", content: "force-terra-limit" }]);
  assert.equal(response.status, 429);
  const data = await response.json();
  assert.equal(data.error.type, "model_cooldown");
});

test("/v1/models: virtual 1M 3종을 중복 없이 노출", async () => {
  const data = await (await fetch(`http://127.0.0.1:${GATE_PORT}/v1/models`)).json();
  const ids = data.data.map((model) => model.id);
  for (const virtualId of bases.keys()) {
    assert.equal(ids.filter((id) => id === virtualId).length, 1);
    assert.equal(data.data.find((model) => model.id === virtualId).context_length, 1_000_000);
  }
});
