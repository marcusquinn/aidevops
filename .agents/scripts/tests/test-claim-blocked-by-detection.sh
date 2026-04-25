#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-blocked-by-detection.sh — GH#20834 regression guard.
#
# Validates _detect_predecessor_refs() in claim-task-id.sh correctly extracts
# predecessor references from description text and emits comma-separated IDs.
#
# Cases covered:
#   1. Pattern 1: "Follow-up from tNNN"          → t-style ref
#   2. Pattern 1: "Follow-up from GH#NNN"         → GH# ref
#   3. Pattern 2: "tracked in GH#NNN"             → GH# ref
#   4. Pattern 2: "tracked in #NNN"               → normalised to GH#NNN
#   5. Pattern 3: "blocked-by:tNNN"               → explicit pass-through
#   6. Pattern 3: "blocked-by: GH#NNN" (space)    → explicit pass-through
#   7. Pattern 4: "after tNNN ships"              → t-style ref
#   8. Pattern 4: "after tNNN merges"             → t-style ref
#   9. Pattern 4: "after tNNN lands"              → t-style ref
#  10. Multiple patterns in one description        → comma-separated, ordered
#  11. Deduplication: same ref via two patterns    → emitted only once
#  12. No-match description                        → empty output
#  13. Empty description                           → empty output
#  14. --no-blocked-by suppresses detection        → _CLAIM_BLOCKED_BY_REFS stays empty
#
# NOTE: not using `set -e` — assertions rely on capturing non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

# ---------------------------------------------------------------------------
# Test framework helpers
# ---------------------------------------------------------------------------

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       expected: %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}\n  - ${name}: ${detail}"
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		pass "$name"
	else
		fail "$name" "want='${want}' got='${got}'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Source claim-task-id.sh to access _detect_predecessor_refs and
# _apply_blocked_by_detection. The BASH_SOURCE guard prevents main() from
# running on source.
# ---------------------------------------------------------------------------
_setup() {
	# Provide minimal stubs so sub-library sourcing succeeds in a test env.
	local stub_dir
	stub_dir=$(mktemp -d)
	trap 'rm -rf '"$stub_dir"'' EXIT

	# Fake git: return empty string for remote get-url (silences detect_platform)
	cat >"${stub_dir}/git" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "${stub_dir}/git"

	# Fake gh: auth ok, everything else no-op
	cat >"${stub_dir}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then exit 0; fi
exit 0
STUB
	chmod +x "${stub_dir}/gh"

	# Fake jq: return empty string (so label validation skips)
	cat >"${stub_dir}/jq" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "${stub_dir}/jq"

	export PATH="${stub_dir}:${PATH}"
	export HOME="${stub_dir}/home"
	mkdir -p "${HOME}/.aidevops/logs"

	# shellcheck disable=SC1090
	if ! source "$CLAIM_SCRIPT" 2>/dev/null; then
		printf '%s[FATAL]%s Failed to source %s\n' "$RED" "$NC" "$CLAIM_SCRIPT" >&2
		exit 1
	fi

	return 0
}

_setup

# ---------------------------------------------------------------------------
# Helper: run _detect_predecessor_refs and capture output
# ---------------------------------------------------------------------------
detect() {
	local text="$1"
	_detect_predecessor_refs "$text" 2>/dev/null || true
	return 0
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

# 1. Pattern 1 — t-style ref
assert_eq "pattern1_t_style" \
	"$(detect 'Follow-up from t2799 after one release cycle')" \
	"t2799"

# 2. Pattern 1 — GH# ref
assert_eq "pattern1_gh_style" \
	"$(detect 'Follow-up from GH#20774 per discussion')" \
	"GH#20774"

# 3. Pattern 2 — GH# ref
assert_eq "pattern2_gh_style" \
	"$(detect 'This work is tracked in GH#20734 roadmap')" \
	"GH#20734"

# 4. Pattern 2 — bare #NNN normalised to GH#NNN
assert_eq "pattern2_bare_hash_normalised" \
	"$(detect 'This work is tracked in #20734')" \
	"GH#20734"

# 5. Pattern 3 — explicit blocked-by (no space)
assert_eq "pattern3_explicit_no_space" \
	"$(detect 'blocked-by:t2799 and nothing else')" \
	"t2799"

# 6. Pattern 3 — explicit blocked-by with space
assert_eq "pattern3_explicit_with_space" \
	"$(detect 'This is blocked-by: GH#20774 until that lands')" \
	"GH#20774"

# 7. Pattern 4 — after tNNN ships
assert_eq "pattern4_ships" \
	"$(detect 'Clean up the old API after t2799 ships')" \
	"t2799"

# 8. Pattern 4 — after tNNN merges
assert_eq "pattern4_merges" \
	"$(detect 'Run after t2800 merges into main')" \
	"t2800"

# 9. Pattern 4 — after tNNN lands
assert_eq "pattern4_lands" \
	"$(detect 'Deploy after t2801 lands in production')" \
	"t2801"

# 10. Multiple patterns → comma-separated in detection order
assert_eq "multiple_patterns_ordered" \
	"$(detect 'Follow-up from t2799 — do X after t2800 ships')" \
	"t2799,t2800"

# 11. Deduplication — same ref via two patterns → emitted once
assert_eq "deduplication_same_ref" \
	"$(detect 'Follow-up from t2799, blocked-by:t2799 explicitly')" \
	"t2799"

# 12. No match — unrelated description → empty
assert_eq "no_match_returns_empty" \
	"$(detect 'Completely unrelated task with no predecessor')" \
	""

# 13. Empty description → empty
assert_eq "empty_description_returns_empty" \
	"$(detect '')" \
	""

# 14. --no-blocked-by suppresses detection via _apply_blocked_by_detection
# Save and restore globals so this test doesn't pollute other state.
_saved_no_blocked_by="$NO_BLOCKED_BY"
_saved_task_desc="$TASK_DESCRIPTION"
_saved_dry_run="$DRY_RUN"
_saved_blocked_refs="$_CLAIM_BLOCKED_BY_REFS"
NO_BLOCKED_BY=true
TASK_DESCRIPTION="Follow-up from t2799 after one release cycle"
DRY_RUN=false
_CLAIM_BLOCKED_BY_REFS=""
_apply_blocked_by_detection 2>/dev/null
assert_eq "no_blocked_by_suppresses_detection" "$_CLAIM_BLOCKED_BY_REFS" ""
NO_BLOCKED_BY="$_saved_no_blocked_by"
TASK_DESCRIPTION="$_saved_task_desc"
DRY_RUN="$_saved_dry_run"
_CLAIM_BLOCKED_BY_REFS="$_saved_blocked_refs"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%d tests run: %d passed, %d failed\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
	printf '\nFailed tests:%b\n' "$ERRORS"
	exit 1
fi

exit 0
