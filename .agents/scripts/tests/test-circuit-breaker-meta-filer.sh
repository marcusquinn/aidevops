#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-circuit-breaker-meta-filer.sh — t3076 regression guard.
#
# Asserts circuit-breaker-meta-filer.sh:
#   (1) files a meta-issue with a blocked-by:#<meta> link on the original
#       when a breaker trips for the first time
#   (2) is idempotent — second trip on the same original returns the
#       existing meta-issue URL without creating a duplicate
#   (3) honours AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1 as a no-op
#   (4) validates --breaker as one of {cost,no_work}
#   (5) unblock-on-merge removes blocked-by:#<meta> from the original
#       and clears NMR when no other breaker markers remain
#
# Modeled on test-cost-circuit-breaker.sh (t2007).

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META_FILER="${TEST_SCRIPTS_DIR}/circuit-breaker-meta-filer.sh"

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

# Sandbox HOME so config/state writes are side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"

# =============================================================================
# Stub harness — fake `gh` CLI that returns canned responses and logs all
# invocations so we can assert call counts and operations.
# =============================================================================
STUB_DIR="${TEST_ROOT}/bin"
STUB_LOG="${TEST_ROOT}/gh-stub.log"
ISSUE_CREATE_COUNT_FILE="${TEST_ROOT}/issue-create-count"
mkdir -p "$STUB_DIR"
printf '0' >"$ISSUE_CREATE_COUNT_FILE"

# Fixture state files — the stub reads these to vary behaviour per scenario.
FIXTURE_COMMENTS_JSON="${TEST_ROOT}/fixture-comments.json"
FIXTURE_META_BODY="${TEST_ROOT}/fixture-meta-body"
echo '[]' >"$FIXTURE_COMMENTS_JSON"
echo '' >"$FIXTURE_META_BODY"

write_stub_gh() {
	cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
# Stub gh for test-circuit-breaker-meta-filer.sh
echo "\$@" >>"${STUB_LOG}"

# gh issue create --repo SLUG --title T --body B --label L
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
	# Increment counter so we can assert idempotency
	cnt=\$(cat "${ISSUE_CREATE_COUNT_FILE}")
	printf '%s' "\$((cnt + 1))" >"${ISSUE_CREATE_COUNT_FILE}"
	echo 'https://github.com/marcusquinn/aidevops/issues/99999'
	exit 0
fi

# gh api repos/SLUG/issues/N/comments --paginate
if [[ "\$1" == "api" ]]; then
	case "\$2" in
		repos/*/issues/*/comments)
			cat "${FIXTURE_COMMENTS_JSON}" 2>/dev/null || echo '[]'
			exit 0 ;;
		repos/*/issues/*)
			# gh api repos/SLUG/issues/N --jq '.body'
			cat "${FIXTURE_META_BODY}" 2>/dev/null || echo ''
			exit 0 ;;
		user)
			echo '{"login":"test-runner"}'
			exit 0 ;;
		*)
			echo '{}'
			exit 0 ;;
	esac
fi

# gh issue comment N --repo SLUG --body B
if [[ "\$1" == "issue" && "\$2" == "comment" ]]; then
	exit 0
fi

# gh issue edit N --repo SLUG ...
if [[ "\$1" == "issue" && "\$2" == "edit" ]]; then
	exit 0
fi

# gh label list / create
if [[ "\$1" == "label" ]]; then
	[[ "\$2" == "list" ]] && echo '[]'
	exit 0
fi

exit 0
STUB
	chmod +x "${STUB_DIR}/gh"
	return 0
}

write_stub_gh

# Stub gh-signature-helper.sh so signature footer call doesn't blow up
mkdir -p "${HOME}/.aidevops/agents/scripts"
cat >"${STUB_DIR}/gh-signature-helper.sh" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: emit a canonical sig footer marker
[[ "${1:-}" == "footer" ]] && printf '\n\n<!-- aidevops:sig --> stub footer\n'
exit 0
EOF
chmod +x "${STUB_DIR}/gh-signature-helper.sh"

# Prepend the stub dir so the meta-filer picks up our stub gh and sig helper
export PATH="${STUB_DIR}:${PATH}"

# Minimal pulse log so the forensics block has something to slice
PULSE_LOG="${HOME}/.aidevops/logs/pulse.log"
export PULSE_LOG
{
	echo "[2026-04-30 00:00:00] [dispatch_with_dedup] (t2117) Dispatch deferred for #21840 in marcusquinn/aidevops: FOOTPRINT_OVERLAP"
	echo "[2026-04-30 00:01:00] [worker-lifecycle][t2769] no_work breaker armed for #21840 (count=4)"
} >"$PULSE_LOG"

# =============================================================================
# Helper to reset stub state between scenarios
# =============================================================================
reset_stubs() {
	: >"$STUB_LOG"
	printf '0' >"$ISSUE_CREATE_COUNT_FILE"
	echo '[]' >"$FIXTURE_COMMENTS_JSON"
	echo '' >"$FIXTURE_META_BODY"
	return 0
}

count_issue_creates() {
	cat "$ISSUE_CREATE_COUNT_FILE"
	return 0
}

# =============================================================================
# Test 1: First trip files a meta-issue
# =============================================================================
reset_stubs

OUT=$("$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker no_work --failure-count 4 \
	--reason "FOOTPRINT_OVERLAP with #21818" 2>&1)
RC=$?

# Assert: exit 0
if [[ "$RC" -eq 0 ]]; then
	print_result "first-trip: exit 0" 0
else
	print_result "first-trip: exit 0" 1 "got rc=$RC, output: $OUT"
fi

# Assert: meta URL printed on stdout
if printf '%s' "$OUT" | tail -1 | grep -qE 'github\.com/.+/issues/[0-9]+'; then
	print_result "first-trip: prints meta-issue URL" 0
else
	print_result "first-trip: prints meta-issue URL" 1 "stdout: $OUT"
fi

# Assert: exactly one issue created
CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "1" ]]; then
	print_result "first-trip: created exactly 1 issue" 0
else
	print_result "first-trip: created exactly 1 issue" 1 "got count=$CREATE_COUNT"
fi

# =============================================================================
# Test 2: Idempotency — second trip with marker present returns existing
# =============================================================================
reset_stubs
# Simulate an existing marker comment from a prior trip
cat >"$FIXTURE_COMMENTS_JSON" <<'EOF'
[{"body":"<!-- circuit-breaker-meta-filed:#42424 -->\n## prior trip"}]
EOF

OUT=$("$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker no_work --failure-count 5 \
	--reason "second trip" 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "idempotent: exit 0" 0
else
	print_result "idempotent: exit 0" 1 "rc=$RC"
fi

CREATE_COUNT=$(count_issue_creates)
if [[ "$CREATE_COUNT" == "0" ]]; then
	print_result "idempotent: NO new issue created on second trip" 0
else
	print_result "idempotent: NO new issue created on second trip" 1 "got count=$CREATE_COUNT"
fi

if printf '%s' "$OUT" | tail -1 | grep -q '/issues/42424'; then
	print_result "idempotent: returns existing meta-issue URL (#42424)" 0
else
	print_result "idempotent: returns existing meta-issue URL (#42424)" 1 "stdout: $OUT"
fi

# =============================================================================
# Test 3: Disable env var no-ops
# =============================================================================
reset_stubs

AIDEVOPS_CIRCUIT_BREAKER_META_FILE_DISABLE=1 "$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker cost --failure-count 3 \
	--tier standard --spent 50000 --budget 30000 >/dev/null 2>&1
RC=$?

CREATE_COUNT=$(count_issue_creates)
if [[ "$RC" -eq 0 && "$CREATE_COUNT" == "0" ]]; then
	print_result "disable env var: no-op exit 0" 0
else
	print_result "disable env var: no-op exit 0" 1 "rc=$RC count=$CREATE_COUNT"
fi

# =============================================================================
# Test 4: Argument validation
# =============================================================================
reset_stubs

"$META_FILER" file \
	--issue 21840 --repo marcusquinn/aidevops \
	--breaker INVALID --failure-count 1 >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]]; then
	print_result "validation: rejects invalid --breaker" 0
else
	print_result "validation: rejects invalid --breaker" 1 "expected rc=1, got rc=$RC"
fi

"$META_FILER" file --repo marcusquinn/aidevops --breaker cost \
	--failure-count 1 >/dev/null 2>&1
RC=$?
if [[ "$RC" -eq 1 ]]; then
	print_result "validation: rejects missing --issue" 0
else
	print_result "validation: rejects missing --issue" 1 "expected rc=1, got rc=$RC"
fi

# =============================================================================
# Test 5: unblock-on-merge — happy path with original-issue line in body
# =============================================================================
reset_stubs

# Simulate the meta-issue body containing the canonical Original line
cat >"$FIXTURE_META_BODY" <<'EOF'
## Tracking original issue

- Original: marcusquinn/aidevops#21840
- Breaker: `t2769 no_work` (`cost-circuit-breaker:no_work_loop`)
EOF

OUT=$("$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops 2>&1)
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "unblock: exit 0 on happy path" 0
else
	print_result "unblock: exit 0 on happy path" 1 "rc=$RC, output: $OUT"
fi

# Assert: stub gh got an issue edit --remove-label call against #21840
if grep -qE 'issue edit 21840 .* --remove-label blocked-by:#99999' "$STUB_LOG"; then
	print_result "unblock: removes blocked-by:#<meta>" 0
else
	print_result "unblock: removes blocked-by:#<meta>" 1 "stub log: $(cat "$STUB_LOG")"
fi

# Assert: an unblock comment was posted on #21840
if grep -qE 'issue comment 21840 ' "$STUB_LOG"; then
	print_result "unblock: posts unblock comment on original" 0
else
	print_result "unblock: posts unblock comment on original" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Test 6: unblock-on-merge — meta-body without Original line is a no-op
# =============================================================================
reset_stubs
echo 'No tracking line here.' >"$FIXTURE_META_BODY"

"$META_FILER" unblock-on-merge \
	--meta 99999 --repo marcusquinn/aidevops >/dev/null 2>&1
RC=$?

if [[ "$RC" -eq 0 ]]; then
	print_result "unblock: silent no-op when meta has no Original line" 0
else
	print_result "unblock: silent no-op when meta has no Original line" 1 "rc=$RC"
fi

# Assert: NO issue edit on missing-Original case
if ! grep -q 'issue edit ' "$STUB_LOG"; then
	print_result "unblock: makes NO label changes when not a meta-issue" 0
else
	print_result "unblock: makes NO label changes when not a meta-issue" 1 "stub log: $(cat "$STUB_LOG")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Tests run: $TESTS_RUN, failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
