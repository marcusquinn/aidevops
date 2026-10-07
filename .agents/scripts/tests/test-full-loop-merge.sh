#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression suite for merge transport, readiness, and prospective TODO safety.
# Shared harness and merge cases live in the cases module; planning cases keep
# checkout-free publication and isolated prospective-merge fixtures together.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

test_prospective_todo_requires_supported_native_git() {
	local fixture_dir="" base_sha="" head_sha="" wrapper="" output="" rc=0
	fixture_dir=$(create_prospective_fixture unique)
	base_sha=$(<"${fixture_dir}/base.sha")
	head_sha=$(<"${fixture_dir}/head.sha")
	wrapper="${fixture_dir}/old-git-wrapper"
	cat >"$wrapper" <<'WRAPPER_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	printf '%s\n' 'git version 2.37.0'
	exit 0
fi
exec /usr/bin/git "$@"
WRAPPER_EOF
	chmod +x "$wrapper"
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" stub \
		'https://github.com/testorg/testrepo.git' 'testorg/testrepo' "$fixture_dir" "$wrapper") || rc=$?
	print_result "prospective TODO: Git without merge-tree --write-tree fails with actionable version guidance" \
		"$([[ "$rc" -ne 0 && "$output" == *"2.37.0"* && "$output" == *"Git 2.38+ required"* ]] && printf '0' || printf '1')" \
		"rc=$rc output=$output"
	return 0
}

# Git before 2.44 ignores GIT_NO_LAZY_FETCH. Simulate it with a 2.43 banner and
# the variable removed: validation must still pass, and a missed blob must fail
# closed instead of being lazily fetched (GH#33752).
test_prospective_todo_pre_lazy_fetch_env_git() {
	local fixture_dir="" fixture_root="${TEST_ROOT}/prospective-crisscross"
	local base_sha="" head_sha="" remote_url="" git_probe="" wrapper="" output="" rc=0
	if [[ -f "${fixture_root}/base.sha" ]]; then
		fixture_dir="${fixture_root}/caller"
	else
		fixture_dir=$(create_prospective_crisscross_fixture) || {
			print_result "prospective TODO: Git 2.43 fixture" 1
			return 0
		}
	fi
	base_sha=$(<"${fixture_root}/base.sha")
	head_sha=$(<"${fixture_root}/head.sha")
	remote_url=$(<"${fixture_root}/remote.url")
	git_probe=$(create_prospective_git_probe) || return 0
	wrapper="${fixture_root}/git-2.43-wrapper"
	cat >"$wrapper" <<WRAPPER_EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then
	printf '%s\n' 'git version 2.43.0'
	exit 0
fi
exec env -u GIT_NO_LAZY_FETCH '${git_probe}' "\$@"
WRAPPER_EOF
	chmod +x "$wrapper"
	output=$(run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" \
		'testorg/testrepo' "$fixture_dir" "$wrapper") || rc=$?
	print_result "prospective TODO: Git 2.43 without GIT_NO_LAZY_FETCH validates (GH#33752)" "$rc" "output=$output"

	rc=0
	output=$(AIDEVOPS_TEST_SKIP_BLOB_FETCH=1 \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" \
		'testorg/testrepo' "$fixture_dir" "$wrapper") || rc=$?
	print_result "prospective TODO: Git 2.43 missed blob fails closed without lazy fetch (GH#33752)" \
		"$([[ "$rc" -ne 0 && "$output" == *"required prospective blobs were not materialized"* ]] && printf '0' || printf '1')" \
		"rc=$rc output=$output"
	rc=0
	prospective_contexts_clean "$fixture_dir" || rc=$?
	print_result "prospective TODO: Git 2.43 checks clean isolated contexts" "$rc"
	return 0
}

# Fixture remotes are local paths, which never consult credential helpers. The
# probe replays the HTTPS credential exchange (fill, then approve) with the
# exact config and environment the guard gives its fetch, then runs the real
# fetch. A fake global helper stands in for osxkeychain; system config is
# excluded so a regression fails the test instead of opening a Keychain
# dialog (GH#33904).
test_prospective_todo_fetch_credential_routing() {
	local fixture_dir="" fixture_root="${TEST_ROOT}/prospective-crisscross"
	local base_sha="" head_sha="" remote_url="" output="" rc=0
	local auth_root="${TEST_ROOT}/prospective-auth" probe="" inherited_log="" gh_log=""
	if [[ -f "${fixture_root}/base.sha" ]]; then
		fixture_dir="${fixture_root}/caller"
	else
		fixture_dir=$(create_prospective_crisscross_fixture) || {
			print_result "prospective TODO: credential routing fixture" 1
			return 0
		}
	fi
	base_sha=$(<"${fixture_root}/base.sha")
	head_sha=$(<"${fixture_root}/head.sha")
	remote_url=$(<"${fixture_root}/remote.url")
	inherited_log="${auth_root}/inherited.log"
	gh_log="${auth_root}/gh.log"
	mkdir -p "${auth_root}/bin" "${fixture_dir}/attacker-home" || return 0
	cat >"${auth_root}/inherited-helper" <<HELPER_EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>'${inherited_log}'
printf 'username=inherited\npassword=inherited-synthetic\n'
HELPER_EOF
	cat >"${auth_root}/bin/gh" <<GH_EOF
#!/usr/bin/env bash
[[ "\${1:-} \${2:-}" == "auth git-credential" ]] || exit 1
printf '%s\n' "\${3:-}" >>'${gh_log}'
cat >/dev/null
[[ "\${3:-}" == "get" && -z "\${AIDEVOPS_TEST_GH_NO_TOKEN:-}" ]] || exit 0
printf 'username=x-access-token\npassword=managed-synthetic\n'
GH_EOF
	probe="${auth_root}/credential-probe-git"
	cat >"$probe" <<'PROBE_EOF'
#!/usr/bin/env bash
config_args=() prev="" arg="" subcommand="" credential=""
for arg in "$@"; do
	if [[ "$prev" == "-c" ]]; then
		config_args+=(-c "$arg")
	elif [[ -z "$subcommand" && "$prev" != "-C" && "$arg" != -* ]]; then
		subcommand="$arg"
	fi
	prev="$arg"
done
if [[ "$subcommand" == "fetch" ]]; then
	[[ "${GIT_TERMINAL_PROMPT:-}" == "0" && -z "${GIT_ASKPASS:-}" ]] || {
		printf 'fatal: fetch environment allows interactive prompts\n' >&2
		exit 128
	}
	request=$'protocol=https\nhost=github.com\npath=testorg/testrepo.git\n\n'
	# Never reach a real OS keyring, even when the code under test regresses:
	# the fake global helper is the only inherited helper in scope.
	credential=$(env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 \
		/usr/bin/git "${config_args[@]}" credential fill <<<"$request") || exit 128
	env -u XDG_CONFIG_HOME GIT_CONFIG_NOSYSTEM=1 \
		/usr/bin/git "${config_args[@]}" credential approve <<<"${credential}"$'\n' || exit 128
fi
exec /usr/bin/git "$@"
PROBE_EOF
	chmod +x "${auth_root}/inherited-helper" "${auth_root}/bin/gh" "$probe" || return 0
	HOME="${fixture_dir}/attacker-home" /usr/bin/git config --global credential.helper \
		"${auth_root}/inherited-helper" || return 0
	HOME="${fixture_dir}/attacker-home" /usr/bin/git config --global \
		credential.https://github.com.helper "${auth_root}/inherited-helper" || return 0
	: >"$inherited_log"
	: >"$gh_log"
	output=$(GIT_ASKPASS=/bin/echo \
		AIDEVOPS_TEST_GUARD_PATH="${auth_root}/bin:${TEST_ROOT}/bin:${SCRIPT_DIR}/..:/usr/bin:/bin:${PATH}" \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" \
		'testorg/testrepo' "$fixture_dir" "$probe") || rc=$?
	print_result "prospective TODO: fetch authenticates through gh, never an inherited helper (GH#33904)" \
		"$([[ "$rc" -eq 0 && ! -s "$inherited_log" && "$(<"$gh_log")" == *get*store* ]] && printf '0' || printf '1')" \
		"rc=$rc inherited=$(<"$inherited_log") gh=$(<"$gh_log") output=$output"

	rc=0
	: >"$inherited_log"
	output=$(AIDEVOPS_TEST_GH_NO_TOKEN=1 \
		AIDEVOPS_TEST_GUARD_PATH="${auth_root}/bin:${TEST_ROOT}/bin:${SCRIPT_DIR}/..:/usr/bin:/bin:${PATH}" \
		run_prospective_todo_guard "$fixture_dir" "$base_sha" "$head_sha" live "$remote_url" \
		'testorg/testrepo' "$fixture_dir" "$probe") || rc=$?
	print_result "prospective TODO: missing managed credential fails promptly with redacted guidance (GH#33904)" \
		"$([[ "$rc" -ne 0 && ! -s "$inherited_log" && "$output" == *"gh auth status"* &&
			"$output" != *synthetic* ]] && printf '0' || printf '1')" \
		"rc=$rc inherited=$(<"$inherited_log") output=$output"
	HOME="${fixture_dir}/attacker-home" /usr/bin/git config --global --unset-all credential.helper || true
	HOME="${fixture_dir}/attacker-home" /usr/bin/git config --global --unset-all \
		credential.https://github.com.helper || true
	rc=0
	prospective_contexts_clean "$fixture_dir" || rc=$?
	print_result "prospective TODO: credential routing checks clean isolated contexts" "$rc"
	return 0
}

# shellcheck source=./test-full-loop-merge-cases.sh
# shellcheck disable=SC1091  # Sibling test module resolved at runtime.
source "${SCRIPT_DIR}/test-full-loop-merge-cases.sh"
# shellcheck source=./test-full-loop-merge-planning.sh
# shellcheck disable=SC1091  # Sibling test module resolved at runtime.
source "${SCRIPT_DIR}/test-full-loop-merge-planning.sh"

main() {
	trap teardown_test_env EXIT
	setup_test_env

	echo "=== Admin merge fallback signaling tests (t2247) ==="
	echo ""

	test_admin_fallback_signals
	test_admin_fallback_native_review_handoff
	test_admin_timeout_reconciles_without_replay
	test_admin_fallback_blocks_needs_maintainer_review_issue
	test_admin_fallback_blocks_pending_required_checks
	test_explicit_admin_no_signaling
	test_other_error_no_fallback
	test_late_review_blocks_every_merge_transport
	test_graphql_rate_limit_rest_fallback
	test_graphql_rate_limit_cmd_merge_phase_autofile
	test_graphql_rate_limit_auto_no_rest_fallback
	test_review_gate_failure_blocks_rest_fallback
	test_cooldown_gate_failure_reports_cooldown
	test_local_admission_gate_failure_reports_retry_deadline
	test_post_verification_read_admission_window
	test_bounded_local_admission_recovery
	test_shared_merge_read_admission_recovery
	test_final_head_sha_read_admission_recovery
	test_local_deferral_survives_context_resolution
	test_exact_check_deferral_preserves_retry_deadline
	test_auto_review_required_interactive_admin_fallback
	test_auto_review_required_admin_rejection_handoff
	test_auto_review_required_headless_no_admin_fallback
	test_stale_cache_401_retry
	test_auth_401_detection_avoids_numeric_false_positives
	test_pr_ready_accepts_prefetched_json
	test_pr_ready_blocks_nonpassing_rollup
	test_verified_head_lookup_failure_is_not_reported_as_drift
	test_post_merge_stale_evidence_retries_fresh_read
	test_post_merge_unmerged_evidence_fails_closed
	test_post_merge_api_indeterminate_fails_closed
	test_wip_draft_takeover_uses_reviewed_pr_title
	test_gh_prefixed_feature_inherits_commit_category
	test_gh_prefixed_prose_without_evidence_is_not_guessed
	test_invalid_squash_title_blocks_before_merge
	test_non_squash_skips_subject_override
	test_checkout_free_publication_readiness_handoff
	test_todo_duplicate_report_large_baseline
	test_timeout_sec_fallback_preserves_stdin
	test_prospective_todo_merge_guard
	test_prospective_todo_requires_supported_native_git
	test_prospective_todo_live_fetch_guard
	test_prospective_todo_crisscross_fetch_guard
	test_prospective_todo_pre_lazy_fetch_env_git
	test_prospective_todo_fetch_credential_routing

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
