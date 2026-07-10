// CCR(claude-code-router) config.json에 solgate provider를 비파괴 머지한다.
// 기존 Router/기타 provider는 건드리지 않는다. 백업 후 저장.
// usage: node merge-ccr.mjs [--config <path>] [--port 8321]
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const args = process.argv.slice(2);
function opt(name, dflt) {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
}
const configPath = opt("--config", path.join(os.homedir(), ".claude-code-router", "config.json"));
const port = opt("--port", "8321");

const MODELS = ["gpt-5.6-sol-1m", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"];

if (!fs.existsSync(configPath)) {
  console.error(`FAIL: CCR config not found: ${configPath}`);
  console.error("claude-code-router를 먼저 설치/실행해 config를 생성하세요: npm i -g @musistudio/claude-code-router && ccr start");
  process.exit(1);
}

const raw = fs.readFileSync(configPath, "utf8");
const cfg = JSON.parse(raw);
const key = Array.isArray(cfg.Providers) ? "Providers" : "providers";
cfg[key] = cfg[key] || [];

const desired = {
  name: "solgate",
  api_base_url: `http://127.0.0.1:${port}/v1/chat/completions`,
  api_key: "dummy-not-used",
  models: MODELS,
};

let changed = false;
const existing = cfg[key].find((p) => p && p.name === "solgate");
if (!existing) {
  cfg[key].push(desired);
  changed = true;
} else {
  if (existing.api_base_url !== desired.api_base_url) {
    existing.api_base_url = desired.api_base_url;
    changed = true;
  }
  existing.models = existing.models || [];
  for (const m of MODELS) {
    if (!existing.models.includes(m)) {
      existing.models.push(m);
      changed = true;
    }
  }
}

if (changed) {
  const bak = `${configPath}.bak-solgate-${new Date().toISOString().replace(/[:.]/g, "").slice(0, 15)}`;
  fs.copyFileSync(configPath, bak);
  fs.writeFileSync(configPath, JSON.stringify(cfg, null, 2) + "\n");
  console.log(`OK: solgate provider merged (backup: ${bak})`);
} else {
  console.log("OK: solgate provider already present, no changes");
}
