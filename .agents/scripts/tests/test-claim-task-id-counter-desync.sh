#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23110.
#
# A normal, unprotected counter branch can lag the default branch.  The allocator
# must refetch/reconcile automatically, emit machine-readable recovery status,
# and allocate from the reconciled counter without duplicate or stranded IDs.

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

setup_desynced_remote() {
	local base_dir="$1"
	local bare_dir="${base_dir}/remote.git"
	local work_dir="${base_dir}/work"

	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.email "test@test.local" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config user.name "Test" >/dev/null 2>&1 || return 1
	git -C "$work_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	git -C "$work_dir" config tag.gpgsign false >/dev/null 2>&1 || true

	printf '1000\n' >"${work_dir}/.task-counter"
	printf '# Tasks\n\n- [x] t999 seed task\n' >"${work_dir}/TODO.md"
	git -C "$work_dir" add .task-counter TODO.md >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m "chore: seed develop counter" >/dev/null 2>&1 || return 1
	git -C "$work_dir" branch develop >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin develop >/dev/null 2>&1 || return 1

	printf '1100\n' >"${work_dir}/.task-counter"
	git -C "$work_dir" add .task-counter >/dev/null 2>&1 || return 1
	git -C "$work_dir" commit -m "chore: advance main counter" >/dev/null 2>&1 || return 1
	git -C "$work_dir" push origin main >/dev/null 2>&1 || return 1
	printf '%s\n' "$work_dir"
	return 0
}

protect_counter_branch_pushes() {
	local work_dir="$1"
	local bare_dir
	bare_dir=$(git -C "$work_dir" remote get-url origin 2>/dev/null) || return 1
	mkdir -p "${bare_dir}/hooks" || return 1
	cat >"${bare_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -u

while read -r old_sha new_sha ref_name; do
	if [[ "$ref_name" == "refs/heads/develop" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "$ref_name" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
		exit 1
	fi
done
exit 0
HOOK
	chmod +x "${bare_dir}/hooks/pre-receive" || return 1
	return 0
}

test_counter_branch_desync_reconciles_before_claim() {
	local name="counter branch desync is reconciled before allocation"
	local tmpdir work_dir output rc task_id final_counter claim_commits unique_claims
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }

	work_dir=$(setup_desynced_remote "$tmpdir") || { fail "$name" "repo setup failed"; rm -rf "$tmpdir"; return 0; }

	rc=0
	output=$(CAS_MAX_RETRIES=3 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
		--title "desync recovery test" \
		--no-issue \
		--repo-path "$work_dir" \
		--counter-branch develop 2>&1) || rc=$?

	if [[ $rc -ne 0 ]]; then
		fail "$name" "claim failed: $output"
		rm -rf "$tmpdir"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'AIDEVOPS_TASK_COUNTER_STATUS=recovered_contention'; then
		fail "$name" "missing recovered_contention status: $output"
		rm -rf "$tmpdir"
		return 0
	fi
	task_id=$(printf '%s\n' "$output" | awk -F= '/^task_id=/{print $2; exit}')
	if [[ "$task_id" != "t1100" ]]; then
		fail "$name" "expected t1100 after reconciliation, got ${task_id:-<empty>}"
		rm -rf "$tmpdir"
		return 0
	fi

	git -C "$work_dir" fetch origin develop >/dev/null 2>&1 || true
	final_counter=$(git -C "$work_dir" show origin/develop:.task-counter 2>/dev/null | tr -d '[:space:]')
	if [[ "$final_counter" != "1101" ]]; then
		fail "$name" "expected develop counter 1101, got ${final_counter:-<empty>}"
		rm -rf "$tmpdir"
		return 0
	fi

	claim_commits=$(git -C "$work_dir" log origin/develop --oneline --grep="chore: claim" | grep -oE 't[0-9]+' | sort || true)
	unique_claims=$(printf '%s\n' "$claim_commits" | grep -c '^t1100$' || true)
	if [[ "$unique_claims" -ne 1 ]]; then
		fail "$name" "expected exactly one t1100 claim commit, got ${unique_claims}"
		rm -rf "$tmpdir"
		return 0
	fi

	pass "$name"
	rm -rf "$tmpdir"
	return 0
}

test_reconciliation_protected_branch_rejection_is_unrecoverable() {
	local name="reconciliation protected branch rejection is unrecoverable"
	local tmpdir work_dir output rc
	tmpdir=$(mktemp -d) || { fail "$name" "mktemp failed"; return 0; }

	work_dir=$(setup_desynced_remote "$tmpdir") || { fail "$name" "repo setup failed"; rm -rf "$tmpdir"; return 0; }
	protect_counter_branch_pushes "$work_dir" || { fail "$name" "hook setup failed"; rm -rf "$tmpdir"; return 0; }

	rc=0
	output=$(CAS_MAX_RETRIES=3 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
		--title "protected reconciliation test" \
		--no-issue \
		--repo-path "$work_dir" \
		--counter-branch develop 2>&1) || rc=$?

	if [[ $rc -eq 0 ]]; then
		fail "$name" "claim unexpectedly succeeded: $output"
		rm -rf "$tmpdir"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'PROTECTED_COUNTER_BRANCH'; then
		fail "$name" "missing protected-branch error: $output"
		rm -rf "$tmpdir"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'AIDEVOPS_TASK_COUNTER_STATUS=unrecoverable_desync detail=protected_counter_branch'; then
		fail "$name" "missing protected-counter status: $output"
		rm -rf "$tmpdir"
		return 0
	fi
	if printf '%s\n' "$output" | grep -q 'reconcile_raced'; then
		fail "$name" "protected rejection was treated as retriable contention: $output"
		rm -rf "$tmpdir"
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
	test_counter_branch_desync_reconciles_before_claim
	test_reconciliation_protected_branch_rejection_is_unrecoverable
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
