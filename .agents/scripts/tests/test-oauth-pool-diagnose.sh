#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Offline regression coverage for GH#36099: inspect observed pool permissions,
# preserving stat failures rather than treating them as a clean diagnostic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
printf '%s\n' '{"anthropic":[{"email":"test@example.com"}]}' >"$TEST_DIR/pool.json"
ln -s "$TEST_DIR/pool.json" "$TEST_DIR/pool-link.json"

# Interpose only stat; jq and the diagnostic library remain real. Detection
# probes and permission requests must use the matching GNU/BSD format, and
# permission requests must follow symlinks with -L.
cat >"$TEST_DIR/bin/stat" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$MOCK_VARIANT:$*" in
gnu:'-c %Y /' | bsd:'-f %m /') printf '1234567890\n'; exit 0 ;;
esac
case "$MOCK_VARIANT:$1:$2:${3:-}" in
gnu:-c:%a:-L | bsd:-f:%Lp:-L)
    printf '%s' "$MOCK_MODE"
    exit "$MOCK_STATUS"
    ;;
esac
exit 1
MOCK
chmod +x "$TEST_DIR/bin/stat"

run_case() {
	local label="$1" expected_status="$2" expected_result="$3" expected_detail="$4"
	local output status=0
	# A fresh shell ensures each case exercises portable-stat source-time
	# capability detection, not a cached variant from an earlier case.
	output=$(bash -c '
		set -euo pipefail
		SCRIPT_DIR="$1"
		POOL_FILE="$2"
		source "$SCRIPT_DIR/oauth-pool-diagnose.sh"
		_diag_print() {
			local name="$1" result="$2" detail="$3"
			printf "%s|%s|%s\n" "$name" "$result" "$detail"
			return 0
		}
		_diag_check_pool
	' _ "$SCRIPT_DIR" "$TEST_POOL" 2>&1) || status=$?
	if [[ "$status" != "$expected_status" ||
		"$output" != *"Pool file permissions|$expected_result|$expected_detail"* ]]; then
		printf 'FAIL %s: status=%s\n%s\n' "$label" "$status" "$output" >&2
		return 1
	fi
	if [[ "$expected_result" == FAIL && "$output" == *"Anthropic accounts|PASS"* ]]; then
		printf 'FAIL %s: continued after permission inspection failure\n' "$label" >&2
		return 1
	fi
	printf 'PASS %s\n' "$label"
	return 0
}

TEST_POOL="$TEST_DIR/pool.json"
chmod 600 "$TEST_POOL"
run_case 'native mode 600' 0 PASS 600
chmod 644 "$TEST_POOL"
run_case 'native mode 644' 0 WARN '644 (expected 600)'
TEST_POOL="$TEST_DIR/pool-link.json"
run_case 'symlink follows unsafe target' 0 WARN '644 (expected 600)'
chmod 600 "$TEST_DIR/pool.json"
run_case 'symlink follows safe target' 0 PASS 600

export PATH="$TEST_DIR/bin:$PATH"
export MOCK_VARIANT MOCK_MODE MOCK_STATUS
for MOCK_VARIANT in gnu bsd; do
	MOCK_STATUS=0
	MOCK_MODE=600
	run_case "$MOCK_VARIANT mode 600" 0 PASS 600
	MOCK_MODE=644
	run_case "$MOCK_VARIANT mode 644" 0 WARN '644 (expected 600)'
	MOCK_MODE=0
	run_case "$MOCK_VARIANT short zero mode" 0 WARN '000 (expected 600)'
	MOCK_MODE=0600
	run_case "$MOCK_VARIANT leading zero mode" 0 PASS 600
	for MOCK_MODE in '' invalid 888 10000; do
		run_case "$MOCK_VARIANT invalid mode [$MOCK_MODE]" 1 FAIL 'Unable to inspect file mode (expected 600)'
	done
	# Even apparently safe stdout must not mask a failed stat invocation.
	MOCK_MODE=600
	MOCK_STATUS=1
	run_case "$MOCK_VARIANT failed stat with safe-looking output" 1 FAIL 'Unable to inspect file mode (expected 600)'
done
