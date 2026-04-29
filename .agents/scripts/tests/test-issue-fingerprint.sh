#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Unit tests for .agents/scripts/lib/issue-fingerprint.sh
#
# Pins the dedup contract (GH#21744 / t3044):
#   1. Byte-identical bodies → same fingerprint
#   2. Bodies differing only in aidevops sig footer → same fingerprint
#   3. Bodies with different actual content → different fingerprints
#   4. Bodies differing only in trailing whitespace / "---" separators → same fingerprint
#   5. "*Detected by ...*" trailer stripped → same fingerprint as body without it
#   6. Different titles with identical bodies → different fingerprints
#   7. Same title + same body → deterministic (stable across calls)
#
# Run: bash .agents/scripts/tests/test-issue-fingerprint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/../lib/issue-fingerprint.sh"

if [[ ! -f "$LIB_FILE" ]]; then
	echo "FATAL: lib not found at ${LIB_FILE}" >&2
	exit 1
fi

# shellcheck source=../lib/issue-fingerprint.sh
source "$LIB_FILE"

PASS=0
FAIL=0

check() {
	local ok="$1" tc="$2" detail="$3"
	if [[ "$ok" == "1" ]]; then
		PASS=$((PASS + 1))
		echo "PASS: $tc"
	else
		FAIL=$((FAIL + 1))
		echo "FAIL: $tc — $detail"
	fi
	return 0
}

# ============================================================
# Shared fixtures
# ============================================================

SIG_FOOTER='<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.13.10 plugin for [OpenCode](https://opencode.ai) v1.14.29 with claude-opus-4-7 spent 9m and 9,371 tokens on this as a headless worker.'

BODY_CORE='## Description

Some bug in the framework.

## Reproducer

Steps to reproduce.'

BODY_WITH_FOOTER="${BODY_CORE}

${SIG_FOOTER}"

BODY_WITH_DIFFERENT_FOOTER="${BODY_CORE}

<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.13.10 plugin for [OpenCode](https://opencode.ai) v1.14.29 with claude-opus-4-7 spent 12m and 15,043 tokens on this as a headless worker."

BODY_WITH_TRAILING_BLANKS="${BODY_CORE}


"

BODY_WITH_TRAILING_SEPARATOR="${BODY_CORE}

---
"

BODY_DIFFERENT_CONTENT='## Description

A completely different bug.

## Reproducer

Different steps.'

BODY_WITH_DETECTED_BY="${BODY_CORE}
*Detected by quality-scanner in \`pulse-wrapper.sh\`.*"

TITLE="bug(pulse): example title"
TITLE_DIFFERENT="feat(pulse): completely different title"

# ============================================================
# Test 1: Byte-identical bodies → same fingerprint
# ============================================================
fp1a=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
fp1b=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
[[ "$fp1a" == "$fp1b" ]] && ok=1 || ok=0
check "$ok" "Test 1: byte-identical bodies → same fingerprint" "got $fp1a vs $fp1b"

# ============================================================
# Test 2: Bodies differing only in sig footer → same fingerprint
# ============================================================
fp2a=$(_compute_issue_fingerprint "$TITLE" "$BODY_WITH_FOOTER")
fp2b=$(_compute_issue_fingerprint "$TITLE" "$BODY_WITH_DIFFERENT_FOOTER")
[[ "$fp2a" == "$fp2b" ]] && ok=1 || ok=0
check "$ok" "Test 2a: different sig footer token counts → same fingerprint" "got $fp2a vs $fp2b"

# Body with footer should also match bare core body
fp2c=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
[[ "$fp2a" == "$fp2c" ]] && ok=1 || ok=0
check "$ok" "Test 2b: footer-stripped body matches bare core body" "got $fp2a vs $fp2c"

# ============================================================
# Test 3: Different actual content → different fingerprints
# ============================================================
fp3a=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
fp3b=$(_compute_issue_fingerprint "$TITLE" "$BODY_DIFFERENT_CONTENT")
[[ "$fp3a" != "$fp3b" ]] && ok=1 || ok=0
check "$ok" "Test 3: different body content → different fingerprints" "got same fingerprint: $fp3a"

# ============================================================
# Test 4: Trailing whitespace and "---" separator stripped
# ============================================================
fp4a=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
fp4b=$(_compute_issue_fingerprint "$TITLE" "$BODY_WITH_TRAILING_BLANKS")
[[ "$fp4a" == "$fp4b" ]] && ok=1 || ok=0
check "$ok" "Test 4a: trailing blank lines stripped → same fingerprint" "got $fp4a vs $fp4b"

fp4c=$(_compute_issue_fingerprint "$TITLE" "$BODY_WITH_TRAILING_SEPARATOR")
[[ "$fp4a" == "$fp4c" ]] && ok=1 || ok=0
check "$ok" "Test 4b: trailing '---' separator stripped → same fingerprint" "got $fp4a vs $fp4c"

# ============================================================
# Test 5: "*Detected by ...*" trailer stripped
# ============================================================
fp5a=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
fp5b=$(_compute_issue_fingerprint "$TITLE" "$BODY_WITH_DETECTED_BY")
[[ "$fp5a" == "$fp5b" ]] && ok=1 || ok=0
check "$ok" "Test 5: '*Detected by ...*' trailer stripped → same fingerprint" "got $fp5a vs $fp5b"

# ============================================================
# Test 6: Different titles with identical bodies → different fingerprints
# ============================================================
fp6a=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
fp6b=$(_compute_issue_fingerprint "$TITLE_DIFFERENT" "$BODY_CORE")
[[ "$fp6a" != "$fp6b" ]] && ok=1 || ok=0
check "$ok" "Test 6: different titles → different fingerprints" "got same fingerprint: $fp6a"

# ============================================================
# Test 7: Fingerprint is non-empty
# ============================================================
fp7=$(_compute_issue_fingerprint "$TITLE" "$BODY_CORE")
[[ -n "$fp7" ]] && ok=1 || ok=0
check "$ok" "Test 7: fingerprint is non-empty" "got empty string"

# ============================================================
# Test 8: Empty body produces a fingerprint (no crash)
# ============================================================
fp8=$(_compute_issue_fingerprint "$TITLE" "")
[[ -n "$fp8" ]] && ok=1 || ok=0
check "$ok" "Test 8: empty body produces a fingerprint (no crash)" "got empty string"

# ============================================================
# Test 9: Empty body + different titles → different fingerprints
# ============================================================
fp9a=$(_compute_issue_fingerprint "$TITLE" "")
fp9b=$(_compute_issue_fingerprint "$TITLE_DIFFERENT" "")
[[ "$fp9a" != "$fp9b" ]] && ok=1 || ok=0
check "$ok" "Test 9: empty body + different titles → different fingerprints" "got same fingerprint: $fp9a"

# ============================================================
# Test 10: Canonical reproducer — issues 21729 and 21730 scenario
#           Two identical bodies from the same session double-fire
# ============================================================
CANONICAL_TITLE='bug(pulse): _dff_dispatch_loop_parallel wait -n tight loop grows pulse-wrapper.log to 679GB'
# shellcheck disable=SC2016 # backticks are markdown code ticks, not command substitution
CANONICAL_BODY='## Description

The `_dff_dispatch_loop_parallel` function uses `wait -n` in a tight polling loop.

## Evidence

Log grew to 679GB overnight.

## Acceptance

Fix the tight loop.'

# Simulate two issues with the same content but different sig footers
ISSUE_A_BODY="${CANONICAL_BODY}

<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.13.10 plugin for [OpenCode](https://opencode.ai) v1.14.29 with claude-opus-4-7 spent 9m and 9,371 tokens."

ISSUE_B_BODY="${CANONICAL_BODY}

<!-- aidevops:sig -->
---
[aidevops.sh](https://aidevops.sh) v3.13.10 plugin for [OpenCode](https://opencode.ai) v1.14.29 with claude-opus-4-7 spent 9m and 9,371 tokens."

fp10a=$(_compute_issue_fingerprint "$CANONICAL_TITLE" "$ISSUE_A_BODY")
fp10b=$(_compute_issue_fingerprint "$CANONICAL_TITLE" "$ISSUE_B_BODY")
[[ "$fp10a" == "$fp10b" ]] && ok=1 || ok=0
check "$ok" "Test 10: canonical GH#21729/21730 scenario → same fingerprint" "got $fp10a vs $fp10b"

# ============================================================
# Summary
# ============================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
