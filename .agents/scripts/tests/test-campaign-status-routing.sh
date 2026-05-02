#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-campaign-status-routing.sh — regression tests for aidevops campaign status routing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit
AIDEVOPS_SH="${REPO_ROOT}/aidevops.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

pass_count=0
fail_count=0

_pass() {
	local msg="$1"
	printf '%b  PASS:%b %s\n' "${TEST_GREEN}" "${TEST_NC}" "${msg}"
	pass_count=$((pass_count + 1))
	return 0
}

_fail() {
	local msg="$1"
	printf '%b  FAIL:%b %s\n' "${TEST_RED}" "${TEST_NC}" "${msg}" >&2
	fail_count=$((fail_count + 1))
	return 0
}

_info() {
	local msg="$1"
	printf '%b[INFO]%b %s\n' "${TEST_YELLOW}" "${TEST_NC}" "${msg}"
	return 0
}

_make_repo() {
	local tmp_root="$1"
	local repo_path="${tmp_root}/repo"
	mkdir -p "${repo_path}/_campaigns/active/c001" "${repo_path}/_campaigns/launched" "${repo_path}/_campaigns/archive" "${repo_path}/_campaigns/lib/brand" "${repo_path}/_campaigns/lib/swipe" "${repo_path}/_campaigns/intel" "${repo_path}/_campaigns/_config"
	printf '{"version":1}\n' > "${repo_path}/_campaigns/_config/campaigns.json"
	cat > "${repo_path}/_campaigns/active/c001/brief.md" <<'BRIEF'
# Test Campaign

**ID:** c001
**Name:** Test Campaign
**Channel:** email
**Created:** 2026-05-02
**Status:** active
BRIEF
	printf '%s\n' "${repo_path}"
	return 0
}

test_bare_status_routes_to_provisioning() {
	_info "Test 1: bare campaign status shows provisioning counts"
	local tmp_root repo_path out
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-status-routing.XXXXXX")"
	repo_path="$(_make_repo "${tmp_root}")"

	out="$(cd "${repo_path}" && bash "${AIDEVOPS_SH}" campaign status 2>&1)" || {
		_fail "bare campaign status errored: ${out}"
		rm -rf "${tmp_root}"
		return 1
	}

	if grep -q 'Campaigns plane status:' <<<"${out}" && grep -q 'Active campaigns:' <<<"${out}" && ! grep -q 'Usage: campaign status <id>' <<<"${out}"; then
		_pass "bare status routes to campaigns-provision-helper.sh"
	else
		_fail "bare status did not show provisioning status: ${out}"
		rm -rf "${tmp_root}"
		return 1
	fi
	rm -rf "${tmp_root}"
	return 0
}

test_status_with_campaign_id_routes_to_detail() {
	_info "Test 2: campaign status <id> still shows campaign detail"
	local tmp_root repo_path out
	tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/campaign-status-routing.XXXXXX")"
	repo_path="$(_make_repo "${tmp_root}")"

	out="$(cd "${repo_path}" && bash "${AIDEVOPS_SH}" campaign status c001 2>&1)" || {
		_fail "campaign detail status errored: ${out}"
		rm -rf "${tmp_root}"
		return 1
	}

	if grep -q 'Campaign: c001' <<<"${out}" && grep -q '\[active\]' <<<"${out}"; then
		_pass "status <id> routes to campaign-helper.sh"
	else
		_fail "status <id> did not show campaign detail: ${out}"
		rm -rf "${tmp_root}"
		return 1
	fi
	rm -rf "${tmp_root}"
	return 0
}

main() {
	_info "campaign status routing regression tests (GH#22271)"
	printf '\n'

	test_bare_status_routes_to_provisioning
	test_status_with_campaign_id_routes_to_detail

	printf '\nResults: %d passed, %d failed\n' "${pass_count}" "${fail_count}"
	if [[ ${fail_count} -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
