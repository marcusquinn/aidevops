#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dependabot-intake.sh — idempotent worker intake for stalled bot PRs.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DEPENDABOT_INTAKE_LOADED:-}" ]] && return 0
_PULSE_DEPENDABOT_INTAKE_LOADED=1

: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

_pulse_dependabot_intake_marker() {
	local repo_slug="$1"
	local pr_number="$2"
	printf '<!-- aidevops:dependabot-pr-intake repo=%s pr=%s -->' "$repo_slug" "$pr_number"
	return 0
}

# Build executable scope from the authentic source PR's exact current diff.
# The identity gate runs first; this second read binds the scope to the same
# head and rejects paths that cannot be represented safely in Markdown.
_pulse_dependabot_intake_scope_lines() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local scope_json=""
	local scope_head=""
	local paths=""
	local path=""

	scope_json=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json headRefOid,files 2>/dev/null) || return 1
	scope_head=$(printf '%s' "$scope_json" | jq -r '.headRefOid // ""' 2>/dev/null) || return 1
	[[ "$scope_head" == "$expected_head_sha" ]] || return 1
	paths=$(printf '%s' "$scope_json" | jq -er '
		if ((.files | type) != "array") or (.files | length) == 0
		then error("Dependabot diff files unavailable")
		else .files[] | .path
		end' 2>/dev/null) || return 1

	# shellcheck disable=SC2016 # Literal Markdown scope declaration.
	printf '%s\n' '- EDIT: `.agents/configs/trusted-dependabot-updates.conf`'
	while IFS= read -r path; do
		case "$path" in
		"" | /* | ../* | */../* | */.. | *'`'*) return 1 ;;
		esac
		[[ "$path" != *$'\r'* ]] || return 1
		# shellcheck disable=SC2016 # Literal Markdown code-span delimiters.
		printf -- '- EDIT: `%s`\n' "$path"
	done <<<"$paths"
	return 0
}

_pulse_dependabot_existing_intake_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local issues_json="[]"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	# Do not use GitHub search for this identity check. Search indexing can lag
	# issue creation, so two Pulse cycles may both observe an invented absence.
	# The repository issue list is authoritative and the dependencies label keeps
	# the bounded read focused on generated intake candidates. The extra result is
	# a truncation sentinel: a saturated read is unknown, never absence.
	issues_json=$(gh_issue_list --repo "$repo_slug" --state open \
		--label dependencies --limit 501 \
		--json number,body,url,labels 2>/dev/null) || return 1
	printf '%s' "$issues_json" | jq -r --arg marker "$marker" \
		'if length >= 501 then error("intake lookup truncated") else [.[]
			| ([.labels[]?.name // ""] | unique) as $labels
			| select(($labels | index("origin:worker")) != null)
			| select(($labels | index("dependencies")) != null)
			| select((.body // "") | contains($marker))][0].url // "" end' 2>/dev/null
	return $?
}

_pulse_dependabot_completed_intake_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local issues_json="[]"

	issues_json=$(gh_issue_list --repo "$repo_slug" --state closed \
		--search "Dependabot PR #${pr_number} in:title" --limit 20 \
		--json number,body,labels 2>/dev/null) || return 1
	printf '%s' "$issues_json" | jq -r --arg marker "$marker" '
		[.[]
			 | select((.body // "") | contains($marker))
			 | ([.labels[]?.name // ""] | unique) as $labels
			 | select(($labels | index("origin:worker")) != null)
			 | select(($labels | index("status:done")) != null)
			 | select(($labels | index("solved:worker")) != null)]
		| .[0].number // ""' 2>/dev/null
	return $?
}

# Close an authentic policy-held source PR only when its generated worker intake is
# terminal and a different same-repository PR verifiably merged to close it.
# Missing, truncated, stale-head, or unavailable evidence preserves the hold.
_pulse_dependabot_close_superseded_source_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local marker="$4"
	local intake_issue=""
	local superseding_pr=""
	local final_json=""
	local final_state=""
	local final_head=""
	local close_comment=""

	_PULSE_DEPENDABOT_COMPLETED_INTAKE_ISSUE=""
	_PULSE_DEPENDABOT_SUPERSEDING_PR=""
	intake_issue=$(_pulse_dependabot_completed_intake_issue "$pr_number" "$repo_slug" "$marker") || return 2
	[[ "$intake_issue" =~ ^[0-9]+$ ]] || return 1
	_PULSE_DEPENDABOT_COMPLETED_INTAKE_ISSUE="$intake_issue"
	declare -F _psh_find_merged_closer_for_closed_issue >/dev/null 2>&1 || return 2
	declare -F gh_pr_close_safe >/dev/null 2>&1 || return 2
	superseding_pr=$(_psh_find_merged_closer_for_closed_issue \
		"$repo_slug" "$intake_issue" "$pr_number" 2>/dev/null) || return 2
	[[ "$superseding_pr" =~ ^[0-9]+$ && "$superseding_pr" != "$pr_number" ]] || return 2

	final_json=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json state,headRefOid,labels 2>/dev/null) || return 2
	final_state=$(printf '%s' "$final_json" | jq -r '.state // ""' 2>/dev/null) || return 2
	final_head=$(printf '%s' "$final_json" | jq -r '.headRefOid // ""' 2>/dev/null) || return 2
	[[ "$final_state" == "OPEN" && "$final_head" == "$expected_head_sha" ]] || return 2

	_PULSE_DEPENDABOT_SUPERSEDING_PR="$superseding_pr"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-dependabot-intake] DRY-RUN: PR #${pr_number} in ${repo_slug} would close as superseded by merged PR #${superseding_pr} for completed intake #${intake_issue}" >>"$LOGFILE"
		return 0
	fi

	close_comment="<!-- aidevops:dependabot-source-superseded intake=${intake_issue} replacement=${superseding_pr} -->
Closing this Dependabot source PR as superseded: generated worker intake #${intake_issue} is terminal and was closed by verified merged replacement PR #${superseding_pr}.

The external-authority policy prevented unsafe automatic merge while the replacement converged. Pulse revalidated the authentic source head immediately before this close.

_Closed by deterministic Dependabot lifecycle reconciliation (GH#30478)._"
	if ! gh_pr_close_safe "$pr_number" --repo "$repo_slug" --comment "$close_comment" >/dev/null 2>&1; then
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: verified replacement PR #${superseding_pr}, but source close failed" >>"$LOGFILE"
		return 2
	fi
	if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
		_pulse_merge_invalidate_pr_list_cache "$repo_slug" "closed superseded Dependabot source PR #${pr_number}"
	fi
	echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: closed as superseded by merged PR #${superseding_pr} for completed intake #${intake_issue}" >>"$LOGFILE"
	return 0
}

# Classify the one authenticity failure that is both exact-head verified and
# actionable without guessing: a genuine Dependabot PR whose commit set contains
# a commit not authored by Dependabot. Unknown snapshot failures remain write-free.
_pulse_dependabot_mark_modified_source_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local marker="<!-- aidevops:dependabot-modified-source head=${expected_head_sha} -->"
	local body=""

	declare -F _gh_idempotent_comment >/dev/null 2>&1 || return 1
	declare -F gh_pr_edit_safe >/dev/null 2>&1 || return 1
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-dependabot-intake] DRY-RUN: PR #${pr_number} in ${repo_slug} would receive an actionable maintainer hold for non-Dependabot commit authorship" >>"$LOGFILE"
		return 0
	fi
	body="${marker}
Pulse verified this PR's GitHub Bot identity, same-repository head, and exact head SHA, but the current commit set contains non-Dependabot commit authorship. Automated merge and worker intake remain blocked because a modified bot branch cannot be treated as an authentic Dependabot update.

Maintainer action: inspect the added commits, then either close and recreate the update from Dependabot or use the repository's existing current-head maintainer approval workflow after accepting the modified branch."
	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$body" "pr" || return 1
	gh_pr_edit_safe "$pr_number" --repo "$repo_slug" \
		--add-label "needs-maintainer-review" >/dev/null 2>&1 || return 1
	echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: exact-head bot branch contains non-Dependabot commit authorship; added actionable maintainer hold" >>"$LOGFILE"
	return 0
}

_pulse_dependabot_preflight_route() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" expected_head_sha="$4" marker="$5"
	local reconcile_rc=0

	#aidevops:trust-boundary — only a typed failure reached after exact-head Bot,
	# repository, and source-head verification may trigger a maintainer hold write.
	if ! _is_authentic_dependabot_pr "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha"; then
		if [[ "${_TRUSTED_DEPENDABOT_AUTH_FAILURE_REASON:-}" == "commit-author-mismatch" ]] &&
			_pulse_dependabot_mark_modified_source_pr "$pr_number" "$repo_slug" "$expected_head_sha"; then
			return 5
		fi
		return 1
	fi
	if _pulse_dependabot_close_superseded_source_pr \
		"$pr_number" "$repo_slug" "$expected_head_sha" "$marker"; then
		return 4
	else
		reconcile_rc=$?
	fi
	[[ "$reconcile_rc" -eq 1 ]] && return 0
	if [[ "${_PULSE_DEPENDABOT_COMPLETED_INTAKE_ISSUE:-}" =~ ^[0-9]+$ ]]; then
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: completed intake #${_PULSE_DEPENDABOT_COMPLETED_INTAKE_ISSUE} has no verified merged replacement; preserving source without duplicate intake" >>"$LOGFILE"
	else
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: completed-intake reconciliation evidence unavailable; preserving source without duplicate intake" >>"$LOGFILE"
	fi
	return 6
}

# Return 0 when the source PR carries an explicit maintainer-review hold,
# 1 when it does not, and 2 when the live label state cannot be verified.
_pulse_dependabot_pr_has_maintainer_hold() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels=""

	declare -F gh_pr_view >/dev/null 2>&1 || return 2
	labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name] | join(",")' 2>/dev/null) || return 2
	[[ ",${labels}," == *",needs-maintainer-review,"* ]]
	return $?
}

_pulse_dependabot_intake_body() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="$3"
	local reason="$4"
	local marker="$5"
	local scope_lines="$6"

	cat <<-EOF
		## Dependabot PR worker intake

		Pulse verified GitHub's live Dependabot Bot identity, same-repository head ownership,
		the exact observed head, and Dependabot commit authorship. Automated merge did not
		proceed because: **${reason}**.

		Source PR: https://github.com/${repo_slug}/pull/${pr_number}
		Observed head: \`${head_sha}\`

		### Worker objective

		Inspect the dependency update and terminal checks, reproduce relevant failures, and
		deliver the smallest safe replacement or repair PR. If the source PR is safe but only
		outside the maintained trust policy, update the narrow policy with evidence. If the
		update is unsafe or intentionally deferred, apply an explicit maintainer-review hold
		with rationale. Close or supersede the source PR only after preserving this evidence.

		### Files Scope

		${scope_lines}

		Start from the source PR diff. The exact observed paths above and the narrow trusted
		dependency policy are the initial executable boundary. Follow the
		trusted boundary in \`.agents/scripts/trusted-dependabot-lib.sh\` and the repair-routing
		pattern in \`.agents/scripts/pulse-merge-process.sh::_route_pr_to_fix_worker\`.

		### Verification

		Run the dependency ecosystem's targeted install, typecheck, tests, and security checks;
		then run repository-required checks for changed files. Verify the source PR is merged,
		closed as superseded, or explicitly held before completing this issue.

		${marker}
	EOF
	return 0
}

_pulse_dependabot_intake_lock_dir() {
	local pr_number="$1"
	local repo_slug="$2"
	local lock_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/locks"
	local repo_key="${repo_slug//[^a-zA-Z0-9_.-]/-}"

	printf '%s/dependabot-intake-%s-%s.lock' "$lock_root" "$repo_key" "$pr_number"
	return 0
}

_pulse_dependabot_acquire_intake_lock() {
	local pr_number="$1"
	local repo_slug="$2"
	local output_var="$3"
	local lock_path=""
	local lock_pid=""
	local stale_dir=""
	local attempt=0

	lock_path=$(_pulse_dependabot_intake_lock_dir "$pr_number" "$repo_slug") || return 1
	mkdir -p "${lock_path%/*}" 2>/dev/null || return 1
	while ! mkdir "$lock_path" 2>/dev/null; do
		lock_pid=""
		[[ -f "${lock_path}/pid" ]] && lock_pid=$(<"${lock_path}/pid")
		if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
			stale_dir="${lock_path}.stale.$$"
			if mv "$lock_path" "$stale_dir" 2>/dev/null; then
				rm -rf "$stale_dir"
				continue
			fi
		fi
		attempt=$((attempt + 1))
		[[ "$attempt" -lt 300 ]] || return 1
		sleep 0.1
	done
	printf '%s\n' "$$" >"${lock_path}/pid" 2>/dev/null || {
		rmdir "$lock_path" 2>/dev/null || true
		return 1
	}
	printf -v "$output_var" '%s' "$lock_path"
	return 0
}

_pulse_dependabot_release_intake_lock() {
	local lock_dir="$1"
	local lock_pid=""

	[[ -n "$lock_dir" && -d "$lock_dir" ]] || return 0
	[[ -f "${lock_dir}/pid" ]] && lock_pid=$(<"${lock_dir}/pid")
	[[ "$lock_pid" == "$$" ]] || return 1
	rm -f "${lock_dir}/pid" 2>/dev/null || return 1
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_pulse_route_dependabot_pr_to_worker_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local expected_head_sha="$4"
	local reason="${5:-policy-ineligible}"
	local marker=""
	local existing_url=""
	local temp_dir=""
	local body_file=""
	local issue_output=""
	local lock_dir=""
	local hold_rc=0
	local preflight_rc=0
	local scope_lines=""

	case "$reason" in
	policy-ineligible | terminal-ci-failure | merge-conflict) ;;
	*) reason="policy-ineligible" ;;
	esac
	declare -F _is_authentic_dependabot_pr >/dev/null 2>&1 || return 1
	declare -F gh_create_issue >/dev/null 2>&1 || return 1
	declare -F gh_issue_list >/dev/null 2>&1 || return 1
	declare -F gh_pr_view >/dev/null 2>&1 || return 1
	marker=$(_pulse_dependabot_intake_marker "$repo_slug" "$pr_number") || return 1
	existing_url=$(_pulse_dependabot_existing_intake_issue "$pr_number" "$repo_slug" "$marker") || return 1
	if [[ -n "$existing_url" ]]; then
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: existing worker issue ${existing_url}" >>"$LOGFILE"
		return 0
	fi
	_pulse_dependabot_preflight_route \
		"$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha" "$marker" || preflight_rc=$?
	[[ "$preflight_rc" -eq 0 ]] || return "$preflight_rc"
	_pulse_dependabot_pr_has_maintainer_hold "$pr_number" "$repo_slug" || hold_rc=$?
	case "$hold_rc" in
	0)
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: preserving explicit needs-maintainer-review hold; no worker issue created" >>"$LOGFILE"
		return 3
		;;
	1) ;;
	*)
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: live maintainer-review hold state unavailable; failing closed" >>"$LOGFILE"
		return 1
		;;
	esac
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-dependabot-intake] DRY-RUN: authentic PR #${pr_number} in ${repo_slug} would route ${reason} to a worker issue" >>"$LOGFILE"
		return 0
	fi
	if ! _pulse_dependabot_acquire_intake_lock "$pr_number" "$repo_slug" lock_dir; then
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: worker intake lock unavailable" >>"$LOGFILE"
		return 1
	fi
	existing_url=$(_pulse_dependabot_existing_intake_issue "$pr_number" "$repo_slug" "$marker") || {
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		return 1
	}
	if [[ -n "$existing_url" ]]; then
		_pulse_dependabot_release_intake_lock "$lock_dir" || return 1
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: existing worker issue ${existing_url}" >>"$LOGFILE"
		return 0
	fi
	scope_lines=$(_pulse_dependabot_intake_scope_lines \
		"$pr_number" "$repo_slug" "$expected_head_sha") || {
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: exact-head Files Scope unavailable; failing before issue creation" >>"$LOGFILE"
		return 1
	}

	temp_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_dir" 2>/dev/null || {
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		return 1
	}
	body_file=$(mktemp "${temp_dir}/dependabot-intake.XXXXXX") || {
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		return 1
	}
	_pulse_dependabot_intake_body "$pr_number" "$repo_slug" "$expected_head_sha" "$reason" "$marker" "$scope_lines" >"$body_file" || {
		rm -f "$body_file"
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		return 1
	}
	issue_output=$(gh_create_issue --repo "$repo_slug" \
		--title "Dependabot PR #${pr_number} requires worker resolution" \
		--body-file "$body_file" \
		--label "auto-dispatch,origin:worker,tier:standard,dependencies" 2>&1) || {
		local create_rc=$?
		rm -f "$body_file"
		_pulse_dependabot_release_intake_lock "$lock_dir" || true
		echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: worker issue creation failed" >>"$LOGFILE"
		return "$create_rc"
	}
	rm -f "$body_file"
	_pulse_dependabot_release_intake_lock "$lock_dir" || return 1
	echo "[pulse-dependabot-intake] PR #${pr_number} in ${repo_slug}: routed ${reason} to ${issue_output}" >>"$LOGFILE"
	return 0
}
