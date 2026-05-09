#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23077.
#
# A protected counter branch rejects direct CAS pushes. The allocator must
# classify that as a policy failure, not retriable CAS contention, and leave the
# working tree unchanged.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf 'PASS %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ' — %s' "$detail"
	printf '\n'
	FAIL=$((FAIL + 1))
	return 0
}

setup_protected_remote() {
	local base_dir="$1"
	local bare_dir="${base_dir}/remote.git"
	local work_dir="${base_dir}/work"

	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.email "test@test.local" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.name "Test" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	printf '1000\n' >"${work_dir}/.task-counter"
	printf '# Tasks\n\n' >"${work_dir}/TODO.md"
	git -C "$work_dir" add .task-counter TODO.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m "chore: seed protected counter" >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1

	mkdir -p "${bare_dir}/hooks" || return 1
	cat >"${bare_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
	if [[ "$ref" == "refs/heads/main" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "$ref" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
		exit 1
	fi
done
exit 0
HOOK
	chmod +x "${bare_dir}/hooks/pre-receive" || return 1
	printf '%s\n' "$work_dir"
	return 0
}

test_protected_counter_branch_fast_fail() {
	local name="protected counter branch rejection is non-retriable and clean"
	local tmpdir work_dir before_head output rc after_head status remote_counter
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }

	work_dir=$(setup_protected_remote "$tmpdir") || { fail "$name" "repo setup failed"; return 0; }
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing initial HEAD"; return 0; }

	rc=0
	output=$(CAS_MAX_RETRIES=5 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
		--title "protected counter branch" \
		--no-issue \
		--repo-path "$work_dir" \
		--counter-branch main 2>&1) || rc=$?

	if [[ $rc -eq 0 ]]; then
		fail "$name" "claim unexpectedly succeeded"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'PROTECTED_COUNTER_BRANCH'; then
		fail "$name" "missing protected-branch diagnostic: $output"
		return 0
	fi
	if printf '%s\n' "$output" | grep -q 'Retry attempt'; then
		fail "$name" "protected rejection was retried: $output"
		return 0
	fi

	after_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing final HEAD"; return 0; }
	if [[ "$after_head" != "$before_head" ]]; then
		fail "$name" "local HEAD changed"
		return 0
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ -n "$status" ]]; then
		fail "$name" "working tree dirty: $status"
		return 0
	fi
	git -C "$work_dir" fetch origin main >/dev/null 2>&1 || true
	remote_counter=$(git -C "$work_dir" show origin/main:.task-counter 2>/dev/null | tr -d '[:space:]')
	if [[ "$remote_counter" != "1000" ]]; then
		fail "$name" "remote counter changed to ${remote_counter:-<empty>}"
		return 0
	fi

	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

main() {
	if [[ ! -x "$CLAIM_SCRIPT" ]]; then
		fail "claim script executable" "$CLAIM_SCRIPT missing or not executable"
	else
		pass "claim script executable"
	fi
	test_protected_counter_branch_fast_fail
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
