#!/usr/bin/env bash
# solgate install gate — 설치기 무결성: 문법/템플릿/doctor 실측
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
RC=0

bash -n "$ROOT/setup.sh" || { echo "FAIL: setup.sh syntax"; RC=1; }
zsh -n "$ROOT/install/solgate.zsh" || { echo "FAIL: solgate.zsh syntax"; RC=1; }
node --check "$ROOT/install/merge-ccr.mjs" || { echo "FAIL: merge-ccr.mjs syntax"; RC=1; }

# 템플릿 플레이스홀더 존재 (렌더 치환 누락 방지)
for t in com.solgate.gateway.plist.tmpl com.solgate.sidecar.plist.tmpl sidecar-config.yaml.tmpl; do
  [ -f "$ROOT/install/$t" ] || { echo "FAIL: missing template $t"; RC=1; }
done
grep -q '{{NODE_BIN}}' "$ROOT/install/com.solgate.gateway.plist.tmpl" || { echo "FAIL: gateway tmpl placeholder"; RC=1; }
grep -q '{{SIDECAR_PORT}}' "$ROOT/install/sidecar-config.yaml.tmpl" || { echo "FAIL: sidecar tmpl placeholder"; RC=1; }

# 렌더 후 잔존 플레이스홀더 0 검증 (mock 변수로 렌더)
rendered="$(sed -e 's|{{NODE_BIN}}|/usr/local/bin/node|g' -e 's|{{REPO_ROOT}}|/tmp/x|g' \
  -e 's|{{HOME}}|/tmp/h|g' -e 's|{{UPSTREAM}}|http://u|g' -e 's|{{UPSTREAM_LUNA}}|http://l|g' \
  "$ROOT/install/com.solgate.gateway.plist.tmpl")"
leftover="$(printf '%s' "$rendered" | grep -c '{{')"
[ -z "$leftover" ] && leftover=0
[ "$leftover" -gt 0 ] && { echo "FAIL: gateway tmpl has unrendered placeholders ($leftover)"; RC=1; }

# doctor 실측 (read-only)은 명시한 경우에만 실행한다. CI/배포 검증은 구조 게이트로 재현 가능해야 한다.
if [ "${SOLGATE_INSTALL_LIVE:-0}" = "1" ]; then
  if ! bash "$ROOT/setup.sh" doctor --no-probe >/dev/null 2>&1; then
    echo "FAIL: setup.sh doctor --no-probe exit != 0"
    RC=1
  fi
else
  echo "install_gate: live doctor skipped (SOLGATE_INSTALL_LIVE=1 to enable)"
fi

# zshrc 함수 스모크: 함수 로드 + 모델/캡 해석
out="$(zsh -c "set -e; source '$ROOT/install/solgate.zsh'; _solgate_model_id terra1m; _solgate_model_id luna1m; _solgate_cap_for gpt-5.6-terra-1m" 2>/dev/null)"
fixture_rc=$?
[ "$fixture_rc" -eq 0 ] || { echo "FAIL: model resolution fixture exit $fixture_rc"; RC=1; }
printf '%s' "$out" | grep -q 'gpt-5.6-terra-1m' || { echo "FAIL: terra1m model resolution"; RC=1; }
printf '%s' "$out" | grep -q 'gpt-5.6-luna-1m' || { echo "FAIL: luna1m model resolution"; RC=1; }
printf '%s' "$out" | grep -q '1m' || { echo "FAIL: virtual cap resolution"; RC=1; }

# /model picker env: physical vgpt와 virtual vgpt1m 슬롯을 혼합하지 않는다.
picker_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  set -e
  claude() {
    print -r -- "MAIN=$ANTHROPIC_MODEL"
    print -r -- "ARG=$2"
    print -r -- "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
    print -r -- "ARGS=$*"
    print -r -- "SONNET=$ANTHROPIC_DEFAULT_SONNET_MODEL"
    print -r -- "HAIKU=$ANTHROPIC_DEFAULT_HAIKU_MODEL"
  }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt1m
' 2>/dev/null)"
fixture_rc=$?
[ "$fixture_rc" -eq 0 ] || { echo "FAIL: picker fixture exit $fixture_rc"; RC=1; }
for want in \
  'MAIN=solgate,gpt-5.6-sol-1m[1m]' \
  'ARG=solgate,gpt-5.6-sol-1m[1m]' \
  'OPUS=solgate,gpt-5.6-sol-1m[1m]' \
  'SONNET=solgate,gpt-5.6-terra-1m[1m]' \
  'HAIKU=solgate,gpt-5.6-luna-1m[1m]'; do
  printf '%s\n' "$picker_out" | grep -Fq "$want" || { echo "FAIL: vgpt1m picker env missing: $want"; RC=1; }
done
printf '%s\n' "$picker_out" | grep -Fq '[330k][1m]' && { echo "FAIL: vgpt1m duplicated cap label"; RC=1; }

# Astra aliases preserve the main model and only use the Astra virtual profile
# when requested. Mock the executable so no provider request can be sent.
astra_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  set -e
  claude() {
    print -r -- "MAIN=$ANTHROPIC_MODEL"
    print -r -- "ARG=$2"
    print -r -- "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
    print -r -- "ARGS=$*"
  }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt astra
  vgpt astra1m
  vgpt1m astra
' 2>/dev/null)"
fixture_rc=$?
[ "$fixture_rc" -eq 0 ] || { echo "FAIL: Astra picker fixture exit $fixture_rc"; RC=1; }
for want in \
  'MAIN=solgate,gpt-6-astra[240k]' \
  'ARG=solgate,gpt-6-astra[240k]' \
  'OPUS=solgate,gpt-5.6-sol[330k]' \
  'ARGS=--model solgate,gpt-6-astra[240k] --autocompact 220k' \
  'MAIN=solgate,gpt-6-astra-1m[1m]' \
  'ARG=solgate,gpt-6-astra-1m[1m]' \
  'OPUS=solgate,gpt-5.6-sol-1m[1m]'; do
  printf '%s\n' "$astra_out" | grep -Fq "$want" || { echo "FAIL: Astra alias env missing: $want"; RC=1; }
done
virtual_count="$(printf '%s\n' "$astra_out" | grep -Fc 'MAIN=solgate,gpt-6-astra-1m[1m]')"
[ "$virtual_count" -eq 2 ] || { echo "FAIL: Astra virtual aliases disagree"; RC=1; }
if printf '%s\n' "$astra_out" | grep -E 'ARGS=.*gpt-6-astra-1m.*--autocompact' >/dev/null; then
  echo "FAIL: Astra virtual profile received physical auto-compact option"
  RC=1
fi

override_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  set -e
  claude() { print -r -- "$*"; }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt astra --autocompact 200k
' 2>/dev/null)"
fixture_rc=$?
[ "$fixture_rc" -eq 0 ] || { echo "FAIL: argument override fixture exit $fixture_rc"; RC=1; }
printf '%s\n' "$override_out" | grep -Fq -- '--autocompact 220k --autocompact 200k' || {
  echo "FAIL: explicit user options must follow Astra defaults"
  RC=1
}

if SOLGATE_ROOT="$ROOT" python3 <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

flag = "CLAUDE_CODE_NO_MODEL_FALLBACK"
launchers = (
    ("vgpt astra", "gpt-6-astra", "240k", True),
    ("vgpt astra1m", "gpt-6-astra-1m", "1m", True),
    ("vgpt1m astra", "gpt-6-astra-1m", "1m", True),
    ("vgpt sol", "gpt-5.6-sol", "330k", False),
    ("vgpt terra", "gpt-5.6-terra", "330k", False),
    ("vgpt luna", "gpt-5.6-luna", "330k", False),
    ("vgpt1m", "gpt-5.6-sol-1m", "1m", False),
)
with tempfile.TemporaryDirectory(prefix="solgate-fallback-env-") as directory:
    executable = Path(directory) / "claude"
    executable.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
if os.environ.get("SOLGATE_FIXTURE_CRASH") == "1":
    raise SystemExit(37)
names = ["CLAUDE_CODE_NO_MODEL_FALLBACK", "ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL"]
print(json.dumps({name: os.environ.get(name) for name in names}))
''')
    executable.chmod(0o700)
    base_env = {**os.environ, "PATH": directory + os.pathsep + os.environ.get("PATH", "")}
    base_env.pop(flag, None)
    base_env.pop("SOLGATE_FIXTURE_CRASH", None)
    checked = 0
    for original in (None, "0", "1", "false", "true"):
        for exported in (False, True):
            for launcher, model, cap, astra in launchers:
                assign = "unset " + flag if original is None else (
                    ("export " if exported else "typeset ") + flag + "=" + original
                )
                script = '''set -e
source "$SOLGATE_ROOT/install/solgate.zsh"
''' + assign + "\n" + '''before="${parameters[CLAUDE_CODE_NO_MODEL_FALLBACK]-unset}:${CLAUDE_CODE_NO_MODEL_FALLBACK-unset}"
''' + launcher + "\n" + '''after="${parameters[CLAUDE_CODE_NO_MODEL_FALLBACK]-unset}:${CLAUDE_CODE_NO_MODEL_FALLBACK-unset}"
[[ "$before" == "$after" ]] || exit 41
print -r -- "PARENT-PRESERVED"
'''
                result = subprocess.run(["zsh", "-f", "-c", script], env=base_env, capture_output=True)
                if result.returncode:
                    raise AssertionError(f"fixture failed: {launcher}, state={original}, exported={exported}, exit={result.returncode}")
                lines = result.stdout.decode("utf-8", "replace").splitlines()
                assert len(lines) == 2 and lines[1] == "PARENT-PRESERVED", "fixture output incomplete"
                child = json.loads(lines[0])
                expected = "1" if astra else (original if exported else None)
                assert child[flag] == expected, f"child fallback flag mismatch for {launcher}"
                assert child["ANTHROPIC_MODEL"] == f"solgate,{model}[{cap}]"
                suffix = "-1m[1m]" if cap == "1m" else "[330k]"
                for slot, base in (("OPUS", "sol"), ("SONNET", "terra"), ("HAIKU", "luna")):
                    assert child[f"ANTHROPIC_DEFAULT_{slot}_MODEL"] == f"solgate,gpt-5.6-{base}{suffix}", "subagent tier changed"
                checked += 1
    crash = subprocess.run(["zsh", "-f", "-c", 'set -e; source "$SOLGATE_ROOT/install/solgate.zsh"; vgpt astra'],
                           env={**base_env, "SOLGATE_FIXTURE_CRASH": "1"}, capture_output=True)
    assert crash.returncode == 37, "mock executable failure was swallowed"
    print(f"fallback environment checks PASS ({checked} launches; executable failure preserved)")
PY
then
  :
else
  echo "FAIL: Astra fallback environment fixture"
  RC=1
fi

[ "$RC" -eq 0 ] && echo "install_gate PASS"
exit "$RC"
