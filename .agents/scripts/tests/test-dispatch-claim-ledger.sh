#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-dispatch-claim-ledger.sh — GH#38104: device-local checkpoint-claim ledger
# drives the expired own-claim sweep without a repo scan.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CLAIM_HELPER="${SCRIPT_DIR}/../dispatch-claim-helper.sh"
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_REPO_STATE_GUARD_TEST_BYPASS=1

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf 'PASS: %s\n' "$name"
	else
		printf 'FAIL: %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Print one ledger entry. Args: nonce, issue, expires_at, session.
entry() {
	printf '{"repo":"owner/repo","issue":%s,"claim_id":10,"nonce":"%s","session":"%s","expires_at":%s}\n' "$2" "$1" "$4" "$3"
	return 0
}

test_expired_released_live_and_ready_untouched() {
	local result=0 tmp_dir
	tmp_dir=$(mktemp -d)
	(
		# shellcheck source=../dispatch-claim-helper.sh
		source "$CLAIM_HELPER"
		export AIDEVOPS_CHECKPOINT_CLAIM_LEDGER="${tmp_dir}/state/checkpoint-claims.jsonl"
		local now swept=""
		now=$(date +%s)
		_dch_ledger_add owner/repo 1 10 expired-tok sess-expired "$((now - 100))"
		_dch_ledger_add owner/repo 2 11 future-tok sess-future "$((now + 3600))"
		_dch_ledger_add owner/repo 3 12 live-tok sess-live "$((now - 100))"
		[[ "$(stat -c '%a' "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER" 2>/dev/null || stat -f '%Lp' "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER")" == 600 ]] || exit 1
		_dch_session_has_live_executor() { [[ "$1" == sess-live ]]; }
		cmd_sweep_pr_checkpoint_claim() { swept="${swept}${1} "; return 0; }
		cmd_sweep_checkpoint_ledger 0 || exit 1
		[[ "$swept" == "1 " ]] || exit 1
		local left
		left=$(jq -r '.nonce' "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER" | sort | tr '\n' ' ')
		[[ "$left" == "future-tok live-tok " ]] || exit 1
	) || result=1
	rm -rf "$tmp_dir"
	print_result "expired entry released and pruned; future and live-executor entries untouched" "$result"
	return 0
}

test_failed_release_keeps_entry() {
	local result=0 tmp_dir
	tmp_dir=$(mktemp -d)
	(
		# shellcheck source=../dispatch-claim-helper.sh
		source "$CLAIM_HELPER"
		export AIDEVOPS_CHECKPOINT_CLAIM_LEDGER="${tmp_dir}/ledger.jsonl"
		entry keep-tok 5 "$(($(date +%s) - 100))" sess >"$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER"
		_dch_session_has_live_executor() { return 1; }
		cmd_sweep_pr_checkpoint_claim() { DCH_SWEEP_FAILED=1; return 0; }
		cmd_sweep_checkpoint_ledger 0 || exit 1
		grep -q keep-tok "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER" || exit 1
	) || result=1
	rm -rf "$tmp_dir"
	print_result "failed release keeps the ledger entry for retry" "$result"
	return 0
}

test_no_github_reads_without_expired_entries() {
	local result=0 tmp_dir
	tmp_dir=$(mktemp -d)
	(
		# shellcheck source=../dispatch-claim-helper.sh
		source "$CLAIM_HELPER"
		export AIDEVOPS_CHECKPOINT_CLAIM_LEDGER="${tmp_dir}/ledger.jsonl"
		local calls=0 now
		now=$(date +%s)
		gh() { calls=$((calls + 1)); return 1; }
		_resolve_runner() { calls=$((calls + 1)); return 1; }
		cmd_sweep_checkpoint_ledger 0 || exit 1 # missing ledger
		entry fresh-tok 7 "$((now + 3600))" sess >"$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER"
		cmd_sweep_checkpoint_ledger 0 || exit 1 # nothing expired
		[[ "$calls" -eq 0 ]] || exit 1
	) || result=1
	rm -rf "$tmp_dir"
	print_result "no GitHub reads when the ledger has no expired entries" "$result"
	return 0
}

test_transition_keeps_ledger_in_step() {
	local result=0 tmp_dir
	tmp_dir=$(mktemp -d)
	(
		# shellcheck source=../dispatch-claim-helper.sh
		source "$CLAIM_HELPER"
		export AIDEVOPS_CHECKPOINT_CLAIM_LEDGER="${tmp_dir}/ledger.jsonl"
		{ entry a-tok 1 100 s1; entry b-tok 2 100 s2; } >"$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER"
		_dch_ledger_update_expiry a-tok 500
		_dch_ledger_update_expiry b-tok 50 # never shortens
		[[ "$(jq -r 'select(.nonce == "a-tok") | .expires_at' "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER")" == 500 ]] || exit 1
		[[ "$(jq -r 'select(.nonce == "b-tok") | .expires_at' "$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER")" == 100 ]] || exit 1
		_dch_ledger_remove_nonce a-tok # ready / release / terminal
		[[ "$(wc -l <"$AIDEVOPS_CHECKPOINT_CLAIM_LEDGER" | tr -d ' ')" == 1 ]] || exit 1
	) || result=1
	rm -rf "$tmp_dir"
	print_result "renewal extends and ready/release/terminal removes the entry" "$result"
	return 0
}

test_cli_ledger_sweep_posts_release() {
	local result=0 tmp_dir
	tmp_dir=$(mktemp -d)
	mkdir -p "${tmp_dir}/bin"
	cat >"${tmp_dir}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${2:-}" == user ]]; then
	printf 'mockrunner\n'
elif [[ " $* " == *' --method POST '* ]]; then
	printf '%s\n' "$*" >"${MOCK_SWEEP_DIR}/posted"
else
	printf '%s\n' '[[{"id":10,"user":{"login":"mockrunner"},"author":"mockrunner","author_association":"MEMBER","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","body":"DISPATCH_CLAIM nonce=token runner=mockrunner phase=prelaunch lease_token=token device=fixture-device session=fixture-session expires_at=1 checkpoint_mode=revision checkpoint_approval=22"}]]'
fi
EOF
	chmod +x "${tmp_dir}/bin/gh"
	entry token 42 "$(($(date +%s) - 100))" fixture-session >"${tmp_dir}/ledger.jsonl"
	PATH="${tmp_dir}/bin:$PATH" MOCK_SWEEP_DIR="$tmp_dir" AIDEVOPS_DEVICE_ID=fixture-device \
		AIDEVOPS_CHECKPOINT_CLAIM_LEDGER="${tmp_dir}/ledger.jsonl" \
		"$CLAIM_HELPER" sweep-checkpoint-ledger >/dev/null 2>&1 || result=1
	grep -q 'CLAIM_RELEASED reason=claim_only_no_worker' "${tmp_dir}/posted" 2>/dev/null || result=1
	[[ ! -s "${tmp_dir}/ledger.jsonl" ]] || result=1
	rm -rf "$tmp_dir"
	print_result "CLI ledger sweep posts CLAIM_RELEASED and prunes the entry" "$result"
	return 0
}

main() {
	test_expired_released_live_and_ready_untouched
	test_failed_release_keeps_entry
	test_no_github_reads_without_expired_entries
	test_transition_keeps_ledger_in_step
	test_cli_ledger_sweep_posts_release
	printf 'Results: %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
