#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# worktree-exclusions-helper.sh (t2885)
# Exclude git worktrees from macOS Spotlight, Time Machine, and Backblaze.
#
# Background: every worker dispatch deep-copies node_modules into a fresh
# worktree (see worktree-helper.sh::_restore_worktree_node_modules). With many
# concurrent worktrees, fseventsd / mds / bztransmit cascade and saturate the
# CPU. Worktrees are ephemeral by design — the persistent state lives on the
# git remote — so opting them out of OS indexers and backup tools is correct
# default behaviour, not just a perf hack.
#
# Subcommands:
#   apply <worktree-path>   - exclude one worktree (Spotlight + Time Machine).
#                             Idempotent. Always exits 0 (best-effort).
#   backfill [--dry-run]    - apply to every worktree in every repo registered
#                             in ~/.config/aidevops/repos.json.
#   detect                  - report which tools are installed and which are
#                             scriptable vs require a manual setup step.
#   setup-backblaze         - print the sudo commands needed to add a Backblaze
#                             exclusion rule covering ~/Git/<repo>-* worktree
#                             prefixes (root-only config file).
#   help                    - print usage.
#
# Linux: subcommands print "not implemented" and exit 0. See GH#<linux-followup>.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh disable=SC1091
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Color/log fallbacks if shared-constants.sh is unavailable (defensive).
[[ -z "${RED+x}" ]] && RED=''
[[ -z "${GREEN+x}" ]] && GREEN=''
[[ -z "${YELLOW+x}" ]] && YELLOW=''
[[ -z "${BLUE+x}" ]] && BLUE=''
[[ -z "${NC+x}" ]] && NC=''

REPOS_JSON="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

###############################################################################
# Logging — fall back to printf if shared-constants.sh helpers are absent.
###############################################################################
_we_info() {
	local msg="$1"
	if declare -F print_info >/dev/null 2>&1; then
		print_info "$msg"
	else
		printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$msg"
	fi
	return 0
}

_we_ok() {
	local msg="$1"
	if declare -F print_success >/dev/null 2>&1; then
		print_success "$msg"
	else
		printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$msg"
	fi
	return 0
}

_we_warn() {
	local msg="$1"
	if declare -F print_warning >/dev/null 2>&1; then
		print_warning "$msg"
	else
		printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$msg"
	fi
	return 0
}

_we_err() {
	local msg="$1"
	if declare -F print_error >/dev/null 2>&1; then
		print_error "$msg"
	else
		printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$msg" >&2
	fi
	return 0
}

###############################################################################
# Platform detection.
###############################################################################
_we_is_macos() {
	[[ "$(uname -s)" == "Darwin" ]]
}

_we_has_tmutil() {
	command -v tmutil >/dev/null 2>&1
}

_we_has_backblaze() {
	[[ -d /Library/Backblaze.bzpkg ]] || [[ -d /Applications/Backblaze.app ]]
}

###############################################################################
# Apply Spotlight exclusion (touch .metadata_never_index inside the worktree).
# Idempotent. Returns 0 even if it could not write — best-effort.
###############################################################################
_we_apply_spotlight() {
	local wt_path="$1"
	[[ -d "$wt_path" ]] || return 0
	local marker="${wt_path}/.metadata_never_index"
	if [[ -e "$marker" ]]; then
		return 0
	fi
	# Touch the marker. Failure is non-fatal — worktree creation must not be
	# blocked by exclusion failure.
	touch "$marker" 2>/dev/null || true
	return 0
}

###############################################################################
# Apply Time Machine exclusion via tmutil. Idempotent — checks isexcluded first.
#
# Uses `tmutil addexclusion` without `-p`: the unflagged form sets a per-path
# xattr (com.apple.metadata:com_apple_backup_excludeItem) that any user can
# write. The `-p` (sticky path) form requires root and isn't necessary for
# worktrees — we want xattr-based "this directory" exclusion, which travels
# with the path naturally. Failure is non-fatal — worktree creation must not
# be blocked by exclusion failure.
###############################################################################
_we_apply_timemachine() {
	local wt_path="$1"
	[[ -d "$wt_path" ]] || return 0
	_we_has_tmutil || return 0
	# tmutil isexcluded prints "[Excluded]" or "[Included]" prefix.
	local already=""
	already=$(tmutil isexcluded "$wt_path" 2>/dev/null || true)
	if [[ "$already" == *"[Excluded]"* ]]; then
		return 0
	fi
	tmutil addexclusion "$wt_path" >/dev/null 2>&1 || true
	return 0
}

###############################################################################
# cmd_apply <worktree-path>
# Apply all in-scope exclusions to a single worktree path. Always exits 0.
###############################################################################
cmd_apply() {
	local wt_path="${1:-}"
	if [[ -z "$wt_path" ]]; then
		_we_err "apply: worktree path required"
		return 1
	fi
	if [[ ! -d "$wt_path" ]]; then
		# Path may have been removed in a race — silent.
		return 0
	fi

	if ! _we_is_macos; then
		# Linux indexers (tracker, baloo) tracked separately. Silent skip.
		return 0
	fi

	_we_apply_spotlight "$wt_path"
	_we_apply_timemachine "$wt_path"
	# Backblaze is glob-based and root-only — applied via setup-backblaze, not
	# per-worktree.
	return 0
}

###############################################################################
# Enumerate worktree paths across all registered repos.
# Prints one absolute path per line on stdout. Skips the canonical repo dirs
# (only worktrees attached to them).
###############################################################################
_we_enumerate_worktrees() {
	[[ -f "$REPOS_JSON" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	local repo_path=""
	while IFS= read -r repo_path; do
		[[ -n "$repo_path" && -d "$repo_path/.git" || -f "$repo_path/.git" ]] || continue
		# Skip local_only repos with no git remote (they'd still be valid
		# repos but the field signals user intent to skip framework ops).
		# git worktree list works fine — we just enumerate.

		# Format: "<path>  <sha>  [branch]" or similar.
		# We emit only paths that are NOT the canonical repo path.
		local _line="" _wt=""
		while IFS= read -r _line; do
			_wt=$(printf '%s' "$_line" | awk '{print $1}') || _wt=""
			[[ -n "$_wt" ]] || continue
			[[ "$_wt" == "$repo_path" ]] && continue
			[[ -d "$_wt" ]] || continue
			printf '%s\n' "$_wt"
		done < <(git -C "$repo_path" worktree list 2>/dev/null)
	done < <(jq -r '.initialized_repos[]?.path // empty' "$REPOS_JSON" 2>/dev/null)
	return 0
}

###############################################################################
# cmd_backfill [--dry-run]
###############################################################################
cmd_backfill() {
	local dry_run=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
			--dry-run) dry_run=1; shift ;;
			*) _we_err "backfill: unknown arg: $arg"; return 1 ;;
		esac
	done

	if ! _we_is_macos; then
		_we_warn "backfill: non-macOS — Linux indexers not supported yet (see GH#<linux-followup>)"
		return 0
	fi

	local count=0
	local wt=""
	while IFS= read -r wt; do
		[[ -n "$wt" ]] || continue
		count=$((count + 1))
		if (( dry_run )); then
			printf '  [dry-run] %s\n' "$wt"
		else
			cmd_apply "$wt"
			printf '  [applied] %s\n' "$wt"
		fi
	done < <(_we_enumerate_worktrees)

	if (( dry_run )); then
		_we_info "backfill: would apply to $count worktree(s)"
	else
		_we_ok "backfill: applied to $count worktree(s)"
	fi
	return 0
}

###############################################################################
# cmd_detect — report which tools are installed and which require manual setup.
###############################################################################
cmd_detect() {
	if ! _we_is_macos; then
		_we_info "Platform: $(uname -s) — exclusions not implemented yet on non-macOS"
		_we_info "See GH#<linux-followup>"
		return 0
	fi

	_we_info "Platform: macOS"

	# Spotlight — no detection needed; .metadata_never_index works on any macOS.
	_we_ok "Spotlight: scriptable via .metadata_never_index marker file"

	# Time Machine — tmutil exists on every macOS; we report whether it has a
	# destination configured (informational only).
	if _we_has_tmutil; then
		local tm_dest=""
		tm_dest=$(tmutil destinationinfo 2>/dev/null | head -5 || true)
		if [[ -n "$tm_dest" ]]; then
			_we_ok "Time Machine: scriptable via tmutil addexclusion (destination configured)"
		else
			_we_ok "Time Machine: scriptable via tmutil addexclusion (no destination yet — exclusions still apply)"
		fi
	else
		_we_warn "Time Machine: tmutil not found (unexpected on macOS)"
	fi

	# Backblaze — manual setup only (root-only XML config).
	if _we_has_backblaze; then
		_we_warn "Backblaze: detected — requires manual setup (run 'worktree-exclusions-helper.sh setup-backblaze')"
	else
		_we_info "Backblaze: not installed — skipping"
	fi
	return 0
}

###############################################################################
# cmd_setup_backblaze — check Backblaze's Time Machine inheritance setting.
# If enabled, worktree exclusions are already covered via tmutil. If disabled,
# print GUI guidance to enable it.
###############################################################################
cmd_setup_backblaze() {
	if ! _we_is_macos; then
		_we_info "setup-backblaze: macOS only"
		return 0
	fi

	if ! _we_has_backblaze; then
		_we_info "setup-backblaze: Backblaze not installed — nothing to do"
		return 0
	fi

	local bzinfo_file="/Library/Backblaze.bzpkg/bzdata/bzinfo.xml"
	if [[ ! -f "$bzinfo_file" ]]; then
		_we_warn "setup-backblaze: bzinfo.xml not found at $bzinfo_file"
		_we_warn "setup-backblaze: Backblaze may be a different version — skipping"
		return 0
	fi

	# Parse the use_time_machine_excludes attribute. Read-only, no sudo needed.
	# The attribute is typically: use_time_machine_excludes="true" or "false"
	local tm_excludes=""
	tm_excludes=$(grep -oP 'use_time_machine_excludes="\K[^"]+' "$bzinfo_file" 2>/dev/null || true)

	if [[ "$tm_excludes" == "true" ]]; then
		cat <<'EOF'

Backblaze worktree exclusion — already covered
==============================================

Your Backblaze is configured to inherit Time Machine exclusions
(use_time_machine_excludes="true"). Since worktree-exclusions-helper.sh
already runs `tmutil addexclusion` on all worktrees, Backblaze will
automatically exclude them from backup.

No further action needed.

EOF
		_we_ok "Backblaze is inheriting Time Machine exclusions — worktrees are covered"
		return 0
	fi

	# Attribute is false, missing, or unparseable — print GUI guidance.
	cat <<'EOF'

Backblaze worktree exclusion — enable Time Machine inheritance
==============================================================

Your Backblaze is not currently set to inherit Time Machine exclusions.
To enable this (so worktrees excluded via tmutil are automatically excluded
from Backblaze backup):

  1. Open the Backblaze app
  2. Go to Settings → Backups
  3. Tick the checkbox: "Use Time Machine excludes"
  4. Quit and reopen Backblaze

After this, all worktrees excluded via tmutil (which this setup already does)
will be automatically excluded from Backblaze backup.

Rationale: aidevops worktrees are ephemeral working copies. Their persistent
state lives on the git remote, so backing them up duplicates work the remote
already does. Excluding them removes the bztransmit/bzfilelist load triggered
by per-worktree node_modules copies.

EOF
	return 0
}

###############################################################################
# cmd_help
###############################################################################
cmd_help() {
	cat <<'EOF'
worktree-exclusions-helper.sh - exclude worktrees from macOS indexers/backup

Usage:
  worktree-exclusions-helper.sh apply <worktree-path>
  worktree-exclusions-helper.sh backfill [--dry-run]
  worktree-exclusions-helper.sh detect
  worktree-exclusions-helper.sh setup-backblaze
  worktree-exclusions-helper.sh help

Subcommands:
  apply           Apply Spotlight + Time Machine exclusions to one worktree.
                  Idempotent. Best-effort (always exits 0).
  backfill        Apply to every worktree across registered repos.
                  Use --dry-run to preview without writing.
  detect          Report which tools are installed and scriptable.
  setup-backblaze Print the sudo command for the manual Backblaze step.
  help            This message.

Environment:
  AIDEVOPS_REPOS_JSON  Override path to repos.json (default: ~/.config/aidevops/repos.json)
EOF
	return 0
}

###############################################################################
# Main dispatch.
###############################################################################
main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
		apply)            cmd_apply "$@" ;;
		backfill)         cmd_backfill "$@" ;;
		detect)           cmd_detect "$@" ;;
		setup-backblaze)  cmd_setup_backblaze "$@" ;;
		help|-h|--help)   cmd_help ;;
		*)
			_we_err "unknown subcommand: $cmd"
			cmd_help
			return 1
			;;
	esac
}

# Only run main when invoked directly (not when sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
