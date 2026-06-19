#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# check-workflows-helper.sh — detect framework workflow drift across registered repos (t2778, GH#20648)
#
# Compares each registered repo's managed framework workflows against the
# canonical caller templates in `.agents/templates/workflows/`. Currently
# managed workflows:
#   - issue-sync.yml         (template: issue-sync-caller.yml)
#   - review-bot-gate.yml    (template: review-bot-gate-caller.yml, GH#20727)
#   - maintainer-gate.yml    (template: maintainer-gate-caller.yml, GH#21154)
#
# Classifies each (repo × workflow) as:
#
#   CURRENT/CALLER      — byte-identical to canonical (up to @ref pin variance)
#   CURRENT/SELF-CALLER — aidevops itself: uses `./.github/workflows/...` instead of remote ref
#   DRIFTED/CALLER      — uses the reusable workflow but caller YAML has diverged
#   NEEDS-MIGRATION     — legacy full-copy workflow, no `uses:` → should adopt caller pattern
#   NO-WORKFLOW         — workflow file not present (repo hasn't adopted this workflow)
#   LOCAL-ONLY          — repo has `local_only: true`, no remote to check
#   NO-TEMPLATE         — canonical template missing; helper cannot classify
#
# Usage:
#   check-workflows-helper.sh [--repo OWNER/REPO] [--workflow NAME] [--json] [--verbose]
#   check-workflows-helper.sh --help
#
# Options:
#   --repo OWNER/REPO   Check only the named slug (default: all registered)
#   --workflow NAME     Check only the named workflow (issue-sync or review-bot-gate)
#   --json              Machine-readable output (one JSON object per repo × workflow)
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
#   GH#20727 extended the known-workflow set to include review-bot-gate.yml,
#   which had a SHA-pinned helper checkout that silently drifted after helper
#   changes (the Option A' settlement fix in PR #20572 never reached downstream
#   repos pinned to 73b664a).
#
#   Phase 2 (`aidevops sync-workflows --apply`) will migrate or refresh callers
#   based on this helper's classification.

set -uo pipefail

SCRIPT_NAME=$(basename "$0")
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null) || SELF_DIR=""
REPO_ROOT=""
if [[ -n "$SELF_DIR" ]]; then
	REPO_ROOT=$(cd "$SELF_DIR/../.." && pwd 2>/dev/null) || REPO_ROOT=""
fi

# ─── Known managed workflows ────────────────────────────────────────────────
#
# Each entry is a colon-separated tuple:
#   workflow_file:reusable_file:template_file
#
# workflow_file   — the filename under .github/workflows/ in each repo
# reusable_file  — the reusable workflow filename in marcusquinn/aidevops
# template_file  — the canonical caller template filename under .agents/templates/workflows/
#
# Add new reusable-workflow migrations here. The helper loops over this list
# for every repo and classifies each (repo × workflow) independently.
#
# GH#20727: review-bot-gate added.
# GH#21154: maintainer-gate added (layer-1 defense-in-depth propagation).
readonly _KNOWN_WORKFLOWS=(
	"issue-sync.yml:issue-sync-reusable.yml:issue-sync-caller.yml"
	"review-bot-gate.yml:review-bot-gate-reusable.yml:review-bot-gate-caller.yml"
	"maintainer-gate.yml:maintainer-gate-reusable.yml:maintainer-gate-caller.yml"
	"loc-badge.yml:loc-badge-reusable.yml:loc-badge-caller.yml"
)

# ─── Path resolution ────────────────────────────────────────────────────────

# Canonical template — prefer deployed copy, fall back to the repo checkout.
# _resolve_canonical_template <template_filename>
# e.g. _resolve_canonical_template "issue-sync-caller.yml"
_resolve_canonical_template() {
	local _template_filename="$1"
	local _deployed="$HOME/.aidevops/agents/templates/workflows/${_template_filename}"
	local _repo_local="$SELF_DIR/../templates/workflows/${_template_filename}"

	if [[ -f "$_deployed" ]]; then
		printf '%s\n' "$_deployed"
		return 0
	fi
	if [[ -n "$SELF_DIR" && -f "$_repo_local" ]]; then
		printf '%s\n' "$_repo_local"
		return 0
	fi
	return 1
}

# _resolve_canonical_reusable <reusable_filename>
# Emits the aidevops source reusable workflow path for content-update checks.
_resolve_canonical_reusable() {
	local _reusable_filename="$1"
	local _repo_local="$REPO_ROOT/.github/workflows/${_reusable_filename}"
	if [[ -n "$REPO_ROOT" && -f "$_repo_local" ]]; then
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
	sed -n '4,56s/^# \{0,1\}//p' "$0"
	return 0
}

# ─── Reusable Target Resolution ─────────────────────────────────────────────

readonly _DEFAULT_WORKFLOW_REUSABLE_REPO="marcusquinn/aidevops"
readonly _DEFAULT_WORKFLOW_REUSABLE_REF="main"

_escape_ere() {
	local _text="$1"
	printf '%s' "$_text" | sed -E 's/[][(){}.^$*+?|]/\\&/g'
	return 0
}

_escape_sed_replacement() {
	local _text="$1"
	printf '%s' "$_text" | sed 's/[&|]/\\&/g'
	return 0
}

_normalise_reusable_ref() {
	local _ref="$1"
	_ref="${_ref#@}"
	printf '%s\n' "$_ref"
	return 0
}

_validate_reusable_repo() {
	local _repo="$1"
	if [[ ! "$_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		_die "invalid workflow_reusable_repo: $_repo"
	fi
	return 0
}

_validate_reusable_ref() {
	local _ref="$1"
	if [[ -z "$_ref" || "$_ref" =~ [[:space:][:cntrl:]] ]]; then
		_die "invalid workflow_reusable_ref: $_ref"
	fi
	return 0
}

_read_workflow_reusable_field() {
	local _slug="$1"
	local _field="$2"
	jq -r --arg s "$_slug" --arg f "$_field" '
		([.initialized_repos[]? | select(.slug == $s) | .[$f] // empty] | first // "") as $repo_value
		| if $repo_value != "" then $repo_value else (.[$f] // empty) end
	' "$REPOS_JSON" 2>/dev/null
	return 0
}

_workflow_reusable_repo_for_slug() {
	local _slug="$1"
	local _repo
	_repo=$(_read_workflow_reusable_field "$_slug" "workflow_reusable_repo")
	[[ -z "$_repo" ]] && _repo="$_DEFAULT_WORKFLOW_REUSABLE_REPO"
	_validate_reusable_repo "$_repo"
	printf '%s\n' "$_repo"
	return 0
}

_workflow_reusable_ref_for_slug() {
	local _slug="$1"
	local _ref
	_ref=$(_read_workflow_reusable_field "$_slug" "workflow_reusable_ref")
	[[ -z "$_ref" ]] && _ref="$_DEFAULT_WORKFLOW_REUSABLE_REF"
	_ref=$(_normalise_reusable_ref "$_ref")
	_validate_reusable_ref "$_ref"
	printf '%s\n' "$_ref"
	return 0
}

_render_template_for_target() {
	local _template="$1"
	local _repo="$2"
	local _reusable_file="$3"
	local _ref="$4"
	local _default_repo_escaped _reusable_escaped _repo_repl _ref_repl
	_default_repo_escaped=$(_escape_ere "$_DEFAULT_WORKFLOW_REUSABLE_REPO")
	_reusable_escaped=$(_escape_ere "$_reusable_file")
	_repo_repl=$(_escape_sed_replacement "$_repo")
	_ref_repl=$(_escape_sed_replacement "$_ref")
	sed -E \
		-e "s|(uses:[[:space:]]*)${_default_repo_escaped}(/\.github/workflows/${_reusable_escaped})@[^[:space:]]+|\1${_repo_repl}\2@${_ref_repl}|" \
		-e "s|${_default_repo_escaped}(/\.github/workflows/${_reusable_escaped})|${_repo_repl}\1|g" \
		"$_template"
	return 0
}

# ─── Classification ─────────────────────────────────────────────────────────

# _normalize_wf_for_compare <file> <target_escaped>
# Normalise a workflow file for byte-comparison:
#   - Replaces the @<ref> suffix on reusable `uses:` lines with @REF so that
#     `@main` vs `@v3.9.0` doesn't count as drift.
#   - Replaces `branches: [<name>]` with `branches: [BRANCH]` so repos that
#     default to `develop` aren't flagged as drifted from a main-defaulting template.
#   - Strips injected `runner:` keys from `with:` blocks (GH#21877) and removes
#     any `    with:` block that becomes empty after runner removal, so repos
#     with a repos.json `runner` override aren't flagged as DRIFTED/CALLER.
# Emits normalised content on stdout.
_normalize_wf_for_compare() {
	local _file="$1"
	local _target_escaped="$2"
	# Step 1: normalise @ref and branch filter (existing logic).
	# Step 2: remove injected `      runner: <value>` lines.
	# Step 3: remove `    with:` block headers that are now empty (runner was
	#         the only key). Uses awk: buffer the `    with:` line, emit it
	#         only if the next line is also inside the block (6-space indent);
	#         otherwise discard the header silently.
	# GH#21899: a pending `    with:` at EOF is also empty (sed step 2 already
	#         deleted the only `runner:` child). The earlier `END { print pending }`
	#         resurrected it and made callers where `runner:` was the only `with:`
	#         entry AND `with:` ended up as the last content line in the file
	#         (e.g. callers missing `secrets: inherit`) classify as DRIFTED/CALLER.
	#         Dropping pending at EOF is correct — there is no legitimate scenario
	#         where a `with:` followed by no children should survive normalisation.
	sed -E "s|(${_target_escaped})@[^[:space:]]+|\1@REF|g" "$_file" \
		| sed -E 's|^([[:space:]]+branches:) \[[^]]+\]$|\1 [BRANCH]|' \
		| sed -E '/^      runner: /d' \
		| awk '
			/^    with:$/ { pending = $0; next }
			pending {
				if (/^      /) {
					print pending
					pending = ""
					print
					next
				}
				pending = ""
				print
				next
			}
			{ print }
		'
	return 0
}

_normalize_wf_text_for_compare() {
	local _content="$1"
	local _target_escaped="$2"
	printf '%s\n' "$_content" \
		| sed -E "s|(${_target_escaped})@[^[:space:]]+|\1@REF|g" \
		| sed -E 's|^([[:space:]]+branches:) \[[^]]+\]$|\1 [BRANCH]|' \
		| sed -E '/^      runner: /d' \
		| awk '
			/^    with:$/ { pending = $0; next }
			pending {
				if (/^      /) {
					print pending
					pending = ""
					print
					next
				}
				pending = ""
				print
				next
			}
			{ print }
		'
	return 0
}

# _classify_workflow <workflow-file> <canonical-template> <reusable-file> <target-repo> <target-ref> [<canon-norm>]
# Prints the classification string on stdout.
# Returns 0 always; status is carried via the emitted string.
#
# Parameters:
#   _wf               — path to the workflow file to classify
#   _canon            — path to the canonical caller template
#   _reusable_file    — filename of the reusable workflow (e.g. "issue-sync-reusable.yml")
#   _target_repo      — configured trusted reusable workflow repository
#   _target_ref       — configured trusted reusable workflow ref, without leading @
#   _canon_norm_pre   — optional pre-computed normalised form of the canonical template
#                       (loop-invariant optimisation; skip the inner sed call when provided)
_classify_workflow() {
	local _wf="$1"
	local _canon="$2"
	local _reusable_file="$3"
	local _target_repo="$4"
	local _target_ref="$5"
	local _canon_norm_pre="${6:-}"
	local _reusable_escaped _target_escaped
	_reusable_escaped=$(_escape_ere "$_reusable_file")
	_target_escaped="$(_escape_ere "$_target_repo")/\.github/workflows/${_reusable_escaped}"

	if [[ ! -f "$_wf" ]]; then
		printf 'NO-WORKFLOW\n'
		return 0
	fi

	# Detect self-caller (aidevops itself) — uses: ./.github/workflows/<reusable-name>
	# This is the intended pattern for the aidevops repo and must not be flagged
	# as drift. The self-caller is functionally equivalent to the downstream
	# pattern; it just skips the cross-repo checkout.
	local _self_caller_pattern
	_self_caller_pattern="uses:[[:space:]]*\./\.github/workflows/${_reusable_escaped}"
	if grep -qE "$_self_caller_pattern" "$_wf"; then
		printf 'CURRENT/SELF-CALLER\n'
		return 0
	fi

	# Detect caller pattern: any `uses:` line pointing at the reusable workflow.
	# Accept any `@<ref>` variant (main, v3.9.0, a commit SHA, etc).
	local _downstream_pattern
	_downstream_pattern="uses:[[:space:]]*${_target_escaped}@"
	if grep -qE "$_downstream_pattern" "$_wf"; then
		# It's a caller. Compare against canonical, normalising the @ref so that
		# `@main` vs `@v3.9.0` doesn't count as drift (intentional pinning is OK).
		# Also normalise the push-trigger branch filter so a repo with
		# `branches: [develop]` installed by sync-workflows is not flagged as
		# drift — the branch name reflects the downstream default, not the template.
		local _wf_norm _canon_norm
		_wf_norm=$(_normalize_wf_for_compare "$_wf" "$_target_escaped")
		# Use pre-computed canon_norm when available (caller hoist); fall back to
		# computing it here so the function remains usable in isolation.
		if [[ -n "$_canon_norm_pre" ]]; then
			_canon_norm="$_canon_norm_pre"
		else
			local _canon_rendered
			_canon_rendered=$(_render_template_for_target "$_canon" "$_target_repo" "$_reusable_file" "$_target_ref")
			_canon_norm=$(_normalize_wf_text_for_compare "$_canon_rendered" "$_target_escaped")
		fi

		if [[ "$_wf_norm" == "$_canon_norm" ]]; then
			printf 'CURRENT/CALLER\n'
		else
			printf 'DRIFTED/CALLER\n'
		fi
		return 0
	fi

	# Not a caller. The workflow exists but does not delegate to the reusable
	# pattern — it's a legacy full-copy that needs migration to the caller model.
	# This catches:
	#   - Modern full-copies that invoke the helper script directly
	#   - Older full-copies that inline the gate logic
	#   - SHA-pinned helper checkouts (the GH#20727 pattern)
	# All variants are equivalently "legacy patterns to be replaced by a caller".
	printf 'NEEDS-MIGRATION\n'
	return 0
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

# _render_row_human <slug> <path> <classification> <note> [<workflow>]
_render_row_human() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"
	local _workflow="${5:-}"

	# Colour-code for terminals
	local _colour_reset _colour=''
	if [[ -t 1 ]]; then
		_colour_reset=$'\e[0m'
		case "$_class" in
		CURRENT/CALLER | CURRENT/SELF-CALLER | CURRENT/REUSABLE) _colour=$'\e[32m' ;; # green
		DRIFTED/CALLER | DRIFTED/REUSABLE) _colour=$'\e[33m' ;;                       # yellow
		NEEDS-MIGRATION) _colour=$'\e[31m' ;;                     # red
		NO-WORKFLOW | LOCAL-ONLY) _colour=$'\e[90m' ;;            # grey
		NO-TEMPLATE) _colour=$'\e[35m' ;;                         # magenta
		esac
	else
		_colour_reset=''
	fi

	# When multiple workflows are checked, prefix slug with [workflow] for context.
	local _label="$_slug"
	if [[ -n "$_workflow" ]]; then
		_label="[${_workflow}] ${_slug}"
	fi

	printf '  %-50s %s%-16s%s %s\n' \
		"$_label" "$_colour" "$_class" "$_colour_reset" "$_note"
	return 0
}

_render_row_json() {
	local _slug="$1"
	local _path="$2"
	local _class="$3"
	local _note="${4:-}"
	local _workflow="${5:-}"

	jq -cn \
		--arg slug "$_slug" \
		--arg path "$_path" \
		--arg class "$_class" \
		--arg note "$_note" \
		--arg workflow "$_workflow" \
		'{slug: $slug, path: $path, workflow: $workflow, classification: $class, note: $note}'
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

# Parse command-line flags. Emits TSV: mode\tverbose\tfilter_slug\tfilter_workflow.
# Exits 0 on --help. Exits 2 via _die on unknown option.
_parse_args() {
	local _filter_slug=""
	local _filter_workflow=""
	local _mode="$_MODE_HUMAN"
	local _verbose=0

	while (($# > 0)); do
		local _opt="$1"
		case "$_opt" in
		--repo)
			_filter_slug="${2:-}"
			shift 2 || _die "--repo requires an argument"
			;;
		--workflow)
			_filter_workflow="${2:-}"
			shift 2 || _die "--workflow requires an argument"
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

	printf '%s\t%d\t%s\t%s\n' "$_mode" "$_verbose" "$_filter_slug" "$_filter_workflow"
	return 0
}

# Classify a single (repo × workflow) combination.
# Side-effects: prints a classification line; caller updates counters.
#
# Emits: class\tnote
# _classify_reusable_workflow <repo-path> <canonical-reusable> <reusable-file>
_classify_reusable_workflow() {
	local _path="$1"
	local _canonical_reusable="$2"
	local _reusable_file="$3"
	local _wf="$_path/.github/workflows/${_reusable_file}"
	if [[ ! -f "$_wf" ]]; then
		printf 'NO-WORKFLOW\treusable workflow not present for configured reusable repo\n'
		return 0
	fi
	if [[ -z "$_canonical_reusable" ]]; then
		printf 'NO-TEMPLATE\tcanonical reusable workflow missing — update check deferred\n'
		return 0
	fi
	if diff -q "$_canonical_reusable" "$_wf" >/dev/null 2>&1; then
		printf 'CURRENT/REUSABLE\treusable workflow content matches aidevops baseline\n'
	else
		printf 'DRIFTED/REUSABLE\torg-owned reusable workflow differs; review/update from aidevops baseline\n'
	fi
	return 0
}

# _classify_row <slug> <path> <local_only_flag> <canonical> <reusable_file> <workflow_file> [<canon_norm>]
_classify_row() {
	local _slug="$1"
	local _path="$2"
	local _local_only_flag="$3"
	local _canonical="$4"
	local _reusable_file="$5"
	local _workflow_file="$6"
	local _canon_norm="${7:-}"

	if [[ "$_local_only_flag" == "true" ]]; then
		printf 'LOCAL-ONLY\t\n'
		return 0
	fi

	if [[ ! -d "$_path" ]]; then
		printf 'NO-WORKFLOW\tpath not present: %s\n' "$_path"
		return 0
	fi

	local _wf="$_path/.github/workflows/${_workflow_file}"
	local _target_repo _target_ref
	_target_repo=$(_workflow_reusable_repo_for_slug "$_slug")
	_target_ref=$(_workflow_reusable_ref_for_slug "$_slug")
	if [[ "$_slug" == "$_target_repo" ]]; then
		local _canonical_reusable
		_canonical_reusable=$(_resolve_canonical_reusable "$_reusable_file") || _canonical_reusable=""
		_classify_reusable_workflow "$_path" "$_canonical_reusable" "$_reusable_file"
		return 0
	fi

	if [[ -z "$_canonical" ]]; then
		if [[ -f "$_wf" ]]; then
			printf 'NO-TEMPLATE\tcanonical template missing — classification deferred\n'
		else
			printf 'NO-WORKFLOW\t\n'
		fi
		return 0
	fi

	local _class
	_class=$(_classify_workflow "$_wf" "$_canonical" "$_reusable_file" "$_target_repo" "$_target_ref" "$_canon_norm")
	local _note=""
	case "$_class" in
	NEEDS-MIGRATION)
		_note="legacy full-copy; run: aidevops sync-workflows --apply"
		;;
	esac
	printf '%s\t%s\n' "$_class" "$_note"
	return 0
}

# _resolve_wf_canonical <template_file>
# Emits the canonical template path on stdout (single line).
#
# GH#21477: the previous version emitted a TSV of "canonical_path\tcanon_norm"
# so that callers could pre-compute the normalised canonical content once per
# workflow type (loop-invariant optimisation from PR #20809 / GH#20794).
# The transport was fatally broken: `IFS=$'\t' read -r` reads exactly one line,
# so _canon_norm was silently truncated to the first line of the multi-line YAML
# (~50 bytes vs ~2 KB for the full content). _classify_workflow's equality check
# at line 199 therefore always failed → every caller-pattern workflow was reported
# as DRIFTED/CALLER regardless of actual content.
#
# Fix: emit only the canonical path. _classify_workflow's built-in fallback at
# lines 195-197 recomputes _canon_norm per-repo via _normalize_wf_for_compare,
# which is the verified-correct path. Cost: ~150 extra sed pipelines per full
# run (3 workflows × <50 repos); negligible vs multi-second gh enumeration.
_resolve_wf_canonical() {
	local _template_file="$1"
	local _canonical=""
	_canonical=$(_resolve_canonical_template "$_template_file") || _canonical=""
	printf '%s\n' "$_canonical"
	return 0
}

# Process all rows: for each known workflow, classify each repo, render output,
# tally. Returns exit status (1 if any drifted/needs-migration, 0 otherwise).
# _process_rows <mode> <verbose> <filter_slug> <filter_workflow>
_process_rows() {
	local _mode="$1"
	local _verbose="$2"
	local _filter_slug="$3"
	local _filter_workflow="${4:-}"

	local _any_failure=0
	local _total=0 _current=0 _drifted=0 _needs_mig=0 _no_wf=0 _local_only=0 _no_template=0

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  %-50s %-16s %s\n' "REPO [WORKFLOW]" "STATUS" "NOTE"
		printf '  %s\n' "$(printf '%.0s─' {1..88})"
	fi

	local _rows
	_rows=$(_iterate_repos) || exit $?

	local _wf_tuple
	for _wf_tuple in "${_KNOWN_WORKFLOWS[@]}"; do
		local _workflow_file _reusable_file _template_file
		_workflow_file="${_wf_tuple%%:*}"
		_reusable_file="${_wf_tuple#*:}"; _reusable_file="${_reusable_file%%:*}"
		_template_file="${_wf_tuple##*:}"

		local _workflow_name="${_workflow_file%.yml}"
		if [[ -n "$_filter_workflow" ]]; then
			local _fw_norm="${_filter_workflow%.yml}"
			[[ "$_workflow_name" != "$_fw_norm" ]] && continue
		fi

		local _canonical
		_canonical=$(_resolve_wf_canonical "$_template_file")
		# Canonical normalisation now depends on the configured reusable repo/ref for
		# each slug, so it cannot be safely hoisted per workflow type.
		local _canon_norm=""

		local _path _local_only_flag _slug
		while IFS=$'\t' read -r _path _local_only_flag _slug; do
			[[ -z "$_slug" && -z "$_path" ]] && continue
			local _label="${_slug:-$(basename "$_path")}"
			[[ -n "$_filter_slug" && "$_slug" != "$_filter_slug" ]] && continue

			_total=$((_total + 1))
			_path="${_path/#\~/$HOME}"

			local _class _note
			IFS=$'\t' read -r _class _note < <(_classify_row \
				"$_slug" "$_path" "$_local_only_flag" "$_canonical" \
				"$_reusable_file" "$_workflow_file" "$_canon_norm")

			case "$_class" in
			LOCAL-ONLY) _local_only=$((_local_only + 1)) ;;
			NO-WORKFLOW) _no_wf=$((_no_wf + 1)) ;;
			NO-TEMPLATE) _no_template=$((_no_template + 1)) ;;
			CURRENT/CALLER | CURRENT/SELF-CALLER | CURRENT/REUSABLE) _current=$((_current + 1)) ;;
			DRIFTED/CALLER | DRIFTED/REUSABLE)
				_drifted=$((_drifted + 1)); _any_failure=1
				((_verbose == 1)) && [[ "$_mode" == "$_MODE_HUMAN" ]] && _note="see diff below"
				;;
			NEEDS-MIGRATION)
				_needs_mig=$((_needs_mig + 1)); _any_failure=1 ;;
			esac

			if [[ "$_mode" == "$_MODE_JSON" ]]; then
				_render_row_json "$_label" "$_path" "$_class" "$_note" "$_workflow_name"
			else
				_render_row_human "$_label" "$_path" "$_class" "$_note" "$_workflow_name"
				if ((_verbose == 1)) && [[ "$_class" == "DRIFTED/CALLER" ]] && [[ -n "$_canonical" ]]; then
					echo ""; _diff_summary "$_path/.github/workflows/${_workflow_file}" "$_canonical"; echo ""
				elif ((_verbose == 1)) && [[ "$_class" == "DRIFTED/REUSABLE" ]]; then
					local _canonical_reusable
					_canonical_reusable=$(_resolve_canonical_reusable "$_reusable_file") || _canonical_reusable=""
					[[ -n "$_canonical_reusable" ]] && { echo ""; _diff_summary "$_path/.github/workflows/${_reusable_file}" "$_canonical_reusable"; echo ""; }
				fi
			fi
		done <<<"$_rows"
	done

	if [[ "$_mode" == "$_MODE_HUMAN" ]]; then
		printf '\n  Summary: %d entries — %d current, %d drifted, %d needs-migration, %d no-workflow, %d local-only, %d no-template\n\n' \
			"$_total" "$_current" "$_drifted" "$_needs_mig" "$_no_wf" "$_local_only" "$_no_template"
		((_any_failure == 1)) && printf '  Exit code 1 — see DRIFTED/CALLER or NEEDS-MIGRATION entries above.\n\n'
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

	local _mode _verbose _filter_slug _filter_workflow
	IFS=$'\t' read -r _mode _verbose _filter_slug _filter_workflow < <(_parse_args "$@")

	if _process_rows "$_mode" "$_verbose" "$_filter_slug" "$_filter_workflow"; then
		exit 0
	else
		exit 1
	fi
}

main "$@"
