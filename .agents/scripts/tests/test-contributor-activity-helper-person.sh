#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSON_LIB="${SCRIPT_DIR}/../contributor-activity-helper-person.sh"
DASHBOARD_LIB="${SCRIPT_DIR}/../stats-health-dashboard-data.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '[PASS] %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf '[FAIL] %s\n       %s\n' "$name" "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

define_timeout_sec_mock() {
	timeout_sec() {
		local _seconds="$1"
		shift
		[[ -n "$_seconds" ]] || return 124
		"$@"
		return $?
	}
	return 0
}

test_person_stats_uses_portable_timeout() {
	local name="person stats wraps gh api with timeout_sec"
	local wrapper_pattern="timeout_sec \"\$timeout_budget\" gh api \"\$@\""
	if grep -Fq "$wrapper_pattern" "$PERSON_LIB" && grep -q 'PERSON_STATS_CROSS_REPO_GH_API_TIMEOUT' "$PERSON_LIB"; then
		pass "$name"
	else
		fail "$name" "missing portable gh api wrapper or cross-repo budget"
	fi
	return 0
}

test_person_stats_has_no_direct_timeout() {
	local name="person stats does not call direct timeout"
	if grep -Eq '(^|[[:space:]])timeout[[:space:]]+[0-9]' "$PERSON_LIB"; then
		fail "$name" "found direct timeout invocation"
	else
		pass "$name"
	fi
	return 0
}

test_dashboard_wraps_person_stats_with_timeout() {
	local name="dashboard wraps person-stats helpers with timeout_sec"
	local person_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_TIMEOUT\" bash \"\$activity_helper\" person-stats"
	local cross_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_TIMEOUT\" bash \"\$activity_helper\" cross-repo-person-stats"
	if grep -Fq "$person_pattern" "$DASHBOARD_LIB" && grep -Fq "$cross_pattern" "$DASHBOARD_LIB"; then
		pass "$name"
	else
		fail "$name" "missing dashboard wall-clock timeout around person-stats helper calls"
	fi
	return 0
}

test_dashboard_wraps_person_stats_rate_limit_probes() {
	local name="dashboard wraps person-stats rate-limit probes with timeout_sec"
	local helper_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_RATE_LIMIT_TIMEOUT\" gh api rate_limit"
	local caller_pattern="search_remaining=\$(_stats_health_person_stats_search_remaining)"
	if grep -Fq "$helper_pattern" "$DASHBOARD_LIB" && grep -Fq "$caller_pattern" "$DASHBOARD_LIB"; then
		pass "$name"
	else
		fail "$name" "person-stats Search API budget probes can still call gh api without a wall-clock guard"
	fi
	return 0
}

test_dashboard_preserves_partial_cache() {
	local name="dashboard caches partial person-stats output and updates marker"
	local fake_home="${TMP_DIR}/home-partial"
	mkdir -p "${fake_home}/.aidevops/agents/scripts" "${TMP_DIR}/cache" "${TMP_DIR}/bin"
	cat >"${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
person-stats)
	printf '%s\n' '| Contributor | Issues | PRs | Merged | Commented | % of Total |'
	exit 75
	;;
cross-repo-person-stats)
	printf '%s\n' '_Across 2 managed repos:_'
	exit 75
	;;
esac
exit 1
FAKE
	chmod +x "${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	cat >"${TMP_DIR}/repos.json" <<JSON
{"initialized_repos":[{"pulse":true,"local_only":false,"slug":"owner/repo1","path":"${TMP_DIR}/repo1"},{"pulse":true,"local_only":false,"slug":"owner/repo2","path":"${TMP_DIR}/repo2"}]}
JSON
	mkdir -p "${TMP_DIR}/repo1" "${TMP_DIR}/repo2"
	cat >"${TMP_DIR}/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
	printf '%s\n' '1000'
	exit 0
fi
exit 1
GH
	chmod +x "${TMP_DIR}/bin/gh"
	(
		HOME="$fake_home"
		LOGFILE="${TMP_DIR}/partial.log"
		REPOS_JSON="${TMP_DIR}/repos.json"
		PERSON_STATS_INTERVAL=0
		PERSON_STATS_LAST_RUN="${TMP_DIR}/partial.last"
		PERSON_STATS_CACHE_DIR="${TMP_DIR}/cache"
		define_timeout_sec_mock
		PATH="${TMP_DIR}/bin:${PATH}"
		export HOME LOGFILE REPOS_JSON PERSON_STATS_INTERVAL PERSON_STATS_LAST_RUN PERSON_STATS_CACHE_DIR PATH
		# shellcheck source=../stats-health-dashboard-data.sh
		source "$DASHBOARD_LIB"
		_refresh_person_stats_cache
	)
	if [[ -s "${TMP_DIR}/partial.last" && -s "${TMP_DIR}/cache/person-stats-cache-owner-repo1.md" && -s "${TMP_DIR}/cache/person-stats-cache-cross-repo.md" ]]; then
		pass "$name"
	else
		fail "$name" "partial outputs were not cached or last-run marker missing"
	fi
	return 0
}

test_dashboard_skips_marker_when_all_refreshes_fail() {
	local name="dashboard does not mark success when all person-stats calls fail"
	local fake_home="${TMP_DIR}/home-fail"
	mkdir -p "${fake_home}/.aidevops/agents/scripts" "${TMP_DIR}/cache-fail" "${TMP_DIR}/bin-fail"
	cat >"${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh" <<'FAKE'
#!/usr/bin/env bash
exit 124
FAKE
	chmod +x "${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	cat >"${TMP_DIR}/repos-fail.json" <<JSON
{"initialized_repos":[{"pulse":true,"local_only":false,"slug":"owner/repo1","path":"${TMP_DIR}/repo1"},{"pulse":true,"local_only":false,"slug":"owner/repo2","path":"${TMP_DIR}/repo2"}]}
JSON
	cat >"${TMP_DIR}/bin-fail/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
	printf '%s\n' '1000'
	exit 0
fi
exit 1
GH
	chmod +x "${TMP_DIR}/bin-fail/gh"
	(
		HOME="$fake_home"
		LOGFILE="${TMP_DIR}/fail.log"
		REPOS_JSON="${TMP_DIR}/repos-fail.json"
		PERSON_STATS_INTERVAL=0
		PERSON_STATS_LAST_RUN="${TMP_DIR}/fail.last"
		PERSON_STATS_CACHE_DIR="${TMP_DIR}/cache-fail"
		define_timeout_sec_mock
		PATH="${TMP_DIR}/bin-fail:${PATH}"
		export HOME LOGFILE REPOS_JSON PERSON_STATS_INTERVAL PERSON_STATS_LAST_RUN PERSON_STATS_CACHE_DIR PATH
		# shellcheck source=../stats-health-dashboard-data.sh
		source "$DASHBOARD_LIB"
		_refresh_person_stats_cache
	)
	if [[ ! -e "${TMP_DIR}/fail.last" ]] && grep -q 'last-run marker not updated' "${TMP_DIR}/fail.log"; then
		pass "$name"
	else
		fail "$name" "failure refresh wrote a success marker or omitted log evidence"
	fi
	return 0
}

test_person_stats_uses_portable_timeout
test_person_stats_has_no_direct_timeout
test_dashboard_wraps_person_stats_with_timeout
test_dashboard_wraps_person_stats_rate_limit_probes
test_dashboard_preserves_partial_cache
test_dashboard_skips_marker_when_all_refreshes_fail

if [[ "$FAIL" -ne 0 ]]; then
	printf 'FAIL contributor-activity-helper-person (%s failed, %s passed)\n' "$FAIL" "$PASS"
	exit 1
fi

printf 'PASS contributor-activity-helper-person (%s checks)\n' "$PASS"
