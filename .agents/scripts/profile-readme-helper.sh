#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# profile-readme-helper.sh — Auto-update GitHub profile README with live stats
#
# Usage:
#   profile-readme-helper.sh init                  # Create profile repo, seed README, register
#   profile-readme-helper.sh update [--dry-run]    # Update README with live data
#   profile-readme-helper.sh generate              # Print generated stats section to stdout
#   profile-readme-helper.sh help
#
# Requires:
#   - screen-time-helper.sh (macOS screen time)
#   - contributor-activity-helper.sh (AI session time)
#   - jq, bc, git
#
# The profile repo README must contain marker comments:
#   <!-- STATS-START --> ... <!-- STATS-END -->
#   <!-- UPDATED-START --> ... <!-- UPDATED-END -->
# Optional auto-managed blocks:
#   <!-- PROJECTS-START --> ... <!-- PROJECTS-END -->            (every update)
#   <!-- CONTRIBUTIONS-START --> ... <!-- CONTRIBUTIONS-END -->  (daily)
#
# Thin orchestrator: shared globals, README helpers, init/update commands and
# dispatch live here; cohesive function groups live in sourced sub-libraries:
#   profile-readme-data-lib.sh          (stats data collection and formatting)
#   profile-readme-render-lib.sh        (stats section rendering)
#   profile-readme-publication-lib.sh   (update lock, isolated publication worktree)
#   profile-readme-contributions-lib.sh (Contributions block generation and refresh)
#   profile-readme-projects-lib.sh      (Projects block generation and refresh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=portable-stat.sh
source "${SCRIPT_DIR}/portable-stat.sh"
# shellcheck source=audit-worktree-removal-helper.sh
source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
METRICS_FILE="${HOME}/.aidevops/.agent-workspace/observability/metrics.jsonl"
OBS_DB_FILE="${HOME}/.aidevops/.agent-workspace/observability/llm-requests.db"
OPENCODE_DB_FILE="${HOME}/.local/share/opencode/opencode.db"
OPENCODE_ARCHIVE_DB_FILE="${HOME}/.local/share/opencode/opencode-archive.db"
CONTRIBUTIONS_START_MARKER='<!-- CONTRIBUTIONS-START -->'
CONTRIBUTIONS_END_MARKER='<!-- CONTRIBUTIONS-END -->'
PROJECTS_START_MARKER='<!-- PROJECTS-START -->'
PROJECTS_END_MARKER='<!-- PROJECTS-END -->'
PROFILE_UPDATE_LOCK_TOKEN=""
PROFILE_UPDATE_LOCK_GRACE_SECONDS="${AIDEVOPS_PROFILE_LOCK_GRACE_SECONDS:-30}"
PROFILE_PUBLICATION_WORKTREE=""
PROFILE_PUBLICATION_CANONICAL_REPO=""
PROFILE_PUBLICATION_WORKTREE_BASE=""
PROFILE_PUBLICATION_CANONICAL_HEAD=""
PROFILE_PUBLICATION_CANONICAL_STATUS=""
PROFILE_PUBLICATION_INTENT_PATH=""
PROFILE_PUBLICATION_REGISTRY_TASK="profile-readme"
PROFILE_PUBLICATION_INTENT_SCHEMA="aidevops-profile-publication-intent/v1"
PROFILE_CONTRIBUTIONS_REFRESHED=false

# --- Resolve profile repo path from repos.json ---
_resolve_profile_repo() {
	if [[ -n "${AIDEVOPS_PROFILE_REPO_OVERRIDE:-}" ]]; then
		local override_git_dir=""
		local override_common_dir=""
		local canonical_common_dir=""
		if [[ ! -d "$AIDEVOPS_PROFILE_REPO_OVERRIDE" ]] ||
			! git -C "$AIDEVOPS_PROFILE_REPO_OVERRIDE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
			echo "Error: profile repository override is not a Git worktree" >&2
			return 1
		fi
		override_git_dir=$(git -C "$AIDEVOPS_PROFILE_REPO_OVERRIDE" rev-parse --path-format=absolute --git-dir) || return 1
		override_common_dir=$(git -C "$AIDEVOPS_PROFILE_REPO_OVERRIDE" rev-parse --path-format=absolute --git-common-dir) || return 1
		if [[ "$override_git_dir" == "$override_common_dir" ]]; then
			echo "Error: profile repository override must be a linked worktree" >&2
			return 1
		fi
		if [[ -z "${AIDEVOPS_PROFILE_CANONICAL_REPO:-}" ]] ||
			! canonical_common_dir=$(git -C "$AIDEVOPS_PROFILE_CANONICAL_REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
			[[ "$canonical_common_dir" != "$override_common_dir" ]]; then
			echo "Error: profile repository override does not match its canonical repository" >&2
			return 1
		fi
		printf '%s\n' "$AIDEVOPS_PROFILE_REPO_OVERRIDE"
		return 0
	fi
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Try repos.json first (primary lookup)
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local profile_path
		profile_path=$(jq -r '
			(.initialized_repos // (to_entries | map(.value)))[]
			| select(.priority == "profile")
			| .path // empty
		' "$repos_json" | head -1)

		if [[ -n "$profile_path" && -d "$profile_path" ]]; then
			echo "$profile_path"
			return 0
		fi
	fi

	# Self-healing fallback: find profile repo by convention (~/Git/$username).
	# This handles the case where cmd_init created the repo but repos.json
	# registration failed or was lost. The hourly update job would otherwise
	# silently fail forever.
	local gh_user=""
	if command -v gh &>/dev/null; then
		gh_user=$(gh api user --jq '.login' 2>/dev/null) || true
	fi
	if [[ -z "$gh_user" ]]; then
		echo "Error: no profile repo in repos.json and gh CLI unavailable for fallback" >&2
		return 1
	fi

	local convention_path="${HOME}/Git/${gh_user}"
	if [[ -d "$convention_path" ]] && [[ -f "${convention_path}/README.md" ]]; then
		# Found it — auto-register in repos.json so future lookups are fast.
		# Don't require markers — cmd_init/cmd_update will inject them if missing.
		echo "Auto-registering profile repo at $convention_path" >&2
		if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
			local tmp_json
			tmp_json=$(mktemp)
			if jq --arg path "$convention_path" --arg slug "${gh_user}/${gh_user}" '
				.initialized_repos += [{
					"path": $path,
					"slug": $slug,
					"priority": "profile",
					"pulse": false,
					"maintainer": ($slug | split("/")[0])
				}]
			' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
				mv "$tmp_json" "$repos_json"
			else
				echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
				rm -f "$tmp_json"
			fi
		fi
		echo "$convention_path"
		return 0
	fi

	# Last resort: try cmd_init to create/clone/register everything
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		echo "No profile repo found — running init to create one" >&2
		if cmd_init >&2; then
			# Re-resolve after init
			local init_path="${HOME}/Git/${gh_user}"
			if [[ -d "$init_path" ]]; then
				echo "$init_path"
				return 0
			fi
		fi
	fi

	echo "Error: no profile repo found and could not auto-create one" >&2
	return 1
}

# --- Source sub-libraries ---
# shellcheck source=profile-readme-data-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-data-lib.sh"
# shellcheck source=profile-readme-render-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-render-lib.sh"
# shellcheck source=profile-readme-publication-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-publication-lib.sh"
# shellcheck source=profile-readme-contributions-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-contributions-lib.sh"
# shellcheck source=profile-readme-projects-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/profile-readme-projects-lib.sh"

# =============================================================================
# Profile README Management — Badges, README Generation, Clone/Init, Update
# =============================================================================

# --- Map language name to shields.io badge ---
_lang_badge() {
	local lang="$1"
	case "$lang" in
	Shell) echo '![Shell](https://img.shields.io/badge/-Shell-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)' ;;
	TypeScript) echo '![TypeScript](https://img.shields.io/badge/-TypeScript-3178C6?style=flat-square&logo=typescript&logoColor=white)' ;;
	JavaScript) echo '![JavaScript](https://img.shields.io/badge/-JavaScript-F7DF1E?style=flat-square&logo=javascript&logoColor=black)' ;;
	Python) echo '![Python](https://img.shields.io/badge/-Python-3776AB?style=flat-square&logo=python&logoColor=white)' ;;
	Ruby) echo '![Ruby](https://img.shields.io/badge/-Ruby-CC342D?style=flat-square&logo=ruby&logoColor=white)' ;;
	Go) echo '![Go](https://img.shields.io/badge/-Go-00ADD8?style=flat-square&logo=go&logoColor=white)' ;;
	Rust) echo '![Rust](https://img.shields.io/badge/-Rust-000000?style=flat-square&logo=rust&logoColor=white)' ;;
	Java) echo '![Java](https://img.shields.io/badge/-Java-007396?style=flat-square&logo=openjdk&logoColor=white)' ;;
	PHP) echo '![PHP](https://img.shields.io/badge/-PHP-777BB4?style=flat-square&logo=php&logoColor=white)' ;;
	C) echo '![C](https://img.shields.io/badge/-C-A8B9CC?style=flat-square&logo=c&logoColor=black)' ;;
	"C++") echo '![C++](https://img.shields.io/badge/-C++-00599C?style=flat-square&logo=cplusplus&logoColor=white)' ;;
	"C#") echo '![C#](https://img.shields.io/badge/-C%23-239120?style=flat-square&logo=csharp&logoColor=white)' ;;
	Swift) echo '![Swift](https://img.shields.io/badge/-Swift-FA7343?style=flat-square&logo=swift&logoColor=white)' ;;
	Kotlin) echo '![Kotlin](https://img.shields.io/badge/-Kotlin-7F52FF?style=flat-square&logo=kotlin&logoColor=white)' ;;
	Dart) echo '![Dart](https://img.shields.io/badge/-Dart-0175C2?style=flat-square&logo=dart&logoColor=white)' ;;
	HTML) echo '![HTML](https://img.shields.io/badge/-HTML-E34F26?style=flat-square&logo=html5&logoColor=white)' ;;
	CSS) echo '![CSS](https://img.shields.io/badge/-CSS-1572B6?style=flat-square&logo=css3&logoColor=white)' ;;
	Lua) echo '![Lua](https://img.shields.io/badge/-Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)' ;;
	Elixir) echo '![Elixir](https://img.shields.io/badge/-Elixir-4B275F?style=flat-square&logo=elixir&logoColor=white)' ;;
	Scala) echo '![Scala](https://img.shields.io/badge/-Scala-DC322F?style=flat-square&logo=scala&logoColor=white)' ;;
	Haskell) echo '![Haskell](https://img.shields.io/badge/-Haskell-5D4F85?style=flat-square&logo=haskell&logoColor=white)' ;;
	Vue) echo '![Vue](https://img.shields.io/badge/-Vue-4FC08D?style=flat-square&logo=vuedotjs&logoColor=white)' ;;
	Svelte) echo '![Svelte](https://img.shields.io/badge/-Svelte-FF3E00?style=flat-square&logo=svelte&logoColor=white)' ;;
	*) echo "![${lang}](https://img.shields.io/badge/-${lang// /%20}-555555?style=flat-square)" ;;
	esac
	return 0
}

# --- Sanitize a string for safe use in markdown ---
# Strips characters that could break markdown link/image syntax
_sanitize_md() {
	local input="$1"
	# Remove markdown-breaking characters: [ ] ( ) and backticks
	local sanitized
	sanitized="${input//[\[\]()]/}"
	sanitized="${sanitized//\`/}"
	echo "$sanitized"
	return 0
}

# --- Validate a URL for safe embedding in markdown ---
# Rejects javascript: URIs, non-http(s) schemes, and markdown-breaking chars
_sanitize_url() {
	local url="$1"
	# Must start with http:// or https:// (case-insensitive)
	local url_lower
	url_lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
	if [[ "$url_lower" != http://* && "$url_lower" != https://* ]]; then
		echo ""
		return 0
	fi
	# Reject URLs containing markdown-breaking characters or whitespace
	if [[ "$url" == *'('* || "$url" == *')'* || "$url" == *'['* || "$url" == *']'* || "$url" == *' '* ]]; then
		echo ""
		return 0
	fi
	echo "$url"
	return 0
}

# --- Resolve GitHub username for profile repo ---
_resolve_profile_user() {
	local profile_repo="$1"

	# Try origin remote first (owner/repo)
	local origin_url
	origin_url=$(git -C "$profile_repo" remote get-url origin 2>/dev/null || true)
	if [[ -n "$origin_url" ]]; then
		local slug
		slug=$(echo "$origin_url" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
		local owner repo
		owner="${slug%%/*}"
		repo="${slug##*/}"
		if [[ -n "$owner" && "$owner" == "$repo" ]]; then
			echo "$owner"
			return 0
		fi
	fi

	# Fallback to directory basename
	local fallback_repo="${AIDEVOPS_PROFILE_CANONICAL_REPO:-$profile_repo}"
	local base=""
	base=$(basename "$fallback_repo")
	if [[ -n "$base" ]]; then
		echo "$base"
		return 0
	fi

	echo ""
	return 0
}

# --- Normalize README for no-op comparison ---
# Strips UPDATED and CONTRIBUTIONS blocks so timestamp/contribution changes
# don't suppress real stats diffs (and vice versa).
_normalize_readme_for_compare() {
	local file="$1"
	awk '
		/<!-- UPDATED-START -->/ { print; skip = 1; next }
		/<!-- UPDATED-END -->/ { skip = 0; print; next }
		/<!-- CONTRIBUTIONS-START -->/ { print; skip = 1; next }
		/<!-- CONTRIBUTIONS-END -->/ { skip = 0; print; next }
		!skip { print }
	' "$file"
	return 0
}

# --- Detect if a README is the default GitHub profile template ---
# Returns 0 (true) if the file matches the default template pattern.
# The default template contains "## Hi there" and the commented-out suggestions
# block that GitHub auto-generates for new username/username repos.
_is_default_github_template() {
	local readme_path="$1"
	if [[ ! -f "$readme_path" ]]; then
		return 1
	fi
	# Check for the distinctive GitHub default template markers:
	# 1. The "Hi there" heading (with or without emoji)
	# 2. The commented-out "is a special repository" block
	if grep -q 'Hi there' "$readme_path" 2>/dev/null &&
		grep -q 'is a.*special.*repository' "$readme_path" 2>/dev/null; then
		return 0
	fi
	# Also match minimal default READMEs that just have "# username" and nothing else
	local line_count
	line_count=$(wc -l <"$readme_path" | tr -d ' ')
	if [[ "$line_count" -le 3 ]] && ! grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
		return 0
	fi
	return 1
}

# Preserve the existing file mode when replacing a README with a mktemp file.
# Do not turn an ordinary 0644 README into unsupported 0600 recovery state,
# or normalize permissions deliberately selected by the operator.
_profile_replace_readme() {
	local candidate="$1"
	local readme_path="$2"
	[[ -f "$candidate" && ! -L "$candidate" && -f "$readme_path" && ! -L "$readme_path" ]] || return 1
	if ! python3 -c 'import shutil, sys; shutil.copymode(sys.argv[2], sys.argv[1])' "$candidate" "$readme_path" ||
		! mv "$candidate" "$readme_path"; then
		rm -f "$candidate"
		return 1
	fi
	return 0
}

# --- Inject aidevops markers into an existing README that lacks them ---
# Preserves all existing content and appends marker blocks at the end.
# This handles the case where a user has manually written their README
# (or GitHub created the default template) and we need to add our stats.
_inject_markers_into_readme() {
	local readme_path="$1"
	local tmp_file
	tmp_file=$(mktemp)

	# Copy existing content
	cat "$readme_path" >"$tmp_file"

	# Ensure trailing newline before appending
	if [[ -s "$tmp_file" ]] && [[ "$(tail -c 1 "$tmp_file" | wc -l)" -eq 0 ]]; then
		echo "" >>"$tmp_file"
	fi

	# Append marker blocks
	{
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on next update -->"
		echo "<!-- STATS-END -->"
		echo ""
		echo "<!-- CONTRIBUTIONS-START -->"
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
	} >>"$tmp_file"

	_profile_replace_readme "$tmp_file" "$readme_path" || return 1
	return 0
}

# --- Recover from diverged git history on the profile repo ---
# When the remote repo was deleted and recreated, the local clone has a
# different history. This function re-clones the repo and re-seeds the README.
_recover_diverged_profile() {
	local repo_dir="$1"
	local repo_slug="$2"
	local default_branch="$3"
	local gh_user="$4"

	echo "Recovering profile repo from diverged history..." >&2

	# Back up the local directory and re-clone
	local backup_dir="${repo_dir}.bak.$$"
	mv "$repo_dir" "$backup_dir"

	if git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
		git clone "https://github.com/${repo_slug}.git" "$repo_dir" 2>/dev/null; then
		# Re-seed the README with markers
		local readme_path="${repo_dir}/README.md"
		if [[ -f "$readme_path" ]] && grep -q '<!-- STATS-START -->' "$readme_path" 2>/dev/null; then
			echo "Remote README already has markers — no seeding needed"
		elif [[ ! -f "$readme_path" ]] || _is_default_github_template "$readme_path"; then
			echo "Creating rich profile README..."
			_generate_rich_readme "$gh_user" "$readme_path"
		elif [[ -f "$readme_path" ]]; then
			echo "Injecting markers into remote README..."
			_inject_markers_into_readme "$readme_path"
		fi

		# Commit and push the seeded README
		if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
			git -C "$repo_dir" add README.md
			git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
			git -C "$repo_dir" push origin "$default_branch" 2>/dev/null || {
				echo "Warning: push failed after re-clone — push manually" >&2
			}
		fi

		# Clean up backup
		rm -rf "$backup_dir"
		echo "Profile repo recovered successfully"
	else
		# Re-clone failed — restore backup
		echo "Error: re-clone failed — restoring backup" >&2
		rm -rf "$repo_dir"
		mv "$backup_dir" "$repo_dir"
	fi

	return 0
}

# --- Build language + tooling badge line for a user's repos ---
# Usage: _build_readme_badges <repos_json>
# Outputs badge markdown lines (one per badge).
_build_readme_badges() {
	local repos_json="$1"

	local languages
	languages=$(echo "$repos_json" | jq -r '[.[].language | select(. != null)] | unique | .[]')

	local badges=""
	while IFS= read -r lang; do
		[[ -z "$lang" ]] && continue
		local badge
		badge=$(_lang_badge "$lang")
		badges="${badges}${badge}"$'\n'
	done <<<"$languages"
	# Always add common tooling badges
	badges="${badges}"'![Docker](https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white)'$'\n'
	badges="${badges}"'![Linux](https://img.shields.io/badge/-Linux-FCC624?style=flat-square&logo=linux&logoColor=black)'$'\n'
	badges="${badges}"'![Git](https://img.shields.io/badge/-Git-F05032?style=flat-square&logo=git&logoColor=white)'$'\n'

	printf '%s' "$badges"
	return 0
}

# --- Build the Connect section badges for a user ---
# Usage: _build_readme_connect <gh_user> <blog> <twitter>
# Outputs badge markdown lines.
_build_readme_connect() {
	local gh_user="$1"
	local blog="$2"
	local twitter="$3"

	local connect=""
	if [[ -n "$blog" ]]; then
		local blog_display
		blog_display="${blog##*//}"
		blog_display=$(_sanitize_md "$blog_display")
		connect="${connect}[![Website](https://img.shields.io/badge/-${blog_display}-FF5722?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBhdGggZmlsbD0id2hpdGUiIGQ9Ik0xMiAyQzYuNDggMiAyIDYuNDggMiAxMnM0LjQ4IDEwIDEwIDEwIDEwLTQuNDggMTAtMTBTMTcuNTIgMiAxMiAyem0tMSAxNy45M2MtMy45NS0uNDktNy0zLjg1LTctNy45MyAwLS42Mi4wOC0xLjIxLjIxLTEuNzlMOSAxNXY1YzAgLjU1LjQ1IDEgMSAxdjEuOTN6bTYuOS0yLjU0Yy0uMjYtLjgxLTEtMS4zOS0xLjktMS4zOWgtMXYtM2MwLS41NS0uNDUtMS0xLTFIOHYtMmgyYy41NSAwIDEtLjQ1IDEtMVY3aDJjMS4xIDAgMi0uOSAyLTJ2LS40MWMyLjkzIDEuMTkgNSA0LjA2IDUgNy40MSAwIDIuMDgtLjggMy45Ny0yLjEgNS4zOXoiLz48L3N2Zz4=&logoColor=white)](${blog})"$'\n'
	fi
	if [[ -n "$twitter" ]]; then
		connect="${connect}[![X](https://img.shields.io/badge/-@${twitter}-000000?style=flat-square&logo=x&logoColor=white)](https://twitter.com/${twitter})"$'\n'
	fi
	connect="${connect}[![GitHub](https://img.shields.io/badge/-Follow-181717?style=flat-square&logo=github&logoColor=white)](https://github.com/${gh_user})"$'\n'

	printf '%s' "$connect"
	return 0
}

# --- Build the commit-history chart for a user ---
# Usage: _build_commit_history_chart <gh_user>
# Outputs a centered light/dark picture linked to the user's activity profile.
_build_commit_history_chart() {
	local gh_user="$1"
	gh_user="${gh_user//[^a-zA-Z0-9-]/}"
	if [[ -z "$gh_user" ]]; then
		return 0
	fi
	local chart_href="https://commit-history.com/${gh_user}?metric=total"

	cat <<EOF
<div align="center">
  <a href="${chart_href}">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://commit-history.com/embed/${gh_user}?theme=dark" />
      <img alt="${gh_user}'s commit history" src="https://commit-history.com/embed/${gh_user}" />
    </picture>
  </a>
</div>
EOF
	return 0
}

# --- Append the commit-history chart to an older aidevops-generated README ---
# Usage: _ensure_commit_history_chart <readme_path> <gh_user>
_ensure_commit_history_chart() {
	local readme_path="$1"
	local gh_user="$2"
	if grep -Fq '<!-- TOTAL-CONTRIBUTIONS-START -->' "$readme_path"; then
		return 0
	fi
	if ! grep -Fq '> Stats auto-updated by [aidevops]' "$readme_path" 2>/dev/null; then
		return 0
	fi
	local chart_href="https://commit-history.com/${gh_user}?metric=total"
	if grep -Fq 'https://commit-history.com/embed/' "$readme_path" 2>/dev/null; then
		if grep -Fq "<a href=\"${chart_href}\">" "$readme_path" 2>/dev/null; then
			return 0
		fi
		local migrate_tmp
		migrate_tmp=$(mktemp "${readme_path}.commit-history.XXXXXX") || return 1
		local legacy_href="https://commit-history.com/${gh_user}"
		if grep -Fq "<a href=\"${legacy_href}\">" "$readme_path" 2>/dev/null; then
			if ! awk -v old="href=\"${legacy_href}\"" -v new="href=\"${chart_href}\"" '
				{
					start = index($0, old)
					if (start > 0) {
						$0 = substr($0, 1, start - 1) new substr($0, start + length(old))
					}
					print
				}
			' "$readme_path" >"$migrate_tmp"; then
				rm -f "$migrate_tmp"
				return 1
			fi
			_profile_replace_readme "$migrate_tmp" "$readme_path" || {
				rm -f "$migrate_tmp"
				return 1
			}
			return 0
		fi
		if ! awk -v href="${chart_href}" '
			function emit_picture() {
				if (picture_block ~ /commit-history[.]com\/embed\//) {
					print "  <a href=\"" href "\">"
					printf "%s", picture_block
					print "  </a>"
				} else {
					printf "%s", picture_block
				}
				picture_block = ""
			}
			/^[[:space:]]*<picture>[[:space:]]*$/ {
				in_picture = 1
				picture_block = $0 ORS
				next
			}
			in_picture {
				picture_block = picture_block $0 ORS
				if ($0 ~ /<\/picture>/) {
					emit_picture()
					in_picture = 0
				}
				next
			}
			{ print }
			END { if (in_picture) printf "%s", picture_block }
		' "$readme_path" >"$migrate_tmp"; then
			rm -f "$migrate_tmp"
			return 1
		fi
		_profile_replace_readme "$migrate_tmp" "$readme_path" || {
			rm -f "$migrate_tmp"
			return 1
		}
		return 0
	fi

	local commit_history_chart
	commit_history_chart=$(_build_commit_history_chart "$gh_user")
	if [[ -z "$commit_history_chart" ]]; then
		return 0
	fi
	printf '\n%s\n' "$commit_history_chart" >>"$readme_path"
	return 0
}

# --- Generate rich profile README from GitHub data ---
_generate_rich_readme() {
	local gh_user="$1"
	local readme_path="$2"

	# Fetch user profile — single jq pass for all fields
	local user_json
	user_json=$(gh api "users/${gh_user}") || user_json="{}"
	local display_name bio blog twitter
	IFS=$'\t' read -r display_name bio blog twitter < <(
		echo "$user_json" | jq -r '[
			((.name // "") | gsub("[\\t\\n]"; " ")),
			((.bio // "") | gsub("[\\t\\n]"; " ")),
			(if .blog != null and .blog != "" then (.blog | gsub("[\\t\\n]"; "")) else "" end),
			(if .twitter_username != null and .twitter_username != "" then (.twitter_username | gsub("[\\t\\n]"; "")) else "" end)
		] | join("\t")' || printf '\t\t\t\n'
	)
	display_name="${display_name:-$gh_user}"

	# Sanitize user-controlled fields
	display_name=$(_sanitize_md "$display_name")
	bio=$(_sanitize_md "$bio")
	blog=$(_sanitize_url "$blog")
	# twitter is used as a path component, strip non-alphanumeric/underscore
	twitter="${twitter//[^a-zA-Z0-9_]/}"

	# Fetch repos and detect languages
	local repos_json
	repos_json=$(gh api "users/${gh_user}/repos?per_page=100&sort=updated" --paginate) || repos_json="[]"

	# Build badge line and connect section via helpers
	local badges
	badges=$(_build_readme_badges "$repos_json")

	# Own repos use the same generator as the hourly refresh between markers.
	local own_repos=""
	own_repos=$(_generate_projects "$gh_user") || own_repos=""

	# Build contributions section using shared helper
	local contrib_repos
	contrib_repos=$(_generate_initial_contributions "$gh_user")

	# Build connect section
	local connect
	connect=$(_build_readme_connect "$gh_user" "$blog" "$twitter")
	local commit_history_chart
	commit_history_chart=$(_build_commit_history_chart "$gh_user")

	# Compose the README
	{
		echo "# ${display_name}"
		echo ""
		if [[ -n "$bio" ]]; then
			echo "**${bio}**"
			echo ""
		fi
		# Badges
		printf '%s' "$badges"
		echo ""
		echo "> Shipping with AI agents around the clock -- human hours for thinking, machine hours for doing."
		echo ">"
		echo "> Stats auto-updated by [aidevops](https://aidevops.sh)."
		echo ""
		echo "<!-- STATS-START -->"
		echo "<!-- Stats will be populated on first update -->"
		echo "<!-- STATS-END -->"
		echo ""
		# Own repos (auto-updated on every refresh)
		echo "$PROJECTS_START_MARKER"
		if [[ -n "$own_repos" ]]; then
			echo "## Projects"
			echo ""
			printf '%s\n' "$own_repos"
		fi
		echo "$PROJECTS_END_MARKER"
		echo ""
		# Contributions (auto-updated daily)
		echo "<!-- CONTRIBUTIONS-START -->"
		if [[ -n "$contrib_repos" ]]; then
			echo "## Contributions"
			echo ""
			printf '%s\n' "$contrib_repos"
		fi
		echo "<!-- CONTRIBUTIONS-END -->"
		echo ""
		# Connect
		echo "## Connect"
		echo ""
		printf '%s' "$connect"
		echo ""
		echo "---"
		echo ""
		echo "<!-- UPDATED-START -->"
		echo "<!-- UPDATED-END -->"
		echo ""
		printf '%s\n' "$commit_history_chart"
	} >"$readme_path"

	return 0
}

# --- Clone or pull the profile repo to a local directory ---
# Usage: _init_clone_or_pull <repo_slug> <repo_dir>
# Returns 0 on success, 1 on failure.
_init_clone_or_pull() {
	local repo_slug="$1"
	local repo_dir="$2"

	if [[ ! -d "$repo_dir" ]]; then
		echo "Cloning $repo_slug to $repo_dir"
		git clone "git@github.com:${repo_slug}.git" "$repo_dir" 2>/dev/null ||
			git clone "https://github.com/${repo_slug}.git" "$repo_dir" || {
			echo "Error: failed to clone $repo_slug" >&2
			return 1
		}
	else
		echo "Local repo already exists at $repo_dir"
		local init_branch
		init_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
		if [[ -z "$init_branch" ]]; then
			init_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
		fi
		init_branch="${init_branch:-main}"
		git -C "$repo_dir" pull --ff-only origin "$init_branch" 2>/dev/null || true
	fi
	return 0
}

# --- Register or update the profile repo entry in repos.json ---
# Usage: _init_register_repos_json <repos_json> <repo_dir> <repo_slug>
_init_register_repos_json() {
	local repos_json="$1"
	local repo_dir="$2"
	local repo_slug="$3"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local already_registered
	already_registered=$(jq -r --arg path "$repo_dir" '
		if .initialized_repos then
			[.initialized_repos[] | select(.path == $path)] | length
		else
			[to_entries[] | select(.value.path == $path)] | length
		end
	' "$repos_json" 2>/dev/null)

	local tmp_json
	tmp_json=$(mktemp)
	if [[ "$already_registered" == "0" ]]; then
		echo "Registering profile repo in repos.json"
		if jq --arg path "$repo_dir" --arg slug "$repo_slug" '
			.initialized_repos += [{
				"path": $path,
				"slug": $slug,
				"priority": "profile",
				"pulse": false,
				"maintainer": ($slug | split("/")[0])
			}]
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	else
		# Ensure priority is set to "profile"
		if jq --arg path "$repo_dir" '
			.initialized_repos |= map(
				if .path == $path then .priority = "profile" else . end
			)
		' "$repos_json" >"$tmp_json" && jq empty "$tmp_json" 2>/dev/null; then
			mv "$tmp_json" "$repos_json"
		else
			echo "ERROR: repos.json write produced invalid JSON — aborting (GH#16746)" >&2
			rm -f "$tmp_json"
		fi
	fi
	return 0
}

# --- Check if profile repo is already fully initialized ---
# Usage: _init_check_already_initialized <repos_json> <repo_slug> <gh_user> <default_repo_dir>
# Prints the effective repo_dir to stdout (may differ from default if repos.json has a path).
# Exit codes: 0 = already done (caller should return 0), 1 = not done (caller should continue),
#             2 = recovered from diverged history (caller should return 0).
_init_check_already_initialized() {
	local repos_json="$1"
	local repo_slug="$2"
	local gh_user="$3"
	local default_repo_dir="$4"

	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "$default_repo_dir"
		return 1
	fi

	local existing_profile
	existing_profile=$(jq -r '
		if .initialized_repos then
			.initialized_repos[] | select(.priority == "profile") | .path // empty
		else
			to_entries[] | select(.value.priority == "profile") | .value.path // empty
		end
	' "$repos_json" | head -1)

	if [[ -z "$existing_profile" ]]; then
		echo "$default_repo_dir"
		return 1
	fi

	if [[ -d "$existing_profile" ]] &&
		[[ -f "${existing_profile}/README.md" ]] &&
		grep -q '<!-- STATS-START -->' "${existing_profile}/README.md" 2>/dev/null; then
		# Local looks good — verify we can still push (catches diverged history)
		if git -C "$existing_profile" fetch origin 2>/dev/null; then
			local local_head remote_head merge_base
			local_head=$(git -C "$existing_profile" rev-parse HEAD 2>/dev/null || true)
			remote_head=$(git -C "$existing_profile" rev-parse FETCH_HEAD 2>/dev/null || true)
			if [[ -n "$local_head" && -n "$remote_head" ]]; then
				merge_base=$(git -C "$existing_profile" merge-base "$local_head" "$remote_head" 2>/dev/null || true)
				if [[ -z "$merge_base" ]]; then
					echo "Diverged history detected — re-initializing profile repo..." >&2
					_recover_diverged_profile "$existing_profile" "$repo_slug" "main" "$gh_user"
					echo "Profile repo recovered at $existing_profile" >&2
					echo "$existing_profile"
					return 2
				fi
			fi
		fi
		echo "Profile repo already initialized at $existing_profile" >&2
		echo "$existing_profile"
		return 0
	fi

	# Use existing path if directory exists (may just need README seeding)
	if [[ -d "$existing_profile" ]]; then
		echo "$existing_profile"
	else
		echo "$default_repo_dir"
	fi
	return 1
}

# --- Initialize profile README repo ---
# Creates the username/username GitHub repo if it doesn't exist, clones it,
# seeds a starter README with stat markers, and registers it in repos.json.
cmd_init() {
	# Require gh CLI
	if ! command -v gh &>/dev/null; then
		echo "Error: gh CLI required. Install from https://cli.github.com" >&2
		return 1
	fi

	# Get GitHub username
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null) || {
		echo "Error: not authenticated with gh CLI. Run 'gh auth login' first." >&2
		return 1
	}

	local repo_slug="${gh_user}/${gh_user}"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Check if already fully initialized
	local repo_dir
	repo_dir=$(_init_check_already_initialized "$repos_json" "$repo_slug" "$gh_user" "${HOME}/Git/${gh_user}")
	local check_rc=$?
	if [[ "$check_rc" -eq 0 || "$check_rc" -eq 2 ]]; then
		return 0
	fi

	# Create the repo on GitHub if it doesn't exist
	if ! gh repo view "$repo_slug" &>/dev/null; then
		echo "Creating GitHub profile repo: $repo_slug"
		gh repo create "$repo_slug" --public --add-readme --description "GitHub profile README" || {
			echo "Error: failed to create repo $repo_slug" >&2
			return 1
		}
		sleep 2
	else
		echo "GitHub repo $repo_slug already exists"
	fi

	# Clone or pull the local copy
	_init_clone_or_pull "$repo_slug" "$repo_dir" || return 1

	# Detect default branch for push operations
	local default_branch
	default_branch=$(git -C "$repo_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
	fi
	default_branch="${default_branch:-main}"

	# Seed README.md with stat markers.
	local readme_path="${repo_dir}/README.md"
	if [[ ! -f "$readme_path" ]]; then
		echo "Creating rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		_generate_rich_readme "$gh_user" "$readme_path"
	elif ! grep -q '<!-- STATS-START -->' "$readme_path"; then
		echo "Injecting stat markers into existing README..."
		_inject_markers_into_readme "$readme_path"
	fi

	# Commit and push if there are changes
	if [[ -n "$(git -C "$repo_dir" status --porcelain README.md 2>/dev/null)" ]]; then
		git -C "$repo_dir" add README.md
		git -C "$repo_dir" commit -m "feat: initialize profile README with aidevops stat markers" --no-verify 2>/dev/null || true
		if ! git -C "$repo_dir" push origin "$default_branch" 2>/dev/null; then
			echo "Push failed — attempting recovery from diverged history..." >&2
			_recover_diverged_profile "$repo_dir" "$repo_slug" "$default_branch" "$gh_user"
		fi
	fi

	# Register in repos.json
	_init_register_repos_json "$repos_json" "$repo_dir" "$repo_slug"

	# Run first update
	echo "Running first stats update..."
	cmd_update

	echo ""
	echo "Profile README initialized at: https://github.com/${gh_user}"
	echo ""
	echo "IMPORTANT: To show this on your GitHub profile, visit:"
	echo "  https://github.com/${repo_slug}"
	echo "and click the 'Show on profile' button if prompted."
	echo ""
	echo "Stats will auto-update hourly (configured by setup.sh)."

	return 0
}

# --- Inject the UPDATED timestamp into a README file in-place ---
# Usage: _update_inject_timestamp <file>
# Replaces content between <!-- UPDATED-START --> and <!-- UPDATED-END --> markers.
_update_inject_timestamp() {
	local file="$1"
	if ! grep -q '<!-- UPDATED-START -->' "$file"; then
		return 0
	fi
	local updated_at
	updated_at=$(date -u +"%Y-%m-%d %H:%M UTC")
	local updated_tmp
	updated_tmp=$(mktemp)
	awk -v ts="$updated_at" '
		/<!-- UPDATED-START -->/ {
			print "<!-- UPDATED-START -->"
			skip = 1
			next
		}
		/<!-- UPDATED-END -->/ {
			skip = 0
			printf "_Stats auto-updated %s by [aidevops](https://aidevops.sh) pulse._\n", ts
			print "<!-- UPDATED-END -->"
			next
		}
		!skip { print }
	' "$file" >"$updated_tmp"
	_profile_replace_readme "$updated_tmp" "$file" || return 1
	return 0
}

# --- Ensure STATS markers exist in a README, injecting or regenerating as needed ---
# Usage: _update_inject_markers_if_needed <profile_repo> <readme_path>
# The caller owns the single publication commit after all transforms complete.
_update_inject_markers_if_needed() {
	local profile_repo="$1"
	local readme_path="$2"

	# Even if markers exist, check if the content outside them is the default
	# GitHub template. This handles the case where v3.1.87 injected markers into
	# the default template but didn't replace the template content itself.
	if _is_default_github_template "$readme_path"; then
		echo "Default GitHub template detected — replacing with rich profile README..."
		local gh_user
		gh_user=$(_resolve_profile_user "$profile_repo")
		if [[ -n "$gh_user" ]]; then
			_generate_rich_readme "$gh_user" "$readme_path"
		else
			echo "Could not resolve username — injecting markers only..."
			_inject_markers_into_readme "$readme_path" || return 1
		fi
		return 0
	fi

	if grep -q '<!-- STATS-START -->' "$readme_path" && grep -q '<!-- STATS-END -->' "$readme_path"; then
		return 0
	fi

	echo "Markers missing from README — injecting them..."
	_inject_markers_into_readme "$readme_path" || return 1
	return 0
}

# --- Commit and publish one profile README update from the linked worktree ---
# Usage: _update_push_with_recovery <profile_repo> <commit_msg>
_update_push_with_recovery() {
	local profile_repo="$1"
	local commit_msg="$2"

	git -C "$profile_repo" add README.md || return 1
	local chart_file=""
	for chart_file in total-light.svg total-dark.svg total.json; do
		if [[ -f "$profile_repo/assets/contributions/$chart_file" ]]; then
			git -C "$profile_repo" add -- "assets/contributions/$chart_file" || return 1
		fi
	done
	if ! git -C "$profile_repo" commit -m "$commit_msg" 2>/dev/null; then
		if git -C "$profile_repo" diff --cached --quiet; then
			echo "No changes to commit after profile README update"
			return 0
		fi
		echo "Profile README commit failed in the publication worktree" >&2
		return 1
	fi
	echo "Committed profile README update: $commit_msg"

	local default_branch=""
	default_branch=$(_profile_default_branch "$profile_repo")
	if ! git -C "$profile_repo" push origin "HEAD:refs/heads/${default_branch}" 2>/dev/null; then
		echo "Profile README push failed; canonical checkout was not changed" >&2
		return 1
	fi
	echo "Pushed profile README update to origin/${default_branch}"
	return 0
}

# Refresh contributions for README $1 when due, honoring dry-run flag $2.
# Defer publication to the caller and set PROFILE_CONTRIBUTIONS_REFRESHED on
# success; failures warn without blocking the surrounding stats refresh.
_profile_refresh_daily_contributions() {
	local readme_path="$1"
	local dry_run="$2"
	local last_contrib_file="${HOME}/.aidevops/cache/contributions-last-update"
	local today=""
	local last_contrib_date=""
	PROFILE_CONTRIBUTIONS_REFRESHED=false
	today=$(date -u +"%Y-%m-%d")
	if [[ -f "$last_contrib_file" ]]; then
		last_contrib_date=$(<"$last_contrib_file")
	fi
	if [[ "$last_contrib_date" == "$today" ]] ||
		! grep -q '<!-- CONTRIBUTIONS-START -->' "$readme_path" 2>/dev/null; then
		return 0
	fi
	echo "Daily contributions refresh triggered..."
	if [[ "$dry_run" == true ]]; then
		cmd_update_contributions "--dry-run" || echo "Warning: contributions update failed — continuing with stats" >&2
	elif AIDEVOPS_PROFILE_DEFER_PUBLICATION=1 cmd_update_contributions; then
		PROFILE_CONTRIBUTIONS_REFRESHED=true
	else
		echo "Warning: contributions update failed — continuing with stats" >&2
	fi
	return 0
}

# --- Update the profile README inside an isolated publication worktree ---
_cmd_update_in_repo() {
	local dry_run=false
	if [[ "${1:-}" == "--dry-run" ]]; then
		dry_run=true
	fi
	echo "Profile README update started at $(date -u +%Y-%m-%dT%H:%M:%SZ) (dry_run=${dry_run})"

	# Resolve profile repo
	local profile_repo
	profile_repo=$(_resolve_profile_repo) || return 1
	local readme_path="${profile_repo}/README.md"

	if [[ ! -f "$readme_path" ]]; then
		echo "Error: README.md not found at $readme_path" >&2
		return 1
	fi

	# Generate new stats section
	local new_stats
	new_stats=$(cmd_generate)

	# Daily contributions piggyback on the hourly stats job once per UTC day.
	_profile_refresh_daily_contributions "$readme_path" "$dry_run"

	# Ensure markers exist — inject or regenerate if missing
	_update_inject_markers_if_needed "$profile_repo" "$readme_path" || return 1

	# Replace content between markers
	local tmp_file
	tmp_file=$(mktemp "${profile_repo}/.profile-readme.XXXXXX") || return 1
	NEW_STATS="$new_stats" awk '
		/<!-- STATS-START -->/ {
			print "<!-- STATS-START -->"
			skip = 1
			next
		}
		/<!-- STATS-END -->/ {
			skip = 0
			printf "%s\n", ENVIRON["NEW_STATS"]
			print "<!-- STATS-END -->"
			next
		}
		!skip { print }
	' "$readme_path" >"$tmp_file"
	local gh_user
	gh_user=$(_resolve_profile_user "$profile_repo")
	local chart_args=(--repo "$profile_repo" --readme "$tmp_file" --user "$gh_user")
	[[ "$dry_run" != true ]] || chart_args+=(--dry-run)
	if ! python3 "${SCRIPT_DIR}/profile-contribution-chart.py" "${chart_args[@]}"; then
		rm -f "$tmp_file"
		return 1
	fi
	if ! _ensure_commit_history_chart "$tmp_file" "$gh_user"; then
		rm -f "$tmp_file"
		return 1
	fi
	_refresh_projects_block "$tmp_file" "$gh_user"

	# Check if content changed, ignoring UPDATED marker block
	local old_normalized new_normalized
	old_normalized=$(_normalize_readme_for_compare "$readme_path")
	new_normalized=$(_normalize_readme_for_compare "$tmp_file")
	local readme_dirty=false
	local publication_status=""
	if ! publication_status=$(git -C "$profile_repo" status --porcelain --untracked-files=all -- README.md assets/contributions/total-light.svg assets/contributions/total-dark.svg assets/contributions/total.json); then
		rm -f "$tmp_file"
		return 1
	fi
	if [[ -n "$publication_status" ]]; then
		readme_dirty=true
	fi
	if [[ "$old_normalized" == "$new_normalized" && "$readme_dirty" == false ]]; then
		echo "No changes to profile content — skipping commit"
		rm -f "$tmp_file"
		return 0
	fi

	# Update timestamp
	_update_inject_timestamp "$tmp_file" || return 1

	if [[ "$dry_run" == true ]]; then
		echo "--- DRY RUN: would write to $readme_path ---"
		diff "$readme_path" "$tmp_file" || true
		rm -f "$tmp_file"
		return 0
	fi

	# Apply changes and push
	_profile_replace_readme "$tmp_file" "$readme_path" || return 1
	echo "Profile README content changed — committing and pushing"
	_update_push_with_recovery "$profile_repo" "chore: update profile stats ($(date -u +%Y-%m-%d))" || return 1
	if [[ "$PROFILE_CONTRIBUTIONS_REFRESHED" == true ]]; then
		_record_contributions_update || return 1
	fi

	echo "Profile README updated and pushed"
	return 0
}

# --- Count lines mentioning one marker token as a whole word ---
# Prefixed families such as TOTAL-CONTRIBUTIONS-START must not count as
# CONTRIBUTIONS-START; that collision silently disabled the daily refresh.
_count_marker_mentions() {
	local readme_path="$1"
	local token="$2"
	local count=""
	count=$(grep -cE "(^|[^A-Za-z0-9_-])${token}([^A-Za-z0-9_-]|$)" "$readme_path" 2>/dev/null || true)
	printf '%s\n' "${count:-0}"
	return 0
}

# --- Update the profile README without mutating its configured canonical checkout ---
cmd_update() {
	if [[ "${AIDEVOPS_PROFILE_PUBLICATION_WORKTREE:-0}" == "1" ]]; then
		_cmd_update_in_repo "$@"
		return $?
	fi
	local lock_status=0
	_ensure_profile_update_lock || lock_status=$?
	[[ "$lock_status" -ne 2 ]] || return 0
	[[ "$lock_status" -eq 0 ]] || return "$lock_status"
	_profile_run_in_worktree update "$@"
	return $?
}

# --- Refresh contributions through the same canonical-safe publication boundary ---
cmd_update_contributions() {
	if [[ "${AIDEVOPS_PROFILE_PUBLICATION_WORKTREE:-0}" == "1" ]]; then
		_cmd_update_contributions_in_repo "$@"
		return $?
	fi
	local lock_status=0
	_ensure_profile_update_lock || lock_status=$?
	[[ "$lock_status" -ne 2 ]] || return 0
	[[ "$lock_status" -eq 0 ]] || return "$lock_status"
	_profile_run_in_worktree update-contributions "$@"
	return $?
}

# --- Main dispatch ---
cmd_cleanup_managed() {
	local path="$1"
	local common=""
	[[ -d "$path" && ! -L "$path" ]] || return 1
	python3 "${SCRIPT_DIR}/worktree-managed-lifetime.py" proof "$path" || return 1
	PROFILE_PUBLICATION_CANONICAL_REPO=$(_resolve_profile_repo) || return 1
	PROFILE_PUBLICATION_WORKTREE=$(cd "$path" && pwd -P) || return 1
	PROFILE_PUBLICATION_WORKTREE_BASE=$(cd "${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}" && pwd -P) || return 1
	PROFILE_PUBLICATION_INTENT_PATH=$(_profile_publication_intent_path \
		"$PROFILE_PUBLICATION_CANONICAL_REPO" "$PROFILE_PUBLICATION_WORKTREE") || return 1
	[[ -f "$PROFILE_PUBLICATION_INTENT_PATH" && ! -L "$PROFILE_PUBLICATION_INTENT_PATH" ]] || return 1
	common=$(git -C "$PROFILE_PUBLICATION_CANONICAL_REPO" rev-parse --path-format=absolute --git-common-dir) || return 1
	jq -e --arg path "$PROFILE_PUBLICATION_WORKTREE" --arg common "$common" \
		--arg producer "$PROFILE_PUBLICATION_REGISTRY_TASK" --arg schema "$PROFILE_PUBLICATION_INTENT_SCHEMA" \
		'.schema == $schema and .producer == $producer and
		 .worktree_path == $path and .canonical_common_dir == $common and
		 (.canonical_status | type == "string")' "$PROFILE_PUBLICATION_INTENT_PATH" >/dev/null || return 1
	PROFILE_PUBLICATION_CANONICAL_HEAD=$(jq -er '.canonical_head' "$PROFILE_PUBLICATION_INTENT_PATH") || return 1
	PROFILE_PUBLICATION_CANONICAL_STATUS=$(jq -er '.canonical_status' "$PROFILE_PUBLICATION_INTENT_PATH") || return 1
	_profile_publication_worktree_recovery_is_safe "$PROFILE_PUBLICATION_WORKTREE" || return 1
	_cleanup_profile_publication_worktree || return 1
	return 0
}

# Start before acquiring the publication lock. The child is the managed unit's
# leader; the parent callback runs only after all descendants have drained.
if [[ "${1:-}" == "update" || "${1:-}" == "update-contributions" ]] &&
	[[ "${AIDEVOPS_MANAGED_WORKTREE_RUN:-0}" != "1" && "${AIDEVOPS_PROFILE_PUBLICATION_WORKTREE:-0}" != "1" ]]; then
	if python3 "${SCRIPT_DIR}/worktree-managed-run.py" --check-backend; then
		exec python3 "${SCRIPT_DIR}/worktree-managed-run.py" \
			--after bash --after "${SCRIPT_DIR}/profile-readme-helper.sh" --after cleanup-managed \
			-- bash "${SCRIPT_DIR}/profile-readme-helper.sh" "$@"
	fi
	# Choose before creation. macOS and hosts without user-systemd retain the
	# original synchronous publication and guarded cleanup, with shared creation.
	export AIDEVOPS_WORKTREE_MANAGER="legacy-guards"
fi

case "${1:-help}" in
cleanup-managed)
	shift
	cmd_cleanup_managed "$@"
	;;
init) cmd_init ;;
generate) cmd_generate ;;
update)
	shift
	cmd_update "$@"
	;;
update-contributions)
	shift
	cmd_update_contributions "$@"
	;;
help | *)
	echo "Usage: profile-readme-helper.sh {init|update|update-contributions|generate|help}"
	echo ""
	echo "Commands:"
	echo "  init                          Create profile repo, seed README, register in repos.json"
	echo "  update [--dry-run]            Update profile README with live stats and push"
	echo "  update-contributions [--dry-run]  Refresh contributions list from forks + repos.json"
	echo "  generate                      Print generated stats section to stdout"
	echo "  help                          Show this help"
	echo ""
	echo "The 'update' command automatically refreshes contributions once per day."
	echo "Use 'update-contributions' to force an immediate refresh."
	;;
esac
