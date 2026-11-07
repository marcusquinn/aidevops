#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Profile README Projects block generation, marker migration, and refresh.
# Sourced by profile-readme-helper.sh; uses its markers and README replacement helper.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PROFILE_README_PROJECTS_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_PROJECTS_LIB_LOADED=1

# --- Generate the owned public Projects list ---
# One sanitized Markdown line per public, non-fork, non-archived repository
# owned by the user, excluding the profile repository itself. Ordered by stars,
# then name, so new repositories appear without hand edits. API failures and
# malformed responses fail closed so the existing block is preserved.
_generate_projects() {
	local gh_user="$1"
	local repos_json=""
	local projects=""

	if ! repos_json=$(gh api "users/${gh_user}/repos?per_page=100&type=owner" --paginate 2>/dev/null); then
		echo "Warning: GitHub API failed while listing profile projects" >&2
		return 1
	fi
	# users/{user}/repos returns public repositories only; the private filter is
	# defence in depth so a private name can never reach the public profile.
	if ! projects=$(printf '%s\n' "$repos_json" | jq -er -s --arg user "$gh_user" '
		if length > 0 and all(.[]; type == "array" and all(.[];
			type == "object" and ([.name, .html_url | strings] | length) == 2
			and (.fork | type) == "boolean"))
		then
			[.[][]
			 | select(.fork == false and (.archived // false) == false and (.private // false) == false)
			 | select((.name | ascii_downcase) != ($user | ascii_downcase))
			 | select(.html_url | test("^https://github[.]com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"))]
			| sort_by([-(.stargazers_count // 0), (.name | ascii_downcase)])
			| map("- **[\(.name | gsub("[^A-Za-z0-9._-]"; ""))](\(.html_url))** -- \(
				(.description // "") | gsub("[\\t\\n\\r]"; " ") | gsub("[\\[\\]()`<>]"; "")
				| if . == "" then "No description" else . end)")
			| join("\n")
		else error("malformed") end
	' 2>/dev/null); then
		echo "Warning: malformed GitHub API response for profile projects" >&2
		return 1
	fi
	printf '%s' "$projects"
	return 0
}

# --- Classify Projects marker topology: valid, absent or invalid ---
_projects_marker_state() {
	local readme_path="$1"
	local start_exact end_exact start_any end_any start_line end_line
	[[ -r "$readme_path" ]] || {
		printf '%s\n' invalid
		return 0
	}
	start_exact=$(grep -cFx "$PROJECTS_START_MARKER" "$readme_path" 2>/dev/null || true)
	end_exact=$(grep -cFx "$PROJECTS_END_MARKER" "$readme_path" 2>/dev/null || true)
	start_any=$(_count_marker_mentions "$readme_path" 'PROJECTS-START')
	end_any=$(_count_marker_mentions "$readme_path" 'PROJECTS-END')
	if [[ "$start_any" -eq 0 && "$end_any" -eq 0 ]]; then
		printf '%s\n' absent
		return 0
	fi
	if [[ "$start_exact" -eq 1 && "$end_exact" -eq 1 && "$start_any" -eq 1 && "$end_any" -eq 1 ]]; then
		start_line=$(grep -nFx "$PROJECTS_START_MARKER" "$readme_path" | cut -d: -f1)
		end_line=$(grep -nFx "$PROJECTS_END_MARKER" "$readme_path" | cut -d: -f1)
		if [[ "$start_line" -lt "$end_line" ]]; then
			printf '%s\n' valid
			return 0
		fi
	fi
	printf '%s\n' invalid
	return 0
}

# --- Ensure a candidate README has one Projects marker pair ---
# Returns 0 with valid markers, 2 when the README has not opted in, 1 when the
# markers are malformed. Only the static "## Projects" section written by older
# aidevops init is adopted; hand-written READMEs opt in by adding the markers.
_projects_ensure_markers() {
	local readme_path="$1"
	local state=""
	local heading_count=""
	local migrate_tmp=""

	state=$(_projects_marker_state "$readme_path")
	case "$state" in
	valid) return 0 ;;
	invalid)
		echo "Warning: Projects markers must be one standalone, ordered pair; Projects block preserved" >&2
		return 1
		;;
	esac
	grep -Fq '> Stats auto-updated by [aidevops]' "$readme_path" 2>/dev/null || return 2
	heading_count=$(grep -cE '^## Projects[[:space:]]*$' "$readme_path" 2>/dev/null || true)
	[[ "$heading_count" == "1" ]] || return 2

	echo "Migrating static Projects section to auto-updated markers..."
	migrate_tmp=$(mktemp) || return 1
	if ! awk -v start_marker="$PROJECTS_START_MARKER" -v end_marker="$PROJECTS_END_MARKER" '
		/^## Projects[[:space:]]*$/ { in_section = 1; next }
		in_section && (/^## / || /^<!-- /) {
			print start_marker
			print end_marker
			print ""
			in_section = 0
		}
		in_section { next }
		{ print }
		END {
			if (in_section) {
				print start_marker
				print end_marker
			}
		}
	' "$readme_path" >"$migrate_tmp" || [[ "$(_projects_marker_state "$migrate_tmp")" != valid ]]; then
		rm -f "$migrate_tmp"
		return 1
	fi
	_profile_replace_readme "$migrate_tmp" "$readme_path" || return 1
	return 0
}

# --- Render a validated Projects block between its markers ---
_render_projects_candidate() {
	local readme_path="$1"
	local projects="$2"
	local block=""
	if [[ -n "$projects" ]]; then
		block="## Projects"$'\n'$'\n'"${projects}"$'\n'
	fi
	PROJECTS_BLOCK="$block" awk -v start_marker="$PROJECTS_START_MARKER" -v end_marker="$PROJECTS_END_MARKER" '
		$0 == start_marker { print; skip = 1; next }
		$0 == end_marker {
			skip = 0
			printf "%s", ENVIRON["PROJECTS_BLOCK"]
			print
			next
		}
		!skip { print }
	' "$readme_path"
	return $?
}

# --- Refresh the auto-managed Projects block in a candidate README ---
# Runs on every update so newly created public repositories appear within one
# scheduler interval. Never blocks stats publication: on any failure the
# candidate keeps its previous Projects content.
_refresh_projects_block() {
	local readme_path="$1"
	local gh_user="$2"
	local work_tmp=""
	local render_tmp=""
	local projects=""
	local ensure_rc=0

	[[ -n "$gh_user" && -f "$readme_path" ]] || return 0
	work_tmp=$(mktemp) || return 0
	if ! cp "$readme_path" "$work_tmp"; then
		rm -f "$work_tmp"
		return 0
	fi
	_projects_ensure_markers "$work_tmp" || ensure_rc=$?
	if [[ "$ensure_rc" -ne 0 ]]; then
		rm -f "$work_tmp"
		return 0
	fi
	if ! projects=$(_generate_projects "$gh_user"); then
		echo "Warning: Projects refresh skipped; existing Projects block was preserved" >&2
		rm -f "$work_tmp"
		return 0
	fi
	render_tmp=$(mktemp) || {
		rm -f "$work_tmp"
		return 0
	}
	if ! _render_projects_candidate "$work_tmp" "$projects" >"$render_tmp" ||
		[[ "$(_projects_marker_state "$render_tmp")" != valid ]]; then
		echo "Warning: Projects render failed; existing Projects block was preserved" >&2
		rm -f "$work_tmp" "$render_tmp"
		return 0
	fi
	rm -f "$work_tmp"
	if ! _profile_replace_readme "$render_tmp" "$readme_path"; then
		echo "Warning: could not apply refreshed Projects block" >&2
	fi
	return 0
}
