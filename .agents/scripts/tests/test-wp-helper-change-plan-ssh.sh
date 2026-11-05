#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Offline transport regression: never invokes a real ssh or scp.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# Source the authoritative file list, not the upload function under test.
# shellcheck source=../wp-helper-change-plan.sh
source "$SCRIPT_DIR/../wp-helper-change-plan.sh"
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() {
	local tmp_dir="${TMP_DIR:-}"
	[[ "${tmp_dir##*/}" == aidevops-wpcp-ssh.* && -d "$tmp_dir" ]] || return 1
	rm -rf -- "$tmp_dir"
	return 0
}

assert() {
	local name="$1"
	shift
	if "$@"; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		printf 'PASS %s\n' "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL %s\n' "$name"
	fi
	return 0
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-wpcp-ssh.XXXXXX") || exit 1
trap cleanup EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home/.config/aidevops" || exit 1
cat >"$TMP_DIR/home/.config/aidevops/wordpress-sites.json" <<'JSON'
{"sites":{"fixture":{"type":"hetzner","ssh_host":"transport.invalid","ssh_user":"fixture","ssh_port":2222,"ssh_identity_file":"~/.ssh/fixture","wp_path":"/fixture/wordpress root"}}}
JSON
printf '{"posts":[]}\n' >"$TMP_DIR/plan.json"
cat >"$TMP_DIR/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_DIR/ssh.log"
case "${!#}" in
*'mktemp -d'*) printf '/tmp/wp-change-plan.FIXTURE\n' ;;
*'rm -rf -- '*) : ;;
*'wp eval-file '*)
	[[ "$MOCK_FAILURE" == planner ]] && exit 9
	printf 'Dry run: fixture\n'
	;;
*) exit 90 ;;
esac
exit 0
STUB
cat >"$TMP_DIR/bin/scp" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_DIR/scp.log"
[[ "$MOCK_FAILURE" == upload ]] && exit 8
exit 0
STUB
chmod 755 "$TMP_DIR/bin/ssh" "$TMP_DIR/bin/scp"

for failure in none planner upload; do
	: >"$TMP_DIR/ssh.log"
	: >"$TMP_DIR/scp.log"
	rc=0
	HOME="$TMP_DIR/home" PATH="$TMP_DIR/bin:$PATH" MOCK_DIR="$TMP_DIR" MOCK_FAILURE="$failure" \
		bash "$SCRIPT_DIR/../wp-helper.sh" --change-plan fixture "$TMP_DIR/plan.json" >"$TMP_DIR/output.log" 2>&1 || rc=$?
	if [[ "$failure" == none ]]; then
		assert 'successful transport returns zero' test "$rc" -eq 0
		for php_file in "${WPCP_PHP_FILES[@]}"; do
			assert "uploads $php_file" grep -Fq -- "fixture@transport.invalid:/tmp/wp-change-plan.FIXTURE/$php_file" "$TMP_DIR/scp.log"
		done
		assert 'uploads plan' grep -Fq -- ':/tmp/wp-change-plan.FIXTURE/plan.json' "$TMP_DIR/scp.log"
		assert 'runs planner from quoted WordPress path' grep -Fq -- 'cd /fixture/wordpress\ root && wp eval-file /tmp/wp-change-plan.FIXTURE/wp-change-plan.php /tmp/wp-change-plan.FIXTURE/plan.json' "$TMP_DIR/ssh.log"
		assert 'uses SSH port' grep -Fq -- '-p 2222' "$TMP_DIR/ssh.log"
		assert 'uses SCP port' grep -Fq -- '-P 2222' "$TMP_DIR/scp.log"
	else
		assert "$failure failure propagates" test "$rc" -ne 0
	fi
	assert "removes remote directory after $failure" grep -Fq -- 'rm -rf -- /tmp/wp-change-plan.FIXTURE && test ! -e /tmp/wp-change-plan.FIXTURE' "$TMP_DIR/ssh.log"
	if [[ "$failure" == upload ]]; then
		assert 'does not execute planner after upload failure' test "$(grep -c 'wp eval-file' "$TMP_DIR/ssh.log")" -eq 0
	fi
done
printf '\n%d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
