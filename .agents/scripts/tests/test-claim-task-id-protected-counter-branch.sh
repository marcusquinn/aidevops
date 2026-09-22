#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#23077 and GH#32223.
#
# A protected counter branch rejects direct CAS pushes. The allocator must use
# GitHub's read-only policy API to stop before mutation when available, retain
# push-time classification as a fallback, and leave the working tree unchanged.

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
	local dedicated_state="${2:-valid}"
	local bare_dir="${base_dir}/remote.git"
	local seed_dir="${base_dir}/seed"
	local work_dir="${base_dir}/work"

	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || git init --bare "$bare_dir" >/dev/null 2>&1 || return 1
	git clone "$bare_dir" "$seed_dir" >/dev/null 2>&1 || return 1
	git -C "$seed_dir" config user.email "test@test.local" >/dev/null 2>&1 || return 1
	git -C "$seed_dir" config user.name "Test" >/dev/null 2>&1 || return 1
	git -C "$seed_dir" config commit.gpgsign false >/dev/null 2>&1 || true
	printf '1000\n' >"${seed_dir}/.task-counter"
	printf '%s\n' '.aidevops.json' >"${seed_dir}/.gitignore"
	printf '# Tasks\n\n' >"${seed_dir}/TODO.md"
	git -C "$seed_dir" add .task-counter .gitignore TODO.md >/dev/null 2>&1 || return 1
	git -C "$seed_dir" commit -m "chore: seed protected counter" >/dev/null 2>&1 || return 1
	git -C "$seed_dir" push origin main >/dev/null 2>&1 || return 1
	if [[ "$dedicated_state" != "absent" ]]; then
		git -C "$seed_dir" push origin main:refs/heads/task-id-counter >/dev/null 2>&1 || return 1
	fi
	if [[ "$dedicated_state" == "stale" ]]; then
		printf '1005\n' >"${seed_dir}/.task-counter"
		git -C "$seed_dir" add .task-counter >/dev/null 2>&1 || return 1
		git -C "$seed_dir" commit -m "chore: advance default counter" >/dev/null 2>&1 || return 1
		git -C "$seed_dir" push origin main >/dev/null 2>&1 || return 1
	fi

	mkdir -p "${bare_dir}/hooks" || return 1
	cat >"${bare_dir}/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r _old _new ref; do
	printf 'called\n' >>"$(dirname "$0")/../pre-receive-called"
	if [[ "$ref" == "refs/heads/main" ]]; then
		printf 'remote: error: GH006: Protected branch update failed for %s.\n' "$ref" >&2
		printf 'remote: error: Changes must be made through a pull request.\n' >&2
		exit 1
	fi
	done
	exit 0
HOOK
	chmod +x "${bare_dir}/hooks/pre-receive" || return 1
	git -C "$seed_dir" config "url.file://${bare_dir}.insteadOf" "https://github.com/example/protected-counter.git" || return 1
	git -C "$seed_dir" remote set-url origin "https://github.com/example/protected-counter.git" || return 1
	git -C "$seed_dir" worktree add --detach "$work_dir" main >/dev/null 2>&1 || return 1
	printf '%s\n' '{"default_branch":"main","counter_branch":"main"}' >"${work_dir}/.aidevops.json"
	printf '%s\n' "$work_dir"
	return 0
}

setup_policy_stub() {
	local base_dir="$1"
	local bin_dir="${base_dir}/bin"

	mkdir -p "$bin_dir" || return 1
	cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -u

policy="${FAKE_GH_POLICY:-classic}"
if [[ "$policy" == "unavailable" ]]; then
	exit 1
fi
if [[ "$#" -ge 2 && "$1" == "api" && "$2" == "repos/example/protected-counter/branches/main/protection" ]]; then
	if [[ "$policy" == "classic" ]]; then
		printf '%s\n' '{"required_pull_request_reviews":{"required_approving_review_count":1}}'
	else
		printf '%s\n' '{}'
	fi
	exit 0
fi
if [[ "$#" -ge 2 && "$1" == "api" && "$2" == "repos/example/protected-counter/rules/branches/main" ]]; then
	if [[ "$policy" == "ruleset" ]]; then
		printf '%s\n' '[{"type":"pull_request"}]'
	else
		printf '%s\n' '[]'
	fi
	exit 0
fi
if [[ "$#" -ge 2 && "$1" == "api" && "$2" == "repos/example/protected-counter/branches/task-id-counter/protection" ]]; then
	printf '%s\n' '{}'
	exit 0
fi
if [[ "$#" -ge 2 && "$1" == "api" && "$2" == "repos/example/protected-counter/rules/branches/task-id-counter" ]]; then
	printf '%s\n' '[]'
	exit 0
fi
exit 1
STUB
	chmod +x "${bin_dir}/gh" || return 1
	printf '%s\n' "$bin_dir"
	return 0
}

assert_clean_counter_state() {
	local name="$1"
	local work_dir="$2"
	local before_head="$3"
	local after_head=""
	local status=""
	local remote_counter=""

	after_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing final HEAD"; return 1; }
	if [[ "$after_head" != "$before_head" ]]; then
		fail "$name" "local HEAD changed"
		return 1
	fi
	status=$(git -C "$work_dir" status --short 2>/dev/null)
	if [[ -n "$status" ]]; then
		fail "$name" "working tree dirty: $status"
		return 1
	fi
	git -C "$work_dir" fetch origin main >/dev/null 2>&1 || true
	remote_counter=$(git -C "$work_dir" show origin/main:.task-counter 2>/dev/null | tr -d '[:space:]')
	if [[ "$remote_counter" != "1000" ]]; then
		fail "$name" "remote counter changed to ${remote_counter:-<empty>}"
		return 1
	fi
	return 0
}

push_attempt_count() {
	local marker="$1"
	if [[ ! -f "$marker" ]]; then
		printf '0\n'
		return 0
	fi
	wc -l <"$marker" | tr -d '[:space:]'
	return 0
}

test_protected_counter_branch_preflight() {
	local tmpdir="$1"
	local work_dir="$2"
	local bin_dir="$3"
	local name="protected counter branch fails policy preflight before mutation"
	local before_head output rc marker policy
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing initial HEAD"; return 0; }
	marker="${tmpdir}/remote.git/pre-receive-called"
	rm -f "$marker"
	printf '%s\n' '{"default_branch":"main","counter_branch":"main"}' >"${work_dir}/.aidevops.json"

	for policy in classic ruleset; do
		rc=0
		output=$(PATH="${bin_dir}:${PATH}" FAKE_GH_POLICY="$policy" \
			CAS_MAX_RETRIES=5 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
			--title "protected counter branch" \
			--no-issue \
			--repo-path "$work_dir" 2>&1) || rc=$?

		if [[ $rc -ne 4 ]]; then
			fail "$name" "${policy}: expected setup exit 4, got ${rc}: $output"
			return 0
		fi
		if ! printf '%s\n' "$output" | grep -q 'PROTECTED_COUNTER_BRANCH'; then
			fail "$name" "${policy}: missing protected-branch diagnostic: $output"
			return 0
		fi
		if ! printf '%s\n' "$output" | grep -Fq 'counter_branch set from .aidevops.json: main'; then
			fail "$name" "${policy}: fixture did not exercise project configuration: $output"
			return 0
		fi
		if ! printf '%s\n' "$output" | grep -Fq 'Task ID allocation stopped before reading or advancing .task-counter.'; then
			fail "$name" "${policy}: missing pre-mutation diagnostic: $output"
			return 0
		fi
		if ! printf '%s\n' "$output" | grep -Fq 'set .aidevops.json counter_branch to that branch (for example, "task-id-counter").'; then
			fail "$name" "${policy}: missing dedicated-branch remediation: $output"
			return 0
		fi
		if ! printf '%s\n' "$output" | grep -q 'AIDEVOPS_TASK_COUNTER_STATUS=setup_error detail=protected_counter_branch'; then
			fail "$name" "${policy}: missing setup-error status: $output"
			return 0
		fi
		if [[ -e "$marker" ]]; then
			fail "$name" "${policy}: pre-receive hook proves a push was attempted"
			return 0
		fi
	done
	assert_clean_counter_state "$name" "$work_dir" "$before_head" || return 0

	pass "$name"
	return 0
}

test_protected_counter_branch_push_fallback() {
	local tmpdir="$1"
	local work_dir="$2"
	local bin_dir="$3"
	local name="protected push rejection remains non-retriable when policy API is unavailable"
	local before_head output rc marker push_count
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing initial HEAD"; return 0; }
	marker="${tmpdir}/remote.git/pre-receive-called"
	rm -f "$marker"
	printf '%s\n' '{"default_branch":"main","counter_branch":"main"}' >"${work_dir}/.aidevops.json"

	rc=0
	output=$(PATH="${bin_dir}:${PATH}" FAKE_GH_POLICY=unavailable \
		CAS_MAX_RETRIES=5 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
		--title "protected counter branch fallback" \
		--no-issue \
		--repo-path "$work_dir" 2>&1) || rc=$?

	if [[ $rc -ne 4 ]]; then
		fail "$name" "expected setup exit 4, got ${rc}: $output"
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
	push_count=$(push_attempt_count "$marker")
	if [[ "$push_count" != "1" ]]; then
		fail "$name" "expected exactly one rejected push, got ${push_count}"
		return 0
	fi
	assert_clean_counter_state "$name" "$work_dir" "$before_head" || return 0

	pass "$name"
	return 0
}

test_implicit_dedicated_counter_branch() {
	local tmpdir="$1"
	local work_dir="$2"
	local bin_dir="$3"
	local name="validated dedicated branch is selected without an explicit config value"
	local before_head output rc marker task_id branch_counter push_count
	printf '%s\n' '{}' >"${work_dir}/.aidevops.json"
	before_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || { fail "$name" "missing initial HEAD"; return 0; }
	marker="${tmpdir}/remote.git/pre-receive-called"
	rm -f "$marker"

	rc=0
	output=$(PATH="${bin_dir}:${PATH}" FAKE_GH_POLICY=classic \
		CAS_MAX_RETRIES=5 CAS_WALL_TIMEOUT_S=20 CAS_SSH_FALLBACK_ENABLED=0 "$CLAIM_SCRIPT" \
		--title "dedicated counter branch" \
		--no-issue \
		--repo-path "$work_dir" 2>&1) || rc=$?

	if [[ $rc -ne 0 ]]; then
		fail "$name" "claim failed with ${rc}: $output"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -Fq 'counter branch auto-selected from validated dedicated branch: task-id-counter'; then
		fail "$name" "missing dedicated-branch selection evidence: $output"
		return 0
	fi
	task_id=$(printf '%s\n' "$output" | awk -F= '/^task_id=/{print $2; exit}')
	if [[ "$task_id" != "t1000" ]]; then
		fail "$name" "expected t1000, got ${task_id:-<empty>}"
		return 0
	fi
	push_count=$(push_attempt_count "$marker")
	if [[ "$push_count" != "1" ]]; then
		fail "$name" "expected one dedicated CAS push, got ${push_count}"
		return 0
	fi
	assert_clean_counter_state "$name" "$work_dir" "$before_head" || return 0
	git -C "$work_dir" fetch origin task-id-counter >/dev/null 2>&1 || true
	branch_counter=$(git -C "$work_dir" show origin/task-id-counter:.task-counter 2>/dev/null | tr -d '[:space:]')
	if [[ "$branch_counter" != "1001" ]]; then
		fail "$name" "expected dedicated counter 1001, got ${branch_counter:-<empty>}"
		return 0
	fi

	pass "$name"
	return 0
}

run_canonical_claim() {
	local work_dir="$1"
	local bin_dir="$2"
	local temp_root="$3"
	shift 3
	PATH="${bin_dir}:${SCRIPT_DIR}/..:/usr/bin:/bin" \
		AIDEVOPS_TEMP_DIR="$temp_root" \
		FAKE_GH_POLICY=classic \
		CAS_MAX_RETRIES=5 \
		CAS_WALL_TIMEOUT_S=20 \
		CAS_SSH_FALLBACK_ENABLED=0 \
		"$CLAIM_SCRIPT" --no-issue --repo-path "$work_dir" "$@"
}

assert_canonical_discovery_result() {
	local state="$1"
	local name="$2"
	local case_dir="$3"
	local output="$4"
	local rc="$5"
	local task_id=""
	local branch_counter=""

	case "$state" in
	valid)
		if [[ $rc -ne 0 ]]; then
			fail "$name" "claim failed with ${rc}: $output"
			return 1
		fi
		task_id=$(printf '%s\n' "$output" | awk -F= '/^task_id=/{print $2; exit}')
		if [[ "$task_id" != "t1000" ]]; then
			fail "$name" "expected t1000, got ${task_id:-<empty>}"
			return 1
		fi
		branch_counter=$(/usr/bin/git --git-dir="${case_dir}/remote.git" \
			show refs/heads/task-id-counter:.task-counter 2>/dev/null | tr -d '[:space:]')
		if [[ "$branch_counter" != "1001" ]]; then
			fail "$name" "expected dedicated counter 1001, got ${branch_counter:-<empty>}"
			return 1
		fi
		;;
	absent)
		if [[ $rc -ne 4 ]] || ! printf '%s\n' "$output" | grep -Fq 'Dedicated counter branch task-id-counter not present; using main'; then
			fail "$name" "expected absent-branch fallback and setup exit 4: rc=${rc}: $output"
			return 1
		fi
		;;
	stale)
		if [[ $rc -ne 4 ]] || ! printf '%s\n' "$output" | grep -Fq 'COUNTER_BRANCH_STALE'; then
			fail "$name" "expected stale-branch fallback and setup exit 4: rc=${rc}: $output"
			return 1
		fi
		;;
	indeterminate)
		if [[ $rc -ne 4 ]] || ! printf '%s\n' "$output" | grep -Fq 'AIDEVOPS_TASK_COUNTER_STATUS=setup_error detail=counter_branch_discovery_failed'; then
			fail "$name" "expected typed discovery failure: rc=${rc}: $output"
			return 1
		fi
		if printf '%s\n' "$output" | grep -Fq 'using main'; then
			fail "$name" "indeterminate discovery silently fell back to main: $output"
			return 1
		fi
		;;
	esac
	return 0
}

test_canonical_implicit_counter_discovery() {
	local parent_tmpdir="$1"
	local bin_dir="$2"
	local state=""
	local case_dir=""
	local work_dir=""
	local temp_root=""
	local name=""
	local output=""
	local rc=0
	local before_head=""
	local before_status=""
	local after_head=""
	local after_status=""

	for state in valid absent stale indeterminate; do
		name="canonical implicit discovery handles ${state} dedicated branch with the real Git shim"
		case_dir="${parent_tmpdir}/canonical-${state}"
		mkdir -p "$case_dir" || { fail "$name" "fixture directory failed"; continue; }
		work_dir=$(setup_protected_remote "$case_dir" "$state") || {
			fail "$name" "repo setup failed"
			continue
		}
		work_dir="${case_dir}/seed"
		printf '%s\n' '{}' >"${work_dir}/.aidevops.json"
		temp_root="${case_dir}/contexts"
		mkdir -p "$temp_root" || { fail "$name" "context root setup failed"; continue; }
		if [[ "$state" == "indeterminate" ]]; then
			mv "${case_dir}/remote.git" "${case_dir}/remote-unavailable.git" || {
				fail "$name" "could not make remote unavailable"
				continue
			}
		fi
		before_head=$(/usr/bin/git -C "$work_dir" rev-parse HEAD 2>/dev/null)
		before_status=$(/usr/bin/git -C "$work_dir" status --short 2>/dev/null)

		rc=0
		output=$(run_canonical_claim "$work_dir" "$bin_dir" "$temp_root" \
			--title "canonical ${state} discovery" 2>&1) || rc=$?
		after_head=$(/usr/bin/git -C "$work_dir" rev-parse HEAD 2>/dev/null)
		after_status=$(/usr/bin/git -C "$work_dir" status --short 2>/dev/null)
		if [[ "$after_head" != "$before_head" || "$after_status" != "$before_status" ]]; then
			fail "$name" "canonical source repository changed"
			continue
		fi
		if ! printf '%s\n' "$output" | grep -Fq 'Using isolated Git context for canonical counter discovery and CAS'; then
			fail "$name" "isolated-context evidence missing: $output"
			continue
		fi
		if find "$temp_root" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
			fail "$name" "isolated context was not cleaned up"
			continue
		fi

		assert_canonical_discovery_result "$state" "$name" "$case_dir" "$output" "$rc" || continue

		pass "$name"
	done
	return 0
}

test_canonical_context_setup_failure() {
	local parent_tmpdir="$1"
	local bin_dir="$2"
	local name="canonical context setup failure is typed and leaves the source unchanged"
	local case_dir="${parent_tmpdir}/canonical-context-error"
	local work_dir=""
	local temp_root="${case_dir}/blocked-temp-root"
	local before_head=""
	local output=""
	local rc=0

	mkdir -p "$case_dir" || { fail "$name" "fixture directory failed"; return 0; }
	work_dir=$(setup_protected_remote "$case_dir" valid) || {
		fail "$name" "repo setup failed"
		return 0
	}
	work_dir="${case_dir}/seed"
	printf '%s\n' '{}' >"${work_dir}/.aidevops.json"
	printf '%s\n' 'not a directory' >"$temp_root"
	before_head=$(/usr/bin/git -C "$work_dir" rev-parse HEAD 2>/dev/null)

	output=$(run_canonical_claim "$work_dir" "$bin_dir" "$temp_root" \
		--title "canonical context setup failure" 2>&1) || rc=$?
	if [[ $rc -ne 4 ]] || ! printf '%s\n' "$output" | grep -Fq \
		'AIDEVOPS_TASK_COUNTER_STATUS=setup_error detail=counter_git_context_temp_root_failed'; then
		fail "$name" "expected typed setup failure: rc=${rc}: $output"
		return 0
	fi
	if [[ $(/usr/bin/git -C "$work_dir" rev-parse HEAD 2>/dev/null) != "$before_head" ]]; then
		fail "$name" "canonical source HEAD changed"
		return 0
	fi

	pass "$name"
	return 0
}

main() {
	local tmpdir=""
	local work_dir=""
	local bin_dir=""
	if [[ ! -x "$CLAIM_SCRIPT" ]]; then
		fail "claim script executable" "$CLAIM_SCRIPT missing or not executable"
	else
		pass "claim script executable"
	fi
	tmpdir=$(mktemp -d) || {
		fail "protected counter fixture" "mktemp failed"
		printf '%s passed, %s failed\n' "$PASS" "$FAIL"
		return 1
	}
	work_dir=$(setup_protected_remote "$tmpdir") || {
		fail "protected counter fixture" "repo setup failed"
		rm -rf "$tmpdir"
		printf '%s passed, %s failed\n' "$PASS" "$FAIL"
		return 1
	}
	bin_dir=$(setup_policy_stub "$tmpdir") || {
		fail "protected counter fixture" "policy stub setup failed"
		rm -rf "$tmpdir"
		printf '%s passed, %s failed\n' "$PASS" "$FAIL"
		return 1
	}
	test_protected_counter_branch_preflight "$tmpdir" "$work_dir" "$bin_dir"
	test_protected_counter_branch_push_fallback "$tmpdir" "$work_dir" "$bin_dir"
	test_implicit_dedicated_counter_branch "$tmpdir" "$work_dir" "$bin_dir"
	test_canonical_implicit_counter_discovery "$tmpdir" "$bin_dir"
	test_canonical_context_setup_failure "$tmpdir" "$bin_dir"
	rm -rf "$tmpdir"
	printf '%s passed, %s failed\n' "$PASS" "$FAIL"
	[[ "$FAIL" -eq 0 ]] || return 1
	return 0
}

main "$@"
