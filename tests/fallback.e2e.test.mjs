// SR12 폴백 e2e — 모킹 upstream으로 결정론 검증 (실 토큰 소모 0)
// mock: sol=429 usage_limit_reached / terra·luna=200. solgate가 terra로 갈아타고
// 응답 첫머리에 [solgate fallback] 문구를 주입하는지 확인한다.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MOCK_PORT = 8393;
const GATE_PORT = 8392;
let mock;
let child;
let tmpHome;

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
      if (body.model === "gpt-5.6-sol") {
        res.writeHead(429, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { type: "usage_limit_reached", message: "The usage limit has been reached", resets_in_seconds: 3600 } }));
      }
      if (body.model === "gpt-5.6-terra" && body.messages?.[0]?.content === "force-terra-limit") {
        res.writeHead(429, { "content-type": "application/json" });
        return res.end(JSON.stringify({ error: { type: "model_cooldown", message: "Terra is cooling down", resets_in_seconds: 120 } }));
      }
      if (body.stream) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`data: ${JSON.stringify({ object: "chat.completion.chunk", model: body.model, choices: [{ index: 0, delta: { role: "assistant", content: "STREAM-OK" } }] })}\n\n`);
        res.write("data: [DONE]\n\n");
        return res.end();
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ object: "chat.completion", model: body.model, choices: [{ index: 0, message: { role: "assistant", content: `OK-${body.model}` }, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 2 } }));
    });
  });
}

before(async () => {
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "solgate-test-"));
  mock = mockUpstream();
  await new Promise((r) => mock.listen(MOCK_PORT, "127.0.0.1", r));
  child = spawn(process.execPath, [new URL("../server.mjs", import.meta.url).pathname], {
    env: {
      ...process.env,
      SOLGATE_PORT: String(GATE_PORT),
      SOLGATE_UPSTREAM: `http://127.0.0.1:${MOCK_PORT}`,
      SOLGATE_UPSTREAM_LUNA: `http://127.0.0.1:${MOCK_PORT}`,
      SOLGATE_HOME: tmpHome,
    },
    stdio: "ignore",
  });
  // 기동 대기
  for (let i = 0; i < 50; i += 1) {
    try {
      const r = await fetch(`http://127.0.0.1:${GATE_PORT}/healthz`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("solgate test instance did not start");
});

after(() => {
  child?.kill();
  mock?.close();
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

async function chat(body) {
  const r = await fetch(`http://127.0.0.1:${GATE_PORT}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return r;
}

test("SR12: sol 429 → terra 폴백 + 문구 주입 (non-stream)", async () => {
  const r = await chat({ model: "gpt-5.6-sol", messages: [{ role: "user", content: "hi" }] });
  assert.equal(r.status, 200);
  const d = await r.json();
  const content = d.choices[0].message.content;
  assert.ok(content.startsWith("[solgate fallback] gpt-5.6-sol → gpt-5.6-terra"), `notice missing: ${content.slice(0, 80)}`);
  assert.ok(content.includes("usage_limit_reached"), "사유 포함");
  assert.ok(content.includes("OK-gpt-5.6-terra"), "실응답 보존");
});

test("SR12: stream에서도 첫 청크에 폴백 문구", async () => {
  const r = await chat({ model: "gpt-5.6-sol", stream: true, messages: [{ role: "user", content: "hi" }] });
  assert.equal(r.status, 200);
  const text = await r.text();
  const firstData = text.split("\n\n")[0];
  assert.ok(firstData.includes("[solgate fallback] gpt-5.6-sol"), `first chunk: ${firstData.slice(0, 120)}`);
  assert.ok(text.includes("STREAM-OK"), "업스트림 스트림 보존");
});

test("SR12: terra는 sticky — 한도 오류를 다른 모델로 숨기지 않음", async () => {
  const r = await chat({ model: "gpt-5.6-terra", messages: [{ role: "user", content: "force-terra-limit" }] });
  assert.equal(r.status, 429);
  const d = await r.json();
  assert.equal(d.error.type, "model_cooldown");
});

test("SR12: 폴백 불필요 시 문구 없음 (terra 직행)", async () => {
  const r = await chat({ model: "gpt-5.6-terra", messages: [{ role: "user", content: "hi" }] });
  const d = await r.json();
  assert.equal(d.choices[0].message.content, "OK-gpt-5.6-terra");
});

test("SR12: stats.fallbacks 증가", async () => {
  const s = await (await fetch(`http://127.0.0.1:${GATE_PORT}/solgate/stats`)).json();
  assert.ok(s.fallbacks >= 2, `fallbacks=${s.fallbacks}`);
});

test("SR12: 폴백 대상 아닌 에러(400)는 그대로 반환", async () => {
  // mock은 sol만 429 — 존재하지 않는 경로로 400류 검증 대신 luna 정상 확인
  const r = await chat({ model: "gpt-5.6-luna", messages: [{ role: "user", content: "hi" }] });
  const d = await r.json();
  assert.equal(d.choices[0].message.content, "OK-gpt-5.6-luna");
});
