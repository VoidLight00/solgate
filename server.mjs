// solgate — gpt-5.6-sol(실창 372k) 위의 가상 1M 컨텍스트 프록시.
// Claude Code(CCR) ↔ VibeProxy 사이에서, 300k 초과 대화의 오래된 구간을
// gpt-5.6-luna 청크 요약으로 접고 최근 ~200k는 원문 유지한다.
// 물리 창을 늘리는 게 아니라 압축 계층이다 — 오래된 턴은 요약본(무손실 아님).
// 사양 SSoT: REQUIREMENTS.md (SR1~SR11)
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { Readable } from "node:stream";

const DEFAULT_UPSTREAM = process.env.SOLGATE_UPSTREAM || "http://127.0.0.1:8317";

export const CFG = {
  PORT: Number(process.env.SOLGATE_PORT || 8321),
  UPSTREAM: DEFAULT_UPSTREAM,
  // setup.sh가 luna auth 버그를 검출했을 때만 별도 sidecar URL을 주입한다.
  UPSTREAM_LUNA: process.env.SOLGATE_UPSTREAM_LUNA || DEFAULT_UPSTREAM,
  UPSTREAM_MODEL: process.env.SOLGATE_UPSTREAM_MODEL || "gpt-5.6-sol",
  VIRTUAL_ID: process.env.SOLGATE_VIRTUAL_ID || "gpt-5.6-sol-1m",
  VIRTUAL_CONTEXT: 1_000_000,
  HARD_CEILING: Number(process.env.SOLGATE_HARD_CEILING || 330_000),
  COMPACT_TRIGGER: Number(process.env.SOLGATE_COMPACT_TRIGGER || 300_000),
  KEEP_RECENT: Number(process.env.SOLGATE_KEEP_RECENT || 200_000),
  CHUNK_TOKENS: Number(process.env.SOLGATE_CHUNK_TOKENS || 40_000),
  // SG-003: ctx 재시도는 "직전에 실제로 보낸 추정치"를 기준으로 줄인다. 추정 오차는
  // 페이로드 밀도에 따라 흔들려 고정 배수 1회로는 못 잡으므로 점진 축소한다.
  // 축소 하한은 MAX_RETRIES 가 구조적으로 준다 (0.7^3 ≈ 34%) — 별도 절대 바닥값은
  // 스케일마다 의미가 달라져 두지 않는다.
  CTX_RETRY_SHRINK: Number(process.env.SOLGATE_CTX_RETRY_SHRINK || 0.7),
  CTX_MAX_RETRIES: Number(process.env.SOLGATE_CTX_MAX_RETRIES || 3),
  // luna는 cli-proxy-api 7.2.54에서 auth_unavailable (FAILURE_LOG SG-001) — terra 사용
  SUMMARY_MODEL: process.env.SOLGATE_SUMMARY_MODEL || "gpt-5.6-terra",
  SUMMARY_BUDGET: Number(process.env.SOLGATE_SUMMARY_BUDGET || 60_000),
  HOME_DIR: process.env.SOLGATE_HOME || path.join(os.homedir(), ".solgate"),
};

export const stats = {
  started: new Date().toISOString(),
  requests: 0,
  passthrough: 0,
  compactions: 0,
  cacheHits: 0,
  cacheMisses: 0,
  degraded: 0,
  fallbacks: 0,
  ctxRetries: 0,
};

// ---------- 쿼터/한도 자동 폴백 (SR12) ----------
// 요청 모델이 429/한도/auth 불가면 같은 체급 안에서 갈아탄다.
// Terra는 사용자가 지정한 sticky worker route라 실패 시 다른 모델로 바꾸지 않고
// 오류를 그대로 노출한다. 재시도/세션 재개 역시 Terra로만 수행한다.
export const FAILOVER_CHAIN = {
  "gpt-5.6-sol": ["gpt-5.6-terra", "gpt-5.6-luna"],
  "gpt-5.6-terra": [],
  "gpt-5.6-luna": ["gpt-5.6-terra", "gpt-5.6-sol"],
};

export function upstreamFor(model, cfg = CFG) {
  return model === "gpt-5.6-luna" ? cfg.UPSTREAM_LUNA : cfg.UPSTREAM;
}

export function shouldFailover(status, bodyText) {
  if (status === 429) return true;
  return /usage_limit_reached|model_cooldown|auth_unavailable/.test(bodyText || "");
}

export function parseFailReason(bodyText) {
  try {
    const e = JSON.parse(bodyText || "{}").error || {};
    return {
      reason: e.type || e.code || (e.message || "").slice(0, 60) || "upstream error",
      resetSeconds: Number(e.resets_in_seconds || e.reset_seconds || 0),
    };
  } catch {
    return { reason: "upstream error", resetSeconds: 0 };
  }
}

export function fallbackNotice(from, to, reason, resetSeconds) {
  let when = "";
  if (resetSeconds > 0) {
    const t = new Date(Date.now() + resetSeconds * 1000);
    when = `, ${from} 리셋 ~${t.getHours()}:${String(t.getMinutes()).padStart(2, "0")}`;
  }
  return `[solgate fallback] ${from} → ${to} (${reason}${when})\n\n`;
}

// ---------- 토큰 추정 (SR10: CJK 인식 — 한글 과소추정으로 천장 초과 금지) ----------
export function estimateTokens(text) {
  if (!text) return 0;
  let cjk = 0;
  let other = 0;
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (
      (c >= 0xac00 && c <= 0xd7a3) || // 한글 음절
      (c >= 0x1100 && c <= 0x11ff) || // 한글 자모
      (c >= 0x4e00 && c <= 0x9fff) || // CJK 한자
      (c >= 0x3040 && c <= 0x30ff)    // 가나
    ) cjk += 1;
    else other += 1;
  }
  return Math.ceil(cjk + other / 3.6);
}

function contentText(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => (typeof p === "string" ? p : p?.text || JSON.stringify(p)))
      .join("\n");
  }
  return content == null ? "" : JSON.stringify(content);
}

export function msgTokens(msg) {
  let t = estimateTokens(contentText(msg.content)) + 8;
  if (msg.tool_calls) t += estimateTokens(JSON.stringify(msg.tool_calls));
  return t;
}

export function totalTokens(messages) {
  return messages.reduce((sum, m) => sum + msgTokens(m), 0);
}

// ---------- 압축 계획 (순수 함수 — 단위 게이트 대상) ----------
export function splitLeadingSystem(messages) {
  let i = 0;
  while (i < messages.length && messages[i].role === "system") i += 1;
  return [messages.slice(0, i), messages.slice(i)];
}

// 결정론 그리디 청킹: 같은 old 리스트 → 같은 경계 → 같은 캐시 키.
// 대화가 자라면 마지막(부분) 청크만 해시가 바뀌어 재요약된다 — 턴당 luna 1콜.
export function chunkMessages(msgs, chunkTokens) {
  const chunks = [];
  let cur = [];
  let curTok = 0;
  for (const m of msgs) {
    cur.push(m);
    curTok += msgTokens(m);
    if (curTok >= chunkTokens) {
      chunks.push(cur);
      cur = [];
      curTok = 0;
    }
  }
  if (cur.length) chunks.push(cur);
  return chunks;
}

// SR7: 원문 유지 구간은 user 메시지로 시작해야 orphan tool / 끊긴 tool_call 쌍이 없다.
export function planCompaction(messages, cfg = CFG) {
  const total = totalTokens(messages);
  if (total <= cfg.COMPACT_TRIGGER) return null;

  const [systems, rest] = splitLeadingSystem(messages);
  if (rest.length < 2) return null; // 접을 것이 없음

  // 끝에서부터 KEEP_RECENT 채우는 후보 컷
  let acc = 0;
  let cut = rest.length;
  while (cut > 0 && acc < cfg.KEEP_RECENT) {
    cut -= 1;
    acc += msgTokens(rest[cut]);
  }
  // user 경계로 뒤로(최근 확대) 이동, 없으면 앞으로 탐색
  let boundary = cut;
  while (boundary > 0 && rest[boundary].role !== "user") boundary -= 1;
  if (rest[boundary].role !== "user") {
    boundary = cut;
    while (boundary < rest.length && rest[boundary].role !== "user") boundary += 1;
    if (boundary >= rest.length) return null; // user 메시지가 아예 없음 — 압축 불가
  }
  if (boundary === 0) return null; // old 없음

  return {
    systems,
    old: rest.slice(0, boundary),
    recent: rest.slice(boundary),
    totalBefore: total,
  };
}

// SR5: 어떤 경로로도 HARD_CEILING 초과 전송 금지. 재조립 후에도 넘치면
// recent 앞쪽을 user 경계 단위로 결정론 절단한다.
// user 경계가 더 없어도 fail-closed: 큰 메시지 본문을 절단하고(역할·tool 쌍 유지),
// 그래도 넘치면 앞에서 통 절단한다 (2026-07-12 context_too_large 400 사고, FAILURE_LOG SG-002).
export function enforceCeiling(systems, recapMsgs, recent, cfg = CFG) {
  let kept = recent.slice();
  let dropped = 0;
  let truncated = 0;
  const est = () => totalTokens([...systems, ...recapMsgs, ...kept]);
  while (est() > cfg.HARD_CEILING && kept.length > 1) {
    let next = 1;
    while (next < kept.length && kept[next].role !== "user") next += 1;
    if (next >= kept.length) break;
    dropped += next;
    kept = kept.slice(next);
  }
  const FLOOR = 2000; // 절단 후 메시지당 잔여 추정 토큰
  for (let i = 0; i < kept.length && est() > cfg.HARD_CEILING; i += 1) {
    const text = contentText(kept[i].content);
    const tok = estimateTokens(text);
    if (tok <= FLOOR) continue;
    const cut = Math.max(1, Math.floor((text.length * FLOOR) / tok)); // CJK 비율 보존 절단
    kept[i] = {
      ...kept[i],
      content: text.slice(0, cut) + "\n[solgate: message truncated to fit real context window]",
    };
    truncated += 1;
  }
  // ponytail: 최후 수단 — tool 쌍이 깨질 수 있으나 400 확정보다 낫다. 실측상 truncation에서 끝난다.
  while (est() > cfg.HARD_CEILING && kept.length > 1) {
    kept = kept.slice(1);
    while (kept.length > 1 && kept[0].role === "tool") kept = kept.slice(1);
    dropped += 1;
  }
  const finalEst = est();
  return {
    kept,
    dropped,
    truncated,
    finalEst,
    overflow: finalEst > cfg.HARD_CEILING,
  };
}

// ---------- 요약 캐시 (SR6) ----------
const memCache = new Map();

function cacheDir() {
  const d = path.join(CFG.HOME_DIR, "cache");
  fs.mkdirSync(d, { recursive: true });
  return d;
}

export function chunkKey(chunk, model) {
  return crypto
    .createHash("sha256")
    .update(model + "\n" + JSON.stringify(chunk))
    .digest("hex");
}

function cacheGet(key) {
  if (memCache.has(key)) return memCache.get(key);
  const f = path.join(cacheDir(), key + ".txt");
  if (fs.existsSync(f)) {
    const v = fs.readFileSync(f, "utf8");
    memCache.set(key, v);
    return v;
  }
  return null;
}

function cachePut(key, value) {
  memCache.set(key, value);
  fs.writeFileSync(path.join(cacheDir(), key + ".txt"), value);
}

// ---------- 요약 사이드콜 ----------
export function serializeChunk(chunk) {
  return chunk
    .map((m) => {
      let line = `[${m.role}] ${contentText(m.content)}`;
      if (m.tool_calls) {
        line += "\n" + m.tool_calls
          .map((tc) => `[tool_call] ${tc.function?.name}(${(tc.function?.arguments || "").slice(0, 1500)})`)
          .join("\n");
      }
      return line;
    })
    .join("\n---\n");
}

const SUMMARIZER_SYSTEM = [
  "You compress conversation history for a long coding session.",
  "Summarize the segment into a dense factual digest. PRESERVE: decisions,",
  "file paths, code identifiers, commands and their key outputs/exit codes,",
  "unresolved TODOs, user preferences and constraints, exact numbers.",
  "OMIT pleasantries. Terse bullet points. Max 600 words.",
  "Answer in the dominant language of the segment.",
].join(" ");

async function upstreamChat(model, systemPrompt, userText) {
  const res = await fetch(`${upstreamFor(model)}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userText },
      ],
    }),
  });
  if (!res.ok) throw new Error(`summarizer upstream ${res.status}`);
  const data = await res.json();
  const text = data?.choices?.[0]?.message?.content;
  if (!text) throw new Error("summarizer empty response");
  return text;
}

async function summarizeChunk(chunk) {
  const key = chunkKey(chunk, CFG.SUMMARY_MODEL);
  const hit = cacheGet(key);
  if (hit != null) {
    stats.cacheHits += 1;
    return hit;
  }
  stats.cacheMisses += 1;
  const body = serializeChunk(chunk);
  let summary;
  try {
    summary = await upstreamChat(CFG.SUMMARY_MODEL, SUMMARIZER_SYSTEM, body);
  } catch {
    try {
      // 요약 모델도 한도에 걸릴 수 있다 — 체인의 다음 모델로 1회 폴백
      const alt = (FAILOVER_CHAIN[CFG.SUMMARY_MODEL] || [])[0] || CFG.SUMMARY_MODEL;
      summary = await upstreamChat(alt, SUMMARIZER_SYSTEM, body);
    } catch {
      // 실패 강등: 결정론 절단 마커 (세션 생존 우선, REQUIREMENTS 실패 모드 정책)
      // 강등 마커는 절대 캐시하지 않는다 — 캐시하면 요약 실패가 영구 오염된다 (SG-001)
      stats.degraded += 1;
      return `[earlier context unavailable: ${chunk.length} messages dropped]`;
    }
  }
  cachePut(key, summary);
  return summary;
}

export async function compactBody(body, baseCfg = CFG) {
  // tools 정의도 실창을 먹는다 — 트리거/천장에서 차감해 마진을 보존한다.
  const toolsTok = body.tools ? estimateTokens(JSON.stringify(body.tools)) : 0;
  if (toolsTok >= baseCfg.HARD_CEILING) {
    return {
      body,
      compacted: false,
      error: {
        status: 400,
        code: "context_too_large",
        message: "solgate: tool definitions alone exceed the configured context ceiling",
      },
    };
  }
  const cfg = {
    ...baseCfg,
    COMPACT_TRIGGER: baseCfg.COMPACT_TRIGGER - toolsTok,
    HARD_CEILING: baseCfg.HARD_CEILING - toolsTok,
  };
  const plan = planCompaction(body.messages, cfg);
  if (!plan) {
    const [systems, rest] = splitLeadingSystem(body.messages);
    const { kept, dropped, truncated, finalEst, overflow } = enforceCeiling(systems, [], rest, cfg);
    if (overflow) {
      return {
        body,
        compacted: false,
        error: {
          status: 400,
          code: "context_too_large",
          message: "solgate: system messages and tool definitions leave insufficient context capacity",
        },
      };
    }
    const boundedBody = { ...body, messages: [...systems, ...kept] };
    const changed = dropped > 0 || truncated > 0 || finalEst < totalTokens(body.messages);
    if (!changed) {
      stats.passthrough += 1;
      return { body, compacted: false, meta: { finalEst } };
    }
    stats.compactions += 1;
    return {
      body: boundedBody,
      compacted: true,
      meta: {
        totalBefore: totalTokens(body.messages),
        finalEst,
        chunks: 0,
        droppedRecent: dropped,
        truncatedRecent: truncated,
      },
    };
  }
  stats.compactions += 1;

  const chunks = chunkMessages(plan.old, cfg.CHUNK_TOKENS);
  const summaries = [];
  for (let i = 0; i < chunks.length; i += 1) {
    summaries.push(`### Segment ${i + 1}/${chunks.length}\n${await summarizeChunk(chunks[i])}`);
  }
  let joined = summaries.join("\n\n");
  if (estimateTokens(joined) > CFG.SUMMARY_BUDGET) {
    const key = chunkKey([{ role: "meta", content: joined }], CFG.SUMMARY_MODEL);
    const hit = cacheGet(key);
    if (hit != null) {
      stats.cacheHits += 1;
      joined = hit;
    } else {
      stats.cacheMisses += 1;
      try {
        joined = await upstreamChat(
          CFG.SUMMARY_MODEL,
          SUMMARIZER_SYSTEM,
          `Condense these segment digests into one digest, max 1500 words:\n\n${joined}`,
        );
        cachePut(key, joined);
      } catch {
        stats.degraded += 1; // 강등: 원본 요약 그대로 사용 (예산 초과는 ceiling 절단이 흡수)
      }
    }
  }

  const recapMsgs = [
    {
      role: "user",
      content:
        `<context_recap>\n${joined}\n</context_recap>\n` +
        "The block above is an auto-condensed digest of the earlier part of this conversation " +
        `(${plan.old.length} messages). Everything after this message is verbatim recent history. ` +
        "Continue the session seamlessly; treat the digest as established context.",
    },
    { role: "assistant", content: "Understood. I have the condensed earlier context and the verbatim recent history. Continuing." },
  ];

  const { kept, dropped, truncated, finalEst, overflow } = enforceCeiling(plan.systems, recapMsgs, plan.recent, cfg);
  if (overflow) {
    return {
      body,
      compacted: false,
      error: {
        status: 400,
        code: "context_too_large",
        message: "solgate: protected system messages exceed the remaining context capacity",
      },
    };
  }
  const newBody = { ...body, messages: [...plan.systems, ...recapMsgs, ...kept] };
  return {
    body: newBody,
    compacted: true,
    meta: {
      totalBefore: plan.totalBefore,
      finalEst,
      chunks: chunks.length,
      droppedRecent: dropped,
      truncatedRecent: truncated,
    },
  };
}

// ---------- 로깅 (SR8: 원문 금지, 메타데이터만) ----------
function logLine(obj) {
  const d = path.join(CFG.HOME_DIR, "logs");
  fs.mkdirSync(d, { recursive: true });
  fs.appendFileSync(path.join(d, "solgate.log"), JSON.stringify({ ts: new Date().toISOString(), ...obj }) + "\n");
}

// ---------- HTTP 서버 ----------
async function readJsonBody(req, limitBytes = 64 * 1024 * 1024) {
  const parts = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limitBytes) throw new Error("body too large");
    parts.push(chunk);
  }
  return JSON.parse(Buffer.concat(parts).toString("utf8"));
}

async function pipeUpstream(res, upstreamRes) {
  const headers = {};
  for (const [k, v] of upstreamRes.headers) {
    if (["content-length", "transfer-encoding", "connection"].includes(k)) continue;
    headers[k] = v;
  }
  res.writeHead(upstreamRes.status, headers);
  if (upstreamRes.body) Readable.fromWeb(upstreamRes.body).pipe(res);
  else res.end();
}

async function handleChat(req, res) {
  const t0 = Date.now();
  stats.requests += 1;
  let body;
  try {
    body = await readJsonBody(req);
  } catch (e) {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: `solgate: ${e.message}` } }));
    return;
  }

  const isVirtual = body.model === CFG.VIRTUAL_ID;
  let outBody = body;
  let meta = null;
  if (isVirtual) {
    outBody = { ...body, model: CFG.UPSTREAM_MODEL };
    if (Array.isArray(outBody.messages)) {
      const result = await compactBody(outBody);
      if (result.error) {
        res.writeHead(result.error.status, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: result.error.message, type: "invalid_request_error", code: result.error.code } }));
        return;
      }
      outBody = result.body;
      meta = result.meta || null;
    }
  } else {
    stats.passthrough += 1;
  }

  // SR12: 폴백 루프 — 첫 모델이 한도/쿨다운이면 체인 순서로 갈아탄다.
  const baseModel = outBody.model;
  const attempts = [baseModel, ...(FAILOVER_CHAIN[baseModel] || [])];
  let upstreamRes = null;
  let usedModel = baseModel;
  let fail = { reason: "", resetSeconds: 0 };
  let ctxRetries = 0;
  for (let i = 0; i < attempts.length; i += 1) {
    const m = attempts[i];
    const attemptBody = m === baseModel ? outBody : { ...outBody, model: m };
    let r;
    try {
      r = await fetch(`${upstreamFor(m)}/v1/chat/completions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(attemptBody),
      });
    } catch (e) {
      fail = { reason: `unreachable: ${e.message}`.slice(0, 80), resetSeconds: 0 };
      continue;
    }
    if (r.ok) {
      upstreamRes = r;
      usedModel = m;
      break;
    }
    const txt = await r.text();
    const last = i === attempts.length - 1;
    if (!shouldFailover(r.status, txt) || last) {
      // SR5 폐루프: 추정 오차/절단 불가로 실창을 넘었으면 재압축 후 재시도.
      // 목표는 명목 천장이 아니라 "직전에 실제로 보낸 finalEst" 기준으로 낮춘다.
      // 명목 기준(HARD_CEILING*0.8)으로 낮추면 finalEst가 이미 그 아래일 때 재압축이
      // no-op이 되어 같은 body를 재전송하고 같은 400을 받는다 (FAILURE_LOG SG-003).
      // 요약 청크는 캐시 히트라 재압축 비용은 경계 재계산뿐이다.
      if (isVirtual && r.status === 400 && /context_too_large/.test(txt) && Array.isArray(body.messages)) {
        const sent = meta?.finalEst ?? CFG.HARD_CEILING;
        const target = Math.floor(sent * CFG.CTX_RETRY_SHRINK);
        if (ctxRetries < CFG.CTX_MAX_RETRIES) {
          const shrunk = await compactBody({ ...body, model: CFG.UPSTREAM_MODEL }, {
            ...CFG,
            COMPACT_TRIGGER: Math.floor(target * 0.9),
            HARD_CEILING: target,
            KEEP_RECENT: Math.min(CFG.KEEP_RECENT, Math.floor(target * 0.6)),
          });
          // 진전이 없으면(재압축 불가/동일 크기) 재시도는 같은 400을 반복할 뿐이다 — 에러를 노출한다.
          if (shrunk.meta && shrunk.meta.finalEst < sent) {
            ctxRetries += 1;
            stats.ctxRetries += 1;
            outBody = shrunk.body;
            meta = { ...shrunk.meta, ctxRetry: ctxRetries };
            i = -1; // 체인 처음부터 재시도
            continue;
          }
        }
      }
      // 폴백 대상이 아닌 에러거나 체인 소진: 에러를 그대로 반환
      res.writeHead(r.status, { "content-type": r.headers.get("content-type") || "application/json" });
      res.end(txt);
      logLine({ path: "/v1/chat/completions", model: body.model, virtual: isVirtual, compacted: Boolean(meta), ...(meta || {}), attempted: attempts.slice(0, i + 1), status: r.status, ms: Date.now() - t0 });
      return;
    }
    const p = parseFailReason(txt);
    fail = { reason: `${m}: ${p.reason}`, resetSeconds: p.resetSeconds };
  }
  if (!upstreamRes) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: `solgate: all upstreams failed (${fail.reason})` } }));
    return;
  }

  const fellBack = usedModel !== baseModel;
  if (!fellBack) {
    await pipeUpstream(res, upstreamRes);
  } else {
    // 폴백 문구 주입 — 사용자 대화에 어떤 모델로 대체됐는지 반드시 보이게 한다.
    stats.fallbacks += 1;
    const notice = fallbackNotice(baseModel, usedModel, fail.reason, fail.resetSeconds);
    if (outBody.stream) {
      const headers = {};
      for (const [k, v] of upstreamRes.headers) {
        if (["content-length", "transfer-encoding", "connection"].includes(k)) continue;
        headers[k] = v;
      }
      res.writeHead(200, headers);
      const chunk = {
        id: "solgate-fallback",
        object: "chat.completion.chunk",
        created: Math.floor(Date.now() / 1000),
        model: usedModel,
        choices: [{ index: 0, delta: { content: notice }, finish_reason: null }],
      };
      res.write(`data: ${JSON.stringify(chunk)}\n\n`);
      Readable.fromWeb(upstreamRes.body).pipe(res);
    } else {
      const data = await upstreamRes.json();
      const msg = data?.choices?.[0]?.message;
      if (msg) msg.content = notice + (msg.content || "");
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(data));
    }
  }
  logLine({
    path: "/v1/chat/completions",
    model: body.model,
    virtual: isVirtual,
    compacted: Boolean(meta),
    ...(meta || {}),
    usedModel,
    fellBack,
    fallbackReason: fellBack ? fail.reason : undefined,
    status: upstreamRes.status,
    ms: Date.now() - t0,
  });
}

async function handleModels(res) {
  try {
    const up = await fetch(`${CFG.UPSTREAM}/v1/models`);
    const data = await up.json();
    data.data = data.data || [];
    data.data.push({
      id: CFG.VIRTUAL_ID,
      object: "model",
      owned_by: "solgate",
      context_length: CFG.VIRTUAL_CONTEXT,
      description: `Virtual 1M context over ${CFG.UPSTREAM_MODEL} (rolling summarization above ${CFG.COMPACT_TRIGGER} tokens).`,
    });
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(data));
  } catch (e) {
    res.writeHead(502, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: `solgate upstream unreachable: ${e.message}` } }));
  }
}

export function createServer() {
  return http.createServer(async (req, res) => {
    try {
      if (req.method === "POST" && req.url === "/v1/chat/completions") return await handleChat(req, res);
      if (req.method === "GET" && req.url === "/v1/models") return await handleModels(res);
      if (req.method === "GET" && req.url === "/solgate/stats") {
        res.writeHead(200, { "content-type": "application/json" });
        return res.end(JSON.stringify(stats));
      }
      if (req.method === "GET" && req.url === "/healthz") {
        res.writeHead(200);
        return res.end("ok");
      }
      // 그 외 경로는 upstream 패스스루 (GET/POST)
      const up = await fetch(`${CFG.UPSTREAM}${req.url}`, {
        method: req.method,
        headers: { "content-type": req.headers["content-type"] || "application/json" },
        body: req.method === "GET" || req.method === "HEAD" ? undefined : req,
        duplex: "half",
      });
      return await pipeUpstream(res, up);
    } catch (e) {
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: `solgate: ${e.message}` } }));
      } else {
        res.end();
      }
    }
  });
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  createServer().listen(CFG.PORT, "127.0.0.1", () => {
    console.log(`solgate listening on 127.0.0.1:${CFG.PORT} → ${CFG.UPSTREAM} (${CFG.UPSTREAM_MODEL})`);
  });
}
