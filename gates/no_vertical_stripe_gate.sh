#!/usr/bin/env bash
# no_vertical_stripe_gate.sh — HARD 게이트 (SSoT)
# 카드/헤딩/콜아웃 좌측의 "색 세로 스트라이프"(Claude Code 기본 템플릿 특유의 AI 티) 금지.
# 사용자 영구 지시: 2026-06-17(카드 옆줄) → 2026-06-23(세로줄 전면 HARD 금지, aislop+dptd+모든 CLAUDE.md+검증 게이트).
# 산문 금지 규칙이 아니라 "종료코드로 증명"되는 HARD 게이트다(선언≠증거).
#
# usage: no_vertical_stripe_gate.sh <dir|file> [...]
# exit 0 = clean (세로 색 스트라이프 0건)
# exit 1 = 위반 발견
# exit 2 = 스캔 자체 실패 (fail-closed)
#
# 금지(FAIL):
#   - border-left / border-inline-start 에 accent/brand 색 또는 두께 ≥3px 의 solid 세로 막대
#   - border-left-color 가 accent/brand (transparent 기본 위 활성표시 트릭 포함)
#   - ::before/::after 가짜 세로 막대(width ≤8px + height + 색 background)
# 허용(PASS):
#   - 중립 hairline (var(--border) 등, 1px solid 중립색) — 표/구분선/TOC 레일
#   - accent-color (폼 컨트롤), 하단 border-bottom, 가로 divider
#   - .svg 다이어그램 내부의 세로선(데이터 시각화) — 스캔 대상에서 제외
set -u
[ "$#" -ge 1 ] || { echo "usage: no_vertical_stripe_gate.sh <path> [...]" >&2; exit 2; }

python3 - "$@" <<'PY'
import re, sys, os

paths = sys.argv[1:]
files = []
for p in paths:
    if os.path.isfile(p):
        if p.lower().endswith(('.css', '.html', '.htm')):
            files.append(p)
    elif os.path.isdir(p):
        for root, _, fs in os.walk(p):
            if any(seg in root for seg in ('/node_modules/', '/.git/', '/.next/', '/dist/')):
                continue
            for f in fs:
                if f.lower().endswith(('.css', '.html', '.htm')):
                    files.append(os.path.join(root, f))

# 중립색(허용) — 이 토큰들이 값에 있으면 스트라이프로 보지 않는다
NEUTRAL = re.compile(r'transparent|currentcolor|inherit|none|var\(--(border|hairline|rule|line|divider|grid|track|stone|sand|ivory|parchment|near-black|olive|dark-warm)\b', re.I)
# accent/brand 토큰(금지 신호)
ACCENT_VAR = re.compile(r'var\(--(brand|accent|primary|ink|ink-?blue|highlight|navy|theme|cta)\b', re.I)
HAS_COLOR = re.compile(r'#[0-9a-f]{3,8}\b|\brgb|\bhsl|\boklch|var\(--', re.I)

def to_px(num, unit):
    unit = (unit or '').lower()
    if unit == 'pt':  return num * 1.333
    if unit in ('rem', 'em'): return num * 16
    return num  # px 또는 단위없음

viol = []

def scan_css(text, fname):
    # 1) border-left / border-inline-start 색 세로 막대
    for m in re.finditer(r'border-(?:left|inline-start)\s*:\s*([^;{}]+)', text, re.I):
        val = m.group(1).strip()
        if NEUTRAL.search(val):
            continue
        if not HAS_COLOR.search(val):
            continue
        wmm = re.search(r'(\d+(?:\.\d+)?)\s*(px|pt|rem|em)', val)
        wpx = to_px(float(wmm.group(1)), wmm.group(2)) if wmm else 0
        if ACCENT_VAR.search(val) or wpx >= 3:
            ln = text.count('\n', 0, m.start()) + 1
            viol.append((fname, ln, 'border-left 색 세로 스트라이프: ' + val[:60]))
    # 2) border-left-color: accent (transparent 기본 위 활성표시 트릭)
    for m in re.finditer(r'border-(?:left|inline-start)-color\s*:\s*([^;{}]+)', text, re.I):
        val = m.group(1).strip()
        if NEUTRAL.search(val):
            continue
        if ACCENT_VAR.search(val) or HAS_COLOR.search(val):
            ln = text.count('\n', 0, m.start()) + 1
            viol.append((fname, ln, 'border-left-color accent(활성표시 트릭): ' + val[:60]))
    # 3) ::before/::after 가짜 세로 막대 (작은 width + height + 색 background)
    for m in re.finditer(r'([^{}]*::(?:before|after)[^{}]*)\{([^{}]*)\}', text, re.I):
        block = m.group(2)
        wmm = re.search(r'\bwidth\s*:\s*(\d+(?:\.\d+)?)\s*(px|pt)', block, re.I)
        if not wmm:
            continue
        if to_px(float(wmm.group(1)), wmm.group(2)) > 8:
            continue
        if not re.search(r'\bheight\s*:', block, re.I):
            continue
        bg = re.search(r'background(?:-color)?\s*:\s*([^;{}]+)', block, re.I)
        if not bg or NEUTRAL.search(bg.group(1)):
            continue
        if HAS_COLOR.search(bg.group(1)):
            ln = text.count('\n', 0, m.start()) + 1
            viol.append((fname, ln, '::before/after 세로 막대(width≤8px+height+bg)'))

for fp in files:
    try:
        raw = open(fp, 'rb').read().decode('utf-8', 'replace')
    except Exception as e:
        print('SCANFAIL %s: %s' % (fp, e))
        sys.exit(2)
    if fp.lower().endswith(('.html', '.htm')):
        # 인라인 <style> 블록만 CSS로 스캔 + style="" 속성
        css = '\n'.join(sm.group(1) for sm in re.finditer(r'<style[^>]*>(.*?)</style>', raw, re.I | re.S))
        css += '\n' + '\n'.join(am.group(1) for am in re.finditer(r'style\s*=\s*"([^"]*)"', raw, re.I))
        scan_css(css, fp)
    else:
        scan_css(raw, fp)

if viol:
    print('FAIL[no_vertical_stripe] 세로 색 스트라이프 %d건 (카드/헤딩 좌측 색막대 = AI 티, 영구 금지):' % len(viol))
    for f, l, d in viol[:40]:
        print('  %s:%s  %s' % (f, l, d))
    print('  → 해결: 좌측 색막대 제거. 카테고리/상태색은 작은 점(dot)·라벨 텍스트·옅은 배경 틴트·하단 border 로만.')
    sys.exit(1)

print('PASS[no_vertical_stripe] 세로 색 스트라이프 0건 (%d files scanned)' % len(files))
PY
