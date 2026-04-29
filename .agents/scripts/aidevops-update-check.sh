#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Update Check - Clean version check for session start
# =============================================================================
# Outputs a single clean line for AI assistants to report

set -euo pipefail

# Headless workers never need version checks or security advisories.
# The dispatch already verified the environment; skip to save tokens.
if [[ "${HEADLESS:-}" == "1" || "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
	exit 0
fi

# Shared version-finding logic (avoids duplication with log-issue-helper.sh)
# shellcheck source=lib/version.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/version.sh"
# shellcheck source=shared-constants.sh
source "$(dirname "${BASH_SOURCE[0]}")/shared-constants.sh"

get_version() {
	aidevops_find_version
}

detect_app() {
	# Detect which AI coding assistant is running this script
	# Returns: "AppName|version" or "AppName" or "unknown"
	local app_name="" app_version=""

	# Check environment variables set by various tools
	if [[ "${OPENCODE:-}" == "1" ]]; then
		app_name="OpenCode"
		# Try multiple version detection methods (install path varies: bun, npm, homebrew)
		app_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
		if [[ -z "$app_version" ]]; then
			app_version=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
		fi
		if [[ -z "$app_version" ]]; then
			app_version=$(jq -r '.version // empty' ~/.bun/install/global/node_modules/opencode-ai/package.json 2>/dev/null || echo "")
		fi
	elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		app_name="Claude Code"
		app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
	elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
		app_name="Cursor"
	elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
		app_name="Windsurf"
	elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
		app_name="Continue"
	elif [[ -n "${AIDER_SESSION:-}" ]]; then
		app_name="Aider"
		app_version=$(aider --version 2>/dev/null | head -1 || echo "")
	elif [[ -n "${FACTORY_DROID:-}" ]]; then
		app_name="Factory Droid"
	elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
		app_name="Augment"
	elif [[ -n "${COPILOT_SESSION:-}" ]]; then
		app_name="GitHub Copilot"
	elif [[ -n "${CODY_SESSION:-}" ]]; then
		app_name="Cody"
	elif [[ -n "${KILO_SESSION:-}" ]]; then
		app_name="Kilo Code"
	elif [[ -n "${WARP_SESSION:-}" ]]; then
		app_name="Warp"
	else
		# Fallback: check parent process name
		# Normalize to lowercase for case-insensitive matching (ps -o comm= can
		# return capitalized names on some platforms, e.g. "Cursor" not "cursor")
		local parent parent_lower
		parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
		# Bash 3.2 compat: no ${var,,} — use tr for case conversion
		parent_lower=$(printf '%s' "$parent" | tr '[:upper:]' '[:lower:]')
		case "$parent_lower" in
		*opencode*)
			app_name="OpenCode"
			# Try CLI first, then npm global package.json
			app_version=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
			if [[ -z "$app_version" ]]; then
				app_version=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
			fi
			;;
		*claude*)
			app_name="Claude Code"
			app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
			;;
		*cursor*) app_name="Cursor" ;;
		*windsurf*) app_name="Windsurf" ;;
		*continue*) app_name="Continue" ;;
		*aider*)
			app_name="Aider"
			app_version=$(aider --version 2>/dev/null | head -1 || echo "")
			;;
		*) app_name="unknown" ;;
		esac
	fi

	# Return with version if available
	if [[ -n "$app_version" && "$app_version" != "unknown" ]]; then
		echo "${app_name}|${app_version}"
	else
		echo "$app_name"
	fi
	return 0
}

get_remote_version() {
	local version
	if command -v jq &>/dev/null; then
		# Use --proto =https to enforce HTTPS and prevent protocol downgrade
		version=$(curl --proto '=https' -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi
	# Use --proto =https to enforce HTTPS and prevent protocol downgrade
	curl --proto '=https' -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

get_git_context() {
	# Get current repo and branch for context
	# Note: basename on an empty string returns "." — capture toplevel first
	# and only call basename when non-empty to avoid emitting "." outside a repo.
	local repo branch toplevel
	toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [[ -n "$toplevel" ]]; then
		repo=$(basename "$toplevel" 2>/dev/null || echo "")
	else
		repo=""
	fi
	branch=$(git branch --show-current 2>/dev/null || echo "")

	if [[ -n "$repo" && -n "$branch" ]]; then
		echo "${repo}/${branch}"
	elif [[ -n "$repo" ]]; then
		echo "$repo"
	else
		echo ""
	fi
	return 0
}

is_headless() {
	# Detect non-interactive/headless mode from multiple signals.
	# The --interactive flag overrides all headless detection (used by
	# AGENTS.md greeting flow when the model intentionally wants the
	# full update check despite running inside a Bash tool with no TTY).
	local arg
	for arg in "$@"; do
		if [[ "$arg" == "--interactive" ]]; then
			return 1
		fi
	done
	# 1. Explicit env vars set by dispatch systems
	if [[ "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
		return 0
	fi
	if [[ "${OPENCODE_HEADLESS:-}" == "true" ]]; then
		return 0
	fi
	if [[ "${AIDEVOPS_HEADLESS:-}" == "true" ]]; then
		return 0
	fi
	# 2. CLI flag: --headless passed to this script
	for arg in "$@"; do
		if [[ "$arg" == "--headless" ]]; then
			return 0
		fi
	done
	# 3. No TTY on stdin (piped input, e.g. opencode run / claude -p)
	#    This catches cases where the model ignores AGENTS.md skip rules.
	if [[ ! -t 0 ]]; then
		return 0
	fi
	return 1
}

# -----------------------------------------------------------------------------
# _build_version_str: resolve version string from current/remote versions.
# Sets $1 (nameref not available in bash 3.2) — caller reads stdout.
# Prints the version string, or "UPDATE_AVAILABLE|..." and returns 1 to signal
# early exit.
# -----------------------------------------------------------------------------
_build_version_str() {
	local current="$1" remote="$2" app_name="$3" cache_dir="$4"
	if [[ "$current" == "unknown" ]]; then
		echo "aidevops not installed"
		return 0
	elif [[ "$remote" == "unknown" ]]; then
		echo "aidevops v$current (unable to check for updates)"
		return 0
	elif [[ "$current" != "$remote" ]]; then
		# Special format for update available - parsed by AGENTS.md
		# Cache the update-available string so no-Bash agents can display it too
		mkdir -p "$cache_dir"
		echo "UPDATE_AVAILABLE|$current|$remote|$app_name" >"$cache_dir/session-greeting.txt"
		echo "UPDATE_AVAILABLE|$current|$remote|$app_name"
		return 1
	else
		echo "aidevops v$current"
		return 0
	fi
}

# -----------------------------------------------------------------------------
# _build_app_str: format app name + version for display.
# -----------------------------------------------------------------------------
_build_app_str() {
	local app_name="$1" app_version="$2"
	if [[ "$app_name" == "unknown" ]]; then
		echo ""
		return 0
	fi
	if [[ -n "$app_version" ]]; then
		echo "$app_name v$app_version"
	else
		echo "$app_name"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# _build_output_line: assemble the final single-line status output.
# -----------------------------------------------------------------------------
_build_output_line() {
	local version_str="$1" app_str="$2" git_context="$3"
	local output="$version_str"
	if [[ -n "$app_str" ]]; then
		output="$output running in $app_str"
	fi
	if [[ -n "$git_context" ]]; then
		output="$output | $git_context"
	fi
	echo "$output"
	return 0
}

# -----------------------------------------------------------------------------
# _is_auto_update_active: check if the auto-update scheduler is running.
# Returns 0 if launchd (macOS) or cron (Linux) auto-update job is active.
# -----------------------------------------------------------------------------
_is_auto_update_active() {
	local launchd_label="com.aidevops.aidevops-auto-update"
	if launchctl list "$launchd_label" &>/dev/null; then
		return 0
	fi
	if crontab -l 2>/dev/null | grep -q 'aidevops-auto-update'; then
		return 0
	fi
	return 1
}

# -----------------------------------------------------------------------------
# _get_runtime_hint: emit a runtime config hint for the AI model, if known.
# -----------------------------------------------------------------------------
_get_runtime_hint() {
	local app_name="$1"
	local runtime_hint=""
	case "$app_name" in
	OpenCode)
		runtime_hint="You are running in OpenCode. Global config: ~/.config/opencode/opencode.json"
		;;
	"Claude Code")
		runtime_hint="You are running in Claude Code. Global config: ~/.config/Claude/Claude.json"
		;;
	esac
	echo "$runtime_hint"
	return 0
}

# -----------------------------------------------------------------------------
# _check_local_models: nudge if stale local models detected (>5 GB, >30d unused).
# -----------------------------------------------------------------------------
_check_local_models() {
	local script_dir="$1"
	local nudge_output=""
	if [[ -x "${script_dir}/local-model-helper.sh" ]]; then
		nudge_output="$("${script_dir}/local-model-helper.sh" nudge 2>/dev/null || true)"
	fi
	echo "$nudge_output"
	return 0
}

# -----------------------------------------------------------------------------
# _check_session_count: warn if excessive concurrent interactive sessions (t1398.4).
# -----------------------------------------------------------------------------
_check_session_count() {
	local script_dir="$1"
	local session_warning=""
	if [[ -x "${script_dir}/session-count-helper.sh" ]]; then
		session_warning="$("${script_dir}/session-count-helper.sh" check || true)"
	fi
	echo "$session_warning"
	return 0
}

# -----------------------------------------------------------------------------
# _check_security_posture: security posture check (t1412.6).
# -----------------------------------------------------------------------------
_check_security_posture() {
	local script_dir="$1"
	local security_posture=""
	if [[ -x "${script_dir}/security-posture-helper.sh" ]]; then
		security_posture="$("${script_dir}/security-posture-helper.sh" startup-check || true)"
	fi
	echo "$security_posture"
	return 0
}

# -----------------------------------------------------------------------------
# _check_secret_hygiene: secret hygiene & supply chain IoC check.
# -----------------------------------------------------------------------------
_check_secret_hygiene() {
	local script_dir="$1"
	local secret_hygiene=""
	if [[ -x "${script_dir}/secret-hygiene-helper.sh" ]]; then
		secret_hygiene="$("${script_dir}/secret-hygiene-helper.sh" startup-check || true)"
	fi
	echo "$secret_hygiene"
	return 0
}

# -----------------------------------------------------------------------------
# _check_advisories: surface active security advisories (not yet dismissed).
# -----------------------------------------------------------------------------
_check_advisories() {
	local advisories_dir="$HOME/.aidevops/advisories"
	local dismissed_file="$advisories_dir/dismissed.txt"
	local advisories_output=""

	if [[ ! -d "$advisories_dir" ]]; then
		echo ""
		return 0
	fi

	# t2816: prepend a single aggregated [WARN] line for setup debt so the
	# OpenCode plugin classifier (greeting.mjs) escalates the toast variant
	# to warning when there is non-zero debt. The per-repo [ADVISORY] lines
	# below remain as info-tier follow-up detail.
	local setup_debt_helper="$SCRIPT_DIR/setup-debt-helper.sh"
	if [[ -x "$setup_debt_helper" ]]; then
		local debt_line
		debt_line=$("$setup_debt_helper" summary --format=toast 2>/dev/null) || debt_line=""
		if [[ -n "$debt_line" ]]; then
			advisories_output="$debt_line"
		fi
	fi

	local advisory_file
	for advisory_file in "$advisories_dir"/*.advisory; do
		[[ -f "$advisory_file" ]] || continue
		local adv_id
		adv_id=$(basename "$advisory_file" .advisory)
		# Skip dismissed advisories
		if [[ -f "$dismissed_file" ]] && grep -qxF "$adv_id" "$dismissed_file" 2>/dev/null; then
			continue
		fi
		local first_line
		first_line=$(head -1 "$advisory_file" | sed 's/^[[:space:]]*//')
		if [[ -n "$first_line" ]]; then
			local entry
			entry=$(printf "%s Run in your terminal: \`aidevops security\` | Dismiss: \`aidevops security dismiss %s\`" "$first_line" "$adv_id")
			if [[ -n "$advisories_output" ]]; then
				advisories_output=$(printf '%s\n%s' "$advisories_output" "$entry")
			else
				advisories_output="$entry"
			fi
		fi
	done

	echo "$advisories_output"
	return 0
}

# -----------------------------------------------------------------------------
# _check_contribution_watch: surface external contributions needing reply (t1419).
# Reads cached state file — no API calls, no LLM, no comment bodies.
# -----------------------------------------------------------------------------
_check_contribution_watch() {
	local contribution_watch=""
	local cw_state="${HOME}/.aidevops/cache/contribution-watch.json"

	if [[ ! -f "$cw_state" ]] || ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	local cw_username
	cw_username=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$cw_username" ]]; then
		echo ""
		return 0
	fi

	local cw_count
	cw_count=$(jq -r --arg user "$cw_username" '
		[.items | to_entries[] |
		 select(.value.last_any_comment > (.value.last_our_comment // "")) |
		 select(.value.last_notified == "" or .value.last_any_comment > .value.last_notified)
		] | length
	' "$cw_state" 2>/dev/null) || cw_count=0

	if [[ "${cw_count:-0}" -gt 0 ]]; then
		contribution_watch="${cw_count} external contribution(s) need your reply (run \`aidevops contributions\` to see them)."
	fi

	echo "$contribution_watch"
	return 0
}

# -----------------------------------------------------------------------------
# _check_hotfix_available: poll for hotfix-v* tags newer than the deployed version.
# Uses a shorter interval (5 minutes) than the regular update check (~24h).
# Reads auto_hotfix_accept from ~/.aidevops/configs/auto-hotfix.conf.
# Returns: hotfix notification string, or empty if no hotfix or not due for check.
# -----------------------------------------------------------------------------
# _hotfix_auto_apply: pull latest code, redeploy, and optionally restart pulse.
# Called by _check_hotfix_available when auto_hotfix_accept=true.
# Args: $1=agents_dir, $2=hotfix_version, $3=auto_restart_pulse ("true"|"false")
_hotfix_auto_apply() {
	local agents_dir="$1"
	local hotfix_version="$2"
	local auto_restart_pulse="$3"
	local framework_repo="${AIDEVOPS_FRAMEWORK_REPO:-$HOME/Git/aidevops}"
	local setup_script="${framework_repo}/setup.sh"

	echo "Hotfix v${hotfix_version} available — auto-applying (auto_hotfix_accept=true)..."

	if [[ ! -d "$framework_repo/.git" ]]; then
		return 0
	fi

	# Pull latest and redeploy. setup.sh now calls pulse-lifecycle-helper.sh
	# at the end of its main() (t2579), so the restart happens automatically
	# when setup redeploys scripts. The auto_restart_pulse arg is honoured
	# by setting AIDEVOPS_SKIP_PULSE_RESTART when false.
	local _skip_env=""
	if [[ "$auto_restart_pulse" != "true" ]]; then
		_skip_env="AIDEVOPS_SKIP_PULSE_RESTART=1"
	fi

	(
		cd "$framework_repo" || exit 1
		git pull --ff-only origin main >/dev/null 2>&1
		if [[ -x "$setup_script" ]]; then
			# shellcheck disable=SC2086  # intentional env-var prefix expansion
			env $_skip_env bash "$setup_script" --non-interactive >/dev/null 2>&1
		fi
	) &
	local hotfix_pid=$!
	wait "$hotfix_pid" 2>/dev/null || true
	return 0
}

# _hotfix_resolve_slug: determine the repo slug for hotfix tag polling.
# Returns the slug on stdout; empty string if undeterminable.
_hotfix_resolve_slug() {
	local framework_repo="${AIDEVOPS_FRAMEWORK_REPO:-$HOME/Git/aidevops}"
	local remote_url slug
	if [[ -d "$framework_repo/.git" ]]; then
		remote_url=$(git -C "$framework_repo" remote get-url origin 2>/dev/null || echo "")
		slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	fi
	if [[ -z "${slug:-}" ]]; then
		slug="marcusquinn/aidevops"
	fi
	echo "$slug"
	return 0
}

_check_hotfix_available() {
	local current_version="$1"
	local agents_dir="${AIDEVOPS_DIR:-$HOME/.aidevops}"
	# User-level override first, then deployed default
	local hotfix_conf="$agents_dir/configs/auto-hotfix.conf"
	if [[ ! -f "$hotfix_conf" ]]; then
		hotfix_conf="$agents_dir/agents/configs/auto-hotfix.conf"
	fi
	local hotfix_cache_dir="$agents_dir/cache"
	local hotfix_stamp="$hotfix_cache_dir/hotfix-last-check"
	local hotfix_poll_interval=300 # 5 minutes

	# Test override: skip rate-limit and force the banner check
	if [[ "${AIDEVOPS_FORCE_HOTFIX_BANNER:-}" == "1" ]]; then
		hotfix_poll_interval=0
	fi

	# Rate-limit: only check every 5 minutes
	if [[ -f "$hotfix_stamp" ]]; then
		local stamp_mtime now_epoch age_seconds
		stamp_mtime=$(_file_mtime_epoch "$hotfix_stamp")
		now_epoch=$(date +%s)
		age_seconds=$((now_epoch - stamp_mtime))
		if [[ "$age_seconds" -lt "$hotfix_poll_interval" ]]; then
			echo ""
			return 0
		fi
	fi

	# Update the stamp (create cache dir if needed)
	mkdir -p "$hotfix_cache_dir"
	touch "$hotfix_stamp"

	# Requires gh CLI for tag listing
	if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
		echo ""
		return 0
	fi

	local slug
	slug=$(_hotfix_resolve_slug)

	# Fetch the latest hotfix tag from the remote repo
	local latest_hotfix_tag latest_hotfix_version
	latest_hotfix_tag=$(gh api "repos/${slug}/tags" --jq '[.[] | select((.name // "") | startswith("hotfix-v"))] | sort_by(.name) | last | .name // empty' 2>/dev/null || echo "")

	if [[ -z "$latest_hotfix_tag" ]]; then
		echo ""
		return 0
	fi

	# Extract version from hotfix tag (e.g., "hotfix-v3.8.79" -> "3.8.79")
	latest_hotfix_version="${latest_hotfix_tag#hotfix-v}"

	# Compare: only signal if hotfix is newer than current
	if [[ "$latest_hotfix_version" == "$current_version" ]]; then
		echo ""
		return 0
	fi
	local newer
	newer=$(printf '%s\n%s\n' "$current_version" "$latest_hotfix_version" | sort -V | tail -1)
	if [[ "$newer" != "$latest_hotfix_version" ]]; then
		echo ""
		return 0
	fi

	# Read auto-hotfix config
	local auto_accept="false"
	local auto_restart_pulse="true"
	if [[ -f "$hotfix_conf" ]]; then
		auto_accept=$(grep -E '^auto_hotfix_accept=' "$hotfix_conf" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || echo "false")
		auto_restart_pulse=$(grep -E '^auto_hotfix_restart_pulse=' "$hotfix_conf" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || echo "true")
	fi

	if [[ "$auto_accept" == "true" ]]; then
		_hotfix_auto_apply "$agents_dir" "$latest_hotfix_version" "$auto_restart_pulse"
		return 0
	fi

	# Manual mode: emit banner for the session greeting
	echo "Hotfix available: v${latest_hotfix_version} (current: v${current_version}). Run 'aidevops update' to apply, or set auto_hotfix_accept=true in ${hotfix_conf}"
	return 0
}

# -----------------------------------------------------------------------------
# _check_script_drift: detect SHA drift between deployed agents and canonical
# repo HEAD. Triggers a silent background redeploy when framework code files
# (scripts/, agents/, workflows/, prompts/, hooks/) have changed since the last
# deploy. Doc-only drift (reference/, templates/, todo/, *.md) is skipped.
# t2156: automating the manual "cp + restart pulse" workaround that was needed
# after 3bbe31f36 merged but the production pulse kept using stale code for 90+
# minutes — see GH#19432–19443 blast radius.
# Returns: notification string (empty if in-sync, missing prereqs, or docs-only).
# -----------------------------------------------------------------------------
_check_script_drift() {
	# Allow test override via env var; default to canonical installation path.
	local framework_repo="${AIDEVOPS_FRAMEWORK_REPO:-$HOME/Git/aidevops}"
	local stamp_file="$HOME/.aidevops/.deployed-sha"

	# Prerequisites: framework repo must be a git repo and stamp file must exist.
	# Missing stamp = never deployed via new flow; skip silently until next deploy.
	if [[ ! -d "$framework_repo/.git" ]] || [[ ! -f "$stamp_file" ]]; then
		echo ""
		return 0
	fi

	local deployed_sha current_sha
	deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
	current_sha=$(git -C "$framework_repo" rev-parse HEAD 2>/dev/null) || current_sha=""

	# In-sync, or couldn't read either SHA — nothing to do.
	if [[ -z "$deployed_sha" ]] || [[ -z "$current_sha" ]] || [[ "$deployed_sha" == "$current_sha" ]]; then
		echo ""
		return 0
	fi

	# List files that changed between the deployed commit and HEAD.
	local changed_files
	changed_files=$(git -C "$framework_repo" diff --name-only "$deployed_sha" "$current_sha" 2>/dev/null) || changed_files=""

	if [[ -z "$changed_files" ]]; then
		echo ""
		return 0
	fi

	# Check if any framework code files changed.
	# Doc-only drift (reference/, templates/, todo/, plain *.md) is intentionally
	# skipped — those don't affect runtime behaviour and don't warrant a redeploy.
	local has_code_drift=0
	while IFS= read -r filepath; do
		case "$filepath" in
		.agents/scripts/* | .agents/agents/* | .agents/workflows/* | .agents/prompts/* | .agents/hooks/*)
			has_code_drift=1
			break
			;;
		esac
	done <<<"$changed_files"

	if [[ "$has_code_drift" -eq 0 ]]; then
		echo ""
		return 0
	fi

	# Framework code drift detected.
	# setup.sh --non-interactive deploys, writes .deployed-sha, and restarts the
	# pulse — no manual stamp update or pulse restart needed here.
	local setup_script="$framework_repo/setup.sh"
	if [[ ! -x "$setup_script" ]]; then
		echo "Script drift detected (${deployed_sha:0:7}→${current_sha:0:7}) but setup.sh not executable — run: cd ~/Git/aidevops && ./setup.sh --non-interactive"
		return 0
	fi

	echo "Script drift detected (${deployed_sha:0:7}→${current_sha:0:7}). Redeploying in background..."
	# t2729 (Option B): redirect at subshell level so the background process
	# never holds the parent's stdout FD open for synchronous callers.
	(bash "$setup_script" --non-interactive) >/dev/null 2>&1 &

	return 0
}

# -----------------------------------------------------------------------------
# _write_cache: persist session greeting to cache for agents without Bash.
# -----------------------------------------------------------------------------
_write_cache() {
	local cache_dir="$1"
	local output="$2"
	local runtime_hint="$3"
	local nudge_output="$4"
	local session_warning="$5"
	local security_posture="$6"
	local secret_hygiene="$7"
	local advisories_output="$8"
	local contribution_watch="$9"

	mkdir -p "$cache_dir"
	{
		echo "$output"
		[[ -n "$runtime_hint" ]] && echo "$runtime_hint"
		[[ -n "$nudge_output" ]] && echo "$nudge_output"
		[[ -n "$session_warning" ]] && echo "$session_warning"
		[[ -n "$security_posture" ]] && echo "$security_posture"
		[[ -n "$secret_hygiene" ]] && echo "$secret_hygiene"
		[[ -n "$advisories_output" ]] && echo "$advisories_output"
		[[ -n "$contribution_watch" ]] && echo "$contribution_watch"
	} >"$cache_dir/session-greeting.txt"
	return 0
}

# -----------------------------------------------------------------------------
# _detect_stuck_index_conflict: detect unmerged 3-way merge state in canonical
# repos on session start (t2245, GH#19763).
# A stuck unmerged index (stages 1/2/3 present, no MERGE_HEAD) silently blocks
# git pull --ff-only. Scans each registered repo in repos.json for this state.
# Returns: advisory string (empty if all repos clean or prereqs missing).
# -----------------------------------------------------------------------------
_detect_stuck_index_conflict() {
	local repos_json="$HOME/.config/aidevops/repos.json"

	# Prerequisites: repos.json must exist and jq must be available
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo ""
		return 0
	fi

	local findings=""
	local repo_path repo_name unmerged_files head_sha remote_sha

	while IFS='|' read -r repo_path repo_name; do
		[[ -z "$repo_path" ]] && continue
		# Expand ~ to $HOME (repos.json may contain unexpanded tildes)
		repo_path="${repo_path/#\~/$HOME}"
		[[ -d "$repo_path/.git" ]] || continue

		# Check for unmerged entries in the index
		unmerged_files=$(git -C "$repo_path" ls-files --unmerged 2>/dev/null) || unmerged_files=""
		[[ -z "$unmerged_files" ]] && continue

		# We have unmerged files — check if there's an active merge/rebase
		# operation. If MERGE_HEAD or REBASE_HEAD exists, the user has an
		# in-progress operation (not "stuck") — skip silently.
		if [[ -f "$repo_path/.git/MERGE_HEAD" ]] || [[ -f "$repo_path/.git/REBASE_HEAD" ]] || [[ -d "$repo_path/.git/rebase-merge" ]] || [[ -d "$repo_path/.git/rebase-apply" ]]; then
			continue
		fi

		# Extract just the file names from the unmerged listing (deduplicate
		# since each file appears once per stage: base/ours/theirs).
		local file_list
		file_list=$(echo "$unmerged_files" | awk '{print $NF}' | sort -u | head -5)
		local file_count
		file_count=$(echo "$unmerged_files" | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')

		# Determine safe remediation: if HEAD matches origin/main, a hard
		# reset is safe; otherwise manual inspection is needed.
		local remediation
		head_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null) || head_sha=""
		remote_sha=$(git -C "$repo_path" rev-parse origin/main 2>/dev/null) || remote_sha=""

		if [[ -n "$head_sha" && -n "$remote_sha" && "$head_sha" == "$remote_sha" ]]; then
			remediation="HEAD matches origin/main — safe to run: git -C ${repo_path} reset --hard HEAD"
		else
			remediation="HEAD differs from origin/main — inspect manually: git -C ${repo_path} status"
		fi

		local entry
		entry=$(printf 'Stuck merge state in %s (%s file(s): %s). %s' \
			"$repo_name" "$file_count" \
			"$(echo "$file_list" | tr '\n' ',' | sed 's/,$//')" \
			"$remediation")

		if [[ -n "$findings" ]]; then
			findings=$(printf '%s\n%s' "$findings" "$entry")
		else
			findings="$entry"
		fi
	done < <(jq -r '.initialized_repos[]? | select(.local_only != true) | "\(.path)|\(.slug // .path)"' "$repos_json" 2>/dev/null)

	echo "$findings"
	return 0
}

# -----------------------------------------------------------------------------
# _check_origin: verify framework provenance and notify on forks.
# Checks if the installed framework repo's git remote matches the canonical
# origin. Emits a helpful notice for fork users so they can check upstream
# for updates. Nice way to keep the community connected.
# Returns: origin notice string (empty if canonical or not detectable).
# -----------------------------------------------------------------------------
_check_origin() {
	local agents_dir="${AIDEVOPS_DIR:-$HOME/.aidevops}"
	local framework_repo="$HOME/Git/aidevops"
	local origin_notice=""

	# Only check if the framework repo directory exists and is a git repo
	if [[ ! -d "$framework_repo/.git" ]]; then
		echo ""
		return 0
	fi

	local remote_url
	remote_url=$(git -C "$framework_repo" remote get-url origin 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo ""
		return 0
	fi

	# Normalize: strip protocol/host prefix and .git suffix to get owner/repo
	local slug
	slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')

	# Good stuff — canonical origins that we recognise
	case "$slug" in
	marcusquinn/aidevops)
		# Canonical origin, all good
		echo ""
		return 0
		;;
	esac

	# Non-canonical origin detected — emit a helpful fork notice
	origin_notice="Fork detected: origin is ${slug}. Check https://github.com/marcusquinn/aidevops for upstream updates."

	# Cool — silently notify the provenance endpoint in the background
	# so the maintainer can track redistribution. Only non-canonical origins
	# reach this point; legitimate users of the original repo never trigger it.
	local canary_endpoint="https://provenance-ping.marcusquinn.workers.dev/ping"
	local framework_version
	framework_version=$(cat "$framework_repo/VERSION" 2>/dev/null || echo "unknown")
	local origin_hash
	origin_hash=$(printf '%s' "$remote_url" | shasum -a 256 2>/dev/null | cut -d' ' -f1 || echo "unknown")

	# Background fire-and-forget — never blocks startup, never fails visibly.
	# t2729 (Option B): redirect at subshell level so this background process
	# does not hold the parent's stdout FD open for synchronous callers.
	(curl --proto '=https' -fsSL -X POST "$canary_endpoint" \
		-H "Content-Type: application/json" \
		-d "{\"h\":\"${origin_hash}\",\"v\":\"${framework_version}\"}" \
		-m 3 || true) >/dev/null 2>&1 &

	echo "$origin_notice"
	return 0
}

# -----------------------------------------------------------------------------
# _check_signing: nudge if commit signing is not configured.
# Cool — one-liner reminder that does not repeat after dismissal.
# -----------------------------------------------------------------------------
_check_signing() {
	local dismissed_file="$HOME/.aidevops/cache/signing-nudge-dismissed"

	# Already dismissed — do not nag
	if [[ -f "$dismissed_file" ]]; then
		echo ""
		return 0
	fi

	local signing_format
	signing_format=$(git config --global gpg.format 2>/dev/null || echo "")
	local signing_enabled
	signing_enabled=$(git config --global commit.gpgsign 2>/dev/null || echo "")

	if [[ "$signing_format" != "ssh" || "$signing_enabled" != "true" ]]; then
		echo "Commit signing not configured. Run: aidevops signing setup"
		return 0
	fi

	# Configured — dismiss permanently so we do not check again
	mkdir -p "$(dirname "$dismissed_file")"
	touch "$dismissed_file"
	echo ""
	return 0
}

# -----------------------------------------------------------------------------
# _check_pulse_health: detect stalled/crashed pulse (GH#18979).
# If pulse-health.json exists but hasn't been updated in >30 minutes,
# the pulse is stalled. Emit a warning so the user can investigate.
# If the supervisor pulse launchd job exists but isn't running, nudge.
# -----------------------------------------------------------------------------
_check_pulse_health() {
	local health_file="$HOME/.aidevops/logs/pulse-health.json"

	# No health file = pulse never ran or not configured — skip silently
	if [[ ! -f "$health_file" ]]; then
		echo ""
		return 0
	fi

	local health_mtime now_epoch age_seconds
	health_mtime=$(_file_mtime_epoch "$health_file")
	now_epoch=$(date +%s)
	age_seconds=$((now_epoch - health_mtime))

	# Stale threshold: 30 minutes (1800 seconds). The pulse cycles every 2 minutes,
	# so 30 minutes of silence means ~15 consecutive failed cycles.
	if [[ "$age_seconds" -gt 1800 ]]; then
		local age_mins=$((age_seconds / 60))
		local hint=""
		# Check if launchd job exists but isn't running (macOS only)
		if [[ "$(uname)" == "Darwin" ]]; then
			local plist_label="com.aidevops.aidevops-supervisor-pulse"
			local launchd_state=""
			launchd_state=$(launchctl print "gui/$(id -u)/${plist_label}" 2>/dev/null | grep "state =" | awk '{print $NF}') || launchd_state=""
			if [[ "$launchd_state" == "not" || "$launchd_state" == "" ]]; then
				hint=" Run: launchctl kickstart gui/\$(id -u)/${plist_label}"
			fi
		fi
		echo "Pulse stalled: last health update ${age_mins}m ago.${hint}"
		return 0
	fi

	echo ""
	return 0
}

# -----------------------------------------------------------------------------
# _refresh_oauth_tokens: pre-emptive background token refresh on session startup.
# Refreshes any OAuth tokens expiring within 1 hour — catches tokens that
# expired while the machine was off. Runs silently; failures are harmless.
# -----------------------------------------------------------------------------
_refresh_oauth_tokens() {
	local agents_dir="${AIDEVOPS_DIR:-$HOME/.aidevops}/agents"
	local oauth_helper="$agents_dir/scripts/oauth-pool-helper.sh"
	if [[ -f "$oauth_helper" && -f "$HOME/.aidevops/oauth-pool.json" ]]; then
		(
			bash "$oauth_helper" refresh anthropic >/dev/null 2>&1
			bash "$oauth_helper" refresh openai >/dev/null 2>&1
		) &
	fi
	return 0
}

# -----------------------------------------------------------------------------
# _run_session_advisories: collect and emit all session-start advisories.
# Extracted from main() to keep function complexity under 100 lines.
# Args: $1=script_dir, $2=app_name, $3=cache_dir, $4=output (version line),
#       $5=current_version
# -----------------------------------------------------------------------------
_run_session_advisories() {
	local script_dir="$1" app_name="$2" cache_dir="$3" output="$4"
	local current_version="${5:-}"

	local runtime_hint nudge_output session_warning security_posture
	local secret_hygiene advisories_output contribution_watch origin_notice
	local signing_nudge script_drift stuck_index hotfix_notice
	runtime_hint=$(_get_runtime_hint "$app_name")
	nudge_output=$(_check_local_models "$script_dir")
	session_warning=$(_check_session_count "$script_dir")
	security_posture=$(_check_security_posture "$script_dir")
	secret_hygiene=$(_check_secret_hygiene "$script_dir")
	advisories_output=$(_check_advisories)
	contribution_watch=$(_check_contribution_watch)
	origin_notice=$(_check_origin)
	signing_nudge=$(_check_signing)
	local pulse_health
	pulse_health=$(_check_pulse_health)
	# t2156: detect deployed-script drift and trigger silent background redeploy.
	script_drift=$(_check_script_drift)
	# t2245: detect stuck 3-way merge state in canonical repos.
	stuck_index=$(_detect_stuck_index_conflict)
	# t2398: check for hotfix signal tags requiring immediate runner propagation.
	if [[ -n "$current_version" ]]; then
		hotfix_notice=$(_check_hotfix_available "$current_version")
	else
		hotfix_notice=""
	fi

	[[ -n "$runtime_hint" ]] && echo "$runtime_hint"
	[[ -n "$nudge_output" ]] && echo "$nudge_output"
	[[ -n "$session_warning" ]] && echo "$session_warning"
	[[ -n "$security_posture" ]] && echo "$security_posture"
	[[ -n "$secret_hygiene" ]] && echo "$secret_hygiene"
	[[ -n "$advisories_output" ]] && echo "$advisories_output"
	[[ -n "$contribution_watch" ]] && echo "$contribution_watch"
	[[ -n "$origin_notice" ]] && echo "$origin_notice"
	[[ -n "$signing_nudge" ]] && echo "$signing_nudge"
	[[ -n "$pulse_health" ]] && echo "$pulse_health"
	[[ -n "$script_drift" ]] && echo "$script_drift"
	[[ -n "$stuck_index" ]] && echo "$stuck_index"
	[[ -n "${hotfix_notice:-}" ]] && echo "$hotfix_notice"

	_write_cache "$cache_dir" "$output" "$runtime_hint" "$nudge_output" \
		"$session_warning" "$security_posture" "$secret_hygiene" \
		"$advisories_output" "$contribution_watch"

	_refresh_oauth_tokens

	# t2172: Self-heal broken OpenCode runtime symlinks at session start.
	# Belt-and-braces alongside the `aidevops update` cron path — covers
	# users who haven't yet pulled the latest update but start a new session.
	# Fail-open: must NEVER block session start or produce output.
	local sym_helper="${script_dir}/agent-sources-helper.sh"
	[[ -x "$sym_helper" ]] && "$sym_helper" cleanup-broken-symlinks >/dev/null 2>&1 || true

	return 0
}

main() {
	# In headless/non-interactive mode, skip the network call entirely.
	# This is the #1 fix for "update check kills non-interactive sessions".
	if is_headless "$@"; then
		local current
		current=$(get_version)
		echo "aidevops v$current (headless - skipped update check)"
		return 0
	fi

	local current remote app_info app_name app_version git_context
	current=$(get_version)
	remote=$(get_remote_version)
	app_info=$(detect_app)
	git_context=$(get_git_context)

	# Parse app name and version
	if [[ "$app_info" == *"|"* ]]; then
		app_name="${app_info%%|*}"
		app_version="${app_info##*|}"
	else
		app_name="$app_info"
		app_version=""
	fi

	local cache_dir="$HOME/.aidevops/cache"

	# Build version string — returns 1 and prints UPDATE_AVAILABLE if update found
	local version_str
	if ! version_str=$(_build_version_str "$current" "$remote" "$app_name" "$cache_dir"); then
		# Output the UPDATE_AVAILABLE line so the AI sees it via stdout
		echo "$version_str"
		# Append auto-update status so the AI can reassure the user
		if _is_auto_update_active; then
			echo "AUTO_UPDATE_ENABLED"
		fi
		return 0
	fi

	local app_str git_context_val output
	app_str=$(_build_app_str "$app_name" "$app_version")
	output=$(_build_output_line "$version_str" "$app_str" "$git_context")
	echo "$output"

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	# GH#18950 (t2087) + GH#18965 (t2094): bash 3.2 → modern bash ensure.
	# Actually runs `brew upgrade bash` when drift is detected, matching the
	# framework's own auto-update philosophy. Rate-limits `brew update` to
	# 24h internally via _BREW_UPDATE_STATE. Best-effort — never blocks.
	# Opt-out: AIDEVOPS_AUTO_UPGRADE_BASH=0 disables.
	if [[ -x "${script_dir}/bash-upgrade-helper.sh" ]]; then
		"${script_dir}/bash-upgrade-helper.sh" ensure --yes --quiet 2>/dev/null || true
	fi

	_run_session_advisories "$script_dir" "$app_name" "$cache_dir" "$output" "$current"

	return 0
}

main "$@"
