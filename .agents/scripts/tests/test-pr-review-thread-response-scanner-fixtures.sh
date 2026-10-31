#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shared command stubs, environment setup, and state helpers.
# Sourced by test-pr-review-thread-response-scanner.sh; not a standalone suite.
# The entry point owns strict mode, TEST_SCRIPT_DIR, and shared test state.

[[ -n "${_PRRTS_TEST_FIXTURES_LOADED:-}" ]] && return 0
_PRRTS_TEST_FIXTURES_LOADED=1

write_fake_gh_identity_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "${2:-}" == "user" ]]; then
	[[ "${STUB_GH_REST_FAIL:-0}" == "1" ]] && exit 1
	printf '%s\n' "${STUB_GH_LOGIN:-worker-login}"
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" && "$*" == *"viewer { login }"* ]]; then
	[[ "${STUB_GH_GRAPHQL_FAIL:-0}" == "1" ]] && exit 1
	printf '%s\n' "${STUB_GH_GRAPHQL_LOGIN:-worker-login}"
	exit 0
fi
GH_STUB
	return 0
}

write_fake_gh_stub() {
	local default_reviewer_comments='{"latestReviews":[],"comments":[]}'
	export STUB_REVIEWER_COMMENTS_RESPONSE="${STUB_REVIEWER_COMMENTS_RESPONSE:-$default_reviewer_comments}"
	write_fake_gh_identity_stub
	cat >>"${TEST_ROOT}/bin/gh" <<'GH_STUB'
if [[ "$1" == "api" && "${2:-}" == "rate_limit" ]]; then
	printf '%s\n' "${STUB_GRAPHQL_REMAINING:-100}"
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "user" ]]; then printf '%s\n' "${STUB_GH_LOGIN:-worker-login}"; exit 0; fi
if [[ "$1" == "api" && "${2:-}" =~ ^repos/owner/repo/pulls/[0-9]+/reviews\?per_page=100$ ]]; then
	printf '%s\n' "${STUB_REVIEWS_RESPONSE:-[[]]}"
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" =~ ^repos/owner/repo/pulls/[0-9]+$ ]]; then
	[[ "${AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS:-}" == "1" ]] || exit 1
	case "${STUB_PR_REPOSITORY_MODE:-same}" in
	missing) printf '%s\n' '{"state":"open","draft":false,"head":{"sha":"'"${STUB_PULL_HEAD_OID:-$TEST_HEAD_OID_1}"'","repo":null},"base":{"repo":{"full_name":"owner/repo"}}}' ;;
	cross) printf '%s\n' '{"state":"open","draft":false,"head":{"sha":"'"${STUB_PULL_HEAD_OID:-$TEST_HEAD_OID_1}"'","repo":{"full_name":"contributor/repo"}},"base":{"repo":{"full_name":"owner/repo"}}}' ;;
	*) printf '%s\n' '{"state":"'"${STUB_PULL_STATE:-open}"'","draft":'"${STUB_PULL_DRAFT:-false}"',"head":{"sha":"'"${STUB_PULL_HEAD_OID:-$TEST_HEAD_OID_1}"'","repo":{"full_name":"owner/repo"}},"base":{"repo":{"full_name":"owner/repo"}}}' ;;
	esac
	exit 0
fi
if [[ "$1" == "pr" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${STUB_PR_LIST:-1	Fix active PR	false	origin:worker	feature/review	${TEST_HEAD_OID_1}	worker-bot}"; exit 0; fi
if [[ "$1" == "pr" && "${2:-}" == "view" ]]; then
	if [[ "$*" == *"comments"* ]]; then
		printf '%s\n' "$STUB_REVIEWER_COMMENTS_RESPONSE"
	elif [[ "$*" == *"--json isCrossRepository"* ]]; then exit 1
	else printf '%s\n' "${STUB_PR_VIEW:-Fix active PR	feature/review	${TEST_HEAD_OID_1}	worker-bot}"
	fi
	exit 0
fi
if [[ "$1" == "pr" && "${2:-}" == "edit" && "$*" == *"--add-reviewer"* ]]; then
	printf '%s\n' "$*" >>"${PR_EDIT_LOG:-/dev/null}"
	[[ "${STUB_REREVIEW_REQUEST_FAIL:-false}" == "true" ]] && exit 1
	exit 0
fi
if [[ "$1" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ "$*" == *"addPullRequestReviewThreadReply"* || "$*" == *"resolveReviewThread"* ]]; then [[ "${AIDEVOPS_GH_QUOTA_COST:-}" == "1" && "$*" != *"rateLimit"* ]] || exit 1; else [[ "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" == "1" && "$*" == *"rateLimit"* ]] || exit 1; fi
	for arg in "$@"; do
		if [[ "$arg" == "owner=" || "$arg" == "name=" ]]; then
			printf 'empty repo GraphQL field: %s\n' "$arg" >&2
			exit 1
		fi
	done
	if [[ "$*" == *"addPullRequestReviewThreadReply"* ]]; then
		previous_arg=""
		for arg in "$@"; do
			if [[ "$arg" == body=* ]]; then
				printf '%s' "$previous_arg" >"${GRAPHQL_BODY_FLAG_CAPTURE:-/dev/null}"
				if [[ "$previous_arg" == "-F" && "${arg#body=}" == @* ]]; then
					printf 'error parsing "body" value: open %s: no such file or directory\n' "${arg#body=}" >&2
					exit 1
				fi
				printf '%s' "${arg#body=}" >"${GRAPHQL_BODY_CAPTURE:-/dev/null}"
			fi
			previous_arg="$arg"
		done
		printf 'reply\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		case "${STUB_REPLY_RESPONSE_MODE:-valid}" in missing-id) printf '%s\n' '{"data":{"addPullRequestReviewThreadReply":{"comment":{"url":"https://example.invalid/reply"}}}}' ;; partial-error) printf '%s\n' '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"COMMENT1"}}},"errors":[{"message":"UNCERTAIN_WRITE"}]}' ;; *) printf '%s\n' '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"COMMENT1","url":"https://example.invalid/reply"}}}}' ;; esac
		exit 0
	fi
	if [[ "$*" == *"resolveReviewThread"* ]]; then
		printf 'resolve\n' >>"${GRAPHQL_MUTATIONS_LOG:-/dev/null}"
		case "${STUB_RESOLVE_RESPONSE_MODE:-valid}" in wrong-thread) printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"id":"THREAD_OTHER","isResolved":true}}}}' ;; partial-error) printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"id":"THREAD1","isResolved":true}}},"errors":[{"message":"UNCERTAIN_WRITE"}]}' ;; *) printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"id":"THREAD1","isResolved":true}}}}' ;; esac
		exit 0
	fi
	if [[ "$*" == *"node(id:"* && "$*" == *"comments(first: 1)"* ]]; then
		if [[ "${STUB_THREAD_AUTHOR_MODE:-ok}" == "missing" ]]; then
			printf '{"data":{"node":{"comments":{"nodes":[{"author":null}]}},"rateLimit":{"cost":1}}}\n'
		else
			printf '{"data":{"node":{"comments":{"nodes":[{"author":{"login":"%s"}}]}},"rateLimit":{"cost":1}}}\n' "${STUB_THREAD_AUTHOR_LOGIN:-reviewer}"
		fi
		exit 0
	fi
	if [[ "$*" == *"node(id:"* || "$*" == *"comments(first: 100)"* ]]; then
		printf '{"data":{"node":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":false}}},"rateLimit":{"cost":1}}}\n'
		exit 0
	fi
	if [[ "${STUB_GRAPHQL_COST_MODE:-exact}" == "missing" ]]; then
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
		exit 0
	fi
GH_STUB
	append_fake_gh_thread_modes
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

append_fake_gh_thread_modes() {
	cat >>"${TEST_ROOT}/bin/gh" <<'GH_STUB'
	case "${STUB_THREADS_MODE:-unresolved}" in
	hang)
		sleep "${STUB_HANG_SECONDS:-5}"
		exit 1
		;;
	rate_limit|error)
		printf 'GraphQL failure\n' >&2
		exit 1
		;;
	none)
		printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}\n'
		;;
	human)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_HUMAN","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"maintainer"},"path":"script.sh","line":12,"url":"https://example.invalid/human","updatedAt":"2026-06-03T00:00:00Z"}]}},{"id":"THREAD_BOT","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"bot.sh","line":3,"url":"https://example.invalid/bot","updatedAt":"2026-06-03T00:00:00Z"}]} }],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		;;
	many|remaining)
		thread_start=1
		[[ "${STUB_THREADS_MODE}" == "remaining" ]] && thread_start=4
		thread_end=10
		printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":['
		thread_number="$thread_start"
		while [[ "$thread_number" -le "$thread_end" ]]; do
			thread_id=$(printf '%02d' "$thread_number")
			[[ "$thread_number" -eq "$thread_start" ]] || printf ','
			printf '{"id":"THREAD%s","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"batch.sh","line":%s,"url":"https://example.invalid/thread%s","updatedAt":"2026-06-03T00:00:00Z"}]}}' \
				"$thread_id" "$thread_number" "$thread_id"
			thread_number=$((thread_number + 1))
		done
		printf '%s\n' '],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		;;
	outdated)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_OLD","isResolved":false,"isOutdated":true,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"old.sh","line":7,"url":"https://example.invalid/outdated","updatedAt":"2026-06-03T00:00:00Z"}]}}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		;;
	*)
		printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"gemini-code-assist[bot]"},"path":".agents/scripts/example.sh","line":42,"url":"https://example.invalid/thread","updatedAt":"2026-06-03T00:00:00Z"}]}},{"id":"THREAD2","isResolved":true,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai[bot]"},"path":"old.sh","line":1,"url":"https://example.invalid/resolved","updatedAt":"2026-06-03T00:00:00Z"}]} }],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
		;;
	esac
	exit 0
fi
printf '[]\n'
exit 0
GH_STUB
	return 0
}

write_fake_git_stub() {
	cat >"${TEST_ROOT}/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
if [[ "$*" == *"check-ref-format --branch"* ]]; then
	[[ "${STUB_GIT_INVALID_BRANCH:-false}" == "true" ]] && exit 1
	exit 0
fi
if [[ "$*" == *"worktree list --porcelain"* && -f "${GIT_WORKTREE_REGISTRY}" ]]; then
	while IFS=$'\t' read -r path branch oid; do
		printf 'worktree %s\nHEAD %s\n' "$path" "${oid:-$TEST_HEAD_OID_1}"
		if [[ "$branch" == "__DETACHED__" ]]; then
			printf 'detached\n\n'
		else
			printf 'branch refs/heads/%s\n\n' "$branch"
		fi
	done <"${GIT_WORKTREE_REGISTRY}"
	exit 0
fi
if [[ "$*" == *" worktree add -q --detach "* ]]; then
	bootstrap_path="${7:-}"
	mkdir -p "$bootstrap_path"
	printf '%s\t%s\t%s\n' "$bootstrap_path" '__DETACHED__' "$TEST_HEAD_OID_1" >>"${GIT_WORKTREE_REGISTRY}"
	exit 0
fi
if [[ "$*" == *" worktree remove --force "* ]]; then
	bootstrap_path="${6:-}"
	rm -rf "$bootstrap_path"
	while IFS=$'\t' read -r path branch oid; do
		[[ "$path" == "$bootstrap_path" ]] || printf '%s\t%s\t%s\n' "$path" "$branch" "$oid"
	done <"${GIT_WORKTREE_REGISTRY}" >"${GIT_WORKTREE_REGISTRY}.tmp"
	mv "${GIT_WORKTREE_REGISTRY}.tmp" "${GIT_WORKTREE_REGISTRY}"
	exit 0
fi
if [[ "$*" == *" fetch --no-tags --quiet origin "* ]]; then
	printf '%s\n' "${2:-}" >>"${GIT_FETCH_CWD_LOG}"
	if [[ "${STUB_GIT_CANONICAL_FETCH_FAIL:-false}" == "true" && "${2:-}" == "${GIT_CANONICAL_REPO_PATH}" ]]; then
		exit 1
	fi
	[[ "${STUB_GIT_FETCH_FAIL:-false}" == "true" ]] && exit 1
	printf '%s\n' "${STUB_REMOTE_HEAD_AFTER_FETCH:-${STUB_REMOTE_HEAD:-$TEST_HEAD_OID_1}}" >"${GIT_FETCHED_HEAD_STATE}"
	exit 0
fi
GIT_STUB
	append_fake_git_reconciliation_stub
	chmod +x "${TEST_ROOT}/bin/git"
	return 0
}

append_fake_git_reconciliation_stub() {
	cat >>"${TEST_ROOT}/bin/git" <<'GIT_STUB'
if [[ "$*" == *"rev-parse refs/remotes/origin/"* ]]; then
	if [[ -f "${GIT_FETCHED_HEAD_STATE}" ]]; then
		cat "${GIT_FETCHED_HEAD_STATE}"
		exit 0
	fi
	remote_head="${STUB_REMOTE_HEAD_INITIAL:-${STUB_REMOTE_HEAD:-$TEST_HEAD_OID_1}}"
	[[ "$remote_head" == "missing" ]] && exit 1
	printf '%s\n' "$remote_head"
	exit 0
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "HEAD" && -f "${GIT_WORKTREE_REGISTRY}" ]]; then
	while IFS=$'\t' read -r path branch oid; do
		if [[ "$path" == "${2:-}" ]]; then
			printf '%s\n' "${oid:-$TEST_HEAD_OID_1}"
			exit 0
		fi
	done <"${GIT_WORKTREE_REGISTRY}"
	exit 1
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "symbolic-ref" && "$*" == *"--short HEAD"* && -f "${GIT_WORKTREE_REGISTRY}" ]]; then
	while IFS=$'\t' read -r path branch oid; do
		if [[ "$path" == "${2:-}" && "$branch" != "__DETACHED__" ]]; then
			printf '%s\n' "$branch"
			exit 0
		fi
	done <"${GIT_WORKTREE_REGISTRY}"
	exit 1
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "status" && "${4:-}" == "--porcelain" ]]; then
	if [[ "${STUB_GIT_WORKTREE_DIRTY:-false}" == "true" && ! -f "${DIRTY_BACKUP_CLEANED:-/nonexistent}" ]]; then
		printf ' M diagnostic.txt\n'
	fi
	exit 0
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "merge-base" && "${4:-}" == "--is-ancestor" ]]; then
	[[ "${STUB_GIT_DIVERGED:-false}" == "true" ]] && exit 1
	exit 0
fi
if [[ "${1:-}" == "-C" && "${3:-}" == "merge" && "${4:-}" == "--ff-only" && -f "${GIT_WORKTREE_REGISTRY}" ]]; then
	[[ "${STUB_GIT_FAST_FORWARD_FAIL:-false}" == "true" ]] && exit 1
	merge_path="${2:-}"
	merge_oid="${5:-}"
	while IFS=$'\t' read -r path branch oid; do
		if [[ "$path" == "$merge_path" ]]; then
			printf '%s\t%s\t%s\n' "$path" "$branch" "$merge_oid"
		else
			printf '%s\t%s\t%s\n' "$path" "$branch" "$oid"
		fi
	done <"${GIT_WORKTREE_REGISTRY}" >"${GIT_WORKTREE_REGISTRY}.tmp"
	mv "${GIT_WORKTREE_REGISTRY}.tmp" "${GIT_WORKTREE_REGISTRY}"
	exit 0
fi
if [[ "$*" == *" cat-file -e "* ]]; then
	exit 0
fi
exit 1
GIT_STUB
	return 0
}

write_fake_headless_stub() {
	cat >"${TEST_ROOT}/headless-runtime-helper.sh" <<'HEADLESS_STUB'
#!/usr/bin/env bash
prompt_file=""
all_args="$*"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--prompt-file)
		prompt_file="${2:-}"
		shift 2
		;;
	*)
		shift
		;;
	esac
done
printf '%s\n' "$all_args" >"${HEADLESS_ARGS_CAPTURE}"
printf '%s\n' "${WORKER_WORKTREE_PATH:-}" >"${HEADLESS_ENV_CAPTURE}"
printf 'WORKER_ISSUE_NUMBER=%s\n' "${WORKER_ISSUE_NUMBER:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'WORKER_GITHUB_LOGIN=%s\n' "${WORKER_GITHUB_LOGIN:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'WORKER_NO_EXIT_PUSH=%s\n' "${WORKER_NO_EXIT_PUSH:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER=%s\n' "${AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE=%s\n' "${AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START=%s\n' "${AIDEVOPS_WORKTREE_EXPECTED_OWNER_PROCESS_START:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_PR_REPAIR_NUMBER=%s\n' "${AIDEVOPS_PR_REPAIR_NUMBER:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_PR_REPAIR_HEAD_SHA=%s\n' "${AIDEVOPS_PR_REPAIR_HEAD_SHA:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_PR_REPAIR_HEAD_REF=%s\n' "${AIDEVOPS_PR_REPAIR_HEAD_REF:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_HEADLESS_OUTCOME_FILE=%s\n' "${AIDEVOPS_HEADLESS_OUTCOME_FILE:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_HEADLESS_OUTCOME_ID=%s\n' "${AIDEVOPS_HEADLESS_OUTCOME_ID:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_ATTEMPT_ID=%s\n' "${AIDEVOPS_ATTEMPT_ID:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_ATTEMPT_STATE_ROOT=%s\n' "${AIDEVOPS_ATTEMPT_STATE_ROOT:-}" >>"${HEADLESS_ENV_CAPTURE}"
printf 'AIDEVOPS_ATTEMPT_STATE_FILE=%s\n' "${AIDEVOPS_ATTEMPT_STATE_FILE:-}" >>"${HEADLESS_ENV_CAPTURE}"
if [[ -n "$prompt_file" && -f "$prompt_file" ]]; then
	cp "$prompt_file" "${HEADLESS_PROMPT_CAPTURE}"
fi
printf '%s\n' "${prompt_file}" >>"${HEADLESS_LOG}"
if [[ "${STUB_HEADLESS_MARK_COMPLETE:-false}" == "true" ]]; then
	"${PRRTS_SCANNER_UNDER_TEST}" mark-complete owner/repo "${WORKER_ISSUE_NUMBER}" immediate_worker_completion
fi
printf 'complete\n' >>"${HEADLESS_COMPLETE_LOG}"
exit 0
HEADLESS_STUB
	chmod +x "${TEST_ROOT}/headless-runtime-helper.sh"
	return 0
}

write_fake_detach_stubs() {
	cat >"${TEST_ROOT}/bin/setsid" <<'SETSID_STUB'
#!/usr/bin/env bash
printf 'setsid %s\n' "$*" >>"${DETACH_LAUNCH_LOG}"
exec "$@"
SETSID_STUB
	cat >"${TEST_ROOT}/bin/nohup" <<'NOHUP_STUB'
#!/usr/bin/env bash
printf 'nohup %s\n' "$*" >>"${DETACH_LAUNCH_LOG}"
exec "$@"
NOHUP_STUB
	chmod +x "${TEST_ROOT}/bin/setsid" "${TEST_ROOT}/bin/nohup"
	return 0
}

write_fake_ps_stub() {
	cat >"${TEST_ROOT}/bin/ps" <<'PS_STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" ]]; then
	if [[ "$*" == *"-o lstart="* && -n "${STUB_PS_LSTART_UNAVAILABLE:-}" ]]; then
		exit 1
	fi
	if [[ "$*" == *"-o command="* && -n "${STUB_ACTIVE_RESPONSE_WORKER:-}" ]]; then
		printf 'headless-runtime-helper run --session-key %s\n' "$STUB_ACTIVE_RESPONSE_WORKER"
		exit 0
	fi
	if [[ -x /bin/ps ]]; then
		exec /bin/ps "$@"
	fi
	exec /usr/bin/ps "$@"
fi
if [[ -n "${STUB_ACTIVE_RESPONSE_WORKER:-}" ]]; then
	printf 'headless-runtime-helper run --session-key %s\n' "$STUB_ACTIVE_RESPONSE_WORKER"
fi
exit 0
PS_STUB
	chmod +x "${TEST_ROOT}/bin/ps"
	return 0
}

write_fake_worktree_stub() {
	cat >"${TEST_ROOT}/worktree-helper.sh" <<'WORKTREE_STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${WORKTREE_HELPER_LOG}"
if [[ "${1:-}" == "remove" ]]; then
	path="${2:-}"
	rm -rf "$path"
	if [[ -f "${GIT_WORKTREE_REGISTRY}" ]]; then
		while IFS=$'\t' read -r registered_path branch oid; do
			[[ "$registered_path" == "$path" ]] || printf '%s\t%s\t%s\n' "$registered_path" "$branch" "$oid"
		done <"${GIT_WORKTREE_REGISTRY}" >"${GIT_WORKTREE_REGISTRY}.tmp"
		mv "${GIT_WORKTREE_REGISTRY}.tmp" "${GIT_WORKTREE_REGISTRY}"
	fi
	exit 0
fi
branch="${2:-}"
path="${3:-}"
if [[ "${1:-}" != "add" || -z "$branch" || -z "$path" || "${STUB_WORKTREE_HELPER_FAIL:-false}" == "true" ]]; then
	exit 1
fi
base=""
issue=""
shift 3
while [[ $# -gt 0 ]]; do
	if [[ "$1" == "--base" ]]; then
		base="${2:-}"
		shift 2
	elif [[ "$1" == "--issue" ]]; then
		issue="${2:-}"
		shift 2
	else
		shift
	fi
done
mkdir -p "$path"
printf '%s\t%s\t%s\n' "$path" "$branch" "${STUB_WORKTREE_ACTUAL_HEAD:-$base}" >>"${GIT_WORKTREE_REGISTRY}"
if [[ "${STUB_WORKTREE_REGISTER_OWNER:-false}" == "true" ]]; then
	source "${SHARED_CONSTANTS_PATH}"
	OPENCODE_SESSION_ID="" CLAUDE_SESSION_ID="" register_worktree "$path" "$branch" --task "$issue" \
		--session "${STUB_WORKTREE_OWNER_SESSION-worktree-helper-created}" \
		--owner-pid "${STUB_WORKTREE_OWNER_PID:-$$}"
	check_worktree_owner "$path" >"${WORKTREE_CREATED_OWNER_CAPTURE}"
fi
exit 0
WORKTREE_STUB
	chmod +x "${TEST_ROOT}/worktree-helper.sh"
	return 0
}

write_fake_dirty_backup_stub() {
	cat >"${TEST_ROOT}/dirty-worktree-backup-helper.sh" <<'DIRTY_BACKUP_STUB'
#!/usr/bin/env bash
command_name="${1:-}"
shift || true
printf '%s %s\n' "$command_name" "$*" >>"${DIRTY_BACKUP_LOG}"
case "$command_name" in
backup)
	[[ "${STUB_DIRTY_BACKUP_FAIL:-false}" == "true" ]] && exit 1
	owner_snapshot=$(bash -c 'source "$1"; check_worktree_owner "$2"' _ "${SHARED_CONSTANTS_PATH}" "${STUB_DIRTY_BACKUP_REPO}") || exit 1
	IFS='|' read -r owner_pid owner_session owner_batch owner_task owner_created_at owner_process_start <<EOF
${owner_snapshot}
EOF
	printf 'OWNER_PID=%s\nOWNER_SESSION=%s\nOWNER_TASK=%s\n' "$owner_pid" "$owner_session" "$owner_task" >>"${DIRTY_BACKUP_OWNER_LOG}"
	[[ "$owner_pid" =~ ^[0-9]+$ && "$owner_task" == "1" && "$owner_session" == "dispatch-precreate-1" && -n "$owner_created_at" ]] || exit 1
	printf 'test-dirty-backup|%s/backups/test-dirty-backup\n' "${TEST_ROOT}"
	;;
verify)
	[[ "${STUB_DIRTY_BACKUP_VERIFY_FAIL:-false}" == "true" ]] && exit 1
	printf 'VERIFIED_BACKUP_ID=test-dirty-backup\n'
	;;
matches)
	[[ "${STUB_DIRTY_BACKUP_MATCH_FAIL:-false}" == "true" ]] && exit 1
	printf 'BACKUP_MATCH=true\n'
	;;
clean)
	[[ "${STUB_DIRTY_BACKUP_CLEAN_FAIL:-false}" == "true" ]] && exit 1
	: >"${DIRTY_BACKUP_CLEANED}"
	printf 'CLEANED_BACKUP_ID=test-dirty-backup\n'
	;;
*) exit 1 ;;
esac
exit 0
DIRTY_BACKUP_STUB
	chmod +x "${TEST_ROOT}/dirty-worktree-backup-helper.sh"
	return 0
}

setup_test_env() {
	unset STUB_PR_LIST STUB_PR_VIEW STUB_THREADS_MODE STUB_HANG_SECONDS STUB_GRAPHQL_COST_MODE STUB_PR_REPOSITORY_MODE STUB_REMOTE_HEAD STUB_GH_LOGIN
	unset STUB_GH_REST_FAIL STUB_GH_GRAPHQL_FAIL STUB_GH_GRAPHQL_LOGIN
	unset STUB_PULL_HEAD_OID STUB_PULL_STATE STUB_PULL_DRAFT STUB_REVIEWS_RESPONSE STUB_REREVIEW_REQUEST_FAIL
	unset STUB_GIT_INVALID_BRANCH STUB_GIT_FETCH_FAIL STUB_GIT_CANONICAL_FETCH_FAIL
	unset STUB_REMOTE_HEAD_INITIAL STUB_REMOTE_HEAD_AFTER_FETCH STUB_WORKTREE_ACTUAL_HEAD STUB_WORKTREE_HELPER_FAIL
	unset STUB_GIT_WORKTREE_DIRTY STUB_GIT_DIVERGED STUB_GIT_FAST_FORWARD_FAIL
	unset STUB_DIRTY_BACKUP_FAIL STUB_DIRTY_BACKUP_VERIFY_FAIL STUB_DIRTY_BACKUP_MATCH_FAIL STUB_DIRTY_BACKUP_CLEAN_FAIL
	unset STUB_WORKTREE_REGISTER_OWNER STUB_WORKTREE_OWNER_PID STUB_WORKTREE_OWNER_SESSION
	unset STUB_ACTIVE_RESPONSE_WORKER
	unset STUB_HEADLESS_MARK_COMPLETE
	unset STUB_REVIEWER_COMMENTS_RESPONSE
	unset PR_REVIEW_THREAD_RESPONSE_ESCALATE_AFTER PR_REVIEW_THREAD_RESPONSE_INFRASTRUCTURE_FAILURE_COOLDOWN
	unset PR_REVIEW_THREAD_RESPONSE_MAX_GLOBAL PR_REVIEW_THREAD_RESPONSE_GLOBAL_LEASE_TTL
	unset PR_REVIEW_THREAD_RESPONSE_MAX_THREADS_PER_DISPATCH
	TEST_ROOT="$(mktemp -d -t prrts.XXXXXX)"
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/scanner.log"
	export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="${TEST_ROOT}/state"
	export HEADLESS_LOG="${TEST_ROOT}/headless.log"
	export HEADLESS_COMPLETE_LOG="${TEST_ROOT}/headless-complete.log"
	export HEADLESS_ARGS_CAPTURE="${TEST_ROOT}/headless-args.txt"
	export HEADLESS_ENV_CAPTURE="${TEST_ROOT}/headless-env.txt"
	export HEADLESS_PROMPT_CAPTURE="${TEST_ROOT}/prompt.md"
	export DETACH_LAUNCH_LOG="${TEST_ROOT}/detach-launch.log"
	export WORKTREE_HELPER_LOG="${TEST_ROOT}/worktree-helper.log"
	export WORKTREE_CREATED_OWNER_CAPTURE="${TEST_ROOT}/worktree-created-owner.txt"
	export DIRTY_BACKUP_LOG="${TEST_ROOT}/dirty-backup.log"
	export DIRTY_BACKUP_OWNER_LOG="${TEST_ROOT}/dirty-backup-owner.log"
	export DIRTY_BACKUP_CLEANED="${TEST_ROOT}/dirty-backup-cleaned"
	export GIT_WORKTREE_REGISTRY="${TEST_ROOT}/git-worktrees.tsv"
	export GIT_FETCH_CWD_LOG="${TEST_ROOT}/git-fetch-cwd.log"
	export GIT_FETCHED_HEAD_STATE="${TEST_ROOT}/git-fetched-head.state"
	export GIT_CANONICAL_REPO_PATH="${TEST_ROOT}/repo"
	export WORKTREE_REGISTRY_DIR="${TEST_ROOT}/ownership-registry"
	export WORKTREE_REGISTRY_DB="${WORKTREE_REGISTRY_DIR}/worktree-registry.db"
	export SHARED_CONSTANTS_PATH="${TEST_SCRIPT_DIR}/../shared-constants.sh"
	mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}"
	mkdir -p "${TEST_ROOT}/fetch-worktree"
	printf '%s\t%s\t%s\n' "${TEST_ROOT}/fetch-worktree" 'support/fetch' "$TEST_HEAD_OID_1" >"$GIT_WORKTREE_REGISTRY"
	write_fake_gh_stub
	write_fake_git_stub
	write_fake_ps_stub
	write_fake_headless_stub
	write_fake_detach_stubs
	write_fake_worktree_stub
	write_fake_dirty_backup_stub
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HEADLESS_RUNTIME_HELPER="${TEST_ROOT}/headless-runtime-helper.sh"
	export PR_REVIEW_THREAD_RESPONSE_WORKTREE_HELPER="${TEST_ROOT}/worktree-helper.sh"
	export PR_REVIEW_THREAD_RESPONSE_DIRTY_BACKUP_HELPER="${TEST_ROOT}/dirty-worktree-backup-helper.sh"
	export PR_REVIEW_THREAD_RESPONSE_WORKTREE_BASE_DIR="${TEST_ROOT}/worktrees"
	export GRAPHQL_MUTATIONS_LOG="${TEST_ROOT}/graphql-mutations.log"
	export GRAPHQL_BODY_CAPTURE="${TEST_ROOT}/graphql-body.txt"
	export GRAPHQL_BODY_FLAG_CAPTURE="${TEST_ROOT}/graphql-body-flag.txt"
	export PR_EDIT_LOG="${TEST_ROOT}/pr-edit.log"
	export PR_REVIEW_THREAD_RESPONSE_COOLDOWN=3600
	export PR_REVIEW_THREAD_RESPONSE_INFRASTRUCTURE_FAILURE_COOLDOWN=90
	export PRRTS_SCANNER_UNDER_TEST="$SCANNER"
	: >"$GRAPHQL_MUTATIONS_LOG"
	: >"$GRAPHQL_BODY_CAPTURE"
	: >"$GRAPHQL_BODY_FLAG_CAPTURE"
	: >"$PR_EDIT_LOG"
	: >"$HEADLESS_LOG"
	: >"$HEADLESS_COMPLETE_LOG"
	: >"$DETACH_LAUNCH_LOG"
	: >"$GIT_FETCH_CWD_LOG"
	: >"$DIRTY_BACKUP_LOG"
	: >"$DIRTY_BACKUP_OWNER_LOG"
	rm -f "$GIT_FETCHED_HEAD_STATE"
	rm -f "$DIRTY_BACKUP_CLEANED"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

write_active_global_capacity_lease() {
	local lease_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/global-capacity-leases"
	mkdir -p "$lease_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'session_key=pr-review-thread-response-other-repo-99\n'
	} >"${lease_dir}/other-repo-99.lease"
	return 0
}

write_expired_global_capacity_lease() {
	local session_key="$1"
	local lease_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/global-capacity-leases"
	mkdir -p "$lease_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'created_at=%s\n' "$(($(date +%s) - 120))"
		printf 'session_key=%s\n' "$session_key"
	} >"${lease_dir}/other-repo-99.lease"
	return 0
}

wait_for_headless_log() {
	local attempts=0
	while [[ "$attempts" -lt 10 ]]; do
		if [[ -s "$HEADLESS_LOG" ]]; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

wait_for_state_marker() {
	local state_file="$1"
	local marker="$2"
	local attempts=0
	while [[ "$attempts" -lt 10 ]]; do
		if grep -q "$marker" "$state_file" 2>/dev/null; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

wait_for_headless_completion() {
	local attempts=0
	while [[ "$attempts" -lt 10 ]]; do
		if [[ -s "$HEADLESS_COMPLETE_LOG" ]]; then
			return 0
		fi
		sleep 1
		attempts=$((attempts + 1))
	done
	return 1
}

expire_state_dispatch_time() {
	local state_file="$1"
	local dispatched_at="$2"
	local tmp_file="${state_file}.tmp"
	[[ -f "$state_file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		dispatched_at=*) printf 'dispatched_at=%s\n' "$dispatched_at" ;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$state_file" >"$tmp_file"
	mv "$tmp_file" "$state_file"
	return 0
}

write_worker_outcome() {
	local outcome_file="$1"
	local reason="$2"
	local session_count="$3"
	local finished_at="$4"
	local outcome_id="$5"
	local retry_class="${6:-}"
	{
		printf 'session_key=pr-review-thread-response-owner-repo-1\n'
		printf 'outcome_id=%s\n' "$outcome_id"
		printf 'reason=%s\n' "$reason"
		printf 'session_count=%s\n' "$session_count"
		[[ -n "$retry_class" ]] && printf 'retry_class=%s\n' "$retry_class"
		printf 'finished_at=%s\n' "$finished_at"
	} >"$outcome_file"
	return 0
}

process_start_for_pid() {
	local pid="$1"
	local process_start=""
	if [[ -x /bin/ps ]]; then
		process_start=$(LC_ALL=C /bin/ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || process_start=""
	else
		process_start=$(LC_ALL=C /usr/bin/ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || process_start=""
	fi
	process_start="${process_start#"${process_start%%[![:space:]]*}"}"
	process_start="${process_start%"${process_start##*[![:space:]]}"}"
	printf '%s\n' "$process_start"
	return 0
}

read_state_value() {
	local state_file="$1"
	local wanted_key="$2"
	local key="" value=""
	while IFS='=' read -r key value; do
		if [[ "$key" == "$wanted_key" ]]; then
			printf '%s\n' "$value"
			return 0
		fi
	done <"$state_file"
	return 1
}

write_rereview_dispatch_state() {
	local state_file="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR}/owner-repo-1.state"
	{
		printf 'fingerprint=THREAD1:https://example.invalid/thread\n'
		printf 'dispatched_at=%s\n' "$(date +%s)"
		printf 'thread_count=1\n'
		printf 'attempt_count=1\n'
		printf 'last_head_sha=%s\n' "$TEST_HEAD_OID_1"
	} >"$state_file"
	return 0
}

set_trusted_change_request_review() {
	export STUB_REVIEWS_RESPONSE='[[{"id":11,"submitted_at":"2026-08-28T01:00:00Z","state":"CHANGES_REQUESTED","commit_id":"'"$TEST_HEAD_OID_1"'","author_association":"MEMBER","user":{"login":"trusted-reviewer","type":"User"}}]]'
	return 0
}
