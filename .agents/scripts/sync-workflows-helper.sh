#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# sync-workflows-helper.sh — opt-in resync of framework workflows across registered repos.
#
# Phase 2 of workflow drift elimination (t2779, GH#20649).
# Partner to check-workflows-helper.sh (Phase 1, t2778). Reads classifications
# from the detector and, per repo, either installs or refreshes the canonical
# caller template at `.github/workflows/issue-sync.yml`.
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
# We use gh_create_pr when available; fallback to raw gh pr create if the
# helper isn't deployed (e.g. standalone invocation during dev).
if [[ -f "$SELF_DIR/shared-gh-wrappers.sh" ]]; then
	source "$SELF_DIR/shared-gh-wrappers.sh"
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
readonly WORKFLOW_PATH=".github/workflows/issue-sync.yml"

# Output mode constants.
readonly _STATUS_SKIPPED="SKIPPED"
readonly _STATUS_PLANNED="PLANNED"
readonly _STATUS_APPLIED="APPLIED"
readonly _STATUS_FAILED="FAILED"

# Classification labels (must match check-workflows-helper.sh).
readonly _CLASS_DRIFTED='DRIFTED/CALLER'
readonly _CLASS_NEEDS_MIGRATION='NEEDS-MIGRATION'

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

Reads classifications from check-workflows-helper.sh and, per repo, installs
(NEEDS-MIGRATION) or refreshes (DRIFTED/CALLER) the canonical caller template
at `.github/workflows/issue-sync.yml`.

Default is --dry-run. Pass --apply to write, commit, push, and open PRs.

Usage:
  sync-workflows-helper.sh [--apply] [--repo OWNER/REPO] [--force-ref]
                           [--ref REF] [--branch NAME] [--json]
  sync-workflows-helper.sh --help

Options:
  --apply         Actually perform the migration. Without this, only prints
                  what would happen (dry-run is the default for safety).
  --repo SLUG     Limit to a single repo. Example: --repo owner/repo.
  --force-ref     Overwrite existing @ref pinning with the template's default.
                  Without this, existing pins (@v3.9.0, @<sha>) are preserved.
  --ref REF       Explicit @ref for new installs (default: @main).
  --branch NAME   Branch name prefix (default: chore/workflow-sync-YYYYMMDD).
  --json          Emit one JSON object per repo describing the outcome.
  -h, --help      Show this help.

Exit codes:
  0  no work needed OR all targets succeeded
  1  one or more repos failed
  2  config error

Examples:
  # See what would happen across all repos:
  sync-workflows-helper.sh

  # Migrate one specific repo:
  sync-workflows-helper.sh --apply --repo wpallstars/awardsapp

  # Migrate all drifted/needs-migration repos, pin to v3.9.0:
  sync-workflows-helper.sh --apply --ref @v3.9.0

EOF
	return 0
}

# ─── Template Resolution ────────────────────────────────────────────────────

_resolve_canonical_template() {
	local _candidates=(
		"$HOME/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
		"$SELF_DIR/../templates/workflows/issue-sync-caller.yml"
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
	# Template ships with `@main` by default; rewrite to target ref.
	sed -E 's|(uses:[[:space:]]*marcusquinn/aidevops/.github/workflows/[^@]+)@[^[:space:]]+|\1'"$_ref"'|' "$_template"
	return 0
}

# ─── Classification Ingestion ───────────────────────────────────────────────

# Invoke check-workflows-helper.sh --json and filter to actionable rows.
# Emits TSV: slug\tpath\tstatus\tref_pin
_list_actionable_repos() {
	local _filter_slug="$1"
	local _check_args=(--json)
	[[ -n "$_filter_slug" ]] && _check_args+=(--repo "$_filter_slug")

	# check-workflows-helper.sh exits 1 when actionable rows exist — that is
	# precisely when we have work to do. Capture output regardless of exit.
	local _json
	_json=$("$CHECK_HELPER" "${_check_args[@]}" 2>/dev/null || true)
	if [[ -z "$_json" ]]; then
		return 1
	fi

	# Filter to DRIFTED/CALLER and NEEDS-MIGRATION; carry slug, path, classification.
	# --arg makes the bash constants visible to jq without interpolation hacks.
	printf '%s\n' "$_json" | jq -r \
		--arg drifted "$_CLASS_DRIFTED" \
		--arg needs "$_CLASS_NEEDS_MIGRATION" \
		'select((.classification == $drifted) or (.classification == $needs))
			| [.slug, .path, .classification, ""] | @tsv' 2>/dev/null
	return 0
}

# ─── Per-Repo Operation ─────────────────────────────────────────────────────

# _sync_one_repo <slug> <path> <status> <template_path> <target_ref> <force_ref> <branch_name> <apply>
# Emits a single-line summary; returns 0 on success, 1 on failure.
_sync_one_repo() {
	local _slug="$1"
	local _path="$2"
	local _status="$3"
	local _template="$4"
	local _target_ref="$5"
	local _force_ref="$6"
	local _branch_name="$7"
	local _apply="$8"

	local _workflow="$_path/$WORKFLOW_PATH"

	# Determine the ref to use:
	#   - NEEDS-MIGRATION: use target_ref (no existing pin).
	#   - DRIFTED/CALLER: preserve existing pin unless --force-ref.
	local _effective_ref="$_target_ref"
	if [[ "$_status" == "$_CLASS_DRIFTED" && "$_force_ref" -eq 0 ]]; then
		local _existing_pin
		_existing_pin=$(_extract_ref_pin "$_workflow")
		if [[ -n "$_existing_pin" ]]; then
			_effective_ref="$_existing_pin"
		fi
	fi

	# Render target content once — used for diff (dry-run) or write (apply).
	local _target_content
	if ! _target_content=$(_render_template_with_ref "$_template" "$_effective_ref"); then
		printf '%s\t%s\t%s\ttemplate render failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi

	if [[ "$_apply" -eq 0 ]]; then
		# Dry-run: report planned action. No git preconditions needed — we're
		# not touching the repo.
		local _action="install"
		[[ "$_status" == "$_CLASS_DRIFTED" ]] && _action="refresh"
		printf '%s\t%s\t%s\t%s → %s at ref %s\n' \
			"$_slug" "$_status" "$_STATUS_PLANNED" "$_action" "$WORKFLOW_PATH" "$_effective_ref"
		return 0
	fi

	# Apply mode preconditions: repo directory exists, is a git repo.
	if [[ ! -d "$_path" ]]; then
		printf '%s\t%s\t%s\trepo directory missing: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi
	if [[ ! -d "$_path/.git" ]]; then
		printf '%s\t%s\t%s\tnot a git repo: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_path"
		return 1
	fi

	# Apply mode: branch, write, commit, push, PR.
	local _default_branch
	_default_branch=$(git -C "$_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
	[[ -z "$_default_branch" ]] && _default_branch="main"

	# Check working tree is clean.
	if ! git -C "$_path" diff-index --quiet HEAD -- 2>/dev/null; then
		printf '%s\t%s\t%s\tworking tree not clean; skipping\n' "$_slug" "$_status" "$_STATUS_SKIPPED"
		return 0
	fi

	# Check we're on the default branch.
	local _current_branch
	_current_branch=$(git -C "$_path" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
	if [[ "$_current_branch" != "$_default_branch" ]]; then
		printf '%s\t%s\t%s\ton %s, expected %s; skipping\n' \
			"$_slug" "$_status" "$_STATUS_SKIPPED" "$_current_branch" "$_default_branch"
		return 0
	fi

	# Pull latest to reduce conflict risk, then branch.
	if ! git -C "$_path" pull --ff-only origin "$_default_branch" >/dev/null 2>&1; then
		_warn "$_slug: pull --ff-only failed, attempting without"
	fi

	if ! git -C "$_path" checkout -b "$_branch_name" >/dev/null 2>&1; then
		# Branch may exist from prior attempt; try checkout.
		if ! git -C "$_path" checkout "$_branch_name" >/dev/null 2>&1; then
			printf '%s\t%s\t%s\tbranch create/checkout failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
			return 1
		fi
	fi

	# Write the workflow file.
	mkdir -p "$_path/.github/workflows"
	printf '%s\n' "$_target_content" >"$_workflow"

	# Commit.
	git -C "$_path" add "$WORKFLOW_PATH" >/dev/null 2>&1
	local _commit_subject="chore: resync framework workflow ($_status → CURRENT/CALLER)"
	local _commit_body
	_commit_body=$(cat <<EOF
Resync \`$WORKFLOW_PATH\` to the canonical aidevops caller template.

Classification before: $_status
Ref: $_effective_ref

This migrates/refreshes the workflow to the reusable-workflow pattern
introduced in aidevops v3.9.0. The caller now delegates all logic to
\`marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml\`,
eliminating drift between this repo and the framework canonical version.

Generated by: aidevops sync-workflows --apply (t2779, GH#20649)
EOF
)
	if ! git -C "$_path" commit -m "$_commit_subject" -m "$_commit_body" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgit commit failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		# Return to default branch on failure so subsequent runs are clean.
		git -C "$_path" checkout "$_default_branch" >/dev/null 2>&1 || true
		return 1
	fi

	# Push.
	if ! git -C "$_path" push -u origin "$_branch_name" >/dev/null 2>&1; then
		printf '%s\t%s\t%s\tgit push failed\n' "$_slug" "$_status" "$_STATUS_FAILED"
		return 1
	fi

	# Open PR. Use gh directly (sig footer auto-injected via shim).
	local _pr_title="chore: resync framework workflow to aidevops canonical caller"
	local _pr_body
	_pr_body=$(cat <<EOF
## Summary

Resync \`$WORKFLOW_PATH\` to the canonical aidevops caller template
(v3.9.0+, reusable-workflow pattern).

**Classification before**: \`$_status\`
**Ref**: \`$_effective_ref\`

## Why

The aidevops framework migrated \`issue-sync.yml\` from a full-copy workflow
to a reusable-workflow pattern in v3.9.0. Downstream repos now carry a ~45-line
caller that delegates to \`marcusquinn/aidevops/.github/workflows/issue-sync-reusable.yml\`.

This PR brings this repo in line with the canonical template, eliminating
drift and unblocking automatic updates when the framework evolves.

## How to verify

After merge, the next \`TODO.md\` push should trigger issue-sync using the
reusable workflow. Framework shell scripts are fetched at runtime via a
secondary checkout — no \`.agents/scripts/\` files are needed in this repo.

## Rollback

If issue-sync breaks, revert this PR. The previous workflow is preserved in
git history at the parent commit.

Generated by: \`aidevops sync-workflows --apply\` (t2779, GH#20649).
EOF
)

	# Use the wrapper if sourced (auto-injects sig footer, rate-limit routing).
	# Fallback to raw gh pr create for standalone invocation during dev.
	local _pr_url
	if command -v gh_create_pr >/dev/null 2>&1; then
		if ! _pr_url=$(gh_create_pr \
			--repo "$_slug" \
			--title "$_pr_title" \
			--body "$_pr_body" \
			--head "$_branch_name" \
			--base "$_default_branch" 2>&1); then
			printf '%s\t%s\t%s\tgh_create_pr failed: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_pr_url"
			return 1
		fi
	else
		if ! _pr_url=$(gh pr create \
			--repo "$_slug" \
			--title "$_pr_title" \
			--body "$_pr_body" \
			--head "$_branch_name" \
			--base "$_default_branch" 2>&1); then
			printf '%s\t%s\t%s\tgh pr create failed: %s\n' "$_slug" "$_status" "$_STATUS_FAILED" "$_pr_url"
			return 1
		fi
	fi

	# Return to default branch in the target repo so the path isn't left on
	# a feature branch.
	git -C "$_path" checkout "$_default_branch" >/dev/null 2>&1 || true

	printf '%s\t%s\t%s\tPR: %s\n' "$_slug" "$_status" "$_STATUS_APPLIED" "$_pr_url"
	return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
	local _apply=0
	local _filter_slug=""
	local _force_ref=0
	local _target_ref="@main"
	local _branch_name=""
	local _json=0

	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--apply)
			_apply=1
			shift
			;;
		--repo)
			_filter_slug="${2:-}"
			shift 2 || _die "--repo requires an argument"
			;;
		--force-ref)
			_force_ref=1
			shift
			;;
		--ref)
			_target_ref="${2:-}"
			[[ -z "$_target_ref" ]] && _die "--ref requires an argument"
			# Normalise: if user passed "main", rewrite to "@main".
			[[ "$_target_ref" != @* ]] && _target_ref="@$_target_ref"
			shift 2
			;;
		--branch)
			_branch_name="${2:-}"
			shift 2 || _die "--branch requires an argument"
			;;
		--json)
			_json=1
			shift
			;;
		-h | --help)
			_usage
			exit 0
			;;
		*)
			_die "unknown option: $_opt"
			;;
		esac
	done

	# Preconditions.
	[[ -f "$REPOS_JSON" ]] || _die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	command -v jq >/dev/null 2>&1 || _die "jq required — install via Homebrew/apt"
	[[ -x "$CHECK_HELPER" ]] || _die "check-workflows-helper.sh not found or not executable at $CHECK_HELPER"

	local _template
	if ! _template=$(_resolve_canonical_template); then
		_die "canonical template issue-sync-caller.yml not found — check aidevops installation"
	fi

	# Default branch name: chore/workflow-sync-YYYYMMDD.
	if [[ -z "$_branch_name" ]]; then
		_branch_name="chore/workflow-sync-$(date +%Y%m%d)"
	fi

	# Ingest classification from Phase 1 helper.
	local _tsv
	if ! _tsv=$(_list_actionable_repos "$_filter_slug"); then
		_die "check-workflows-helper.sh failed — cannot classify repos"
	fi

	if [[ -z "$_tsv" ]]; then
		_info "no actionable repos (all CURRENT or NO-WORKFLOW)."
		return 0
	fi

	# Header.
	if [[ "$_json" -eq 0 ]]; then
		printf '\n'
		printf '  %-40s %-20s %-10s %s\n' "REPO" "CLASSIFICATION" "ACTION" "DETAIL"
		printf '  %s\n' "──────────────────────────────────────────────────────────────────────────────────"
	fi

	local _any_failed=0
	local _any_applied=0
	local _any_planned=0
	local _any_skipped=0

	local _slug _path _status _ref_pin
	while IFS=$'\t' read -r _slug _path _status _ref_pin; do
		[[ -z "$_slug" ]] && continue

		# Never touch aidevops itself; check-workflows-helper already emits
		# CURRENT/SELF-CALLER for it, but guard anyway.
		if [[ "$_slug" == "marcusquinn/aidevops" ]]; then
			continue
		fi

		local _result
		if _result=$(_sync_one_repo \
			"$_slug" "$_path" "$_status" "$_template" \
			"$_target_ref" "$_force_ref" "$_branch_name" "$_apply"); then
			:
		else
			_any_failed=1
		fi

		# Parse the result line (slug\tstatus\toutcome\tdetail).
		local _r_slug _r_status _r_outcome _r_detail
		IFS=$'\t' read -r _r_slug _r_status _r_outcome _r_detail <<<"$_result"

		case "$_r_outcome" in
		"$_STATUS_APPLIED") ((_any_applied++)) ;;
		"$_STATUS_PLANNED") ((_any_planned++)) ;;
		"$_STATUS_SKIPPED") ((_any_skipped++)) ;;
		esac

		if [[ "$_json" -eq 1 ]]; then
			jq -cn --arg slug "$_r_slug" --arg status "$_r_status" \
				--arg outcome "$_r_outcome" --arg detail "$_r_detail" \
				--arg ref "$_target_ref" --arg branch "$_branch_name" \
				'{slug:$slug, classification:$status, outcome:$outcome, detail:$detail, ref:$ref, branch:$branch}'
		else
			local _colour="$_C_BLUE"
			case "$_r_outcome" in
			"$_STATUS_APPLIED") _colour="$_C_GREEN" ;;
			"$_STATUS_FAILED") _colour="$_C_RED" ;;
			"$_STATUS_SKIPPED") _colour="$_C_YELLOW" ;;
			esac
			printf '  %-40s %-20s %s%-10s%s %s\n' \
				"$_r_slug" "$_r_status" "$_colour" "$_r_outcome" "$_C_NC" "$_r_detail"
		fi
	done <<<"$_tsv"

	if [[ "$_json" -eq 0 ]]; then
		printf '\n'
		if [[ "$_apply" -eq 0 ]]; then
			_info "dry-run: $_any_planned planned, $_any_skipped skipped. Re-run with --apply to migrate."
		else
			_info "applied: $_any_applied; skipped: $_any_skipped; failed: $_any_failed."
		fi
		printf '\n'
	fi

	return "$_any_failed"
}

main "$@"
