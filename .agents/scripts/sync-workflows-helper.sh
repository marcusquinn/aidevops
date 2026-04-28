#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# sync-workflows-helper.sh — opt-in resync of framework workflows across registered repos.
#
# Phase 2 of workflow drift elimination (t2779, GH#20649).
# Partner to check-workflows-helper.sh (Phase 1, t2778). Reads classifications
# from the detector and, per repo, either installs or refreshes the canonical
# caller template at `.github/workflows/<name>.yml`.
#
# Currently managed workflows (synced by default):
#   - issue-sync.yml         (template: issue-sync-caller.yml)
#   - review-bot-gate.yml    (template: review-bot-gate-caller.yml, GH#20727)
#   - maintainer-gate.yml    (template: maintainer-gate-caller.yml, GH#21154)
#
# Default mode is --dry-run. Pass --apply to actually write, commit, push, and
# open a PR in each target repo.
#
# Design invariants:
#   - Never touch the aidevops repo itself (CURRENT/SELF-CALLER is not drift).
#   - Each repo operation is isolated: its own branch, its own PR, its own
#     commit. No cross-repo atomicity assumed.
#   - Never push directly to main. Always via PR.
#   - Preserve intentional @ref pinning: if the repo's current caller pins a
#     specific ref and the new template's ref would change it, keep the repo's
#     choice unless --force-ref is set.
#   - Skip repos with uncommitted changes. Skip repos that aren't on their
#     default branch. Report both as warnings.
#
# Exit codes:
#   0  all targeted repos processed successfully (or no work needed)
#   1  one or more repos failed (check report for per-repo status)
#   2  config error (repos.json missing, jq unavailable, template missing,
#      check-workflows-helper.sh unavailable)

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
if [[ -f "$SELF_DIR/shared-constants.sh" ]]; then
	source "$SELF_DIR/shared-constants.sh"
fi

# shellcheck source=/dev/null
# gh wrappers inject signature footers and route around GraphQL rate limits.
# Mandatory — this script ships as part of aidevops so the wrappers are
# always available; a missing file indicates a broken install.
if [[ -f "$SELF_DIR/shared-gh-wrappers.sh" ]]; then
	source "$SELF_DIR/shared-gh-wrappers.sh"
else
	printf '[%s] WARN: shared-gh-wrappers.sh not found — PR creation will fail\n' \
		"$SCRIPT_NAME" >&2
fi

# Interpreted escapes — shared-constants.sh uses literal strings which printf
# prints verbatim. Override locally with ANSI-C quoted variants so printf
# emits actual control codes.
_C_GREEN=$'\033[0;32m'
_C_RED=$'\033[0;31m'
_C_YELLOW=$'\033[1;33m'
_C_BLUE=$'\033[0;34m'
_C_NC=$'\033[0m'

readonly REPOS_JSON="$HOME/.config/aidevops/repos.json"
readonly CHECK_HELPER="$SELF_DIR/check-workflows-helper.sh"

# Known managed workflows — each entry is workflow_file:template_file.
# Mirrors _KNOWN_WORKFLOWS in check-workflows-helper.sh.
# GH#20727: review-bot-gate added.
# GH#21154: maintainer-gate added (layer-1 defense-in-depth propagation).
readonly _SYNC_KNOWN_WORKFLOWS=(
	"issue-sync.yml:issue-sync-caller.yml"
	"review-bot-gate.yml:review-bot-gate-caller.yml"
	"maintainer-gate.yml:maintainer-gate-caller.yml"
)

# Output mode constants.
readonly _STATUS_SKIPPED="SKIPPED"
readonly _STATUS_PLANNED="PLANNED"
readonly _STATUS_APPLIED="APPLIED"
readonly _STATUS_FAILED="FAILED"

# Classification labels (must match check-workflows-helper.sh).
readonly _CLASS_DRIFTED='DRIFTED/CALLER'
readonly _CLASS_NEEDS_MIGRATION='NEEDS-MIGRATION'

# Canonical default branch name used in the template and as preflight fallback.
readonly _BRANCH_DEFAULT_NAME="main"

# ─── Helpers ────────────────────────────────────────────────────────────────

_die() {
	local _msg="$1"
	local _code="${2:-2}"
	printf '[%s] %sERROR%s: %s\n' "$SCRIPT_NAME" "$_C_RED" "$_C_NC" "$_msg" >&2
	exit "$_code"
}

_warn() {
	local _msg="$1"
	printf '[%s] %sWARN%s: %s\n' "$SCRIPT_NAME" "$_C_YELLOW" "$_C_NC" "$_msg" >&2
	return 0
}

_info() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

_usage() {
	cat <<'EOF'

sync-workflows-helper.sh — resync drifted framework workflows (t2779, GH#20649)

Reads classifications from check-workflows-helper.sh and, per repo × workflow,
installs (NEEDS-MIGRATION) or refreshes (DRIFTED/CALLER) the canonical caller
template. Managed workflows: issue-sync.yml, review-bot-gate.yml (GH#20727),
maintainer-gate.yml (GH#21154).

Default is --dry-run. Pass --apply to write, commit, push, and open PRs.

Usage:
  sync-workflows-helper.sh [--apply] [--repo OWNER/REPO] [--workflow NAME]
                           [--force-ref] [--ref REF] [--branch NAME] [--json]
  sync-workflows-helper.sh --help

Options:
  --apply           Actually perform the migration. Without this, only prints
                    what would happen (dry-run is the default for safety).
  --repo SLUG       Limit to a single repo. Example: --repo owner/repo.
  --workflow NAME   Limit to a single workflow (issue-sync or review-bot-gate).
  --force-ref       Overwrite existing @ref pinning with the template's default.
                    Without this, existing pins (@v3.9.0, @<sha>) are preserved.
  --ref REF         Explicit @ref for new installs (default: @main).
  --branch NAME     Branch name prefix (default: chore/workflow-sync-YYYYMMDD).
  --json            Emit one JSON object per repo × workflow describing outcome.
  -h, --help        Show this help.

Exit codes:
  0  no work needed OR all targets succeeded
  1  one or more repos failed
  2  config error

Examples:
  # See what would happen across all repos (all workflows):
  sync-workflows-helper.sh

  # Migrate review-bot-gate only for one repo:
  sync-workflows-helper.sh --apply --repo wpallstars/awardsapp --workflow review-bot-gate

  # Migrate all drifted/needs-migration repos, pin to v3.9.0:
  sync-workflows-helper.sh --apply --ref @v3.9.0

EOF
	return 0
}

# ─── Template Resolution ────────────────────────────────────────────────────

# _resolve_canonical_template <template_filename>
# e.g. _resolve_canonical_template "review-bot-gate-caller.yml"
_resolve_canonical_template() {
	local _template_filename="$1"
	local _candidates=(
		"$HOME/.aidevops/agents/templates/workflows/${_template_filename}"
		"$SELF_DIR/../templates/workflows/${_template_filename}"
	)
	local _path
	for _path in "${_candidates[@]}"; do
		if [[ -f "$_path" ]]; then
			printf '%s\n' "$_path"
			return 0
		fi
	done
	return 1
}

# Extract the @ref token from a caller YAML's `uses:` line, e.g. "@main",
# "@v3.9.0", "@<sha>". Empty on failure.
_extract_ref_pin() {
	local _file="$1"
	[[ -f "$_file" ]] || return 0
	grep -oE 'uses:[[:space:]]*[^[:space:]]+@[^[:space:]]+' "$_file" 2>/dev/null |
		head -1 | sed -E 's|.*@([^[:space:]]+)$|@\1|'
	return 0
}

# Render the caller template with a target @ref, writing to stdout.
_render_template_with_ref() {
	local _template="$1"
	local _ref="$2"
	# Escape sed replacement special chars (&, |) before interpolation.
	local _ref_escaped
	_ref_escaped=$(printf '%s' "$_ref" | sed 's/[&|]/\\&/g')
	# Template ships with `@main` by default; rewrite to target ref.
	sed -E 's|(uses:[[:space:]]*marcusquinn/aidevops/.github/workflows/[^@]+)@[^[:space:]]+|\1'"$_ref_escaped"'|' "$_template"
	return 0
}

# Rewrite `branches: [main]` → `branches: [<default_branch>]` in caller YAML content.
# No-op when default branch is `main`. Emits rewritten content on stdout.
# Used after preflight resolves the downstream default branch.
_rewrite_content_branch_filter() {
	local _content="$1"
	local _branch="$2"
	if [[ "$_branch" == "$_BRANCH_DEFAULT_NAME" ]]; then
		printf '%s\n' "$_content"
		return 0
	fi
	local _branch_escaped
	_branch_escaped=$(printf '%s' "$_branch" | sed 's/[&|/]/\\&/g')
	printf '%s\n' "$_content" | \
		sed -E "s|^([[:space:]]+branches:) \[${_BRANCH_DEFAULT_NAME}\]$|\1 [${_branch_escaped}]|"
	return 0
}

# ─── Classification Ingestion ───────────────────────────────────────────────

# Invoke check-workflows-helper.sh --json and filter to actionable rows.
# Emits TSV: slug\tpath\tstatus\tworkflow
# _list_actionable_repos <filter_slug> [filter_workflow]
_list_actionable_repos() {
	local _filter_slug="$1"
	local _filter_workflow="${2:-}"
	local _check_args=(--json)
	[[ -n "$_filter_slug" ]] && _check_args+=(--repo "$_filter_slug")
	[[ -n "$_filter_workflow" ]] && _check_args+=(--workflow "$_filter_workflow")

	# check-workflows-helper.sh exits 1 when actionable rows exist — that is
	# precisely when we have work to do. Capture output regardless of exit.
	local _json
	_json=$("$CHECK_HELPER" "${_check_args[@]}" 2>/dev/null || true)
	if [[ -z "$_json" ]]; then
		return 1
	fi

	# Filter to DRIFTED/CALLER and NEEDS-MIGRATION; carry slug, path,
	# classification, and workflow name so _process_rows can pick the right
	# template for each (repo × workflow) combination.
	# --arg makes the bash constants visible to jq without interpolation hacks.
	printf '%s\n' "$_json" | jq -r \
		--arg drifted "$_CLASS_DRIFTED" \
		--arg needs "$_CLASS_NEEDS_MIGRATION" \
		'select((.classification == $drifted) or (.classification == $needs))
			| [.slug, .path, .classification, (.workflow // "")] | @tsv' 2>/dev/null
	return 0
}

# ─── Message Formatters ─────────────────────────────────────────────────────
# Bash 3.2-safe multi-line body builders (no heredoc inside $()).

# _format_commit_body <status> <ref> <workflow_path>
# shellcheck disable=SC2016  # backticks are intentional markdown literals
_format_commit_body() {
	local _status="$1"
	local _ref="$2"
	local _workflow_path="$3"
	printf 'Resync `%s` to the canonical aidevops caller template.\n\n' "$_workflow_path"
	printf 'Classification before: %s\n' "$_status"
	printf 'Ref: %s\n\n' "$_ref"
	printf 'This migrates/refreshes the workflow to the reusable-workflow pattern.\n'
	printf 'The caller now delegates all logic to the aidevops reusable workflow,\n'
	printf 'eliminating drift between this repo and the framework canonical version.\n\n'
	printf 'Generated by: aidevops sync-workflows --apply\nRef marcusquinn/aidevops#20649\n'
	return 0
}

# _format_pr_body <status> <ref> <workflow_path>
# shellcheck disable=SC2016  # backticks are intentional markdown literals
_format_pr_body() {
	local _status="$1"
	local _ref="$2"
	local _workflow_path="$3"
	printf '## Summary\n\n'
	printf 'Resync `%s` to the canonical aidevops caller template\n' "$_workflow_path"
	printf '(reusable-workflow pattern, GH#20649 + GH#20727).\n\n'
	printf '**Classification before**: `%s`\n' "$_status"
	printf '**Ref**: `%s`\n\n' "$_ref"
	printf '## Why\n\n'
	printf 'The aidevops framework ships managed GitHub Actions workflows as reusable\n'
	printf 'workflows. Downstream repos carry ~45-line callers that delegate all logic\n'
	printf 'to `marcusquinn/aidevops/.github/workflows/*-reusable.yml`.\n\n'
	printf 'This PR brings this repo in line with the canonical template, eliminating\n'
	printf 'drift and unblocking automatic updates when the framework evolves.\n\n'
	printf '## How to verify\n\n'
	printf 'After merge, trigger an event matching the workflow triggers. Framework\n'
	printf 'scripts are fetched at runtime via a secondary checkout — no\n'
	printf '`.agents/scripts/` files are needed in this repo.\n\n'
	printf '## Rollback\n\n'
	printf 'If the workflow breaks, revert this PR. The previous workflow is preserved\n'
	printf 'in git history at the parent commit.\n\n'
	printf 'Generated by: `aidevops sync-workflows --apply` (see marcusquinn/aidevops#20649).\n'
	return 0
}

# ─── Per-Repo Operation ─────────────────────────────────────────────────────

# _resolve_effective_ref <status> <workflow_path> <target_ref> <force_ref>
# Emits the ref to use for the sync (preserves pin for DRIFTED unless forced).
_resolve_effective_ref() {
	local _status="$1"
	local _workflow="$2"
	local _target_ref="$3"
	local _force_ref="$4"
	local _effective_ref="$_target_ref"
	if [[ "$_status" == "$_CLASS_DRIFTED" && "$_force_ref" -eq 0 ]]; then
		local _existing_pin
		_existing_pin=$(_extract_ref_pin "$_workflow")
		if [[ -n "$_existing_pin" ]]; then
			_effective_ref="$_existing_pin"
		fi
	fi
	printf '%s\n' "$_effective_ref"
	return 0
}

# _sync_dryrun_emit <slug> <status> <effective_ref> [workflow_relpath]
_sync_dryrun_emit() {
	local _slug="$1"
	local _status="$2"
	local _effective_ref="$3"
	local _workflow_relpath="${4:-.github/workflows/issue-sync.yml}"
	local _action="install"
	[[ "$_status" == "$_CLASS_DRIFTED" ]] && _action="refresh"
	printf '%s\t%s\t%s\t%s → %s at ref %s\n' \
		"$_slug" "$_status" "$_STATUS_PLANNED" "$_action" "$_workflow_relpath" "$_effective_ref"
	return 0
}

# _sync_preflight <slug> <path> <status> <default_branch_out>
# Validates repo precondition and clean-tree/branch state.
# Returns 0 proceed; 1 fail; 2 skip. Sets _PREFLIGHT_DEFAULT_BRANCH on proceed.
_sync_preflight() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"

	if [[ ! -d "$_path" ]]; then
		printf '%s\t%s\t%s\trepo directory missing: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	if [[ ! -d "$_path/.git" ]]; then
		printf '%s\t%s\t%s\tnot a git repo: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	local _default_branch
	_default_branch=$(git -C "$_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
	[[ -z "$_default_branch" ]] && _default_branch="$_BRANCH_DEFAULT_NAME"
	if ! git -C "$_path" diff-index --quiet HEAD -- 2>/dev/null; then
		printf '%s\t%s\t%s\tworking tree not clean; skipping\n' "$_slug" "$_status" "$_STATUS_SKIPPED"
		return 2
	fi
	local _current_branch
	_current_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
	if [[ "$_current_branch" != "$_default_branch" ]]; then
		printf '%s\t%s\t%s\ton %s, expected %s; skipping\n' \
			"$_slug" "$_status" "$_STATUS_SKIPPED" "$_current_branch" "$_default_branch"
		return 2
	fi
	_PREFLIGHT_DEFAULT_BRANCH="$_default_branch"
	return 0
}

# _sync_write_commit_push <slug> <path> <status> <branch> <default_branch> <effective_ref> <content> [workflow_relpath]
_sync_write_commit_push() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _branch_name="$4"
	local _default_branch="$5"
	local _effective_ref="$6"
	local _target_content="$7"
	local _workflow_relpath="${8:-.github/workflows/issue-sync.yml}"
	local _workflow="$_path/$_workflow_relpath"

	if ! git -C "$_path" pull --ff-only origin "$_default_branch" >/dev/null 2>&1; then
		_warn "$_slug: pull --ff-only failed, attempting without"
	fi
	if ! git -C "$_path" checkout -q -B "$_branch_name" "$_default_branch"; then
		printf '%s\t%s\t%s\tbranch create/reset failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	mkdir -p "$_path/.github/workflows"
	printf '%s\n' "$_target_content" >"$_workflow"
	git -C "$_path" add "$_workflow_relpath" >/dev/null 2>&1
	local _commit_subject="chore: resync framework workflow ($_status → CURRENT/CALLER)"
	local _commit_body
	_commit_body=$(_format_commit_body "$_status" "$_effective_ref" "$_workflow_relpath")
	if ! git -C "$_path" diff --cached --quiet; then
		if ! git -C "$_path" commit -q -m "$_commit_subject" -m "$_commit_body"; then
			printf '%s\t%s\t%s\tgit commit failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
			# Return to default branch on failure so subsequent runs are clean.
			git -C "$_path" checkout -q "$_default_branch" || true
			return 1
		fi
	fi
	if ! git -C "$_path" push -u origin "$_branch_name" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgit push failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	return 0
}

# _sync_open_pr <slug> <path> <status> <branch> <default_branch> <effective_ref> [workflow_relpath]
_sync_open_pr() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _branch_name="$4"
	local _default_branch="$5"
	local _effective_ref="$6"
	local _workflow_relpath="${7:-.github/workflows/issue-sync.yml}"

	if ! command -v gh_create_pr >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgh_create_pr unavailable — source shared-gh-wrappers.sh\n' \
			"$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi
	local _pr_title="chore: resync framework workflow to aidevops canonical caller"
	local _pr_body
	_pr_body=$(_format_pr_body "$_status" "$_effective_ref" "$_workflow_relpath")
	local _pr_url
	if ! _pr_url=$(gh_create_pr \
		--repo "$_slug" \
		--title "$_pr_title" \
		--body "$_pr_body" \
		--head "$_branch_name" \
		--base "$_default_branch" 2>&1); then
		printf '%s\t%s\t%s\tgh_create_pr failed: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_pr_url"
		return 1
	fi
	git -C "$_path" checkout "$_default_branch" >/dev/null 2>&1 || true
	printf '%s\t%s\t%s\tPR: %s\n' "$_slug" "$_status" "$_STATUS_APPLIED" "$_pr_url"
	return 0
}

# _sync_one_repo <slug> <path> <status> <template_path> <target_ref> <force_ref> <branch_name> <apply> <workflow_relpath>
# Emits a single-line summary; returns 0 on success, 1 on failure.
# workflow_relpath — path relative to repo root e.g. .github/workflows/review-bot-gate.yml
_sync_one_repo() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _template="$4"
	local _target_ref="$5"
	local _force_ref="$6"
	local _branch_name="$7"
	local _apply="$8"
	local _workflow_relpath="${9:-.github/workflows/issue-sync.yml}"

	local _workflow="$_path/$_workflow_relpath"
	local _effective_ref
	_effective_ref=$(_resolve_effective_ref "$_status" "$_workflow" "$_target_ref" "$_force_ref")

	local _target_content
	if ! _target_content=$(_render_template_with_ref "$_template" "$_effective_ref"); then
		printf '%s\t%s\t%s\ttemplate render failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi

	if [[ "$_apply" -eq 0 ]]; then
		_sync_dryrun_emit "$_slug" "$_status" "$_effective_ref"
		return 0
	fi

	_PREFLIGHT_DEFAULT_BRANCH=""
	local _pf_rc
	_sync_preflight "$_slug" "$_path" "$_status"
	_pf_rc=$?
	if [[ "$_pf_rc" -ne 0 ]]; then
		# 1=failed (already emitted), 2=skipped (already emitted as SKIPPED).
		[[ "$_pf_rc" -eq 2 ]] && return 0
		return 1
	fi
	local _default_branch="$_PREFLIGHT_DEFAULT_BRANCH"

	# Rewrite branch filter to match downstream default branch (e.g. develop → develop).
	if [[ "$_default_branch" != "$_BRANCH_DEFAULT_NAME" ]]; then
		_target_content=$(_rewrite_content_branch_filter "$_target_content" "$_default_branch")
	fi

	if ! _sync_write_commit_push \
		"$_slug" "$_path" "$_status" "$_branch_name" \
		"$_default_branch" "$_effective_ref" "$_target_content" "$_workflow_relpath"; then
		return 1
	fi

	_sync_open_pr \
		"$_slug" "$_path" "$_status" "$_branch_name" \
		"$_default_branch" "$_effective_ref" "$_workflow_relpath"
	return $?
}

# ─── Main ───────────────────────────────────────────────────────────────────

# ─── Arg Parsing & Output ───────────────────────────────────────────────────

# _parse_args "$@"  → sets package-level _OPT_* variables.
_parse_args() {
	_OPT_APPLY=0
	_OPT_FILTER_SLUG=""
	_OPT_FILTER_WORKFLOW=""
	_OPT_FORCE_REF=0
	_OPT_TARGET_REF="@main"
	_OPT_BRANCH_NAME=""
	_OPT_JSON=0
	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--apply) _OPT_APPLY=1; shift ;;
		--repo) _OPT_FILTER_SLUG="${2:-}"; shift 2 || _die "--repo requires an argument" ;;
		--workflow) _OPT_FILTER_WORKFLOW="${2:-}"; shift 2 || _die "--workflow requires an argument" ;;
		--force-ref) _OPT_FORCE_REF=1; shift ;;
		--ref)
			_OPT_TARGET_REF="${2:-}"
			[[ -z "$_OPT_TARGET_REF" ]] && _die "--ref requires an argument"
			[[ "$_OPT_TARGET_REF" != @* ]] && _OPT_TARGET_REF="@$_OPT_TARGET_REF"
			shift 2 ;;
		--branch) _OPT_BRANCH_NAME="${2:-}"; shift 2 || _die "--branch requires an argument" ;;
		--json) _OPT_JSON=1; shift ;;
		-h | --help) _usage; exit 0 ;;
		*) _die "unknown option: $_opt" ;;
		esac
	done
	return 0
}

# _print_result_row <json> <target_ref> <branch> <result_tsv>
_print_result_row() {
	local _json="$1"
	local _target_ref="$2"
	local _branch_name="$3"
	local _result="$4"
	local _r_slug _r_status _r_outcome _r_detail
	IFS=$'\t' read -r _r_slug _r_status _r_outcome _r_detail <<<"$_result"
	if [[ "$_json" -eq 1 ]]; then
		jq -cn --arg slug "$_r_slug" --arg status "$_r_status" \
			--arg outcome "$_r_outcome" --arg detail "$_r_detail" \
			--arg ref "$_target_ref" --arg branch "$_branch_name" \
			'{slug:$slug, classification:$status, outcome:$outcome, detail:$detail, ref:$ref, branch:$branch}'
		return 0
	fi
	local _colour="$_C_BLUE"
	case "$_r_outcome" in
	"$_STATUS_APPLIED") _colour="$_C_GREEN" ;;
	"$_STATUS_FAILED") _colour="$_C_RED" ;;
	"$_STATUS_SKIPPED") _colour="$_C_YELLOW" ;;
	esac
	printf '  %-40s %-20s %s%-10s%s %s\n' \
		"$_r_slug" "$_r_status" "$_colour" "$_r_outcome" "$_C_NC" "$_r_detail"
	return 0
}

# _process_rows <tsv> → iterates, resolves per-workflow template, calls _sync_one_repo.
# TSV columns: slug\tpath\tstatus\tworkflow_name
# Returns the number of failures (0 if all ok).
_process_rows() {
	local _tsv="$1"
	local _any_failed=0
	local _slug _path _status _workflow_name
	while IFS=$'\t' read -r _slug _path _status _workflow_name; do
		[[ -z "$_slug" ]] && continue
		# Never touch aidevops itself (defence in depth; Phase 1 also emits
		# CURRENT/SELF-CALLER).
		[[ "$_slug" == "marcusquinn/aidevops" ]] && continue

		# Resolve the template for this workflow.
		# _workflow_name is the short name (e.g. "issue-sync" or "review-bot-gate").
		# Map it to the template filename.
		local _workflow_file="${_workflow_name}.yml"
		local _template_file="${_workflow_name}-caller.yml"
		local _workflow_relpath=".github/workflows/${_workflow_file}"
		local _template=""
		if ! _template=$(_resolve_canonical_template "$_template_file"); then
			_warn "$_slug: cannot resolve template for workflow '${_workflow_name}' — skipping"
			continue
		fi

		local _result
		if _result=$(_sync_one_repo \
			"$_slug" "$_path" "$_status" "$_template" \
			"$_OPT_TARGET_REF" "$_OPT_FORCE_REF" "$_OPT_BRANCH_NAME" "$_OPT_APPLY" \
			"$_workflow_relpath"); then
			:
		else
			_any_failed=1
		fi

		case "$(printf '%s' "$_result" | awk -F'\t' '{print $3}')" in
		"$_STATUS_APPLIED") ((_COUNT_APPLIED++)) ;;
		"$_STATUS_PLANNED") ((_COUNT_PLANNED++)) ;;
		"$_STATUS_SKIPPED") ((_COUNT_SKIPPED++)) ;;
		esac
		_print_result_row "$_OPT_JSON" "$_OPT_TARGET_REF" "$_OPT_BRANCH_NAME" "$_result"
	done <<<"$_tsv"
	return "$_any_failed"
}

# _print_header_footer <phase: header|footer> <apply>
_print_header_footer() {
	local _phase="$1"
	local _apply="$2"
	if [[ "$_OPT_JSON" -eq 1 ]]; then
		return 0
	fi
	if [[ "$_phase" == "header" ]]; then
		printf '\n'
		printf '  %-40s %-20s %-10s %s\n' "REPO" "CLASSIFICATION" "ACTION" "DETAIL"
		printf '  %s\n' "──────────────────────────────────────────────────────────────────────────────────"
		return 0
	fi
	printf '\n'
	if [[ "$_apply" -eq 0 ]]; then
		_info "dry-run: $_COUNT_PLANNED planned, $_COUNT_SKIPPED skipped. Re-run with --apply to migrate."
	else
		_info "applied: $_COUNT_APPLIED; skipped: $_COUNT_SKIPPED."
	fi
	printf '\n'
	return 0
}

main() {
	_parse_args "$@"

	# Preconditions.
	[[ -f "$REPOS_JSON" ]] || _die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	command -v jq >/dev/null 2>&1 || _die "jq required — install via Homebrew/apt"
	[[ -x "$CHECK_HELPER" ]] || _die "check-workflows-helper.sh not found or not executable at $CHECK_HELPER"

	if [[ -z "$_OPT_BRANCH_NAME" ]]; then
		_OPT_BRANCH_NAME="chore/workflow-sync-$(date +%Y%m%d)"
	fi

	local _tsv
	if ! _tsv=$(_list_actionable_repos "$_OPT_FILTER_SLUG" "$_OPT_FILTER_WORKFLOW"); then
		_die "check-workflows-helper.sh failed — cannot classify repos"
	fi
	if [[ -z "$_tsv" ]]; then
		_info "no actionable repos/workflows (all CURRENT or NO-WORKFLOW)."
		return 0
	fi

	_COUNT_APPLIED=0
	_COUNT_PLANNED=0
	_COUNT_SKIPPED=0

	_print_header_footer "header" "$_OPT_APPLY"
	local _any_failed=0
	_process_rows "$_tsv" || _any_failed=1
	_print_header_footer "footer" "$_OPT_APPLY"

	return "$_any_failed"
}

main "$@"
