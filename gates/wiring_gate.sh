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
assert 'gpt-5.6-sol-1m' in sg['models'], 'virtual model not in provider models'
" 2>/dev/null || { echo "FAIL: CCR config solgate provider"; RC=1; }

node -e '
const router = require(process.env.HOME + "/.claude-code-router/custom-router.js");
(async () => {
  const r = await router({ body: { model: "gpt-5.6-sol-1m" }, tokenCount: 500000 });
  if (r !== "solgate,gpt-5.6-sol-1m") { console.error("route:", r); process.exit(1); }
})();
' 2>/dev/null || { echo "FAIL: custom-router gpt-5.6-sol-1m mapping (500k must stay on solgate)"; RC=1; }

if ! grep -q 'gpt-5.6-sol-1m' "$HOME/.zshrc"; then
  echo "FAIL: zshrc vgpt1m not wired to gpt-5.6-sol-1m"
  RC=1
fi

[ "$RC" -eq 0 ] && echo "wiring_gate PASS"
exit "$RC"
