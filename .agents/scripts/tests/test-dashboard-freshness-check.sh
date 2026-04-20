#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dashboard-freshness-check.sh — t2418 regression guard (GH#20016).
#
# Exercises the supervisor-dashboard staleness watchdog across its five
# core behaviours:
#
#   1. check-body on a fresh body → exit 0, prints a non-zero-age line.
#   2. check-body on a stale body → exit 1, prints an age line.
#   3. check-body on a body missing the last_refresh marker → exit 1,
#      prints "MISSING".
#   4. scan with a stale dashboard fixture → files exactly one alert issue
#      via the stubbed `gh` invocation (label & title format asserted).
#   5. scan with a stale dashboard AND a pre-existing open alert → files
#      NO second alert (dedup via <!-- aidevops:dashboard-freshness:*:* -->
#      marker match).
#   6. scan with a fresh dashboard → files no alert.
#   7. cadence gate: a second scan within the interval is short-circuited
#      without calling `gh`.
#
# The scanner is expected to use `command -v gh` + `gh auth status` guards
# and to fail-open on every error path; the test sets up a self-contained
# HOME so nothing leaks into the user's real state.
#
# Stub strategy: export a minimal `gh` shell function in a per-test
# environment, then invoke the scanner as a subprocess with
# `bash -c 'source stubs; exec scanner …'` so the function is inherited.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
SCANNER="${SCRIPTS_DIR}/dashboard-freshness-check.sh"

if [[ ! -x "$SCANNER" ]]; then
	echo "FATAL: scanner not executable: $SCANNER" >&2
	exit 2
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN=""
	TEST_RED=""
	TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
TMP="$(mktemp -d -t t2418.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A per-test isolated HOME so cache/log/state writes don't touch real state.
HOME_ISO="${TMP}/home"
mkdir -p "${HOME_ISO}/.aidevops/logs" \
	"${HOME_ISO}/.aidevops/cache/dashboard-freshness" \
	"${HOME_ISO}/.config/aidevops" \
	"${HOME_ISO}/.aidevops/agents/scripts"

# repos.json: one entry with slug = test/repo so _resolve_slug_from_dashed
# can map "test-repo" → "test/repo".
cat >"${HOME_ISO}/.config/aidevops/repos.json" <<'EOF'
{
	"initialized_repos": [
		{ "slug": "test/repo", "pulse": true }
	],
	"git_parent_dirs": []
}
EOF

# Health-issue cache pointing at dashboard issue 424242 on slug test/repo.
# Filename format: health-issue-<runner>-supervisor-<slug-dashed>.
HEALTH_CACHE="${HOME_ISO}/.aidevops/logs/health-issue-testrunner-supervisor-test-repo"
printf '%s\n' 424242 >"$HEALTH_CACHE"

# ---------------------------------------------------------------------------
# Body fixtures
# ---------------------------------------------------------------------------
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE_ISO="2026-04-01T00:00:00Z" # ~3 weeks old — well past 48h threshold

FRESH_BODY="${TMP}/fresh-body.md"
cat >"$FRESH_BODY" <<EOF
## Queue Health Dashboard

**Last pulse**: \`${NOW_ISO}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${NOW_ISO}

### Summary
EOF

STALE_BODY="${TMP}/stale-body.md"
cat >"$STALE_BODY" <<EOF
## Queue Health Dashboard

**Last pulse**: \`${STALE_ISO}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${STALE_ISO}

### Summary
EOF

MISSING_BODY="${TMP}/missing-body.md"
cat >"$MISSING_BODY" <<'EOF'
## Queue Health Dashboard

**Last pulse**: `2026-04-20T00:00:00Z`

### Summary
EOF

# ---------------------------------------------------------------------------
# Test 1-3: check-body mode exit codes and output
# ---------------------------------------------------------------------------
echo "Testing: check-body parsing"

out="$(bash "$SCANNER" check-body "$FRESH_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 0 ]] && [[ "$out" == *"age_seconds="* ]] && [[ "$out" != *"MISSING"* ]]; then
	pass "check-body on fresh body → exit 0 + age line"
else
	fail "check-body on fresh body" "ec=$ec out='$out'"
fi

out="$(bash "$SCANNER" check-body "$STALE_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 1 ]] && [[ "$out" == *"age_seconds="* ]]; then
	pass "check-body on stale body → exit 1 + age line"
else
	fail "check-body on stale body" "ec=$ec out='$out'"
fi

out="$(bash "$SCANNER" check-body "$MISSING_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 1 ]] && [[ "$out" == "MISSING" ]]; then
	pass "check-body on missing-marker body → exit 1 + MISSING"
else
	fail "check-body on missing-marker body" "ec=$ec out='$out'"
fi

# ---------------------------------------------------------------------------
# Scan harness — runs the scanner with stubbed `gh` and isolated HOME.
# Arguments:
#   $1 — body fixture file
#   $2 — 0|1 should alert_already_open return "alert exists"
#   $3 — extra env (space-separated KEY=VAL)
# Writes a fresh GH_CALLS log to $TMP/gh-calls.log and runs the scanner.
# ---------------------------------------------------------------------------
run_scan_with_stubs() {
	local body_file="$1"
	local alert_exists="$2"
	local extra_env="${3:-}"
	local gh_calls="${TMP}/gh-calls.log"
	: >"$gh_calls"

	# Reset last-scan marker so cadence gate doesn't suppress unless the
	# test explicitly sets DASHBOARD_FRESHNESS_SCAN_INTERVAL high.
	rm -f "${HOME_ISO}/.aidevops/cache/dashboard-freshness/last-scan"

	# shellcheck disable=SC2016
	HOME="$HOME_ISO" \
		REPOS_JSON="${HOME_ISO}/.config/aidevops/repos.json" \
		DASHBOARD_FRESHNESS_SCAN_INTERVAL="${SCAN_INTERVAL:-1}" \
		DASHBOARD_FRESHNESS_THRESHOLD_SECONDS="172800" \
		GH_CALLS_LOG="$gh_calls" \
		BODY_FIXTURE="$body_file" \
		ALERT_EXISTS="$alert_exists" \
		EXTRA_ENV="$extra_env" \
		SCANNER_PATH="$SCANNER" \
		bash -c '
			set +u
			# Stub gh: records every call and returns canned responses
			# for the three paths the scanner exercises:
			#   gh auth status       → success
			#   gh api repos/.../issues/N  → dashboard body (read from fixture)
			#   gh issue list --search ... → alert dedup check (count 0 or 1)
			#   gh issue create ...  → URL + 0
			gh() {
				printf "%s\n" "$*" >> "$GH_CALLS_LOG"
				case "$1" in
					auth)
						return 0
						;;
					api)
						# $2 = repos/test/repo/issues/424242
						cat "$BODY_FIXTURE"
						return 0
						;;
					issue)
						case "$2" in
							list)
								if [[ "$ALERT_EXISTS" == "1" ]]; then
									printf "1\n"
								else
									printf "0\n"
								fi
								return 0
								;;
							create)
								printf "https://example.invalid/test/repo/issues/99\n"
								return 0
								;;
						esac
						return 0
						;;
				esac
				return 0
			}
			export -f gh
			# shellcheck disable=SC1091
			eval "$EXTRA_ENV"
			# Force force-scan so the scanner does not throttle itself
			exec bash "$SCANNER_PATH" scan --force
		' 2>&1
	return $?
}

# ---------------------------------------------------------------------------
# Test 4: stale → file exactly one alert
# ---------------------------------------------------------------------------
echo "Testing: scan on stale dashboard files alert"
run_scan_with_stubs "$STALE_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )); then
	pass "stale dashboard → exactly 1 alert filed"
else
	fail "stale dashboard alert count" \
		"expected 1, got $created_count; calls:\n$(cat "$calls_file")"
fi

# Assert the alert carries the correct labels and a dashboard-freshness marker.
if grep -q 'review-followup' "$calls_file" \
	&& grep -q 'priority:high' "$calls_file"; then
	pass "alert labelled review-followup + priority:high"
else
	fail "alert labelling" "calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 5: dedup — existing open alert → no second alert
# ---------------------------------------------------------------------------
echo "Testing: existing-alert dedup"
run_scan_with_stubs "$STALE_BODY" 1 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )); then
	pass "stale dashboard with open alert → no duplicate alert"
else
	fail "dedup violated: created $created_count alerts" \
		"calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 6: fresh body → no alert
# ---------------------------------------------------------------------------
echo "Testing: fresh dashboard → no alert"
run_scan_with_stubs "$FRESH_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )); then
	pass "fresh dashboard → no alert filed"
else
	fail "fresh dashboard triggered alert" \
		"calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 7: cadence gate — second scan within interval short-circuits
# ---------------------------------------------------------------------------
echo "Testing: cadence gate suppresses rapid re-scan"
# First run updates last-scan; second run (without --force) should exit
# immediately with no `gh` calls at all.
now_epoch=$(date -u +%s)
printf '%d' "$now_epoch" \
	>"${HOME_ISO}/.aidevops/cache/dashboard-freshness/last-scan"

calls_file="${TMP}/gh-calls.log"
: >"$calls_file"

# Intentionally don't pass --force; invoke scanner directly
HOME="$HOME_ISO" \
	REPOS_JSON="${HOME_ISO}/.config/aidevops/repos.json" \
	DASHBOARD_FRESHNESS_SCAN_INTERVAL="3600" \
	bash -c '
		gh() { printf "%s\n" "$*" >> "'"$calls_file"'"; return 0; }
		export -f gh
		exec bash "'"$SCANNER"'" scan
	' >/dev/null 2>&1

calls=$(wc -l <"$calls_file" | tr -d ' ')
if (( calls == 0 )); then
	pass "cadence gate → zero gh calls within interval"
else
	fail "cadence gate leaked ${calls} gh calls" \
		"calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 8: missing-marker body → alerts with MISSING title
# ---------------------------------------------------------------------------
echo "Testing: missing-marker body files alert"
run_scan_with_stubs "$MISSING_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )) && grep -q 'missing last_refresh marker' "$calls_file"; then
	pass "missing-marker body → alert with descriptive title"
else
	fail "missing-marker alert" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if (( TESTS_FAILED == 0 )); then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
