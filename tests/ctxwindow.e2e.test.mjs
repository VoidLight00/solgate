// SG-003 회귀 — 업스트림이 "실제 크기"로 거부할 때 폐루프가 진짜로 닫히는지.
//
// ctxretry.e2e.test.mjs 의 mock 은 첫 1회만 400을 주는 횟수 기반이라, 재압축이
// no-op(같은 body 재전송)이어도 2번째가 200이라 통과한다 — SG-002 수정이 초록으로
// 보였던 이유다. 여기서는 mock 이 REAL_WINDOW 를 넘는 body 를 항상 거부한다.
// 재압축이 실제로 크기를 줄이지 못하면 400이 무한 반복되고 테스트는 실패한다.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const MOCK_PORT = 8397;
const GATE_PORT = 8396;
// 1차 압축의 finalEst 는 실측 4062 (recent 4건 + recap). 실창을 그 아래로 잡아야
// "추정은 천장(11000) 아래인데 실창은 초과" — SG-003 그 자체 — 가 재현된다.
// 4062 → 2843(×0.7) → 1990 으로 2회 축소돼야 통과하므로 고정 1회 축소로는 못 넘는다.
const REAL_WINDOW = 2500;
let mock;
let child;
let tmpHome;
let bodyRequests = 0;

function approxTokens(messages) {
  return messages.reduce((n, m) => n + Math.ceil(String(m.content ?? "").length / 3.6) + 8, 0);
}

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
      const isSummarySidecall = msgs.length <= 3;
      if (!isSummarySidecall) {
        bodyRequests += 1;
        if (approxTokens(msgs) > REAL_WINDOW) {
          res.writeHead(400, { "content-type": "application/json" });
          return res.end(JSON.stringify({ error: { message: "Your input exceeds the context window of this model.", type: "invalid_request_error", code: "context_too_large" } }));
        }
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
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), "solgate-ctxwindow-"));
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
  throw new Error("solgate ctxwindow test instance did not start");
});

after(() => {
  child?.kill();
  mock?.close();
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

test("SG-003: 추정<천장 이지만 실창 초과 → 재압축이 실제로 줄어 200으로 닫힌다", async () => {
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
  assert.equal(r.status, 200, "실창 기준 거부에도 재압축으로 살아나야 함");

  const s = await (await fetch(`http://127.0.0.1:${GATE_PORT}/solgate/stats`)).json();
  assert.ok(s.ctxRetries >= 1, `ctxRetries=${s.ctxRetries}`);
  // no-op 재시도 방지: 같은 body 를 천장 횟수만큼 재던지면 요청 수가 부풀어오른다.
  assert.ok(bodyRequests <= 4, `본문 요청 ${bodyRequests}회 — no-op 재시도 의심`);
});
