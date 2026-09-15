#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Conflict feedback classification and routing helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_FEEDBACK_CONFLICT_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_CONFLICT_LOADED=1

#######################################
# Build a whole-token lookup set for add/add conflict paths (t3199).
#
# Args:
#   $1 - (optional) path to a git repo with an in-flight rebase/merge.
#
# Output: space-padded path set suitable for `[[ "$set" == *" $path "* ]]`.
#######################################
_conflict_add_add_path_set() {
	local repo_path="${1:-}"
	local add_add_files=""

	if [[ -n "$repo_path" ]] && [[ -d "$repo_path/.git" || -f "$repo_path/.git" ]]; then
		add_add_files=$(git -C "$repo_path" status --porcelain 2>/dev/null \
			| awk '/^AA / {print $2}' | tr '\n' ' ')
		add_add_files="${add_add_files% }"
	fi

	if [[ -n "$add_add_files" ]]; then
		printf ' %s ' "$add_add_files"
	else
		printf ' '
	fi
	return 0
}

#######################################
# Check whether a path is present in a space-padded lookup set.
#
# Args:
#   $1 - file path
#   $2 - space-padded lookup set
#######################################
_conflict_path_in_set() {
	local fpath="$1"
	local lookup_set="$2"

	[[ "$lookup_set" == *" ${fpath} "* ]] || return 1
	return 0
}

#######################################
# Match one conflicting path against the conflict pattern registry.
#
# Args:
#   $1 - file path
#   $2 - conflict-patterns.conf path
#
# Output: matching classification, or CODE.
#######################################
_conflict_registry_class_for_path() {
	local fpath="$1"
	local conf_file="$2"
	local fname
	fname="${fpath##*/}"
	local matched_class=""

	while IFS='|' read -r class_raw glob_raw _rest; do
		local class="" glob=""
		class="${class_raw#"${class_raw%%[![:space:]]*}"}"
		class="${class%"${class##*[![:space:]]}"}"
		glob="${glob_raw#"${glob_raw%%[![:space:]]*}"}"
		glob="${glob%"${glob##*[![:space:]]}"}"

		[[ -n "$class" && -n "$glob" ]] || continue
		[[ "$class" == \#* ]] && continue
		[[ "$class" == "ADD_ADD_NEW_FILE" ]] && continue

		local did_match=0
		# shellcheck disable=SC2254  # dynamic glob is intentional
		case "$fpath" in
			$glob) did_match=1 ;;
		esac
		if [[ $did_match -eq 0 ]]; then
			# shellcheck disable=SC2254  # dynamic glob is intentional
			case "$fname" in
				$glob) did_match=1 ;;
			esac
		fi

		if [[ $did_match -eq 1 ]]; then
			matched_class="$class"
			break
		fi
	done < <(grep -v '^[[:space:]]*#' "$conf_file" | grep -v '^[[:space:]]*$')

	printf '%s\n' "${matched_class:-CODE}"
	return 0
}

#######################################
# Group `CLASS:path` rows into conflict-pattern output lines.
#
# Args:
#   $1 - classified rows, one `CLASS:path` entry per line
#
# Output: multi-line classification string.
#######################################
_emit_grouped_conflict_classifications() {
	local classified_lines="$1"
	local all_classes="ADD_ADD_NEW_FILE DRIZZLE_MIGRATION LOCKFILE I18N_JSON GENERATED CODE"
	local class

	for class in $all_classes; do
		local paths_for_class=""
		while IFS= read -r entry; do
			[[ "$entry" == "${class}:"* ]] || continue
			local p="${entry#*:}"
			paths_for_class="${paths_for_class}${p} "
		done < <(printf '%s\n' "$classified_lines")
		paths_for_class="${paths_for_class% }"
		if [[ -n "$paths_for_class" ]]; then
			printf '%s %s\n' "$class" "$paths_for_class"
		fi
	done
	return 0
}

#######################################
# Classify a list of conflicting file paths against the conflict-patterns.conf
# registry and return a multi-line classification string (t2987).
#
# Each output line has the form:
#   CLASSIFICATION path/to/file1 path/to/file2 ...
#
# Patterns are matched in conf order. CODE is the catch-all fallback.
# Files that match a non-CODE pattern are collected per-classification.
# Unmatched files fall through to the CODE bucket.
#
# add/add detection (t3199): when a repo_path is supplied AND it contains
# an in-progress rebase/merge with `AA` rows in `git status --porcelain`,
# those files are pre-classified as ADD_ADD_NEW_FILE — independent of
# filename glob. add/add conflicts can occur on any path, so glob matching
# is not a reliable signal. The pulse caller (`_dispatch_conflict_fix_worker`)
# does not have a local checkout and passes no repo_path, so its existing
# classification path is preserved. Worker / test contexts that DO have a
# checkout pass repo_path to enable the structural detection.
#
# Args:
#   $1 - newline-separated list of conflicting file paths
#   $2 - (optional) path to conflict-patterns.conf; defaults to the conf
#        in the same directory as this script's parent configs/ dir.
#   $3 - (optional, t3199) path to a git repo with an in-flight rebase/merge.
#        When set and valid, files marked `AA` by `git status --porcelain`
#        are classified as ADD_ADD_NEW_FILE before glob matching.
#
# Output: multi-line classification on stdout (empty if no files given).
#######################################
_classify_conflicts_by_pattern() {
	local file_list="$1"
	local conf_file="${2:-}"
	local repo_path="${3:-}"

	# Locate conf file relative to this script if not supplied.
	if [[ -z "$conf_file" ]]; then
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		conf_file="${script_dir}/../configs/conflict-patterns.conf"
	fi

	[[ -n "$file_list" ]] || return 0
	[[ -f "$conf_file" ]] || {
		# Fallback: classify everything as CODE if conf is missing.
		printf 'CODE %s\n' "$file_list"
		return 0
	}

	local add_add_set
	add_add_set="$(_conflict_add_add_path_set "$repo_path")"

	local classified_lines=""
	local class

	while IFS= read -r fpath; do
		[[ -n "$fpath" ]] || continue

		if _conflict_path_in_set "$fpath" "$add_add_set"; then
			class="ADD_ADD_NEW_FILE"
		else
			class="$(_conflict_registry_class_for_path "$fpath" "$conf_file")"
		fi
		classified_lines="${classified_lines}${class}:${fpath}"$'\n'
	done < <(printf '%s\n' "$file_list")

	_emit_grouped_conflict_classifications "$classified_lines"
	return 0
}

#######################################
# Emit markdown guidance blocks for each non-CODE conflict pattern (t2987).
#
# Called by _build_conflict_feedback_section after classification to append
# a ### Pattern-Specific Resolution Guidance subsection per detected class.
#
# Args:
#   $1 - classification_output  (multi-line: "CLASS file1 file2 ...")
#   $2 - default_branch         (e.g. "main", "develop")
#   $3 - conf_file              (path to conflict-patterns.conf)
#
# Output: markdown guidance blocks on stdout (nothing if all CODE or empty).
#######################################
_emit_pattern_guidance_blocks() {
	local classification_output="$1"
	local default_branch="$2"
	local conf_file="$3"

	[[ -n "$classification_output" ]] || return 0

	# Check if any non-CODE class is present.
	local has_non_code=0
	while IFS= read -r cls_line; do
		[[ "$cls_line" == CODE\ * ]] || has_non_code=1
	done < <(printf '%s\n' "$classification_output")
	[[ $has_non_code -eq 1 ]] || return 0

	printf '\n### Pattern-Specific Resolution Guidance\n\n'
	printf 'The conflicting files match known patterns with deterministic resolution paths.\n'
	printf 'Follow the per-pattern guidance below before falling back to the generic\n'
	printf 'cherry-pick instructions in the Worker guidance section above.\n\n'

	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		local class="${cls_line%% *}"
		local files="${cls_line#* }"
		[[ "$class" == "CODE" ]] && continue

		# Look up first matching guidance record in conf for this class.
		local resolution_cmd="" guidance=""
		if [[ -f "$conf_file" ]]; then
			while IFS='|' read -r cr _gr rr guide_raw; do
				# Trim whitespace.
				local cn="${cr#"${cr%%[![:space:]]*}"}"
				cn="${cn%"${cn##*[![:space:]]}"}"
				[[ "$cn" == "$class" ]] || continue
				rr="${rr#"${rr%%[![:space:]]*}"}"; rr="${rr%"${rr##*[![:space:]]}"}"
				guide_raw="${guide_raw#"${guide_raw%%[![:space:]]*}"}"
				guide_raw="${guide_raw%"${guide_raw##*[![:space:]]}"}"
				resolution_cmd="$rr"; guidance="$guide_raw"
				break
			done < <(grep -v '^[[:space:]]*#' "$conf_file" \
				| grep -v '^[[:space:]]*$')
		fi

		printf '#### Pattern: %s\n\n' "$class"
		# shellcheck disable=SC2016  # backticks are literal markdown, not expansion
		printf 'Affected files: `%s`\n\n' "${files// /, }"
		if [[ -n "$guidance" ]]; then
			local expanded="${guidance//\{default_branch\}/${default_branch}}"
			expanded="${expanded//\\n/$'\n'}"
			printf '%s\n\n' "$expanded"
		fi
		if [[ -n "$resolution_cmd" ]]; then
			local rcmd="${resolution_cmd//\{default_branch\}/${default_branch}}"
			# shellcheck disable=SC2016  # backticks are literal markdown, not expansion
			printf 'Quick resolution command: `%s`\n\n' "$rcmd"
		fi
	done < <(printf '%s\n' "$classification_output")
	return 0
}
#######################################
# Build the conflict-feedback Markdown section for a closed-conflict PR.
#
# Produces the "## Merge Conflict Feedback" block appended to the linked
# issue body. Leads with cherry-pick-first guidance (t2426) — the prior
# worker's commit is usually correct-but-stale, so cherry-picking onto a
# fresh branch off current default branch is ~10x cheaper than rewriting.
#
# Scope-leak heuristic (t2802): if the prior PR touched more files than a
# focused fix should, that's a signal the BRANCH BASE was wrong, not that
# the semantic conflict is real. Rebuilding from the issue body is then
# cheaper than cherry-picking a scope-leaked branch. Canonical failure:
# example-repo#2716 / PR #2733 (100 files for a 2-line fix). Successive
# workers burned opus tokens trying to cherry-pick the monster.
#
# Extracted from _dispatch_conflict_fix_worker to keep that function under
# the 100-line threshold (function-complexity gate).
#
# Args: $1=pr_number, $2=pr_title, $3=pr_files, $4=pr_head_sha,
#       $5=default_branch (e.g. "main", "develop"),
#       $6=pr_file_count (integer, may be empty)
# Stdout: the rendered section
#######################################
_build_conflict_feedback_section() {
	local pr_number="$1"
	local pr_title="$2"
	local pr_files="$3"
	local pr_head_sha="$4"
	local default_branch="${5:-main}"
	local pr_file_count="${6:-}"

	# Locate the conflict-patterns.conf registry (t2987).
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local conf_file="${script_dir}/../configs/conflict-patterns.conf"

	# Classify conflicting files for pattern-aware guidance (t2987).
	local classification_output=""
	if [[ -n "$pr_files" ]]; then
		classification_output=$(_classify_conflicts_by_pattern "$pr_files" "$conf_file")
	fi

	# Scope-leak detection (t2802). If prior PR touched >20 files, the
	# base was probably wrong (canonical HEAD stale). Cherry-picking a
	# scope-leaked branch is expensive and usually fails the same way
	# the first attempt did. Surface the signal upfront so the worker
	# rebuilds from the issue body instead of chasing a ghost diff.
	#
	# Build as plain quoted string (not heredoc-in-$()) so bash 3.2 accepts it.
	local scope_leak_warning=""
	if [[ -n "$pr_file_count" ]] && [[ "$pr_file_count" =~ ^[0-9]+$ ]] && ((pr_file_count > 20)); then
		scope_leak_warning="> ⚠ **Scope-leak signal**: the prior PR touched **${pr_file_count} files**. For most
> conflict-feedback loops the touch-count should be 1-5. A high count usually means
> the prior worker's branch was created off a stale canonical HEAD (not \`origin/${default_branch}\`),
> so the diff = \"everything ${default_branch} has that the stale base doesn't\" + the actual fix.
>
> **If the file list below looks unrelated to the original issue scope, skip the
> cherry-pick entirely** and rebuild from the issue body onto a fresh branch explicitly
> based on \`origin/${default_branch}\`. Cherry-picking a scope-leaked branch will fail
> the same way — that is why the prior attempt was closed.
>
> Framework fix in-flight: t2802 makes \`worktree-helper.sh add\` base new branches
> on \`origin/<default>\` explicitly instead of inheriting canonical HEAD."
	fi

	# Build scope-warning block separately to avoid interpolating empty lines.
	local scope_block=""
	if [[ -n "$scope_leak_warning" ]]; then
		scope_block=$'\n'"${scope_leak_warning}"$'\n'
	fi

	cat <<-EOF
		## Merge Conflict Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} (\`${pr_title}\`) developed merge conflicts with
		\`${default_branch}\` that could not be resolved by \`gh pr update-branch\` (server-side fast-forward).
		The conflicts are semantic — the same files were modified on both branches${pr_file_count:+ (${pr_file_count} files touched)}.${scope_block}

		### Files in the conflicting PR

		\`\`\`
		${pr_files}
		\`\`\`

		### Worker guidance

		The prior PR's head commit is \`${pr_head_sha:-<lookup via gh pr view ${pr_number} --json headRefOid>}\`. Choose the cheapest path that works:

		1. **Cherry-pick onto a fresh branch off current \`origin/${default_branch}\`** (~10x cheaper than rewriting, works when the prior implementation was correct-but-stale):

		   \`\`\`bash
		   git fetch origin pull/${pr_number}/head:recovered-${pr_number}
		   # Explicit base on origin/${default_branch} — NOT canonical HEAD (t2802).
		   git worktree add -b fresh-branch ../fresh-worktree origin/${default_branch}
		   cd ../fresh-worktree
		   git cherry-pick ${pr_head_sha:-<head-sha>}
		   # run tests — if clean, proceed to PR
		   \`\`\`

		2. **If cherry-pick surfaces conflicts**, resolve them. The conflict surface IS the semantic overlap between the two branches — resolve those specific hunks rather than rewriting untouched logic.

		3. **If the scope-leak warning above fired** (prior PR >20 files but the issue describes a focused fix), **skip cherry-pick entirely** and rebuild from scratch using the issue body as the spec. Do NOT try to cherry-pick-then-drop-files — too error-prone. A clean rewrite from the 2-line spec is cheaper than surgery on a 100-file branch.

		4. **Only rewrite from scratch (scope-OK case)** if the prior approach was rejected in review. Check PR #${pr_number}'s review comments for \`CHANGES_REQUESTED\` or rejection keywords before assuming the approach was wrong.

		Do NOT reuse the old PR's branch directly — always cherry-pick onto a fresh branch off current \`origin/${default_branch}\`.

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF

	# Append pattern-specific guidance block for non-CODE patterns (t2987).
	_emit_pattern_guidance_blocks "$classification_output" "$default_branch" "$conf_file"
	return 0
}

#######################################
# Route merge conflict context from a worker PR to its linked issue, close
# the PR, and set the issue to status:available for re-dispatch.
#
# Called when `gh pr update-branch` fails (true semantic conflict) on a
# worker PR. The next worker gets the conflict context and the list of
# conflicting files in its prompt.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_title
#######################################
_dispatch_conflict_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_title="$4"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids conflict feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi

	# Create labels (idempotent, --force)
	_feedback_route_gh_write label create "conflict-feedback-routed" --repo "$repo_slug" --color "D4C5F9" \
		--description "Worker PR with merge conflicts routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:conflict-feedback" --repo "$repo_slug" --color "E6D8FA" \
		--description "Issue carries conflict context routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true

	# Get the list of files changed in the PR (these are the conflict candidates).
	# Prefer the operation-owned REST helper from the PR gates module; retain an
	# exact REST path for isolated module callers.
	local pr_files
	local fetch_failure="(could not fetch)"
	if declare -F _pulse_merge_pr_file_paths_rest >/dev/null 2>&1; then
		pr_files=$(_pulse_merge_pr_file_paths_rest "$pr_number" "$repo_slug" 2>/dev/null) || pr_files="$fetch_failure"
	else
		pr_files=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-pr-files-rest" \
			gh api --paginate "repos/${repo_slug}/pulls/${pr_number}/files?per_page=100" \
				--jq '.[].filename' 2>/dev/null) || pr_files="$fetch_failure"
	fi

	# File count for scope-leak heuristic (t2802). Rely on the already-fetched
	# file list rather than a second API call — a line count of the joined
	# output matches the files array length when pr_files fetched cleanly.
	local pr_file_count=""
	if [[ -n "$pr_files" ]] && [[ "$pr_files" != "$fetch_failure" ]]; then
		pr_file_count=$(printf '%s\n' "$pr_files" | grep -c '^.' || true)
	fi

	# Snapshot the PR head before finalization so every later write is generation-bound.
	local pr_head_sha
	pr_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_head_sha=""

	# Default branch for the repo. Use gh for the authoritative answer (the
	# pulse may run from a repo path that differs from repo_slug). Fall back
	# to "main" if detection fails — matches pre-t2802 behaviour.
	local default_branch
	default_branch=$(gh repo view "$repo_slug" \
		--json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || default_branch=""
	[[ -n "$default_branch" ]] || default_branch="main"

	local feedback_section
	feedback_section=$(_build_conflict_feedback_section \
		"$pr_number" "$pr_title" "$pr_files" "$pr_head_sha" \
		"$default_branch" "$pr_file_count")

	local marker="<!-- conflict-feedback:PR${pr_number} -->"
	local close_comment="## Merge conflict feedback routed to issue #${linked_issue}

This worker PR had semantic merge conflicts with \`${default_branch}\` that \`update-branch\` could not resolve. The conflict context and file list have been appended to the linked issue body so the next worker can re-implement on top of current \`${default_branch}\`.

_Closed by deterministic merge pass (pulse-merge.sh)._"
	local finalize_rc=0
	_finalize_feedback_route "conflict" "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"source:conflict-feedback" "conflict-feedback-routed" "$marker" "$feedback_section" \
		"_dispatch_conflict_fix_worker" "$close_comment" || finalize_rc=$?
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: routed conflict feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}
