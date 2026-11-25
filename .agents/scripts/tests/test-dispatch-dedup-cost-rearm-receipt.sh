#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dispatch-dedup-cost-rearm-receipt.sh — GH#40366 regression guard.
#
# Root cause: _cost_spend_from_comments (dispatch-dedup-cost.sh) counted the
# signature footer of every terminal-blocker re-arm receipt as a worker attempt.
# The receipt is runtime bookkeeping posted from whichever session ran recovery;
# its footer carries that whole session's usage (18.3M tokens on #40029), which
# tripped the t2007 cost breaker (28.2M vs 20M budget) after only three real
# worker attempts (~9.9M).
#
# Asserts: re-arm receipts never count as attempts or spend, while genuine
# worker footers still do.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEDUP_HELPER="${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh"

TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
FIXTURE_COMMENTS_JSON="${TEST_ROOT}/fixture-comments.json"

cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "api" ]]; then
	if [[ "\$2" == "repos/"*"/issues/"*"/comments" ]]; then
		if [[ " \$* " == *" --slurp "* ]]; then
			jq -s '.' "${FIXTURE_COMMENTS_JSON}" || exit 1
			exit 0
		fi
		cat "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || echo '[]'
		exit 0
	fi
	if [[ "\$2" == "repos/"*"/issues/"*"/timeline" ]]; then
		printf '[[]]'
		exit 0
	fi
	echo '{}'
	exit 0
fi
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Args: "<kind>|<tokens>|<created_at>"; kind is worker or rearm.
write_comments() {
	local item kind tokens ts body first=1 json=""
	for item in "$@"; do
		IFS='|' read -r kind tokens ts <<<"$item"
		case "$kind" in
		worker) body="Worker run." ;;
		quote) body="Fixed re-arm: quoted marker \`<!-- aidevops:terminal-blocker-rearmed key=abc \` inline." ;;
		rearm) body="<!-- aidevops:terminal-blocker-rearmed key=318f89c8b453b47155f8234f -->\\n<!-- aidevops:terminal-blocker-rearm-reason reason=revision_changed -->" ;;
		*) return 1 ;;
		esac
		body+="\\n\\n<!-- aidevops:sig -->\\n---\\n[aidevops.sh](https://aidevops.sh) v3.39.281 plugin for [OpenCode](https://opencode.ai) v1.19.6 with claude-opus-5-5 spent 33m and ${tokens} tokens on this as a headless worker. Usage includes cache and reasoning. <!-- aidevops:usage:full-v1 -->"
		[[ "$first" -eq 0 ]] && json+=","
		first=0
		json+="{\"body\":\"${body}\",\"created_at\":\"${ts}\",\"user\":{\"login\":\"w\"}}"
	done
	printf '[%s]' "$json" >"$FIXTURE_COMMENTS_JSON"
	return 0
}

run_sum() {
	local issue="$1"
	"$DEDUP_HELPER" sum-issue-token-spend "$issue" "owner/repo" 2>/dev/null || return 1
	return 0
}

# 1. #40029 shape: three worker attempts plus huge re-arm receipts.
write_comments \
	"worker|6084586|2026-11-24T12:17:25Z" \
	"rearm|68278|2026-11-25T01:51:10Z" \
	"worker|1095362|2026-11-25T03:29:04Z" \
	"worker|2714871|2026-11-25T11:37:05Z" \
	"rearm|18301166|2026-11-25T12:03:53Z"
out=$(run_sum 40029)
if [[ "$out" == "9894819|3" ]]; then
	print_result "re-arm receipts excluded (3 worker attempts → 9894819|3)" 0
else
	print_result "re-arm receipts excluded (3 worker attempts → 9894819|3)" 1 "(got: '$out')"
fi

# 2. Receipt-only thread → 0|0.
write_comments "rearm|18301166|2026-11-25T12:03:53Z"
out=$(run_sum 40030)
if [[ "$out" == "0|0" ]]; then
	print_result "receipt-only thread → 0|0" 0
else
	print_result "receipt-only thread → 0|0" 1 "(got: '$out')"
fi

# 3. Genuine worker footers remain counted.
write_comments "worker|30000|2026-11-25T01:00:00Z" "worker|40000|2026-11-25T02:00:00Z"
out=$(run_sum 40031)
if [[ "$out" == "70000|2" ]]; then
	print_result "worker footers still counted (→ 70000|2)" 0
else
	print_result "worker footers still counted (→ 70000|2)" 1 "(got: '$out')"
fi

# 4. Worker report quoting the marker inline stays counted.
write_comments "quote|30000|2026-11-25T01:00:00Z"
out=$(run_sum 40032)
if [[ "$out" == "30000|1" ]]; then
	print_result "inline marker quotation still counted (→ 30000|1)" 0
else
	print_result "inline marker quotation still counted (→ 30000|1)" 1 "(got: '$out')"
fi

export PATH="$OLD_PATH"
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
fi
printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
exit 1
