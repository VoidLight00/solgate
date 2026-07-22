#!/usr/bin/env bash
# solgate wiring gate — SR11: CCR provider + custom-router 매핑 + zshrc vgpt1m 배선
set -u
RC=0
CCR_CFG="$HOME/.claude-code-router/config.json"
CCR_ROUTER="$HOME/.claude-code-router/custom-router.js"

python3 -c "
import json
cfg = json.load(open('$CCR_CFG'))
providers = {p['name']: p for p in cfg.get('Providers', cfg.get('providers', []))}
sg = providers.get('solgate')
assert sg, 'solgate provider missing'
assert '8321' in sg['api_base_url'], 'solgate provider not on 8321'
for m in ('gpt-5.6-sol-1m','gpt-5.6-terra-1m','gpt-5.6-luna-1m','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna'):
    assert m in sg['models'], f'{m} not in provider models'
" 2>/dev/null || { echo "FAIL: CCR config solgate provider"; RC=1; }

node -e '
const router = require(process.env.HOME + "/.claude-code-router/custom-router.js");
(async () => {
  const checks = [
    ["gpt-5.6-sol-1m", 500000, "solgate,gpt-5.6-sol-1m"],
    ["gpt-5.6-terra-1m", 500000, "solgate,gpt-5.6-terra-1m"],
    ["gpt-5.6-luna-1m", 500000, "solgate,gpt-5.6-luna-1m"],
    ["gpt-5.6-sol", 100000, "solgate,gpt-5.6-sol"],
    ["gpt-5.6-terra", 100000, "solgate,gpt-5.6-terra"],
    ["gpt-5.6-luna", 100000, "solgate,gpt-5.6-luna"],
    ["gpt-5.6-sol", 350000, "vibeproxy,gemini-3-flash"],
  ];
  for (const [m, tok, want] of checks) {
    const r = await router({ body: { model: m }, tokenCount: tok });
    if (r !== want) { console.error(`route ${m}@${tok}: got ${r}, want ${want}`); process.exit(1); }
  }
})();
' 2>/dev/null || { echo "FAIL: custom-router gpt-5.6 routing table"; RC=1; }

for virtual_model in gpt-5.6-sol-1m gpt-5.6-terra-1m gpt-5.6-luna-1m; do
  if ! grep -q "$virtual_model" "$HOME/.zshrc"; then
    echo "FAIL: zshrc not wired to $virtual_model"
    RC=1
  fi
done

# 서브에이전트 티어 별칭 배선 (opus=sol / sonnet=terra / haiku=luna) — zshrc·vclaude-proxy 양쪽
for f in "$HOME/.zshrc" "$HOME/.local/bin/vclaude-proxy"; do
  for pair in 'ANTHROPIC_DEFAULT_OPUS_MODEL="gpt-5.6-sol' 'ANTHROPIC_DEFAULT_SONNET_MODEL="gpt-5.6-terra' 'ANTHROPIC_DEFAULT_HAIKU_MODEL="gpt-5.6-luna'; do
    if ! grep -q "$pair" "$f"; then
      echo "FAIL: subagent tier env missing in $f ($pair)"
      RC=1
    fi
  done
done

[ "$RC" -eq 0 ] && echo "wiring_gate PASS"
exit "$RC"
