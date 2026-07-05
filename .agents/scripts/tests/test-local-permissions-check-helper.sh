#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected to find: %s\n' "$needle"
	fi
	return 0
}

assert_not_contains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  did not expect to find: %s\n' "$needle"
	else
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
HELPER="${SCRIPT_DIR}/local-permissions-check-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	printf '%sFATAL%s: helper not executable: %s\n' "$TEST_RED" "$TEST_NC" "$HELPER"
	exit 1
fi

TEST_ROOT="$(mktemp -d -t local-permissions-check-test-XXXXXX)"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

fixture_rows="${TEST_ROOT}/tcc-rows.txt"
cat >"$fixture_rows" <<'ROWS'
kTCCServiceSystemPolicyAllFiles|org.tabby|2|
kTCCServiceAccessibility|org.tabby|0|
kTCCServiceScreenCapture|org.tabby||1
ROWS

apps_root="${TEST_ROOT}/Applications"
mkdir -p "${apps_root}/Tabby.app" "${apps_root}/Terminal.app"

report_output="$(LPC_UNAME=Darwin LPC_ACTIVE_HOST=Tabby LPC_TCC_ROWS="$fixture_rows" LPC_APP_ROOTS="$apps_root" "$HELPER" report --active-host)"
assert_contains "maps active host to Tabby" "Active host: Tabby (bundle: org.tabby)" "$report_output"
assert_contains "reports granted Full Disk Access" "Full Disk Access" "$report_output"
assert_contains "reports granted status" "granted" "$report_output"
assert_contains "reports denied Accessibility" "Accessibility" "$report_output"
assert_contains "reports denied status" "denied" "$report_output"
assert_contains "explains Tabby Trash remediation" "grant Full Disk Access to Tabby" "$report_output"
assert_contains "includes installed inventory" "Tabby: installed" "$report_output"

unknown_output="$(LPC_UNAME=Darwin LPC_ACTIVE_HOST=Tabby LPC_TCC_ROWS="${TEST_ROOT}/missing.txt" LPC_APP_ROOTS="$apps_root" "$HELPER" report --active-host)"
assert_contains "unreadable TCC state is unknown" "unknown" "$unknown_output"
assert_contains "unknown is not treated as OK" "Check System Settings" "$unknown_output"

fake_bin="${TEST_ROOT}/bin"
mkdir -p "$fake_bin"
cat >"${fake_bin}/sqlite3" <<'SQLITE'
#!/usr/bin/env bash
set -u
query="${2:-}"
if [[ "$query" == "PRAGMA table_info(access);" ]]; then
	printf '0|auth_value|INTEGER|0||0\n'
	exit 0
fi
exit 1
SQLITE
chmod +x "${fake_bin}/sqlite3"
fake_tcc_db="${TEST_ROOT}/TCC.db"
touch "$fake_tcc_db"
sqlite_error_output="$(LPC_UNAME=Darwin LPC_ACTIVE_HOST=Tabby LPC_TCC_ROWS="${TEST_ROOT}/missing.txt" LPC_TCC_DB="$fake_tcc_db" LPC_APP_ROOTS="$apps_root" PATH="${fake_bin}:$PATH" "$HELPER" report --active-host)"
assert_contains "sqlite read errors are unknown" "unknown" "$sqlite_error_output"
assert_contains "sqlite read errors are not missing" "Check System Settings" "$sqlite_error_output"

json_output="$(LPC_UNAME=Darwin LPC_ACTIVE_HOST=Tabby LPC_TCC_ROWS="$fixture_rows" LPC_APP_ROOTS="$apps_root" "$HELPER" json --active-host)"
assert_contains "json names active host" '"active_host":"Tabby"' "$json_output"
assert_contains "json includes granted evidence" '"status":"granted"' "$json_output"
assert_contains "json includes denied evidence" '"status":"denied"' "$json_output"
assert_not_contains "json omits private app root path" "$apps_root" "$json_output"

unsupported_output="$(LPC_UNAME=Linux "$HELPER" report --active-host)"
assert_contains "non-macOS degrades cleanly" "unsupported platform (Linux)" "$unsupported_output"

apps_output="$(LPC_UNAME=Darwin LPC_APP_ROOTS="$apps_root" "$HELPER" apps)"
assert_contains "apps command lists Tabby" "Tabby" "$apps_output"
assert_contains "apps command shows installed" "installed" "$apps_output"

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	printf '%sTests failed: %s%s\n' "$TEST_RED" "$TESTS_FAILED" "$TEST_NC"
	exit 1
fi

exit 0
