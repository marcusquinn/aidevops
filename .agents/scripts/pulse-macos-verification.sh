#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Trusted native verification runs independently of the pulse dispatch budget.

_PULSE_MACOS_DIR="${BASH_SOURCE[0]%/*}"

_preflight_start_macos_verification() {
	# No auth, configuration or GitHub reads on other platforms.
	[[ "$(uname -s)" == Darwin ]] || return 0
	local helper="${_PULSE_MACOS_DIR}/pulse-macos-verification.sh"
	local log_file="${HOME}/.aidevops/logs/pulse-macos-verification.log"
	mkdir -p "${log_file%/*}" || return 1
	_preflight_launch_async_cleanup "$helper" "$log_file" macos-verification run
	return 0
}

_pulse_macos_failure_comment() {
	local repo="$1" pr="$2" head="$3" attempt="$4"
	local marker="<!-- aidevops:macos-verification:${head} -->" comments="" body=""
	comments=$(gh api --paginate "repos/$repo/issues/$pr/comments?per_page=100" --jq '.[].body') || return 1
	[[ "$comments" != *"$marker"* ]] || return 0
	body="$attempt/comment.md"
	{
		printf '%s\n\nNative macOS verification failed at %s; needs-macos-verification is retained.\n' "$marker" "$head"
		printf 'The final suite diagnostic and last 40 output lines follow (exit/timeout details included).\n\n```text\n'
		# Bound public output; remove terminal controls and home-directory spellings.
		tail -n 40 "$attempt/output.log" | python3 -c '
import os, re, sys
text = sys.stdin.read().replace(os.environ["HOME"], "~").replace("`", "\x27")
sys.stdout.write(re.sub(r"[^\x20-\x7e\n\t]", "", text))'
		printf '\n```\n'
	} >"$body"
	bash "$_PULSE_MACOS_DIR/gh-write-helper.sh" pr comment "$pr" --repo "$repo" --body-file "$body" || return 1
	return 0
}

_pulse_macos_cleanup() {
	local rc="$?"
	if [[ -n "${SCRATCH_WORKTREE_PATH:-}" ]]; then
		scratch_worktree_remove "$SCRATCH_WORKTREE_PATH" pulse-macos-verification.sh || true
	fi
	if [[ -n "${_pulse_macos_attempt:-}" && ! -f "$_pulse_macos_attempt/outcome" ]]; then
		printf 'Native verification interrupted (exit %s); suite did not complete.\n' "$rc" >>"$_pulse_macos_attempt/output.log"
		printf 'failed\n' >"$_pulse_macos_attempt/outcome"
	fi
	return 0
}

_pulse_macos_verify() {
	local repo="$1" path="$2" pr="$3" head="$4" base="$5" attempt="$6"
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-$HOME/Git/_worktrees}" rc=0
	# Bind controlled creation to this bounded verifier, not an inherited pulse
	# owner. This selects the sanctioned registry creation path on canonical repos.
	local AIDEVOPS_LIFECYCLE_RUNTIME_PID="$$"
	local AIDEVOPS_LIFECYCLE_SESSION_ID="pulse-macos:$repo:$pr:$head:$$"
	local AIDEVOPS_WORKTREE_CREATE_TASK="Native macOS verification $repo#$pr at $head"
	# The scratch helper owns creation provenance, locking and non-force removal.
	# shellcheck source=scratch-worktree-helper.sh
	source "$_PULSE_MACOS_DIR/scratch-worktree-helper.sh" || return 1
	_pulse_macos_attempt="$attempt"
	trap _pulse_macos_cleanup EXIT
	trap 'exit 124' TERM INT HUP
	{
		# Never trust origin to identify this repository, nor a mutable head branch.
		scratch_worktree_fetch "$path" "$worktree_base" "macos-verify-fetch-$pr" \
			"pulse-macos-verification.sh" --no-tags --no-write-fetch-head \
			"https://github.com/$repo.git" "refs/pull/$pr/head" "$base" &&
			git -C "$path" cat-file -e "$head^{commit}" &&
			scratch_worktree_add "$path" "$worktree_base" "macos-verify-$pr" "$head" &&
			(
				cd "$SCRATCH_WORKTREE_PATH" || exit 1
				[[ "$(git rev-parse HEAD)" == "$head" ]] || exit 1
				bash .agents/scripts/macos-local-checks.sh verify-pr "$pr" "$repo"
			)
	} >"$attempt/output.log" 2>&1 || rc=$?
	if [[ "$rc" == 0 ]]; then
		printf 'success\n' >"$attempt/outcome"
	else
		printf 'Native verification failed (exit %s); see the last suite diagnostic above.\n' "$rc" >>"$attempt/output.log"
		printf 'failed\n' >"$attempt/outcome"
		_pulse_macos_failure_comment "$repo" "$pr" "$head" "$attempt" || true
	fi
	return 0
}

_pulse_macos_checks_pass() {
	local repo="$1" pr="$2" head="$3" checks="" branch="" rules=""
	# Query the immutable commit, not the PR's mutable current-head check list.
	# isRequired uses this PR's branch protection/ruleset context. Incomplete or
	# unknown rollups fail closed, including a truncated (>100 contexts) response.
	# shellcheck disable=SC2016 # GraphQL variables are bound by gh, not Bash.
	checks=$(gh api graphql -f owner="${repo%/*}" -f name="${repo#*/}" -F pr="$pr" -f head="$head" -f query='
		query($owner:String!, $name:String!, $pr:Int!, $head:GitObjectID!) {
		  repository(owner:$owner, name:$name) {
		    pullRequest(number:$pr) { headRefOid baseRefName baseRef { branchProtectionRule {
		      requiresStatusChecks requiredStatusChecks { context app { databaseId } }
		    } } }
		    object(oid:$head) { ... on Commit {
		    oid statusCheckRollup { contexts(first:100) {
		      nodes { __typename
		        ... on CheckRun { name isRequired(pullRequestNumber:$pr) status conclusion checkSuite { app { databaseId } } }
		        ... on StatusContext { context isRequired(pullRequestNumber:$pr) state }
		      } pageInfo { hasNextPage }
		    } }
		  } } }
		}') || return 1
	branch=$(jq -er --arg head "$head" '.data.repository.pullRequest |
		select(.headRefOid == $head and .baseRef != null) | .baseRefName | select(type == "string" and length > 0) | @uri' <<<"$checks") || return 1
	# Enumerate requirements too: absent required contexts are not in the rollup.
	# This endpoint returns active rules, including inherited organization rules.
	rules=$(gh api --paginate --slurp "repos/$repo/rules/branches/$branch") || return 1
	jq -e --arg head "$head" --argjson pages "$rules" '
		def passed: (.__typename == "CheckRun" and .status == "COMPLETED" and .conclusion == "SUCCESS") or
			(.__typename == "StatusContext" and .state == "SUCCESS");
		($pages | add) as $rules |
		select(($rules | type) == "array" and all($rules[]; .type != "workflows")) |
		.data.repository as $repo | $repo.object | select(.oid == $head) |
		.statusCheckRollup.contexts | select(.pageInfo.hasNextPage == false and (.nodes | type) == "array") |
		.nodes as $nodes |
		([$repo.pullRequest.baseRef.branchProtectionRule.requiredStatusChecks[]? |
			{context, app: .app.databaseId}] +
		 [$rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] |
			{context, app: .integration_id}]) as $required |
		all($nodes[]; .isRequired == false or (.isRequired == true and passed)) and
		all($required[]; . as $requirement | any($nodes[];
			(.name // .context) == $requirement.context and passed and
			($requirement.app == null or $requirement.app == -1 or
			 .checkSuite.app.databaseId == $requirement.app)))' <<<"$checks" >/dev/null || return 1
	return 0
}

_pulse_macos_candidates() {
	local repo="$1" path="$2" state="$3" candidates="" row="" pr="" head="" base="" author="" fork=""
	local permission="" current="" attempt=""
	candidates=$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq '
		.[] | select(.draft == false and any(.labels[]; .name == "needs-macos-verification")) |
		[.number, .head.sha, .base.sha, .user.login, (.head.repo.full_name != .base.repo.full_name)] | @tsv') || return 1
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		IFS=$'\t' read -r pr head base author fork <<<"$row"
		[[ "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[a-f0-9]{40}$ && "$base" =~ ^[a-f0-9]{40}$ ]] || continue
		if [[ "$fork" != false ]]; then
			printf 'macos-verify skipped: fork (%s#%s)\n' "$repo" "$pr"
			continue
		fi
		# aidevops:trust-boundary -- PR code executes on the maintainer host.
		permission=$(gh api "repos/$repo/collaborators/$author/permission" --jq .permission 2>/dev/null) || permission=""
		case "$permission" in
		write | maintain | admin) ;;
		*) printf 'macos-verify skipped: untrusted-author (%s#%s)\n' "$repo" "$pr"; continue ;;
		esac
		attempt="$state/$repo/$pr/$head"
		if [[ -d "$attempt" ]]; then
			# The global lock proves a prior in-progress attempt is now interrupted.
			if [[ ! -f "$attempt/outcome" ]]; then
				printf 'Native verification interrupted before a terminal suite result.\n' >>"$attempt/output.log"
				printf 'failed\n' >"$attempt/outcome"
			fi
			if [[ -f "$attempt/outcome" ]] && [[ "$(<"$attempt/outcome")" == failed ]]; then
				_pulse_macos_failure_comment "$repo" "$pr" "$head" "$attempt" || true
			fi
			continue
		fi
		_pulse_macos_checks_pass "$repo" "$pr" "$head" || continue
		# Retain the freshness check as well as the immutable check snapshot.
		current=$(gh api "repos/$repo/pulls/$pr" --jq 'select(.state == "open" and .draft == false) | .head.sha') || continue
		[[ "$current" == "$head" ]] || continue
		mkdir -p "${attempt%/*}" || return 1
		mkdir "$attempt" || continue
		_pulse_macos_verify "$repo" "$path" "$pr" "$head" "$base" "$attempt"
		return 10 # One attempted head across all registered repositories per cycle.
	done <<<"$candidates"
	return 0
}

_pulse_macos_cycle() {
	local state="$1"
	local config="${AIDEVOPS_REPOS_CONFIG:-${REPOS_JSON:-$HOME/.config/aidevops/repos.json}}"
	local login="" repo="" path="" maintainer="" entries="" rc=0
	# shellcheck source=macos-local-checks.sh
	source "$_PULSE_MACOS_DIR/macos-local-checks.sh" || return 1
	[[ "$(macos_checks_host)" == Darwin ]] || return 0
	# Match macos_checks_route's unique registration and login validation exactly.
	entries=$(jq -er '.initialized_repos | group_by(.slug)[] | select(length == 1) | .[0] |
		select(.pulse == true and .maintenance != false and .local_only != true) |
		(.macos_maintainer // .maintainer) as $maintainer |
		select($maintainer | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")) |
		[.slug, .path, $maintainer] | @tsv' "$config") || return 0
	# Resolve active credentials, including GH_TOKEN, rather than assuming the OS user.
	login=$(gh api user --jq .login) || return 1
	while IFS=$'\t' read -r repo path maintainer; do
		[[ "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$maintainer" | tr '[:upper:]' '[:lower:]')" ]] || continue
		[[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && "${repo#*/}" != . && "${repo#*/}" != .. && -d "$path" ]] || continue
		_pulse_macos_candidates "$repo" "$path" "$state" || rc=$?
		[[ "$rc" != 10 ]] || return 0
	done <<<"$entries"
	return 0
}

_pulse_macos_run() {
	[[ "$(uname -s)" == Darwin ]] || return 0
	local budget="${AIDEVOPS_PULSE_MACOS_VERIFICATION_BUDGET_SECONDS:-1200}"
	local state="$HOME/.aidevops/.agent-workspace/state/macos-verification" rc=0
	[[ "$budget" =~ ^[1-9][0-9]*$ ]] || return 1
	umask 077
	mkdir -p "$state" || return 1
	# shellcheck source=shared-constants.sh
	# Pass `run` so a Bash 3.2 re-exec keeps the entrypoint command.
	source "$_PULSE_MACOS_DIR/shared-constants.sh" run || return 1
	local -a timer=(timeout_sec "$budget")
	# Coreutils otherwise waits forever if a suite ignores TERM. The stock
	# macOS timeout_sec fallback already escalates to KILL for the whole group.
	if command -v timeout >/dev/null 2>&1; then
		timer=(timeout --kill-after=5 "$budget")
	elif command -v gtimeout >/dev/null 2>&1; then
		timer=(gtimeout --kill-after=5 "$budget")
	fi
	# Portable advisory lock: parent Perl holds it until the bounded cycle exits.
	# A timeout kills the process group; the next cycle can acquire the same lock.
	# shellcheck disable=SC2016 # Perl, not Bash, expands these variables.
	"${timer[@]}" perl -MFcntl=:flock -e '
		open my $lock, ">>", shift @ARGV or exit 1;
		flock($lock, LOCK_EX | LOCK_NB) or exit 0;
		system @ARGV; exit($? == -1 ? 1 : ($? & 127 ? 1 : $? >> 8));
	' "$state/cycle.lock" bash "${BASH_SOURCE[0]}" cycle "$state" || rc=$?
	return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	case "${1:-}" in
	run) _pulse_macos_run ;;
	cycle) _pulse_macos_cycle "${2:?state required}" ;;
	*) printf 'Usage: pulse-macos-verification.sh run\n' >&2; exit 1 ;;
	esac
fi
