#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  PASS %s\n' "$1"; return 0; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; return 0; }

TMP=$(mktemp -d -t health-identity.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
export LOGFILE="${TMP}/stats.log"
export AIDEVOPS_IDENTITY_ALIASES_CONF="${TMP}/identity-aliases.conf"
mkdir -p "${HOME}/.aidevops/logs"
: >"$LOGFILE"

printf '%s\n' 'canonical-operator=local-user,github-user' >"$AIDEVOPS_IDENTITY_ALIASES_CONF"

GH_CALLS="${TMP}/gh-calls.log"
: >"$GH_CALLS"

# shellcheck disable=SC2317
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	case "$call" in
		*"issue list --repo owner/repo --label source:health-dashboard"*)
			printf '%s' '[{"number":20408,"title":"[Supervisor:github-user] 1 PR at 10:00 UTC","labels":[{"name":"source:health-dashboard"},{"name":"supervisor"},{"name":"github-user"}],"createdAt":"2026-05-01T10:00:00Z"},{"number":18669,"title":"[Contributor:local-user] 0 PRs at 09:00 UTC","labels":[{"name":"source:health-dashboard"},{"name":"contributor"},{"name":"local-user"}],"createdAt":"2026-04-01T09:00:00Z"}]'
			return 0
			;;
		*) return 0 ;;
	esac
	return 0
}

# shellcheck disable=SC2317
gh_issue_list() { gh issue list "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_issue_view() { gh issue view "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_create_issue() { gh issue create "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_issue_edit_safe() { gh issue edit "$@" && return 0; return 1; }

# shellcheck source=../portable-stat.sh
source "${SCRIPTS_DIR}/portable-stat.sh"
# shellcheck source=../stats-shared.sh
source "${SCRIPTS_DIR}/stats-shared.sh"
# shellcheck source=../stats-health-dashboard.sh
source "${SCRIPTS_DIR}/stats-health-dashboard.sh"

# shellcheck disable=SC2317
_unpin_health_issue() { printf 'unpin %s\n' "$*" >>"$GH_CALLS"; return 0; }

identity_lines=$(_dashboard_identity_aliases "github-user")
canonical=$(printf '%s\n' "$identity_lines" | sed -n '1p')
aliases=$(printf '%s\n' "$identity_lines" | sed '1d')

if [[ "$canonical" == "canonical-operator" ]]; then
	pass "resolves GitHub username to canonical operator"
else
	fail "resolves GitHub username to canonical operator" "canonical=${canonical}"
fi

result=$(_find_health_issue "owner/repo" "github-user" "supervisor" "[Supervisor:canonical-operator]" \
	"supervisor" "Supervisor" "${HOME}/.aidevops/logs/health-issue-canonical-owner-repo" \
	"$canonical" "$aliases")

if [[ "$result" == "20408" ]]; then
	pass "keeps deterministic newest dashboard across aliases and roles"
else
	fail "keeps deterministic newest dashboard across aliases and roles" "result=${result}"
fi

if grep -q 'issue close 18669' "$GH_CALLS"; then
	pass "closes stale alias dashboard"
else
	fail "closes stale alias dashboard" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

if grep -q 'canonical operator canonical-operator' "$GH_CALLS"; then
	pass "dedup close comment names canonical identity"
else
	fail "dedup close comment names canonical identity" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

before_malformed_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)
_close_health_issue_identity_duplicates \
	'[{"number":20408},{"number":20316},{"number":18669}]' \
	$'https://example.invalid/issues/20316\nhttps://example.invalid/issues/18669\n20408' \
	"owner/repo" "canonical-operator" "github-user"
after_malformed_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)

if [[ "$after_malformed_close_count" == "$before_malformed_close_count" ]]; then
	pass "does not close persistent dashboards without one numeric supersession target"
else
	fail "does not close persistent dashboards without one numeric supersession target" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

before_periodic_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)
HEALTH_DEDUP_INTERVAL=0 _periodic_health_issue_dedup \
	"owner/repo" "github-user" "supervisor" "supervisor" "Supervisor" \
	$'https://example.invalid/issues/20316\nhttps://example.invalid/issues/18669\n20408' \
	"canonical-operator" "$aliases"
after_periodic_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)

if [[ "$after_periodic_close_count" == "$before_periodic_close_count" ]]; then
	pass "periodic dedup skips malformed cached current issue"
else
	fail "periodic dedup skips malformed cached current issue" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

extracted=$(_health_issue_number_from_text $'noise\nhttps://example.invalid/issues/20316\n20408')
if [[ "$extracted" == "20408" ]]; then
	pass "extracts one issue number from noisy wrapper output"
else
	fail "extracts one issue number from noisy wrapper output" "extracted=${extracted}"
fi

body=$(_build_health_issue_body \
	"2026-05-08T00:00:00Z" "Supervisor" "github-user" "owner/repo" \
	"0" "0" "0" "0" "4" "1" "0" "" \
	"_No open PRs_" "_No active workers_" "_Person stats_" "_Cross stats_" \
	"_Session time_" "_Cross session_" "_Activity_" "_Cross activity_" \
	"0" "4" "0.00" "0.00" "low" "100" "supervisor" \
	"—" "—" "0" "0" "_No diagnostics_" "$canonical" "$aliases")

if [[ "$body" == *"canonical:"* && "$body" == *"canonical-operator"* && "$body" == *"local-user"* ]]; then
	pass "dashboard body exposes canonical identity context"
else
	fail "dashboard body exposes canonical identity context" "$body"
fi

printf '\n== Summary ==\n'
if ((TESTS_FAILED > 0)); then
	printf '  %d failed of %d tests\n' "$TESTS_FAILED" "$TESTS_RUN"
	exit 1
fi
printf '  All %d tests passed\n' "$TESTS_RUN"
exit 0
