#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression tests for GH#22324 / t3461 GitHub App auth and routing helper.
# =============================================================================

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

PASS=0
FAIL=0
TMP=$(mktemp -d -t github-app-auth.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export AIDEVOPS_GITHUB_APP_CONFIG="$TMP/github-app-auth.json"
export AIDEVOPS_GITHUB_APP_CACHE_DIR="$TMP/cache"
export AIDEVOPS_GITHUB_APP_RATE_LIMIT_CACHE_TTL=30
GH_CALLS="$TMP/gh-calls.log"

pass() {
	local label="$1"
	PASS=$((PASS + 1))
	printf '  PASS %s\n' "$label"
	return 0
}

fail() {
	local label="$1"
	local detail="${2:-}"
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$label"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	return 0
}

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		pass "$label"
	else
		fail "$label" "expected=${expected} actual=${actual}"
	fi
	return 0
}

gh() {
	local args="$*"
	local first="${1:-}"
	local second="${2:-}"
	local fourth="${4:-}"
	printf '%s|token=%s\n' "$args" "${GH_TOKEN:-}" >>"$GH_CALLS"
	if [[ "$first" == "api" && "$second" == "rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":4321},"core":{"remaining":4999},"search":{"remaining":29}}}\n'
		return 0
	fi
	if [[ "$first" == "api" && "$second" == "/repos/owner/repo/installation" ]]; then
		printf '{"id":456}\n'
		return 0
	fi
	if [[ "$first" == "api" && "$second" == "-X" && "$fourth" =~ /app/installations/.*/access_tokens ]]; then
		printf '{"token":"exchanged-token","expires_at":"2099-01-01T00:00:00Z"}\n'
		return 0
	fi
	printf '{}\n'
	return 0
}
export -f gh

# shellcheck source=../github-app-auth-helper.sh
source "${SCRIPTS_DIR}/github-app-auth-helper.sh"

printf 'Running GitHub App auth helper tests\n'

# shellcheck disable=SC2016 # Keep the inner script expanded by the env-isolated bash process.
fallback_output=$(env -i USER="fallback-user" TMPDIR="$TMP/fallback-tmp" PATH="$PATH" bash -c '
source "$1"
_github_app_cache_dir >/dev/null
printf "%s\n%s\n%s\n" "$AIDEVOPS_GITHUB_APP_HOME" "$AIDEVOPS_GITHUB_APP_CONFIG" "$AIDEVOPS_GITHUB_APP_CACHE_DIR"
' bash "${SCRIPTS_DIR}/github-app-auth-helper.sh")
fallback_home=$(printf '%s\n' "$fallback_output" | sed -n '1p')
fallback_config=$(printf '%s\n' "$fallback_output" | sed -n '2p')
fallback_cache=$(printf '%s\n' "$fallback_output" | sed -n '3p')
assert_eq "unset HOME uses user-scoped tmp fallback root" "$TMP/fallback-tmp/aidevops-fallback-user" "$fallback_home"
assert_eq "unset HOME config stays under user-scoped fallback" "$TMP/fallback-tmp/aidevops-fallback-user/.config/aidevops/github-app-auth.json" "$fallback_config"
assert_eq "unset HOME cache stays under user-scoped fallback" "$TMP/fallback-tmp/aidevops-fallback-user/.aidevops/cache/github-app" "$fallback_cache"
mkdir -p "$TMP/fallback-tmp"
ln -s "$TMP" "$TMP/fallback-tmp/aidevops-linked-user"
# shellcheck disable=SC2016 # Keep the inner script expanded by the env-isolated bash process.
if env -i USER="linked-user" TMPDIR="$TMP/fallback-tmp" PATH="$PATH" bash -c '
source "$1"
_github_app_cache_dir >/dev/null
' bash "${SCRIPTS_DIR}/github-app-auth-helper.sh"; then
	fail "unset HOME fallback cache rejects symlinked fallback root"
else
	pass "unset HOME fallback cache rejects symlinked fallback root"
fi

route_auth=$(github_app_route_json issue-list owner/repo | jq -r '.auth_mode')
assert_eq "no app configured falls back to gh/PAT auth" "gh-pat" "$route_auth"

cat >"$AIDEVOPS_GITHUB_APP_CONFIG" <<'JSON'
{
  "enabled": true,
  "app_id": "123",
  "installation_id": "456",
  "private_key_path": ""
}
JSON

_github_app_cache_token "456" "cached-token" "2099-01-01T00:00:00Z"

if github_app_is_configured; then
	pass "cached installation token makes app auth configured without exposing key material"
else
	fail "cached installation token makes app auth configured without exposing key material"
fi

token=$(github_app_token_for_repo owner/repo)
assert_eq "token lookup returns cached token" "cached-token" "$token"

status_auth=$(github_app_status_json owner/repo | jq -r '.active_auth_mode')
assert_eq "status uses app auth when token is available" "github-app" "$status_auth"

search_pool=$(github_app_route_json issue-search owner/repo | jq -r '.selected_pool')
search_auth=$(github_app_route_json issue-search owner/repo | jq -r '.auth_mode')
assert_eq "issue search routes to REST search pool" "rest-search" "$search_pool"
assert_eq "issue search prefers GitHub App auth" "github-app" "$search_auth"

: >"$GH_CALLS"
github_app_api_call read rest-core gh api /repos/owner/repo/issues >/dev/null
if grep -q 'api /repos/owner/repo/issues|token=cached-token' "$GH_CALLS" 2>/dev/null; then
	pass "github_app_api_call injects installation token for REST API call"
else
	fail "github_app_api_call injects installation token for REST API call" "GH_CALLS=$(<"$GH_CALLS")"
fi

if _github_app_cli token >/dev/null 2>&1; then
	fail "token CLI refuses stdout by default"
else
	pass "token CLI refuses stdout by default"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
