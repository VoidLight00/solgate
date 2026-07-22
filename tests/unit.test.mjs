// solgate 순수 함수 단위 테스트 — SR3/SR4/SR5/SR7/SR10 + 청킹 결정론(SR6 기반)
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  estimateTokens,
  msgTokens,
  totalTokens,
  splitLeadingSystem,
  chunkMessages,
  planCompaction,
  enforceCeiling,
  compactBody,
  chunkKey,
  virtualProfile,
  VIRTUAL_MODEL_PROFILES,
} from "../server.mjs";

const CFG_TEST = {
  COMPACT_TRIGGER: 10_000,
  KEEP_RECENT: 4_000,
  CHUNK_TOKENS: 2_000,
  HARD_CEILING: 11_000,
};

function filler(tokens) {
  // "word " ≈ 5 chars ≈ 1.39 tok/word(추정식 /3.6) → tokens 맞춤 근사
  return "word ".repeat(Math.ceil((tokens * 3.6) / 5));
}

function convo(turns, tokensPerMsg) {
  const msgs = [{ role: "system", content: "You are helpful." }];
  for (let i = 0; i < turns; i += 1) {
    msgs.push({ role: "user", content: `u${i} ` + filler(tokensPerMsg) });
    msgs.push({ role: "assistant", content: `a${i} ` + filler(tokensPerMsg) });
  }
  return msgs;
}

test("SR10: CJK 인식 추정 — 한글은 char≈1tok, 영문은 1/3.6", () => {
  const ko = "가".repeat(1000);
  const en = "a".repeat(1000);
  assert.ok(estimateTokens(ko) >= 1000, "한글 1000자 ≥ 1000tok");
  assert.ok(estimateTokens(en) <= 300, "영문 1000자 ≤ 300tok");
});

test("SR3: COMPACT_TRIGGER 이하 → planCompaction null(무변형 패스스루)", () => {
  const msgs = convo(4, 500); // ~4k tok < 10k
  assert.equal(planCompaction(msgs, CFG_TEST), null);
});

test("SR4: 초과 시 old/recent 분리, recent ≥ KEEP_RECENT 근사", () => {
  const msgs = convo(30, 500); // ~30k tok > 10k
  const plan = planCompaction(msgs, CFG_TEST);
  assert.ok(plan, "plan 존재");
  assert.ok(plan.old.length > 0, "old 비어있지 않음");
  assert.ok(totalTokens(plan.recent) >= CFG_TEST.KEEP_RECENT, "recent가 예산 이상");
});

test("SR7: recent는 반드시 user 메시지로 시작", () => {
  const msgs = convo(30, 500);
  const plan = planCompaction(msgs, CFG_TEST);
  assert.equal(plan.recent[0].role, "user");
});

test("SR7: tool 메시지가 경계에 있어도 orphan 없이 user 경계로 컷", () => {
  const msgs = [{ role: "system", content: "sys" }];
  for (let i = 0; i < 20; i += 1) {
    msgs.push({ role: "user", content: `u${i} ` + filler(400) });
    msgs.push({
      role: "assistant",
      content: "",
      tool_calls: [{ id: `t${i}`, function: { name: "run", arguments: filler(200) } }],
    });
    msgs.push({ role: "tool", tool_call_id: `t${i}`, content: `r${i} ` + filler(400) });
    msgs.push({ role: "assistant", content: `a${i} ` + filler(400) });
  }
  const plan = planCompaction(msgs, CFG_TEST);
  assert.ok(plan, "plan 존재");
  assert.equal(plan.recent[0].role, "user", "user 경계 시작");
  // recent 안의 모든 tool 메시지는 대응하는 assistant tool_calls 뒤에 있어야 함
  const seen = new Set();
  for (const m of plan.recent) {
    if (m.tool_calls) for (const tc of m.tool_calls) seen.add(tc.id);
    if (m.role === "tool") assert.ok(seen.has(m.tool_call_id), `orphan tool: ${m.tool_call_id}`);
  }
});

test("SR6 기반: 청킹은 결정론 — 같은 입력, 같은 경계, 같은 키; prefix 안정", () => {
  const msgs = convo(30, 500);
  const plan = planCompaction(msgs, CFG_TEST);
  const c1 = chunkMessages(plan.old, CFG_TEST.CHUNK_TOKENS);
  const c2 = chunkMessages(plan.old, CFG_TEST.CHUNK_TOKENS);
  assert.equal(c1.length, c2.length);
  for (let i = 0; i < c1.length; i += 1) {
    assert.equal(chunkKey(c1[i], "m"), chunkKey(c2[i], "m"));
  }
  // 대화가 자라도(append-only) 앞쪽 완전 청크 경계·키는 불변
  const grown = [...plan.old, { role: "user", content: filler(500) }];
  const c3 = chunkMessages(grown, CFG_TEST.CHUNK_TOKENS);
  for (let i = 0; i < c1.length - 1; i += 1) {
    assert.equal(chunkKey(c3[i], "m"), chunkKey(c1[i], "m"), `full chunk ${i} 키 불변`);
  }
});

test("SR5: enforceCeiling — 재조립이 천장을 넘으면 user 경계 단위 결정론 절단", () => {
  const systems = [{ role: "system", content: filler(500) }];
  const recap = [{ role: "user", content: filler(1000) }, { role: "assistant", content: "ok" }];
  const recent = [];
  for (let i = 0; i < 20; i += 1) {
    recent.push({ role: "user", content: filler(600) });
    recent.push({ role: "assistant", content: filler(600) });
  }
  const { kept, dropped, finalEst } = enforceCeiling(systems, recap, recent, CFG_TEST);
  assert.ok(finalEst <= CFG_TEST.HARD_CEILING, `finalEst ${finalEst} ≤ ceiling`);
  assert.ok(dropped > 0, "실제로 절단 발생");
  assert.equal(kept[0].role, "user", "절단 후에도 user 경계 시작");
});

test("SR5 fail-closed: user 경계가 없어도 천장 초과 전송 금지 — 본문 결정론 절단", () => {
  const systems = [{ role: "system", content: filler(500) }];
  const recap = [{ role: "user", content: filler(1000) }, { role: "assistant", content: "ok" }];
  // user는 맨 앞 1개뿐 — 기존 코드는 여기서 break로 천장 초과 전송(2026-07-12 400 사고 재현)
  const recent = [
    { role: "user", content: "go" },
    { role: "assistant", content: filler(8000) },
    { role: "assistant", content: filler(8000) },
  ];
  const { truncated, finalEst } = enforceCeiling(systems, recap, recent, CFG_TEST);
  assert.ok(finalEst <= CFG_TEST.HARD_CEILING, `finalEst ${finalEst} ≤ ceiling ${CFG_TEST.HARD_CEILING}`);
  assert.ok(truncated > 0, "본문 절단 발생");
});

test("SR5 fail-closed: CJK 본문도 비율 절단으로 천장 준수", () => {
  const recent = [
    { role: "user", content: "go" },
    { role: "assistant", content: "가".repeat(15000) }, // est ≈ 15000tok
  ];
  const { truncated, finalEst } = enforceCeiling([], [], recent, CFG_TEST);
  assert.ok(finalEst <= CFG_TEST.HARD_CEILING, `finalEst ${finalEst} ≤ ceiling`);
  assert.ok(truncated > 0);
});

test("virtual profiles: 3개 1M ID가 정확한 physical base와 non-self summarizer를 가짐", () => {
  const expected = {
    "gpt-5.6-sol-1m": "gpt-5.6-sol",
    "gpt-5.6-terra-1m": "gpt-5.6-terra",
    "gpt-5.6-luna-1m": "gpt-5.6-luna",
  };
  assert.deepEqual(Object.keys(VIRTUAL_MODEL_PROFILES).sort(), Object.keys(expected).sort());
  for (const [virtualId, baseModel] of Object.entries(expected)) {
    const profile = virtualProfile(virtualId);
    assert.equal(profile.baseModel, baseModel);
    assert.ok(profile.summaryCandidates.length >= 1);
    assert.ok(!profile.summaryCandidates.includes(baseModel));
    assert.ok(profile.summaryCandidates.every((model) => !model.endsWith("-1m")));
  }
  assert.equal(virtualProfile("gpt-5.6-sol"), null);
});

test("SR5 integration: 압축 계획이 없어도 oversized assistant 본문은 compactBody에서 천장 준수", async () => {
  const body = {
    model: "gpt-5.6-sol",
    messages: [
      { role: "system", content: "system" },
      { role: "assistant", content: filler(15000) },
    ],
  };
  const result = await compactBody(body, CFG_TEST);
  assert.ok(result.meta.finalEst <= CFG_TEST.HARD_CEILING, `finalEst ${result.meta.finalEst} ≤ ceiling`);
  assert.equal(result.compacted, true);
});

test("SR5 integration: tools만 천장을 넘으면 명시적 context_too_large", async () => {
  const body = {
    model: "gpt-5.6-sol",
    messages: [{ role: "user", content: "hi" }],
    tools: [{ type: "function", function: { name: "huge", description: filler(15000), parameters: {} } }],
  };
  const result = await compactBody(body, CFG_TEST);
  assert.equal(result.error?.code, "context_too_large");
});

test("SR5 integration: oversized leading system은 명시적 context_too_large", async () => {
  const body = {
    model: "gpt-5.6-sol",
    messages: [
      { role: "system", content: filler(15000) },
      { role: "user", content: "hi" },
    ],
  };
  const result = await compactBody(body, CFG_TEST);
  assert.equal(result.error?.code, "context_too_large");
});

test("SR5 integration: tools와 작은 단일 메시지 합계가 천장을 넘으면 오류", async () => {
  const body = {
    model: "gpt-5.6-sol",
    messages: [{ role: "user", content: filler(3000) }],
    tools: [{ type: "function", function: { name: "large", description: filler(9000), parameters: {} } }],
  };
  const result = await compactBody(body, CFG_TEST);
  assert.equal(result.error?.code, "context_too_large");
});

test("splitLeadingSystem: 선두 system 블록 보존", () => {
  const msgs = [
    { role: "system", content: "a" },
    { role: "system", content: "b" },
    { role: "user", content: "hi" },
    { role: "system", content: "late" },
  ];
  const [sys, rest] = splitLeadingSystem(msgs);
  assert.equal(sys.length, 2);
  assert.equal(rest.length, 2);
});

test("msgTokens: tool_calls 포함 추정", () => {
  const plain = { role: "assistant", content: "hello" };
  const withTool = { role: "assistant", content: "hello", tool_calls: [{ function: { name: "x", arguments: filler(100) } }] };
  assert.ok(msgTokens(withTool) > msgTokens(plain) + 50);
});
