#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# check-workflows-helper.sh — detect framework workflow drift across registered repos (t2778, GH#20648)
#
# Compares each registered repo's `.github/workflows/issue-sync.yml` against the
# canonical caller template at `.agents/templates/workflows/issue-sync-caller.yml`.
# Classifies each repo as:
#
#   CURRENT/CALLER      — byte-identical to canonical (up to @ref pin variance)
#   CURRENT/SELF-CALLER — aidevops itself: uses `./.github/workflows/...` instead of remote ref
#   DRIFTED/CALLER      — uses the reusable workflow but caller YAML has diverged
#   NEEDS-MIGRATION     — legacy full-copy workflow, no `uses:` → should adopt caller pattern
#   NO-WORKFLOW         — no `issue-sync.yml` present (repo doesn't sync TODO ↔ issues)
#   LOCAL-ONLY          — repo has `local_only: true`, no remote to check
#   NO-TEMPLATE         — canonical template missing; helper cannot classify
#
# Usage:
#   check-workflows-helper.sh [--repo OWNER/REPO] [--json] [--verbose]
#   check-workflows-helper.sh --help
#
# Options:
#   --repo OWNER/REPO   Check only the named slug (default: all registered)
#   --json              Machine-readable output (one JSON object per repo)
#   --verbose           Show diff summary for DRIFTED/CALLER entries
#   -h, --help          Show usage and exit 0
#
# Exit codes:
#   0  — all checked repos are CURRENT/CALLER, NO-WORKFLOW, or LOCAL-ONLY
#   1  — one or more repos are DRIFTED/CALLER or NEEDS-MIGRATION
#   2  — configuration or IO error (repos.json missing, template missing, jq unavailable)
#
# Why this exists:
#   Before the reusable-workflow architecture (t2770), every aidevops-enabled repo
#   carried a full copy of issue-sync.yml (~1300 lines) and the `.agents/scripts/`
#   helpers those workflows depended on. Fixes landed upstream never propagated.
#   Three known-drifted repos surfaced GH#20637 before this gap was closed.
#
#   After t2770, downstream repos ship a ~45-line caller that points at the
#   aidevops reusable workflow. This helper detects which repos still use the
#   legacy full-copy pattern (NEEDS-MIGRATION) and which caller YAMLs have
#   diverged from the canonical template (DRIFTED/CALLER).
#
#   Phase 2 (`aidevops sync-workflows --apply`) will migrate or refresh callers
#   based on this helper's classification.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")

# ─── Path resolution ────────────────────────────────────────────────────────

# Canonical template — prefer deployed copy, fall back to the repo checkout
_resolve_canonical_template() {
	local _deployed="$HOME/.aidevops/agents/templates/workflows/issue-sync-caller.yml"
	local _self_dir
	_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null) || _self_dir=""
	local _repo_local="$_self_dir/../templates/workflows/issue-sync-caller.yml"

	if [[ -f "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -n "$_self_dir" && -f "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

REPOS_JSON="$HOME/.config/aidevops/repos.json"

# ─── Logging ────────────────────────────────────────────────────────────────

_log() {
	local _msg="$1"
	printf '[%s] %s\n' "$SCRIPT_NAME" "$_msg" >&2
	return 0
}

_die() {
	local _msg="$1"
	local _code="${2:-2}"
	printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$_msg" >&2
	exit "$_code"
}

_usage() {
	sed -n '4,38p' "$0" | sed 's/^# \{0,1\}//'
	return 0
}

# ─── Classification ─────────────────────────────────────────────────────────

# _classify_workflow <workflow-file> <canonical-template>
# Prints the classification string on stdout.
# Returns 0 always; status is carried via the emitted string.
_classify_workflow() {
	local _wf="$1"
	local _canon="$2"

	if [[ ! -f "$_wf" ]]; then
		printf 'NO-WORKFLOW\n'
		return 0
	fi

	# Detect self-caller (aidevops itself) — uses: ./.github/workflows/...
	# This is the intended pattern for the aidevops repo and must not be flagged
	# as drift. The self-caller is functionally equivalent to the downstream
	# pattern; it just skips the cross-repo checkout.
	if grep -qE "uses:\s*\./\.github/workflows/issue-sync-reusable\.yml" "$_wf"; then
		printf 'CURRENT/SELF-CALLER\n'
		return 0
	fi

	# Detect caller pattern: any `uses:` line pointing at the reusable workflow.
	# Accept any `@<ref>` variant (main, v3.9.0, a commit SHA, etc).
	if grep -qE "uses:\s*marcusquinn/aidevops/\.github/workflows/issue-sync-reusable\.yml@" "$_wf"; then
		# It's a caller. Compare against canonical, normalising the @ref so that
		# `@main` vs `@v3.9.0` doesn't count as drift (intentional pinning is OK).
		local _wf_norm _canon_norm
		_wf_norm=$(sed -E 's|(marcusquinn/aidevops/\.github/workflows/issue-sync-reusable\.yml)@[^[:space:]]+|\1@REF|g' "$_wf")
		_canon_norm=$(sed -E 's|(marcusquinn/aidevops/\.github/workflows/issue-sync-reusable\.yml)@[^[:space:]]+|\1@REF|g' "$_canon")

		if [[ "$_wf_norm" == "$_canon_norm" ]]; then
			printf 'CURRENT/CALLER\n'
		else
			printf 'DRIFTED/CALLER\n'
		fi
		return 0
	fi

	# Not a caller. If the filename is `issue-sync.yml`, it's presumed to be
	# an aidevops issue-sync workflow and the legacy pattern needs migration
	# to the caller model. This catches:
	#   - Modern full-copies that invoke `issue-sync-helper.sh` directly
	#   - Older full-copies that inline the TODO.md parsing logic
	#   - Any variant of either that has drifted over time
	# All three are equivalently "legacy patterns to be replaced by a caller".
	printf 'NEEDS-MIGRATION\n'
	return 0
}

# _is_failure_classification <classification>
# Returns 0 if the classification should cause a non-zero exit.
_is_failure_classification() {
	local _c="$1"
	case "$_c" in
	DRIFTED/CALLER | NEEDS-MIGRATION) return 0 ;;
	*) return 1 ;;
	esac
}

# _is_current_classification <classification>
# Returns 0 if the classification counts as "up-to-date".
_is_current_classification() {
	local _c="$1"
	case "$_c" in
	CURRENT/CALLER | CURRENT/SELF-CALLER) return 0 ;;
	*) return 1 ;;
	esac
}

# ─── Repo iteration ─────────────────────────────────────────────────────────

# _iterate_repos — emit one "slug|path|local_only" line per registered repo
_iterate_repos() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	# Order: path, local_only, slug — path is never empty, so it occupies the
	# leading field. Slug (which CAN be empty for local_only repos) goes last
	# so bash's `read` with IFS=$'\t' doesn't collapse the empty-slug case
	# (tab is treated as whitespace IFS; leading empties collapse, trailing
	# empties are preserved).
	jq -r '
		.initialized_repos[]?
		| [
			(.path // ""),
			(.local_only // false | tostring),
			(.slug // "")
		]
		| @tsv
	' "$REPOS_JSON"
	return 0
}

# ─── Output formats ─────────────────────────────────────────────────────────

# _render_row <slug> <path> <classification> <note>
_render_row_human() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"

	# Colour-code for terminals
	local _colour_reset _colour=''
	if [[ -t 1 ]]; then
		_colour_reset=$'\e[0m'
		case "$_class" in
		CURRENT/CALLER | CURRENT/SELF-CALLER) _colour=$'\e[32m' ;; # green
		DRIFTED/CALLER) _colour=$'\e[33m' ;;                      # yellow
		NEEDS-MIGRATION) _colour=$'\e[31m' ;;                     # red
		NO-WORKFLOW | LOCAL-ONLY) _colour=$'\e[90m' ;;            # grey
		NO-TEMPLATE) _colour=$'\e[35m' ;;                         # magenta
		esac
	else
		_colour_reset=''
	fi

	printf '  %-40s %s%-16s%s %s\n' \
		"$_slug" "$_colour" "$_class" "$_colour_reset" "$_note"
	return 0
}

_render_row_json() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"

	jq -cn \
		--arg slug "$_slug" \
		--arg path "$_path" \
		--arg class "$_class" \
		--arg note "$_note" \
		'{slug: $slug, path: $path, classification: $class, note: $note}'
	return 0
}

# _diff_summary <workflow-file> <canonical-template>
# Emit a compact diff summary for verbose mode.
_diff_summary() {
	local _wf="$1"
	local _canon="$2"
	if ! command -v diff >/dev/null 2>&1; then
		return 0
	fi
	# Unified diff, only show first 20 lines so a huge drift doesn't blast output.
	diff -u "$_canon" "$_wf" 2>/dev/null | head -n 20
	return 0
}

# ─── Main ───────────────────────────────────────────────────────────────────

readonly _MODE_HUMAN="human"
readonly _MODE_JSON="json"

# Parse command-line flags. Emits TSV: mode\tverbose\tfilter_slug.
# Exits 0 on --help. Exits 2 via _die on unknown option.
_parse_args() {
	local _filter_slug=""
	local _mode="$_MODE_HUMAN"
	local _verbose=0

	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--repo)
			_filter_slug="${2:-}"
			shift 2 || _die "--repo requires an argument"
			;;
		--json)
			_mode="$_MODE_JSON"
			shift
			;;
		--verbose | -v)
			_verbose=1
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

	printf '%s\t%d\t%s\n' "$_mode" "$_verbose" "$_filter_slug"
	return 0
}

# Classify a single repo row and update counters via namerefs.
# Side-effects: updates _counters_* via indirect-assignment (pass counter vars
# by reference is bash 4+; instead we print a classification line and let the
# caller update counters).
#
# Emits: class\tnote
_classify_row() {
	local _path="$1"
	local _local_only_flag="$2"
	local _canonical="$3"

	if [[ "$_local_only_flag" == "true" ]]; then
		printf 'LOCAL-ONLY\t\n'
		return 0
	fi

	if [[ ! -d "$_path" ]]; then
		printf 'NO-WORKFLOW\tpath not present: %s\n' "$_path"
		return 0
	fi

	local _wf="$_path/.github/workflows/issue-sync.yml"
	if [[ -z "$_canonical" ]]; then
		if [[ -f "$_wf" ]]; then
			printf 'NO-TEMPLATE\tcanonical template missing — classification deferred\n'
		else
			printf 'NO-WORKFLOW\t\n'
		fi
		return 0
	fi

	local _class
	_class=$(_classify_workflow "$_wf" "$_canonical")
	local _note=""
	case "$_class" in
	NEEDS-MIGRATION)
		_note="legacy full-copy; run: aidevops sync-workflows --apply (Phase 2)"
		;;
	esac
	printf '%s\t%s\n' "$_class" "$_note"
	return 0
}

# Process all rows: classify each, render output, tally. Returns exit status
# (1 if any drifted/needs-migration, 0 otherwise).
_process_rows() {
	local _mode="$1"
	local _verbose="$2"
	local _filter_slug="$3"
	local _canonical="$4"

	local _any_failure=0
	local _total=0 _current=0 _drifted=0 _needs_mig=0 _no_wf=0 _local_only=0 _no_template=0

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  %-40s %-16s %s\n' "REPO" "STATUS" "NOTE"
		printf '  %s\n' "$(printf '%.0s─' {1..78})"
	fi

	local _rows
	_rows=$(_iterate_repos)

	local _path _local_only_flag _slug
	while IFS=$'\t' read -r _path _local_only_flag _slug; do
		[[ -z "$_slug" && -z "$_path" ]] && continue
		local _label="${_slug:-$(basename "$_path")}"
		[[ -n "$_filter_slug" && "$_slug" != "$_filter_slug" ]] && continue

		_total=$((_total + 1))
		_path="${_path/#\~/$HOME}"

		local _class _note
		IFS=$'\t' read -r _class _note < <(_classify_row "$_path" "$_local_only_flag" "$_canonical")

		case "$_class" in
		LOCAL-ONLY) _local_only=$((_local_only + 1)) ;;
		NO-WORKFLOW) _no_wf=$((_no_wf + 1)) ;;
		NO-TEMPLATE) _no_template=$((_no_template + 1)) ;;
		CURRENT/CALLER | CURRENT/SELF-CALLER) _current=$((_current + 1)) ;;
		DRIFTED/CALLER)
			_drifted=$((_drifted + 1))
			_any_failure=1
			if ((_verbose == 1)) && [[ "$_mode" == "$_MODE_HUMAN" ]]; then
				_note="see diff below"
			fi
			;;
		NEEDS-MIGRATION)
			_needs_mig=$((_needs_mig + 1))
			_any_failure=1
			;;
		esac

		if [[ "$_mode" == "$_MODE_JSON" ]]; then
			_render_row_json "$_label" "$_path" "$_class" "$_note"
		else
			_render_row_human "$_label" "$_path" "$_class" "$_note"
			if ((_verbose == 1)) && [[ "$_class" == "DRIFTED/CALLER" ]] && [[ -n "$_canonical" ]]; then
				echo ""
				_diff_summary "$_path/.github/workflows/issue-sync.yml" "$_canonical"
				echo ""
			fi
		fi
	done <<<"$_rows"

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  Summary: %d repos — %d current, %d drifted, %d needs-migration, %d no-workflow, %d local-only, %d no-template\n\n' \
			"$_total" "$_current" "$_drifted" "$_needs_mig" "$_no_wf" "$_local_only" "$_no_template"
		if ((_any_failure == 1)); then
			printf '  Exit code 1 — see DRIFTED/CALLER or NEEDS-MIGRATION entries above.\n\n'
		fi
	fi

	return "$_any_failure"
}

main() {
	# Fail fast on missing repos.json — _die inside command substitution only
	# exits the subshell, not the parent.
	if [[ ! -f "$REPOS_JSON" ]]; then
		_die "repos.json not found at $REPOS_JSON — aidevops may not be initialised"
	fi
	if ! command -v jq >/dev/null 2>&1; then
		_die "jq required — install via Homebrew/apt or equivalent"
	fi

	local _mode _verbose _filter_slug
	IFS=$'\t' read -r _mode _verbose _filter_slug < <(_parse_args "$@")

	local _canonical
	if ! _canonical=$(_resolve_canonical_template); then
		if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
			_log "canonical template not found — install aidevops to resolve templates/workflows/issue-sync-caller.yml"
		fi
		_canonical=""
	fi

	if _process_rows "$_mode" "$_verbose" "$_filter_slug" "$_canonical"; then
		exit 0
	else
		exit 1
	fi
}

main "$@"
