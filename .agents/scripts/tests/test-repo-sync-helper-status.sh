#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for repo-sync scheduler status routing (GH#27618).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../repo-sync-helper.sh"

failures=0
declare -a TEMP_DIRS=()

cleanup() {
	rm -rf "${TEMP_DIRS[@]}"
	return 0
}
trap cleanup EXIT

pass() {
	local message="$1"
	printf 'PASS: %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	failures=$((failures + 1))
	return 0
}

assert_contains() {
	local file_path="$1"
	local expected="$2"
	local message="$3"
	if grep -qF "$expected" "$file_path"; then
		pass "$message"
	else
		fail "$message (missing: $expected)"
	fi
	return 0
}

assert_not_contains() {
	local file_path="$1"
	local unexpected="$2"
	local message="$3"
	if grep -qF "$unexpected" "$file_path"; then
		fail "$message (unexpected: $unexpected)"
	else
		pass "$message"
	fi
	return 0
}

assert_rc() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$message"
	else
		fail "$message (expected ${expected}, got ${actual})"
	fi
	return 0
}

make_fake_tools() {
	local tmp_dir="$1"
	mkdir -p "${tmp_dir}/bin"

	cat >"${tmp_dir}/bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail

command_name=""
property_name=""
unit_name=""
for arg in "$@"; do
	case "$arg" in
	is-active | is-enabled | show) command_name="$arg" ;;
	--property=*) property_name="${arg#--property=}" ;;
	*.timer | *.service) unit_name="$arg" ;;
	esac
done

case "$command_name" in
is-active)
	printf '%s\n' "${FAKE_SYSTEMD_ACTIVE:-inactive}"
	;;
is-enabled)
	printf '%s\n' "${FAKE_SYSTEMD_ENABLED:-disabled}"
	;;
show)
	case "${unit_name}:${property_name}" in
	*.timer:LoadState) printf '%s\n' "${FAKE_SYSTEMD_LOAD:-loaded}" ;;
	*.timer:SubState) printf '%s\n' "${FAKE_SYSTEMD_SUBSTATE:-waiting}" ;;
	*.timer:NextElapseUSecRealtime) printf '%s\n' "${FAKE_SYSTEMD_NEXT_REALTIME:-n/a}" ;;
	*.timer:NextElapseUSecMonotonic) printf '%s\n' "${FAKE_SYSTEMD_NEXT_MONOTONIC:-n/a}" ;;
	*.timer:LastTriggerUSec) printf '%s\n' "${FAKE_SYSTEMD_LAST_TRIGGER:-n/a}" ;;
	*.service:Result) printf '%s\n' "${FAKE_SYSTEMD_RESULT:-}" ;;
	*.service:ExecMainStatus) printf '%s\n' "${FAKE_SYSTEMD_EXIT:-0}" ;;
	esac
	;;
esac
exit 0
FAKE_SYSTEMCTL

	cat >"${tmp_dir}/bin/crontab" <<'FAKE_CRONTAB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-l" ]] && [[ -n "${FAKE_CRONTAB:-}" ]]; then
	printf '%s\n' "$FAKE_CRONTAB"
fi
exit 0
FAKE_CRONTAB

	cat >"${tmp_dir}/bin/launchctl" <<'FAKE_LAUNCHCTL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "list" ]] && [[ "${FAKE_LAUNCHD_LOADED:-false}" == "true" ]]; then
	printf '123\t0\tsh.aidevops.repo-sync\n'
fi
exit 0
FAKE_LAUNCHCTL

	chmod +x "${tmp_dir}/bin/systemctl" "${tmp_dir}/bin/crontab" "${tmp_dir}/bin/launchctl"
	return 0
}

run_status_case() {
	local case_name="$1"
	local backend="$2"
	shift 2
	local tmp_dir
	tmp_dir=$(mktemp -d)
	TEMP_DIRS+=("$tmp_dir")
	mkdir -p "${tmp_dir}/home/.config/aidevops"
	printf '{"git_parent_dirs":["%s"]}\n' "${tmp_dir}/repos" >"${tmp_dir}/home/.config/aidevops/repos.json"
	make_fake_tools "$tmp_dir"

	local rc=0
	env \
		HOME="${tmp_dir}/home" \
		PATH="${tmp_dir}/bin:${PATH}" \
		AIDEVOPS_SCHEDULER="$backend" \
		"$@" \
		"$HELPER" status >"${tmp_dir}/output.log" 2>"${tmp_dir}/error.log" || rc=$?

	LAST_CASE_NAME="$case_name"
	LAST_CASE_DIR="$tmp_dir"
	LAST_CASE_RC="$rc"
	return 0
}

run_status_case active systemd \
	FAKE_SYSTEMD_ENABLED=enabled \
	FAKE_SYSTEMD_ACTIVE=active \
	FAKE_SYSTEMD_NEXT_REALTIME="Tue 2026-07-14 18:00:00 UTC" \
	FAKE_SYSTEMD_LAST_TRIGGER="Tue 2026-07-14 17:00:00 UTC" \
	FAKE_SYSTEMD_RESULT=success
assert_rc 0 "$LAST_CASE_RC" "active systemd status exits cleanly"
assert_contains "${LAST_CASE_DIR}/output.log" "Scheduler: systemd (user timer)" "active timer reports systemd backend"
assert_contains "${LAST_CASE_DIR}/output.log" "active" "active timer reports active state"
assert_contains "${LAST_CASE_DIR}/output.log" "(enabled)" "active timer reports enabled state"
assert_contains "${LAST_CASE_DIR}/output.log" "Next fire: Tue 2026-07-14 18:00:00 UTC" "active timer reports next fire"
assert_contains "${LAST_CASE_DIR}/output.log" "Last result:" "active timer reports last result"
assert_not_contains "${LAST_CASE_DIR}/output.log" "Scheduler: cron" "systemd status does not fall through to cron"

run_status_case disabled systemd FAKE_SYSTEMD_ENABLED=disabled FAKE_SYSTEMD_ACTIVE=inactive
assert_rc 0 "$LAST_CASE_RC" "disabled systemd status exits cleanly"
assert_contains "${LAST_CASE_DIR}/output.log" "disabled" "disabled timer is distinguished"

run_status_case missing systemd FAKE_SYSTEMD_ENABLED=not-found FAKE_SYSTEMD_ACTIVE=inactive FAKE_SYSTEMD_LOAD=not-found
assert_rc 0 "$LAST_CASE_RC" "missing systemd status exits cleanly"
assert_contains "${LAST_CASE_DIR}/output.log" "not installed" "missing timer is distinguished"

run_status_case failed systemd FAKE_SYSTEMD_ENABLED=enabled FAKE_SYSTEMD_ACTIVE=failed FAKE_SYSTEMD_RESULT=exit-code FAKE_SYSTEMD_EXIT=1
assert_rc 0 "$LAST_CASE_RC" "failed systemd status remains diagnostic"
assert_contains "${LAST_CASE_DIR}/output.log" "failed" "failed timer is distinguished"
assert_contains "${LAST_CASE_DIR}/output.log" "exit-code" "failed service result is reported"
assert_contains "${LAST_CASE_DIR}/output.log" "(exit 1)" "failed service exit status is reported"

run_status_case cron cron FAKE_CRONTAB="0 3 * * * repo-sync-helper.sh check # aidevops-repo-sync"
assert_rc 0 "$LAST_CASE_RC" "cron status exits cleanly"
assert_contains "${LAST_CASE_DIR}/output.log" "Scheduler: cron" "cron backend remains supported"
assert_contains "${LAST_CASE_DIR}/output.log" "Schedule:  0 3 * * *" "cron schedule remains visible"

run_status_case launchd launchd FAKE_LAUNCHD_LOADED=true
assert_rc 0 "$LAST_CASE_RC" "launchd status exits cleanly"
assert_contains "${LAST_CASE_DIR}/output.log" "Scheduler: launchd (macOS LaunchAgent)" "launchd backend remains supported"
assert_contains "${LAST_CASE_DIR}/output.log" "loaded" "launchd loaded state remains visible"

"$HELPER" help >"${LAST_CASE_DIR}/help.log"
assert_contains "${LAST_CASE_DIR}/help.log" "systemd user timer preferred" "help documents the preferred Linux backend"
assert_contains "${LAST_CASE_DIR}/help.log" "Falls back to cron" "help documents the cron fallback"

if [[ $failures -gt 0 ]]; then
	printf '\n%d repo-sync status test(s) failed\n' "$failures" >&2
	exit 1
fi

printf '\nAll repo-sync status tests passed\n'
exit 0
