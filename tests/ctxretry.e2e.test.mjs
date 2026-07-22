// SR5 폐루프 e2e — 압축 후에도 업스트림이 context_too_large(400)를 주면
// 천장을 낮춰 1회 재압축-재시도해 200으로 살아나는지 모킹 upstream으로 검증.
// mock: 본문 요청(messages>3)의 첫 1회만 400 context_too_large, 이후 200.
// 요약 사이드콜(system+user 2개)은 항상 200 — 실 토큰 소모 0.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MOCK_PORT = 8395;
const GATE_PORT = 8394;
let mock;
let child;
let tmpHome;
let failedOnce = false;

function mockUpstream() {
  return http.createServer((req, res) => {
    let raw = "";
    req.on("data", (c) => (raw += c));
    req.on("end", () => {
      if (req.url === "/v1/models") {
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify({ object: "list", data: [{ id: "gpt-5.6-sol" }] }));
      }
      const body = JSON.parse(raw || "{}");
      const msgs = Array.isArray(body.messages) ? body.messages : [];
      if (msgs.length > 3 && !failedOnce) {
        failedOnce = true;
        res.writeHead(400, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { message: "Your input exceeds the context window of this model.", type: "invalid_request_error", code: "context_too_large" } }));
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ object: "chat.completion", model: body.model, choices: [{ index: 0, message: { role: "assistant", content: `OK-${body.model}` }, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 2 } }));
    });
  });
}

function filler(tokens) {
  return "word ".repeat(Math.ceil((tokens * 3.6) / 5));
}

before(async () => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "solgate-ctxretry-"));
  mock = mockUpstream();
  await new Promise((r) => mock.listen(MOCK_PORT, "127.0.0.1", r));
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
      const r = await fetch(`http://127.0.0.1:${GATE_PORT}/healthz`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("solgate ctxretry test instance did not start");
});

after(() => {
  child?.kill();
  mock?.close();
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

test("SR5 폐루프: 압축 후 400 context_too_large → 재압축 1회 재시도로 200", async () => {
  const messages = [{ role: "system", content: "You are helpful." }];
  for (let i = 0; i < 8; i += 1) {
    messages.push({ role: "user", content: `u${i} ` + filler(1000) });
    messages.push({ role: "assistant", content: `a${i} ` + filler(1000) });
  }
  const r = await fetch(`http://127.0.0.1:${GATE_PORT}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "gpt-5.6-sol-1m", messages }),
  });
  assert.equal(r.status, 200, "재시도 후 200이어야 함");
  const d = await r.json();
  assert.ok(d.choices[0].message.content.includes("OK-gpt-5.6-sol"), "실응답 보존");
  const s = await (await fetch(`http://127.0.0.1:${GATE_PORT}/solgate/stats`)).json();
  assert.ok(s.ctxRetries >= 1, `ctxRetries=${s.ctxRetries}`);
});
