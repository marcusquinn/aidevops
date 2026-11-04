#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Audit and optionally delete stale remote branches for the current repository.

set -euo pipefail

# Explicit --repo selection must win over inherited repository context, including
# during transport creation and read-only queries before transport Git calls.
# Object-store overrides are cleared too: an inherited object directory or
# alternate would let fetch store objects outside --repo while its refs move.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
	GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worktree-paths.sh
source "${SCRIPT_DIR}/worktree-paths.sh"

REPO_PATH="${PWD}"
REMOTE_NAME="origin"
APPLY=0
INCLUDE_CLOSED_PR=0
SKIP_FETCH=0
FETCH_STATE="pending"
DELETE_TRANSPORT_WORKTREE=""
DELETE_FAILURES=0
PR_MATCH=""
PR_MATCH_NUMBER=""
CLASSIFY_SAFE=""
CLASSIFY_REVIEW=""

usage() {
	cat <<'EOF'
Usage: remote-branch-cleanup-helper.sh [scan] [options]

Audits stale remote branches and optionally deletes only branches proven safe.
Default mode is dry-run. Merged/closed PR evidence counts only when the branch
tip equals, or is an ancestor of, a same-repository PR head SHA.

Options:
  --repo PATH           Repository path (default: current directory)
  --remote NAME         Remote to audit (default: origin)
  --apply, --delete     Delete safe candidates (default: dry-run)
  --include-closed-pr   Treat closed-without-merge PR branches as safe candidates
  --skip-fetch          Do not fetch/prune before scanning (tests/offline only)
  -h, --help            Show this help

Fetch/prune runs through an isolated linked worktree because canonical
checkouts refuse `git fetch`. --apply refuses to run when that fetch fails.

Examples:
  aidevops cleanup remote-branches
  aidevops cleanup remote-branches --apply
  aidevops cleanup branches --repo ~/Git/aidevops --remote origin
EOF
	return 0
}

parse_args() {
	local arg=""
	while [[ $# -gt 0 ]]; do
		arg="${1:-}"
		case "$arg" in
		scan | remote-branches | branches)
			shift
			;;
		--repo)
			REPO_PATH="${2:-}"
			shift 2
			;;
		--remote)
			REMOTE_NAME="${2:-}"
			shift 2
			;;
		--apply | --delete)
			APPLY=1
			shift
			;;
		--include-closed-pr)
			INCLUDE_CLOSED_PR=1
			shift
			;;
		--skip-fetch)
			SKIP_FETCH=1
			shift
			;;
		-h | --help | help)
			usage
			exit 0
			;;
		*)
			print_error "Unknown argument: $arg"
			usage
			exit 1
			;;
		esac
	done
	return 0
}

repo_git() {
	git -C "$REPO_PATH" "$@"
	return $?
}

default_branch() {
	local branch=""
	branch=$(repo_git symbolic-ref --quiet --short "refs/remotes/${REMOTE_NAME}/HEAD" 2>/dev/null | sed "s|^${REMOTE_NAME}/||") || branch=""
	if [[ -z "$branch" ]]; then
		branch=$(repo_git remote show "$REMOTE_NAME" 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p' | sed -n '1p') || branch=""
	fi
	[[ -z "$branch" ]] && branch="main"
	printf '%s\n' "$branch"
	return 0
}

remote_branches() {
	# Use the full refname: `%(refname:short)` abbreviates the remote HEAD
	# symref to the bare remote name ("origin"), which then leaked into the
	# audit as a phantom branch (GH#36601).
	local prefix="refs/remotes/${REMOTE_NAME}/"
	repo_git for-each-ref --format='%(refname)' "refs/remotes/${REMOTE_NAME}" |
		while IFS= read -r ref; do
			[[ "$ref" == "$prefix"* ]] || continue
			ref="${ref#"$prefix"}"
			[[ -z "$ref" || "$ref" == "HEAD" ]] && continue
			printf '%s\n' "$ref"
		done
	return 0
}

active_worktree_branches() {
	repo_git worktree list --porcelain 2>/dev/null |
		sed -n 's|^branch refs/heads/||p'
	return 0
}

gh_pr_branches() {
	local state="$1"
	if [[ "${AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH:-0}" == "1" ]]; then
		return 0
	fi
	if ! command -v gh >/dev/null 2>&1; then
		return 0
	fi

	local slug=""
	local api_state=""
	local jq_filter=""
	local page=1
	local page_count=0
	local page_json=""
	slug=$(repo_slug)
	[[ -n "$slug" ]] || return 0
	# Open PRs only protect branches, so a name match (including a fork head
	# with the same ref) stays conservative. Merged/closed evidence authorizes
	# deletion, so it is restricted to same-repository heads and carries the
	# head SHA and PR number for tip binding (GH#36601).
	# shellcheck disable=SC2016 # $slug is a jq variable bound with --arg below.
	local same_repo_rows='select(((.head.repo.full_name // "") | ascii_downcase) == ($slug | ascii_downcase)) | [.head.ref, (.head.sha // ""), (.number | tostring)] | @tsv'
	case "$state" in
	open)
		api_state="open"
		jq_filter='.[].head.ref'
		;;
	merged)
		api_state="closed"
		jq_filter=".[] | select(.merged_at != null) | ${same_repo_rows}"
		;;
	closed)
		api_state="closed"
		jq_filter=".[] | select(.merged_at == null) | ${same_repo_rows}"
		;;
	*) return 0 ;;
	esac

	# Preserve the previous 200-PR bound. Unbounded REST pagination can turn a
	# cleanup pass over a mature repository into a full-history API sweep.
	while [[ "$page" -le 2 ]]; do
		page_json=$(AIDEVOPS_GH_ROUTE_DECISION="remote-branch-cleanup-pr-branches-rest" \
			gh api "repos/${slug}/pulls?state=${api_state}&per_page=100&page=${page}" \
			2>/dev/null) || return 0
		page_count=$(printf '%s' "$page_json" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null) || return 0
		[[ "$page_count" =~ ^[0-9]+$ ]] || return 0
		printf '%s' "$page_json" | jq -r --arg slug "$slug" "$jq_filter" 2>/dev/null || return 0
		[[ "$page_count" -lt 100 ]] && break
		page=$((page + 1))
	done
	return 0
}

repo_slug() {
	local url slug
	url=$(repo_git remote get-url "$REMOTE_NAME" 2>/dev/null || true)
	slug="$url"
	slug="${slug#git@github.com:}"
	slug="${slug#https://github.com/}"
	slug="${slug%.git}"
	printf '%s\n' "$slug"
	return 0
}

contains_line() {
	local needle="$1"
	local haystack="$2"
	[[ $'\n'"$haystack"$'\n' == *$'\n'"$needle"$'\n'* ]]
	return $?
}

# Bind PR evidence to the audited tip (GH#36601), matching the
# local-branch-cleanup-helper.sh closed_pr_lookup rule: the tip must equal a
# same-repository PR head SHA or be an ancestor of one. A branch name alone is
# not evidence, because squash-merged heads never reach the default branch and
# commits pushed after the merge would otherwise be deleted with it.
# rows: "<head.ref>\t<head.sha>\t<number>" lines from gh_pr_branches.
# Sets PR_MATCH to sha|ancestor|differs (empty: no same-name PR evidence) and
# PR_MATCH_NUMBER.
pr_head_evidence() {
	local branch="$1"
	local tip="$2"
	local rows="$3"
	local ref=""
	local head_sha=""
	local number=""
	PR_MATCH=""
	PR_MATCH_NUMBER=""
	[[ -n "$tip" && -n "$rows" ]] || return 0
	while IFS=$'\t' read -r ref head_sha number; do
		[[ "$ref" == "$branch" ]] || continue
		[[ "$head_sha" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || continue
		if [[ "$head_sha" == "$tip" ]]; then
			PR_MATCH="sha"
			PR_MATCH_NUMBER="$number"
			return 0
		fi
		if [[ "$PR_MATCH" != "ancestor" ]] &&
			repo_git cat-file -e "${head_sha}^{commit}" 2>/dev/null &&
			repo_git merge-base --is-ancestor "$tip" "$head_sha" 2>/dev/null; then
			PR_MATCH="ancestor"
			PR_MATCH_NUMBER="$number"
		elif [[ -z "$PR_MATCH" ]]; then
			PR_MATCH="differs"
			PR_MATCH_NUMBER="$number"
		fi
	done <<<"$rows"
	return 0
}

is_protected_branch() {
	local branch="$1"
	local default="$2"
	case "$branch" in
	"$default" | main | master | develop | development | staging | production | release | gh-pages)
		return 0
		;;
	esac
	return 1
}

print_candidate() {
	local action="$1"
	local branch="$2"
	local reason="$3"
	printf '%-10s %-55s %s\n' "$action" "$branch" "$reason"
	return 0
}

cleanup_delete_transport() {
	local worktree="$DELETE_TRANSPORT_WORKTREE"
	[[ -n "$worktree" ]] || return 0
	if ! (
		# shellcheck source=audit-worktree-removal-helper.sh
		source "${BASH_SOURCE[0]%/*}/audit-worktree-removal-helper.sh" || exit 1
		worktree_managed_require_removal_proof "$worktree"
	); then
		print_warning "Transport retained pending managed completion proof: $worktree"
		return 0
	fi
	if repo_git worktree remove --force "$worktree" >/dev/null 2>&1; then
		DELETE_TRANSPORT_WORKTREE=""
		return 0
	fi
	print_warning "Unable to remove remote-branch cleanup transport worktree: $worktree"
	return 1
}

prepare_delete_transport() {
	local worktree=""
	[[ -z "$DELETE_TRANSPORT_WORKTREE" ]] || return 0
	worktree=$(aidevops_generate_worktree_path "$REPO_PATH" "remote-branch-cleanup-$$") || {
		print_error "Unable to resolve the remote-branch cleanup transport path"
		return 1
	}
	if [[ -e "$worktree" || -L "$worktree" ]]; then
		print_error "Remote-branch cleanup transport path already exists: $worktree"
		return 1
	fi
	DELETE_TRANSPORT_WORKTREE="$worktree"
	if ! (
		# shellcheck source=shared-worktree-create.sh
		source "${BASH_SOURCE[0]%/*}/shared-worktree-create.sh" || exit 1
		# Synchronous, process-scoped transport: choose the legacy backend before
		# creation so this process can retire it on exit instead of leaving an
		# owner-cgroup record that only a later exit could seal (GH#35490).
		# No checkout: the transport only fetches, reads and pushes refs, and it
		# is now created on every scan, including dry runs (GH#36601).
		AIDEVOPS_WORKTREE_MANAGER=legacy-guards \
			worktree_create_registered "$REPO_PATH" "$worktree" HEAD --detach --no-checkout
	) >/dev/null; then
		DELETE_TRANSPORT_WORKTREE=""
		print_error "Unable to create an isolated linked worktree for remote-ref transport"
		return 1
	fi
	return 0
}

delete_transport_git() {
	local worktree="$DELETE_TRANSPORT_WORKTREE"
	[[ -n "$worktree" ]] || return 1
	git -C "$worktree" "$@"
	return $?
}

# The canonical Git guard refuses `git fetch` in canonical checkouts, so a
# direct fetch always failed there and the audit ran on stale tracking refs.
# A linked worktree shares the remote-tracking refs and may update them.
# The explicit all-heads refspec keeps a single-branch clone's narrow configured
# refspec from refreshing one ref while the audit reports every ref fresh;
# --prune with it still preserves the refs/remotes/<remote>/HEAD symref.
fetch_remote_refs() {
	prepare_delete_transport || return 1
	local error_output=""
	if ! error_output=$(delete_transport_git fetch --prune --quiet "$REMOTE_NAME" \
		"+refs/heads/*:refs/remotes/${REMOTE_NAME}/*" 2>&1 >/dev/null); then
		# Report the cause (bounded, credential-scrubbed); the stale/refuse
		# logic keys off the return code only.
		error_output=$(sed -n '1,3p' <<<"$error_output")
		if [[ -n "$error_output" ]]; then
			print_warning "fetch failed: $(scrub_credentials "$error_output")"
		fi
		return 1
	fi
	return 0
}

record_delete_failure() {
	local branch="$1"
	local reason="$2"
	DELETE_FAILURES=$((DELETE_FAILURES + 1))
	print_candidate "failed" "$branch" "$reason"
	return 0
}

delete_branch() {
	local branch="$1"
	# The lease SHA is the exact tip the classification evidence was bound to,
	# not a re-read that a concurrent fetch could have advanced (GH#36601).
	local expected_sha="${2:-}"
	local remote_output=""
	local remote_sha=""
	local verify_rc=0

	if ! repo_git check-ref-format --branch "$branch" >/dev/null 2>&1; then
		record_delete_failure "$branch" "invalid branch ref"
		return 0
	fi
	if [[ -z "$expected_sha" ]]; then
		record_delete_failure "$branch" "unable to resolve audited remote-tracking ref"
		return 0
	fi
	if ! prepare_delete_transport; then
		record_delete_failure "$branch" "isolated deletion transport unavailable"
		return 0
	fi
	if ! remote_output=$(delete_transport_git ls-remote --heads "$REMOTE_NAME" "refs/heads/${branch}" 2>/dev/null); then
		record_delete_failure "$branch" "unable to verify remote ref before deletion"
		return 0
	fi
	if [[ -z "$remote_output" ]]; then
		print_candidate "deleted" "$branch" "remote absence verified"
		return 0
	fi
	remote_sha="${remote_output%%[[:space:]]*}"
	if [[ "$remote_sha" != "$expected_sha" ]]; then
		record_delete_failure "$branch" "remote ref changed after safety scan"
		return 0
	fi
	if ! delete_transport_git push \
		"--force-with-lease=refs/heads/${branch}:${expected_sha}" \
		"$REMOTE_NAME" ":refs/heads/${branch}" >/dev/null 2>&1; then
		record_delete_failure "$branch" "lease-bound remote deletion failed"
		return 0
	fi
	if remote_output=$(delete_transport_git ls-remote --exit-code --heads "$REMOTE_NAME" "refs/heads/${branch}" 2>/dev/null); then
		verify_rc=0
	else
		verify_rc=$?
	fi
	case "$verify_rc" in
	2)
		print_candidate "deleted" "$branch" "remote absence verified"
		;;
	0)
		record_delete_failure "$branch" "remote ref still present after deletion"
		;;
	*)
		record_delete_failure "$branch" "remote absence verification failed"
		;;
	esac
	return 0
}

print_sync() {
	local action="$1"
	local branch="$2"
	local reason="$3"
	printf '%-10s %-55s %s\n' "$action" "$branch" "$reason"
	return 0
}

sync_default_branch_after_cleanup() {
	local default="$1"
	local current upstream expected local_sha remote_sha merge_base

	printf '\nDefault branch sync check:\n'
	current=$(repo_git symbolic-ref --quiet --short HEAD 2>/dev/null) || current=""
	if [[ -z "$current" ]]; then
		print_sync "skip-sync" "$default" "detached HEAD"
		return 0
	fi
	if [[ "$current" != "$default" ]]; then
		print_sync "skip-sync" "$current" "not default branch (${default})"
		return 0
	fi

	upstream=$(repo_git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || upstream=""
	expected="${REMOTE_NAME}/${default}"
	if [[ -z "$upstream" ]]; then
		print_sync "skip-sync" "$current" "no upstream configured"
		return 0
	fi
	if [[ "$upstream" != "$expected" ]]; then
		print_sync "skip-sync" "$current" "upstream is ${upstream}, expected ${expected}"
		return 0
	fi
	if ! repo_git diff --quiet || ! repo_git diff --cached --quiet; then
		print_sync "skip-sync" "$current" "worktree or index is dirty"
		return 0
	fi

	local_sha=$(repo_git rev-parse HEAD 2>/dev/null) || local_sha=""
	remote_sha=$(repo_git rev-parse "$upstream" 2>/dev/null) || remote_sha=""
	if [[ -z "$local_sha" || -z "$remote_sha" ]]; then
		print_sync "skip-sync" "$current" "unable to resolve local or upstream SHA"
		return 0
	fi
	if [[ "$local_sha" == "$remote_sha" ]]; then
		print_sync "up-to-date" "$current" "matches ${upstream}"
		return 0
	fi
	merge_base=$(repo_git merge-base HEAD "$upstream" 2>/dev/null) || merge_base=""
	if [[ -z "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "no merge-base with ${upstream}"
		return 0
	fi
	if [[ "$remote_sha" == "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "local branch is ahead of ${upstream}"
		return 0
	fi
	if [[ "$local_sha" != "$merge_base" ]]; then
		print_sync "skip-sync" "$current" "local branch has diverged from ${upstream}"
		return 0
	fi

	if [[ "$APPLY" != "1" ]]; then
		print_sync "would-ff" "$current" "behind ${upstream}; dry-run only"
		return 0
	fi
	if repo_git merge --ff-only "$upstream" >/dev/null 2>&1; then
		remote_sha=$(repo_git rev-parse --short HEAD 2>/dev/null) || remote_sha="unknown"
		print_sync "fast-fwd" "$current" "updated to ${remote_sha} from ${upstream}"
	else
		print_sync "failed" "$current" "git merge --ff-only ${upstream} failed"
	fi
	return 0
}

# Classify one remote branch from SHA-bound evidence only. Sets CLASSIFY_SAFE
# to the deletion reason, or leaves it empty with CLASSIFY_REVIEW explaining
# why the branch needs manual review.
classify_branch() {
	local branch="$1"
	local tip="$2"
	local default="$3"
	local default_tip="$4"
	local merged_prs="$5"
	local closed_prs="$6"
	CLASSIFY_SAFE=""
	CLASSIFY_REVIEW="unmerged/no closed evidence"
	if [[ -z "$tip" ]]; then
		CLASSIFY_REVIEW="unable to resolve remote-tracking ref"
		return 0
	fi
	if [[ -n "$default_tip" ]] && repo_git merge-base --is-ancestor "$tip" "$default_tip" 2>/dev/null; then
		CLASSIFY_SAFE="merged to ${default}"
		return 0
	fi
	pr_head_evidence "$branch" "$tip" "$merged_prs"
	case "$PR_MATCH" in
	sha)
		CLASSIFY_SAFE="merged PR #${PR_MATCH_NUMBER} head SHA"
		return 0
		;;
	ancestor)
		CLASSIFY_SAFE="merged PR #${PR_MATCH_NUMBER} head ancestor"
		return 0
		;;
	differs) CLASSIFY_REVIEW="tip differs from merged PR #${PR_MATCH_NUMBER} head" ;;
	esac
	[[ -n "$closed_prs" ]] || return 0
	pr_head_evidence "$branch" "$tip" "$closed_prs"
	case "$PR_MATCH" in
	sha) CLASSIFY_SAFE="closed PR #${PR_MATCH_NUMBER} head SHA (--include-closed-pr)" ;;
	ancestor) CLASSIFY_SAFE="closed PR #${PR_MATCH_NUMBER} head ancestor (--include-closed-pr)" ;;
	differs)
		if [[ "$CLASSIFY_REVIEW" == "unmerged/no closed evidence" ]]; then
			CLASSIFY_REVIEW="tip differs from closed PR #${PR_MATCH_NUMBER} head"
		fi
		;;
	esac
	return 0
}

scan_branches() {
	if [[ ! -d "$REPO_PATH/.git" && ! -f "$REPO_PATH/.git" ]]; then
		print_error "Not a git worktree: $REPO_PATH"
		return 1
	fi

	if [[ "$SKIP_FETCH" == "1" ]]; then
		FETCH_STATE="unfetched"
	elif fetch_remote_refs; then
		FETCH_STATE="fresh"
	else
		FETCH_STATE="stale"
		if [[ "$APPLY" == "1" ]]; then
			print_error "Fetch/prune failed; refusing --apply against stale remote-tracking refs"
			return 1
		fi
		print_warning "Fetch/prune failed; dry-run audit uses stale remote-tracking refs"
	fi

	local default default_tip active open_prs merged_prs closed_prs branch tip safe_count skip_count review_count mode skip_action dash_label
	default=$(default_branch)
	default_tip=$(repo_git rev-parse --verify "refs/remotes/${REMOTE_NAME}/${default}" 2>/dev/null) || default_tip=""
	active=$(active_worktree_branches)
	open_prs=$(gh_pr_branches open)
	merged_prs=$(gh_pr_branches merged)
	closed_prs=""
	if [[ "$INCLUDE_CLOSED_PR" == "1" ]]; then
		closed_prs=$(gh_pr_branches closed)
	fi
	safe_count=0
	skip_count=0
	review_count=0
	mode="dry-run"
	skip_action="skip"
	dash_label="------"
	[[ "$APPLY" == "1" ]] && mode="apply"

	printf 'Remote branch cleanup audit: repo=%s remote=%s default=%s mode=%s refs=%s\n' "$REPO_PATH" "$REMOTE_NAME" "$default" "$mode" "$FETCH_STATE"
	printf '%-10s %-55s %s\n' "action" "branch" "reason"
	printf '%-10s %-55s %s\n' "$dash_label" "$dash_label" "$dash_label"

	while IFS= read -r branch; do
		[[ -z "$branch" ]] && continue
		if is_protected_branch "$branch" "$default"; then
			print_candidate "$skip_action" "$branch" "protected/default branch"
			skip_count=$((skip_count + 1))
			continue
		fi
		if contains_line "$branch" "$active"; then
			print_candidate "$skip_action" "$branch" "checked out in a local worktree"
			skip_count=$((skip_count + 1))
			continue
		fi
		if contains_line "$branch" "$open_prs"; then
			print_candidate "$skip_action" "$branch" "open PR exists"
			skip_count=$((skip_count + 1))
			continue
		fi
		tip=$(repo_git rev-parse --verify "refs/remotes/${REMOTE_NAME}/${branch}" 2>/dev/null) || tip=""
		classify_branch "$branch" "$tip" "$default" "$default_tip" "$merged_prs" "$closed_prs"

		if [[ -n "$CLASSIFY_SAFE" ]]; then
			safe_count=$((safe_count + 1))
			if [[ "$APPLY" == "1" ]]; then
				delete_branch "$branch" "$tip"
			else
				print_candidate "would-del" "$branch" "$CLASSIFY_SAFE"
			fi
		else
			review_count=$((review_count + 1))
			print_candidate "review" "$branch" "$CLASSIFY_REVIEW"
		fi
	done < <(remote_branches)

	printf '\nSummary: safe=%s skipped=%s review=%s\n' "$safe_count" "$skip_count" "$review_count"
	if [[ "$APPLY" != "1" ]]; then
		printf 'Dry-run only. Re-run with --apply to delete safe candidates.\n'
	fi
	sync_default_branch_after_cleanup "$default"
	[[ "$DELETE_FAILURES" -eq 0 ]] || return 1
	return 0
}

main() {
	local scan_rc=0
	local cleanup_rc=0
	parse_args "$@"
	trap 'cleanup_delete_transport >/dev/null 2>&1 || true' EXIT
	scan_branches || scan_rc=$?
	cleanup_delete_transport || cleanup_rc=$?
	trap - EXIT
	[[ "$scan_rc" -eq 0 ]] || return "$scan_rc"
	[[ "$cleanup_rc" -eq 0 ]] || return "$cleanup_rc"
	return 0
}

main "$@"
