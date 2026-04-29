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
# Linux: tracker3 (GNOME) and baloo (KDE Plasma) exclusions are supported.
#        Per-tool detection replaces the prior Darwin-only short-circuit.

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
# Linux platform detection helpers.
###############################################################################
_we_is_linux() {
	[[ "$(uname -s)" == "Linux" ]]
}

_we_has_tracker3() {
	command -v tracker3 >/dev/null 2>&1
}

_we_has_baloo() {
	command -v balooctl6 >/dev/null 2>&1 || command -v balooctl >/dev/null 2>&1
}

# Return the first available balooctl binary name (balooctl6 preferred).
_we_balooctl_bin() {
	if command -v balooctl6 >/dev/null 2>&1; then
		printf 'balooctl6'
	elif command -v balooctl >/dev/null 2>&1; then
		printf 'balooctl'
	fi
	return 0
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
# Apply tracker3 exclusion (GNOME / freedesktop.org file indexer).
# Adds wt_path to the ignored-directories GSettings key (persistent exclusion)
# and resets the path from the live index. Idempotent. Returns 0 on failure.
###############################################################################
_we_apply_tracker3() {
	local wt_path="$1"
	[[ -d "$wt_path" ]] || return 0
	_we_has_tracker3 || return 0

	# --- Persistent exclusion via gsettings ----------------------------------
	# Requires gsettings and the Tracker3 Miner.Files schema.
	if command -v gsettings >/dev/null 2>&1; then
		local schema="org.freedesktop.Tracker3.Miner.Files"
		local key="ignored-directories"
		local current=""
		current=$(gsettings get "$schema" "$key" 2>/dev/null || true)
		# current is a GVariant array: '@as []' (empty) or ['path1', 'path2'].
		# Only proceed when the schema is installed (non-empty output).
		if [[ -n "$current" && "$current" != *"${wt_path}"* ]]; then
			local new_value=""
			if [[ "$current" == "@as []" || "$current" == "[]" ]]; then
				new_value="['${wt_path}']"
			else
				# Strip trailing ] then append the new path.
				new_value="${current%]}, '${wt_path}']"
			fi
			gsettings set "$schema" "$key" "$new_value" 2>/dev/null || true
		fi
	fi

	# --- Remove existing index entries for this path -------------------------
	# Best-effort; signals tracker3 to forget prior index data for the path.
	tracker3 reset --files "$wt_path" >/dev/null 2>&1 || true

	return 0
}

###############################################################################
# Apply baloo exclusion (KDE Plasma file indexer).
# Appends wt_path to the 'exclude folders[$e]' key in ~/.config/baloofilerc
# and restarts baloo to pick up the change. Idempotent. Returns 0 on failure.
###############################################################################
_we_apply_baloo() {
	local wt_path="$1"
	local balooctl=""
	local baloofilerc=""
	local changed=0
	local current_excludes=""
	local tmpfile=""

	[[ -d "$wt_path" ]] || return 0
	balooctl="$(_we_balooctl_bin)"
	[[ -n "$balooctl" ]] || return 0

	baloofilerc="${HOME}/.config/baloofilerc"

	if [[ ! -f "$baloofilerc" ]]; then
		# No existing config — create a minimal file with the exclusion.
		mkdir -p "${HOME}/.config" 2>/dev/null || true
		printf "[General]\nexclude folders[\$e]=%s\n" "$wt_path" \
			> "$baloofilerc" 2>/dev/null || true
		changed=1
	else
		# Read the existing exclude-folders line (if any).
		current_excludes=$(grep '^exclude folders\[' "$baloofilerc" 2>/dev/null || true)

		if [[ -z "$current_excludes" ]]; then
			# No exclusion line yet — insert one into the config.
			if grep -q '^\[General\]' "$baloofilerc" 2>/dev/null; then
				# [General] section exists — insert exclude line right after it.
				tmpfile=$(mktemp 2>/dev/null) || return 0
				awk -v path="$wt_path" \
					'/^\[General\]/{print; print "exclude folders[$e]=" path; next}1' \
					"$baloofilerc" > "$tmpfile" 2>/dev/null \
					&& mv "$tmpfile" "$baloofilerc" 2>/dev/null \
					|| { rm -f "$tmpfile" 2>/dev/null || true; return 0; }
			else
				# No [General] section — append one with the exclusion.
				printf "\n[General]\nexclude folders[\$e]=%s\n" "$wt_path" \
					>> "$baloofilerc" 2>/dev/null || true
			fi
			changed=1
		elif [[ "$current_excludes" != *"${wt_path}"* ]]; then
			# Exclusion line exists but path is not listed — append with comma.
			tmpfile=$(mktemp 2>/dev/null) || return 0
			awk -v old="$current_excludes" -v wt="$wt_path" \
				'$0 == old {print $0 "," wt; next}1' \
				"$baloofilerc" > "$tmpfile" 2>/dev/null \
				&& mv "$tmpfile" "$baloofilerc" 2>/dev/null \
				|| { rm -f "$tmpfile" 2>/dev/null || true; return 0; }
			changed=1
		fi
		# else: path already excluded — idempotent, no change needed.
	fi

	# Restart baloo only when something changed so it picks up the new config.
	if (( changed )); then
		"$balooctl" disable >/dev/null 2>&1 || true
		"$balooctl" enable >/dev/null 2>&1 || true
	fi

	return 0
}

###############################################################################
# Apply Plasma file indexer exclusion.
# On KDE Plasma the file indexer IS baloo — delegate to avoid duplication.
###############################################################################
_we_apply_plasma_indexer() {
	local wt_path="$1"
	_we_apply_baloo "$wt_path"
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

	if _we_is_macos; then
		_we_apply_spotlight "$wt_path"
		_we_apply_timemachine "$wt_path"
		# Backblaze is glob-based and root-only — applied via setup-backblaze, not
		# per-worktree.
		return 0
	fi

	if _we_is_linux; then
		_we_apply_tracker3 "$wt_path"
		_we_apply_baloo "$wt_path"
		# _we_apply_plasma_indexer delegates to baloo — already covered above.
		return 0
	fi

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

		# Use --porcelain so paths with spaces are handled correctly.
		# Each worktree block starts with "worktree <path>"; the last
		# variable in read captures the remainder of the line verbatim.
		# We emit only paths that are NOT the canonical repo path.
		local _key="" _wt=""
		while read -r _key _wt; do
			[[ "$_key" == "worktree" ]] || continue
			[[ -n "$_wt" ]] || continue
			[[ "$_wt" == "$repo_path" ]] && continue
			[[ -d "$_wt" ]] || continue
			printf '%s\n' "$_wt"
		done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null)
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
	if _we_is_macos; then
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
	fi

	if _we_is_linux; then
		_we_info "Platform: Linux"

		# tracker3 (GNOME / freedesktop.org file indexer)
		if _we_has_tracker3; then
			if command -v gsettings >/dev/null 2>&1; then
				_we_ok "tracker3: scriptable via gsettings org.freedesktop.Tracker3.Miner.Files + tracker3 reset"
			else
				_we_warn "tracker3: present but gsettings unavailable — only tracker3 reset applied (no persistent config exclusion)"
			fi
		else
			_we_info "tracker3: not found — skipping"
		fi

		# baloo (KDE Plasma file indexer; balooctl6 preferred over balooctl)
		if command -v balooctl6 >/dev/null 2>&1; then
			_we_ok "baloo (balooctl6): scriptable via ~/.config/baloofilerc — Plasma file indexer"
		elif command -v balooctl >/dev/null 2>&1; then
			_we_ok "baloo (balooctl): scriptable via ~/.config/baloofilerc — Plasma file indexer"
		else
			_we_info "baloo: not found — skipping"
		fi

		return 0
	fi

	_we_info "Platform: $(uname -s) — no indexer exclusions implemented"
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
worktree-exclusions-helper.sh - exclude worktrees from OS indexers and backup

Usage:
  worktree-exclusions-helper.sh apply <worktree-path>
  worktree-exclusions-helper.sh backfill [--dry-run]
  worktree-exclusions-helper.sh detect
  worktree-exclusions-helper.sh setup-backblaze
  worktree-exclusions-helper.sh help

Subcommands:
  apply           Apply indexer exclusions to one worktree. Idempotent.
                  macOS: Spotlight (.metadata_never_index) + Time Machine (tmutil).
                  Linux: tracker3 (gsettings + reset) + baloo (baloofilerc restart).
                  Best-effort (always exits 0).
  backfill        Apply to every worktree across registered repos.
                  Use --dry-run to preview without writing.
  detect          Report which tools are installed and scriptable.
  setup-backblaze Check/print the manual Backblaze setup step (macOS only).
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
