#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-circuit-breaker-investigation-task.sh — t3208 / GH#21923 regression guard.
#
# Asserts circuit-breaker-helper.sh's supervisor breaker:
#   (1) on first-trip notification creation, also files a sibling
#       investigation task with the canonical 5-label set
#   (2) the investigation title encodes the trip issue number,
#       failure_reason, and consecutive-failure count
#   (3) the investigation body links back via `Ref #<trip-issue-num>`
#       so triage can navigate from notification to root-cause work
#   (4) honours CB_SKIP_INVESTIGATION_TASK=true as a no-op (trip
#       notification still files, investigation task does not)
#   (5) does not file an investigation task on a re-trip path —
#       _cb_update_existing_issue posts a comment, not a new issue
#
# Modeled on test-circuit-breaker-meta-filer.sh (t3076) for stub-gh harness.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${TEST_SCRIPTS_DIR}/circuit-breaker-helper.sh"

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

# Sandbox HOME so config/state writes are side-effect-free.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# Isolated breaker state directory so we don't fight a real breaker file.
SUPERVISOR_DIR="${TEST_ROOT}/supervisor"
mkdir -p "$SUPERVISOR_DIR"
export SUPERVISOR_DIR

# Pin repo so _cb_resolve_repo_slug doesn't shell out to `gh repo view`.
export SUPERVISOR_CIRCUIT_BREAKER_REPO="marcusquinn/aidevops"

# =============================================================================
# Stub harness — fake `gh` CLI that logs all invocations and returns a
# deterministic issue URL on `gh issue create`.
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
STUB_LOG="${TEST_ROOT}/gh-stub.log"
ISSUE_CREATE_BODIES_DIR="${TEST_ROOT}/issue-create-bodies"
ISSUE_CREATE_COUNT_FILE="${TEST_ROOT}/issue-create-count"
mkdir -p "$STUB_DIR" "$ISSUE_CREATE_BODIES_DIR"
printf '0' >"$ISSUE_CREATE_COUNT_FILE"

write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test-circuit-breaker-investigation-task.sh
# Logs every invocation to STUB_LOG and captures \`gh issue create\` flags
# so tests can assert on title/body/label arguments after the fact.
echo "\$@" >>"${STUB_LOG}"

if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
	cnt=\$(cat "${ISSUE_CREATE_COUNT_FILE}")
	cnt=\$((cnt + 1))
	printf '%s' "\$cnt" >"${ISSUE_CREATE_COUNT_FILE}"
	# Persist the entire flag vector verbatim for per-create assertions.
	printf '%s\n' "\$@" >"${ISSUE_CREATE_BODIES_DIR}/create-\$cnt.argv"
	# Issue numbers 99001 (trip), 99002 (investigation), etc.
	echo "https://github.com/marcusquinn/aidevops/issues/9900\$cnt"
	exit 0
fi

if [[ "\$1" == "issue" && "\$2" == "list" ]]; then
	# No existing open issue → triggers _cb_create_new_issue path.
	echo ''
	exit 0
fi

if [[ "\$1" == "label" ]]; then
	exit 0
fi

if [[ "\$1" == "issue" && ( "\$2" == "comment" || "\$2" == "edit" || "\$2" == "close" ) ]]; then
	exit 0
fi

if [[ "\$1" == "api" ]]; then
	# Used by gh_create_issue wrapper for rate-limit checks etc.
	echo '{}'
	exit 0
fi

if [[ "\$1" == "auth" && "\$2" == "status" ]]; then
	exit 0
fi

exit 0
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

write_stub_gh

# Stub gh-signature-helper.sh so signature footer call doesn't break the
# helper. Emit the canonical sig marker so the body still passes any
# downstream `<!-- aidevops:sig -->` assertion gates.
mkdir -p "${HOME}/.aidevops/agents/scripts"
cat >"${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "footer" ]] && printf '\n\n<!-- aidevops:sig --> stub footer\n'
exit 0
EOF
chmod +x "${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh"

# Prepend stub dir so the helper picks up our fake gh.
export PATH="${STUB_DIR}:${PATH}"

# =============================================================================
# Helpers
# =============================================================================
reset_stubs() {
	: >"$STUB_LOG"
	rm -f "$ISSUE_CREATE_BODIES_DIR"/create-*.argv 2>/dev/null || true
	printf '0' >"$ISSUE_CREATE_COUNT_FILE"
	# Clean breaker state between scenarios so each test starts CLOSED.
	rm -f "${SUPERVISOR_DIR}/circuit-breaker.state" 2>/dev/null || true
	return 0
}

count_issue_creates() {
	cat "$ISSUE_CREATE_COUNT_FILE"
	return 0
}

# Find the create-N.argv whose arg list contains all of the given labels.
# Args: each arg is a `--label <value>` pair to search for.
# Outputs: path to the matching argv file, or empty if no match.
find_create_with_labels() {
	local f
	for f in "$ISSUE_CREATE_BODIES_DIR"/create-*.argv; do
		[[ -f "$f" ]] || continue
		local matched=true label
		for label in "$@"; do
			if ! grep -qFx -- "$label" "$f"; then
				matched=false
				break
			fi
		done
		[[ "$matched" == "true" ]] && {
			echo "$f"
			return 0
		}
	done
	return 0
}

# =============================================================================
# Test 1: First trip files BOTH a notification and an investigation task
# =============================================================================
reset_stubs

OUT=$("$HELPER" trip "t999-test" "watchdog_stall_killed" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "trip: exit 0" 0
else
	print_result "trip: exit 0" 1 "got rc=$RC, output: $OUT"
fi

CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "2" ]]; then
	print_result "trip: created exactly 2 issues (notification + investigation)" 0
else
	print_result "trip: created exactly 2 issues (notification + investigation)" 1 \
		"got count=$CREATE_COUNT; stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 2: Investigation issue carries the canonical 5-label set
# =============================================================================
INV_ARGV=$(find_create_with_labels \
	"source:circuit-breaker-investigation" \
	"auto-dispatch" \
	"tier:thinking" \
	"bug" \
	"framework")

if [[ -n "$INV_ARGV" && -f "$INV_ARGV" ]]; then
	print_result "investigation: carries all 5 canonical labels" 0
else
	print_result "investigation: carries all 5 canonical labels" 1 \
		"no create call had the full label set; argv files: $(ls "$ISSUE_CREATE_BODIES_DIR" 2>/dev/null)"
fi

# =============================================================================
# Test 3: Investigation title encodes trip issue number, reason, count
# =============================================================================
if [[ -n "${INV_ARGV:-}" && -f "$INV_ARGV" ]]; then
	# The trip notification gets issue 99001, investigation gets 99002.
	# So the investigation references trip #99001.
	# Title pattern: "Investigate circuit-breaker trip #99001: watchdog_stall_killed after 3 consecutive failures"
	if grep -qF "Investigate circuit-breaker trip #99001" "$INV_ARGV" \
		&& grep -qF "watchdog_stall_killed" "$INV_ARGV" \
		&& grep -qE "after [0-9]+ consecutive failures" "$INV_ARGV"; then
		print_result "investigation: title encodes trip# / reason / count" 0
	else
		print_result "investigation: title encodes trip# / reason / count" 1 \
			"argv: $(cat "$INV_ARGV")"
	fi
else
	print_result "investigation: title encodes trip# / reason / count" 1 \
		"investigation argv not found (preceding test failed)"
fi

# =============================================================================
# Test 4: Investigation body links back via Ref #<trip>
# =============================================================================
if [[ -n "${INV_ARGV:-}" && -f "$INV_ARGV" ]]; then
	if grep -qF "Ref #99001" "$INV_ARGV"; then
		print_result "investigation: body contains Ref #<trip-issue-num> backlink" 0
	else
		print_result "investigation: body contains Ref #<trip-issue-num> backlink" 1 \
			"argv lacked 'Ref #99001'; saw: $(grep -c '#' "$INV_ARGV") '#' chars total"
	fi
else
	print_result "investigation: body contains Ref #<trip-issue-num> backlink" 1 \
		"investigation argv not found"
fi

# =============================================================================
# Test 5: CB_SKIP_INVESTIGATION_TASK=true suppresses ONLY the investigation,
#         not the trip notification
# =============================================================================
reset_stubs
export CB_SKIP_INVESTIGATION_TASK=true

OUT=$("$HELPER" trip "t998-skip" "rate_limit" 2>&1)
RC=$?
unset CB_SKIP_INVESTIGATION_TASK

if [[ "$RC" -eq 0 ]]; then
	CREATE_COUNT=$(count_issue_creates)
	if [[ "$CREATE_COUNT" == "1" ]]; then
		print_result "CB_SKIP_INVESTIGATION_TASK=true: only trip notification filed" 0
	else
		print_result "CB_SKIP_INVESTIGATION_TASK=true: only trip notification filed" 1 \
			"expected 1 create, got $CREATE_COUNT"
	fi
else
	print_result "CB_SKIP_INVESTIGATION_TASK=true: only trip notification filed" 1 \
		"trip command failed: rc=$RC, output: $OUT"
fi

# Confirm the surviving create is the trip notification, not an investigation.
if [[ -f "${ISSUE_CREATE_BODIES_DIR}/create-1.argv" ]]; then
	if grep -qFx -- "circuit-breaker" "${ISSUE_CREATE_BODIES_DIR}/create-1.argv" \
		&& ! grep -qFx -- "source:circuit-breaker-investigation" "${ISSUE_CREATE_BODIES_DIR}/create-1.argv"; then
		print_result "CB_SKIP_INVESTIGATION_TASK=true: surviving create is the trip notification" 0
	else
		print_result "CB_SKIP_INVESTIGATION_TASK=true: surviving create is the trip notification" 1 \
			"argv: $(cat "${ISSUE_CREATE_BODIES_DIR}/create-1.argv")"
	fi
else
	print_result "CB_SKIP_INVESTIGATION_TASK=true: surviving create is the trip notification" 1 \
		"create-1.argv missing"
fi

# =============================================================================
# Test 6: Re-trip path (existing open issue) does NOT file a new investigation
# =============================================================================
# Simulate _cb_find_open_issue returning a hit by re-stubbing `gh issue list`
# to print an issue number. We rewrite the stub for this scenario only.
reset_stubs
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$@" >>"GH_STUB_LOG_PLACEHOLDER"

if [[ "$1" == "issue" && "$2" == "create" ]]; then
	cnt=$(cat "ISSUE_CREATE_COUNT_FILE_PLACEHOLDER")
	cnt=$((cnt + 1))
	printf '%s' "$cnt" >"ISSUE_CREATE_COUNT_FILE_PLACEHOLDER"
	printf '%s\n' "$@" >"ISSUE_CREATE_BODIES_DIR_PLACEHOLDER/create-$cnt.argv"
	echo "https://github.com/marcusquinn/aidevops/issues/9900$cnt"
	exit 0
fi

if [[ "$1" == "issue" && "$2" == "list" ]]; then
	# Pretend an open trip notification already exists — issue #88888.
	echo '88888'
	exit 0
fi

if [[ "$1" == "label" || "$1" == "auth" ]]; then
	exit 0
fi
if [[ "$1" == "issue" && ( "$2" == "comment" || "$2" == "edit" || "$2" == "close" ) ]]; then
	exit 0
fi
if [[ "$1" == "api" ]]; then
	echo '{}'
	exit 0
fi
exit 0
STUB
# Substitute placeholders with the real test paths.
sed -i.bak \
	-e "s|GH_STUB_LOG_PLACEHOLDER|${STUB_LOG}|g" \
	-e "s|ISSUE_CREATE_COUNT_FILE_PLACEHOLDER|${ISSUE_CREATE_COUNT_FILE}|g" \
	-e "s|ISSUE_CREATE_BODIES_DIR_PLACEHOLDER|${ISSUE_CREATE_BODIES_DIR}|g" \
	"${STUB_DIR}/gh"
rm -f "${STUB_DIR}/gh.bak"
chmod +x "${STUB_DIR}/gh"

OUT=$("$HELPER" trip "t997-retrip" "no_worker_process" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	CREATE_COUNT=$(count_issue_creates)
	if [[ "$CREATE_COUNT" == "0" ]]; then
		print_result "re-trip: no investigation filed when trip notification already open" 0
	else
		print_result "re-trip: no investigation filed when trip notification already open" 1 \
			"expected 0 creates (only a comment), got $CREATE_COUNT"
	fi
else
	print_result "re-trip: no investigation filed when trip notification already open" 1 \
		"trip command failed: rc=$RC, output: $OUT"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "Total:  $TESTS_RUN"
echo "Failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
