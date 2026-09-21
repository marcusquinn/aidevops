#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${TEST_DIR}/../dispatch-dedup-helper.sh"
TEST_ROOT="$(mktemp -d -t dispatch-dedup-running-keys.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${TEST_ROOT}/bin"
cat >"${TEST_ROOT}/bin/ps" <<'EOF'
#!/usr/bin/env bash
cat "${PS_FIXTURE_FILE}"
EOF
chmod +x "${TEST_ROOT}/bin/ps"

export PS_FIXTURE_FILE="${TEST_ROOT}/ps-fixture.txt"
REAL_PATH="$PATH"
export PATH="${TEST_ROOT}/bin:${PATH}"
EFFECTIVE_UID="$(id -u)"

assert_equals() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
		exit 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

cat >"$PS_FIXTURE_FILE" <<EOF
${EFFECTIVE_UID} 7101 S 00:01 bash /repo/.agents/scripts/pulse-wrapper.sh --command dispatch --prompt /full-loop Implement issue #32181
${EFFECTIVE_UID} 7102 S 00:01 bash /repo/.agents/scripts/dispatch-dedup-helper.sh is-duplicate Issue #32181
${EFFECTIVE_UID} 7103 S 00:01 bash /repo/.agents/scripts/headless-runtime-helper.sh run --role worker --session-key issue-32181 --dir /repo-worktree -- opencode run /full-loop Implement issue #32181
${EFFECTIVE_UID} 7104 S 00:01 opencode run /pulse dispatch prompt /full-loop Implement issue #32181
EOF

actual=$(PATH="${TEST_ROOT}/bin:${REAL_PATH}" "$HELPER" list-running-keys)
assert_equals "local dedup ignores orchestration processes and keeps the real worker" \
	$'7103|issue-32181\n7103|ref-32181' "$actual"

rc=0
SUPERVISOR_DIR="${TEST_ROOT}/supervisor" PATH="${TEST_ROOT}/bin:${REAL_PATH}" \
	"$HELPER" is-duplicate "Issue #32181" >/dev/null || rc=$?
assert_equals "real active worker blocks duplicate dispatch" "0" "$rc"

cat >"$PS_FIXTURE_FILE" <<EOF
${EFFECTIVE_UID} 7201 S 00:01 bash /repo/.agents/scripts/pulse-wrapper.sh --command dispatch --prompt /full-loop Implement issue #32181
${EFFECTIVE_UID} 7202 S 00:01 bash /repo/.agents/scripts/dispatch-dedup-helper.sh is-duplicate Issue #32181
EOF

actual=$(PATH="${TEST_ROOT}/bin:${REAL_PATH}" "$HELPER" list-running-keys)
assert_equals "command-router dispatch does not match itself" "" "$actual"

rc=0
SUPERVISOR_DIR="${TEST_ROOT}/supervisor" PATH="${TEST_ROOT}/bin:${REAL_PATH}" \
	"$HELPER" is-duplicate "Issue #32181" >/dev/null || rc=$?
assert_equals "command-router dispatch remains safe to launch" "1" "$rc"

printf 'All dispatch dedup running-key tests passed.\n'
