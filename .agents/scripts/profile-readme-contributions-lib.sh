#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Profile README Contributions Library -- Generation, Markers and Refresh
# =============================================================================
# Builds the auto-managed Contributions block from forks and repos.json
# contributed entries and refreshes it at most once per day:
#   1. Generate    -- fetch, validate and format contribution records
#   2. Markers     -- classify, normalize and migrate CONTRIBUTIONS markers
#   3. Throttle    -- daily refresh and pending-push bookkeeping
#   4. Publish     -- render, commit and push the contributions update
#
# Usage: source "${SCRIPT_DIR}/profile-readme-contributions-lib.sh"
#        (Sourced automatically by profile-readme-helper.sh)
#
# Dependencies:
#   - CONTRIBUTIONS_START_MARKER, CONTRIBUTIONS_END_MARKER -- globals defined
#     in profile-readme-helper.sh (orchestrator)
#   - _sanitize_md, _sanitize_url, _count_marker_mentions, _profile_replace_readme,
#     _normalize_readme_for_compare, _update_inject_timestamp -- orchestrator
#   - _profile_default_branch -- profile-readme-publication-lib.sh
#   - gh, jq, git
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PROFILE_README_CONTRIBUTIONS_LIB_LOADED:-}" ]] && return 0
_PROFILE_README_CONTRIBUTIONS_LIB_LOADED=1

# --- Fetch and validate one contribution record ---
# Prints a sanitized tab-separated name, description, and URL. API failures and
# malformed responses fail closed so error payloads can never become Markdown.
_fetch_contribution_record() {
	local endpoint="$1"
	local jq_filter="$2"
	local context="$3"
	local record=""
	local malformed_warning="Warning: malformed GitHub API response for ${context}"

	if ! record=$(gh api "$endpoint" --jq "$jq_filter" 2>/dev/null); then
		echo "Warning: GitHub API failed for ${context}" >&2
		return 1
	fi
	if [[ -z "$record" || "$record" == *$'\n'* ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi

	local name="${record%%$'\t'*}"
	local remainder="${record#*$'\t'}"
	if [[ "$remainder" == "$record" ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi
	local description="${remainder%%$'\t'*}"
	local url="${remainder#*$'\t'}"
	if [[ "$url" == "$remainder" || "$url" == *$'\t'* ]]; then
		echo "$malformed_warning" >&2
		return 1
	fi
	name=$(_sanitize_md "$name")
	description=$(_sanitize_md "$description")
	url=$(_sanitize_url "$url")
	if [[ "$name" == *'<'* || "$name" == *'>'* || "$description" == *'<'* || "$description" == *'>'* ]]; then
		echo "Warning: unsafe GitHub API record for ${context}" >&2
		return 1
	fi
	if [[ -z "$name" || -z "$url" ]]; then
		echo "Warning: invalid GitHub API record for ${context}" >&2
		return 1
	fi
	[[ -n "$description" ]] || description="No description"
	printf '%s\t%s\t%s\n' "$name" "$description" "$url"
	return 0
}

# --- List and validate fork names for the profile user ---
_list_profile_fork_names() {
	local gh_user="$1"
	local repos_json=""
	if ! repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate 2>/dev/null); then
		echo "Warning: GitHub API failed while listing profile repositories" >&2
		return 1
	fi
	if ! printf '%s\n' "$repos_json" | jq -e -s '
		length > 0 and all(.[];
			type == "array" and all(.[];
				type == "object"
				and (.fork | type) == "boolean"
				and (.name | type) == "string"
			)
		)
	' >/dev/null 2>&1; then
		echo "Warning: malformed GitHub API repository list" >&2
		return 1
	fi
	if ! printf '%s\n' "$repos_json" | jq -r '.[] | select(.fork == true) | .name'; then
		echo "Warning: could not parse GitHub API repository list" >&2
		return 1
	fi
	return 0
}

# --- Generate contributions list from forks + repos.json contributed entries ---
# Outputs markdown lines (one per contributed repo), or empty string if none.
# Uses core API only (no search API) — ~11 sequential calls per run. Sequential
# collection prevents concurrent gh output streams from interleaving.
# Deduplicates across all sources using a newline-delimited "seen" list with
# exact matching (bash 3.2 compatible — no associative arrays).
_generate_contributions() {
	local gh_user="$1"
	local contrib_repos=""
	# Newline-delimited list of repo names already added (for O(1)-ish dedup).
	# Each entry is stored as a full line for exact grep -x matching, avoiding
	# false positives from partial name matches (e.g., "app" vs "webapp").
	local seen_repos=""

	# Source 1: forks — resolve parent URLs
	local fork_names
	fork_names=$(_list_profile_fork_names "$gh_user") || return 1
	if [[ -n "$fork_names" ]]; then
		local fork_filter
		fork_filter='"\(.name // "")\t\((.description // "No description") | gsub("[\\t\\n\\r]"; " "))\t\(.parent.html_url // "")"'
		while IFS= read -r fork_name; do
			[[ -z "$fork_name" ]] && continue
			local fork_record
			fork_record=$(_fetch_contribution_record "repos/${gh_user}/${fork_name}" "$fork_filter" "fork ${fork_name}") || return 1
			local rname rdesc rurl
			IFS=$'\t' read -r rname rdesc rurl <<<"$fork_record"
			if [[ -n "$seen_repos" ]] && grep -qxF -- "$rname" <<<"$seen_repos" 2>/dev/null; then
				continue
			fi
			seen_repos="${seen_repos}${rname}"$'\n'
			contrib_repos="${contrib_repos}- **[${rname}](${rurl})** -- ${rdesc}"$'\n'
		done <<<"$fork_names"
	fi

	# Source 2: repos.json "contributed: true" entries (non-fork contributions)
	local repos_config="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_config" ]] && command -v jq &>/dev/null; then
		local contributed_slugs
		if ! contributed_slugs=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.contributed == true)
			| .slug // empty
		' "$repos_config" 2>/dev/null); then
			echo "Warning: could not parse contributed repositories config" >&2
			return 1
		fi

		local repo_filter
		repo_filter='"\(.name // "")\t\((.description // "No description") | gsub("[\\t\\n\\r]"; " "))\t\(.html_url // "")"'
		while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue
			local repo_name
			repo_name="${slug##*/}"
			# Deduplicate against all previously seen repos (forks + earlier entries)
			if [[ -n "$seen_repos" ]] && grep -qxF -- "$repo_name" <<<"$seen_repos" 2>/dev/null; then
				continue
			fi
			local repo_record desc url
			repo_record=$(_fetch_contribution_record "repos/${slug}" "$repo_filter" "repository ${slug}") || return 1
			IFS=$'\t' read -r repo_name desc url <<<"$repo_record"
			seen_repos="${seen_repos}${repo_name}"$'\n'
			contrib_repos="${contrib_repos}- **[${repo_name}](${url})** -- ${desc}"$'\n'
		done <<<"$contributed_slugs"
	fi

	# Sort alphabetically for deterministic output (prevents unnecessary commits
	# when the API returns results in a different order)
	if [[ -n "$contrib_repos" ]]; then
		contrib_repos=$(printf '%s' "$contrib_repos" | sort -f)
		# Ensure trailing newline
		contrib_repos="${contrib_repos}"$'\n'
	fi

	printf '%s' "$contrib_repos"
	return 0
}

# --- Generate contributions for a new rich README without blocking init ---
_generate_initial_contributions() {
	local gh_user="$1"
	local contributions=""
	if ! contributions=$(_generate_contributions "$gh_user"); then
		echo "Warning: initial Contributions block omitted because GitHub data was unavailable" >&2
		return 0
	fi
	printf '%s' "$contributions"
	return 0
}

# --- Classify contribution marker topology ---
_contribution_marker_state() {
	local readme_path="$1"
	if [[ ! -r "$readme_path" ]]; then
		printf '%s\n' invalid
		return 0
	fi
	local start_exact end_exact start_any end_any
	start_exact=$(grep -cFx "$CONTRIBUTIONS_START_MARKER" "$readme_path" 2>/dev/null || true)
	end_exact=$(grep -cFx "$CONTRIBUTIONS_END_MARKER" "$readme_path" 2>/dev/null || true)
	start_any=$(_count_marker_mentions "$readme_path" 'CONTRIBUTIONS-START')
	end_any=$(_count_marker_mentions "$readme_path" 'CONTRIBUTIONS-END')

	if [[ "$start_exact" -eq 1 && "$end_exact" -eq 1 && "$start_any" -eq 1 && "$end_any" -eq 1 ]]; then
		local start_line end_line
		start_line=$(grep -nFx "$CONTRIBUTIONS_START_MARKER" "$readme_path" | cut -d: -f1)
		end_line=$(grep -nFx "$CONTRIBUTIONS_END_MARKER" "$readme_path" | cut -d: -f1)
		[[ "$start_line" -lt "$end_line" ]] && printf '%s\n' valid || printf '%s\n' invalid
		return 0
	fi
	if [[ "$start_any" -eq 0 && "$end_any" -eq 0 ]]; then
		printf '%s\n' absent
		return 0
	fi
	if [[ "$start_exact" -eq 1 && "$start_any" -eq 1 && "$end_exact" -eq 0 && "$end_any" -eq 1 ]] &&
		awk -v marker="$CONTRIBUTIONS_END_MARKER" '
			index($0, marker) > 1 && index($0, marker) + length(marker) - 1 == length($0) { found = 1 }
			END { exit(found ? 0 : 1) }
		' "$readme_path"; then
		printf '%s\n' legacy-joined-end
		return 0
	fi
	printf '%s\n' invalid
	return 0
}

# --- Normalize the legacy generated form with END joined to the last item ---
_normalize_legacy_contribution_end() {
	local readme_path="$1"
	local output_path="$2"
	awk -v marker="$CONTRIBUTIONS_END_MARKER" '
		{
			position = index($0, marker)
			if (position > 1 && position + length(marker) - 1 == length($0)) {
				print substr($0, 1, position - 1)
				print marker
				next
			}
			print
		}
	' "$readme_path" >"$output_path"
	return $?
}

# --- Migrate static Contributions section to auto-updated markers ---
# Usage: _update_contributions_migrate_markers <readme_path> <dry_run>
_update_contributions_migrate_markers() {
	local readme_path="$1"
	local dry_run="$2"
	local marker_state
	marker_state=$(_contribution_marker_state "$readme_path")

	case "$marker_state" in
	valid)
		return 0
		;;
	invalid)
		echo "Error: Contributions markers must be one standalone, ordered pair" >&2
		return 1
		;;
	legacy-joined-end)
		if [[ "$dry_run" == true ]]; then
			echo "Note: legacy joined Contributions marker would be normalized"
			return 1
		fi
		local normalize_tmp
		normalize_tmp=$(mktemp)
		if ! _normalize_legacy_contribution_end "$readme_path" "$normalize_tmp"; then
			rm -f "$normalize_tmp"
			return 1
		fi
		if [[ "$(_contribution_marker_state "$normalize_tmp")" != valid ]]; then
			rm -f "$normalize_tmp"
			return 1
		fi
		_profile_replace_readme "$normalize_tmp" "$readme_path" || return 1
		return 0
		;;
	absent) ;;
	esac

	if [[ "$dry_run" == true ]]; then
		echo "Note: CONTRIBUTIONS markers not found — would migrate static section"
		return 1
	fi

	echo "Migrating static Contributions section to auto-updated markers..."
	local inject_tmp
	inject_tmp=$(mktemp)
	if ! awk -v start_marker="$CONTRIBUTIONS_START_MARKER" -v end_marker="$CONTRIBUTIONS_END_MARKER" '
		/^## Contributions/ { in_old_contrib = 1; next }
		in_old_contrib && /^## / {
			in_old_contrib = 0
			print start_marker
			print end_marker
			print ""
			print $0
			next
		}
		in_old_contrib { next }
		{ print }
	' "$readme_path" >"$inject_tmp"; then
		rm -f "$inject_tmp"
		return 1
	fi
	# If EOF reached while still in old section, append markers
	if ! grep -qxF "$CONTRIBUTIONS_START_MARKER" "$inject_tmp"; then
		{
			echo "$CONTRIBUTIONS_START_MARKER"
			echo "$CONTRIBUTIONS_END_MARKER"
		} >>"$inject_tmp"
	fi
	if [[ "$(_contribution_marker_state "$inject_tmp")" != valid ]]; then
		echo "Error: valid Contributions markers not found after migration" >&2
		rm -f "$inject_tmp"
		return 1
	fi
	_profile_replace_readme "$inject_tmp" "$readme_path" || return 1
	return 0
}

# --- Record the daily contributions throttle after a complete refresh ---
_record_contributions_update() {
	local cache_dir="${HOME}/.aidevops/cache"
	if ! mkdir -p "$cache_dir"; then
		echo "Warning: could not create contributions throttle cache" >&2
		return 1
	fi
	if ! date -u +"%Y-%m-%d" >"${cache_dir}/contributions-last-update"; then
		echo "Warning: could not record contributions refresh timestamp" >&2
		return 1
	fi
	return 0
}

# Print the cache path that records a contributions commit awaiting publication.
_contributions_pending_push_file() {
	printf '%s\n' "${HOME}/.aidevops/cache/contributions-pending-push"
	return 0
}

# Record HEAD from the profile repository ($1) for a later push retry.
# Return non-zero if the cache directory or commit record cannot be written.
_record_pending_contributions_push() {
	local profile_repo="$1"
	local pending_file
	pending_file=$(_contributions_pending_push_file)
	mkdir -p "${pending_file%/*}" || return 1
	git -C "$profile_repo" rev-parse HEAD >"$pending_file"
	return $?
}

# Remove the pending-push record after publication; missing records are harmless.
_clear_pending_contributions_push() {
	local pending_file
	pending_file=$(_contributions_pending_push_file)
	rm -f "$pending_file"
	return 0
}

# --- Commit and push contributions update, recording daily throttle timestamp ---
# Usage: _update_contributions_push <profile_repo>
_update_contributions_push() {
	local profile_repo="$1"
	local readme_path="${profile_repo}/README.md"

	# Update timestamp
	_update_inject_timestamp "$readme_path"

	local commit_msg
	commit_msg="chore: update profile contributions ($(date -u +%Y-%m-%d))"
	git -C "$profile_repo" add README.md
	if ! git -C "$profile_repo" commit -m "$commit_msg" --no-verify -- README.md 2>/dev/null; then
		echo "Warning: contributions commit failed" >&2
		return 1
	fi
	_record_pending_contributions_push "$profile_repo" || return 1

	local default_branch
	default_branch=$(_profile_default_branch "$profile_repo")
	if ! git -C "$profile_repo" push origin "HEAD:refs/heads/${default_branch}" 2>/dev/null; then
		echo "Warning: push failed — contributions committed locally" >&2
		return 1
	fi
	_clear_pending_contributions_push
	_record_contributions_update || return 1

	echo "Profile contributions updated and pushed"
	return 0
}

# --- Verify a profile write cannot publish unrelated local work ---
_ensure_profile_write_ready() {
	local profile_repo="$1"
	local readme_status=""
	if ! readme_status=$(git -C "$profile_repo" status --porcelain -- README.md 2>/dev/null); then
		echo "Warning: could not verify local profile README state" >&2
		return 1
	fi
	if [[ -n "$readme_status" ]]; then
		echo "Warning: local profile README has uncommitted changes; refusing automated commit" >&2
		return 1
	fi
	if ! git -C "$profile_repo" diff --cached --quiet; then
		echo "Warning: profile repository has unrelated staged changes" >&2
		return 1
	fi

	local default_branch ahead_count pending_file pending_sha head_sha
	default_branch=$(_profile_default_branch "$profile_repo")
	if ! ahead_count=$(git -C "$profile_repo" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null); then
		echo "Warning: could not verify whether profile contributions were pushed" >&2
		return 1
	fi
	if [[ "$ahead_count" -gt 0 ]] 2>/dev/null; then
		pending_file=$(_contributions_pending_push_file)
		if [[ ! -f "$pending_file" ]]; then
			echo "Warning: local profile branch has unrelated unpushed commits" >&2
			return 1
		fi
		pending_sha=$(<"$pending_file")
		head_sha=$(git -C "$profile_repo" rev-parse HEAD 2>/dev/null || true)
		if [[ -z "$pending_sha" || "$pending_sha" != "$head_sha" ]]; then
			echo "Warning: pending contributions marker does not match local profile HEAD" >&2
			return 1
		fi
		if ! git -C "$profile_repo" push origin "$default_branch" 2>/dev/null; then
			echo "Warning: pending profile contributions push failed" >&2
			return 1
		fi
	fi
	_clear_pending_contributions_push
	return 0
}

# --- Complete a local no-op without suppressing pending push retries ---
_finalize_unchanged_contributions() {
	local profile_repo="$1"
	_ensure_profile_write_ready "$profile_repo" || return 1
	_record_contributions_update || return 1
	return 0
}

# --- Render a validated contributions block into a candidate README ---
_render_contributions_candidate() {
	local readme_path="$1"
	local new_contribs="$2"
	local contribs_block=""
	if [[ -n "$new_contribs" ]]; then
		contribs_block="## Contributions"$'\n'$'\n'"${new_contribs}"$'\n'
	fi
	if ! CONTRIBS_BLOCK="$contribs_block" awk \
		-v start_marker="$CONTRIBUTIONS_START_MARKER" \
		-v end_marker="$CONTRIBUTIONS_END_MARKER" '
		$0 == start_marker {
			print
			skip = 1
			next
		}
		$0 == end_marker {
			skip = 0
			block = ENVIRON["CONTRIBS_BLOCK"]
			if (block != "") {
				printf "%s", block
			}
			print
			next
		}
		!skip { print }
	' "$readme_path"; then
		return 1
	fi
	return 0
}

# --- Update contributions section between markers ---
# Can be called standalone or from cmd_update with daily throttle.
# Uses _generate_contributions() to fetch fork parent URLs + repos.json entries.
_cmd_update_contributions_in_repo() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi

	# Resolve profile repo and user
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Resolve GitHub username
	local gh_user
	gh_user=$(_resolve_profile_user "$profile_repo")
	if [[ -z "$gh_user" ]]; then
		echo "Error: could not resolve GitHub username for profile repo" >&2
		return 1
	fi

	# Generate new contributions content
	local new_contribs
	if ! new_contribs=$(_generate_contributions "$gh_user"); then
		echo "Warning: contributions refresh aborted; existing Contributions block was preserved" >&2
		return 1
	fi
	if [[ "$dry_run" != true ]]; then
		_ensure_profile_write_ready "$profile_repo" || return 1
	fi

	# Build every migration and render in temporary files. README.md is replaced
	# only after all remote reads, marker transforms, and rendering succeed.
	local migration_source
	migration_source=$(mktemp)
	if ! cp "$readme_path" "$migration_source"; then
		rm -f "$migration_source"
		return 1
	fi
	if ! _update_contributions_migrate_markers "$migration_source" "$dry_run"; then
		rm -f "$migration_source"
		if [[ "$dry_run" == true ]] && [[ "$(_contribution_marker_state "$readme_path")" == absent ]]; then
			return 0
		fi
		return 1
	fi

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp)
	if ! _render_contributions_candidate "$migration_source" "$new_contribs" >"$tmp_file"; then
		rm -f "$migration_source" "$tmp_file"
		return 1
	fi
	rm -f "$migration_source"

	# Check if content actually changed
	if diff -q "$readme_path" "$tmp_file" >/dev/null 2>&1; then
		echo "Contributions unchanged — skipping"
		rm -f "$tmp_file"
		if [[ "$dry_run" != true ]]; then
			_finalize_unchanged_contributions "$profile_repo" || return 1
		fi
		return 0
	fi

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: contributions changes ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	if ! _profile_replace_readme "$tmp_file" "$readme_path"; then
		rm -f "$tmp_file"
		return 1
	fi
	if [[ "${AIDEVOPS_PROFILE_DEFER_PUBLICATION:-0}" == "1" ]]; then
		echo "Profile contributions staged for the combined README publication"
		return 0
	fi
	_update_contributions_push "$profile_repo" || return 1
	return 0
}
