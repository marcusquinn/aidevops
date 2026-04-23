#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# -----------------------------------------------------------------------------
# review-gate-config-helper.sh — CLI for configuring review_gate.rate_limit_behavior
# in ~/.config/aidevops/repos.json without hand-editing JSON.
#
# Usage:
#   aidevops review-gate                              Show config for all repos
#   aidevops review-gate list                         Same as above (explicit)
#   aidevops review-gate <slug>                       Show config for one repo
#   aidevops review-gate <slug> pass|wait|unset       Set per-repo default
#   aidevops review-gate <slug> --tool <bot> pass|wait|unset  Per-tool override
#   aidevops review-gate --help                       Show this help
#
# Schema written to ~/.config/aidevops/repos.json under the matching
# initialized_repos entry:
#   { "review_gate": { "rate_limit_behavior": "pass",
#                      "tools": { "coderabbitai": { "rate_limit_behavior": "wait" } } } }
#
# Resolution order (unchanged): per-tool > per-repo > env var > "pass".
# This helper only edits repos.json. Env var and default are untouched.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Fallback colors when shared-constants.sh is not present
[[ -z "${RED+x}" ]]    && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]]  && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]]   && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]]     && NC='\033[0m'

readonly REPOS_JSON="${HOME}/.config/aidevops/repos.json"

# Known bot logins for --tool validation. New bots warn but are not rejected
# (forward-compat: new bots should work without a helper update).
readonly KNOWN_BOT_LOGINS="coderabbitai gemini-code-assist augment-code augmentcode copilot"

_print_ok() {
	local msg="$1"
	printf "${GREEN}[OK]${NC} %s\n" "$msg"
	return 0
}

_print_info() {
	local msg="$1"
	printf "${BLUE}[INFO]${NC} %s\n" "$msg"
	return 0
}

_print_warn() {
	local msg="$1"
	printf "${YELLOW}[WARN]${NC} %s\n" "$msg" >&2
	return 0
}

_print_error() {
	local msg="$1"
	printf "${RED}[ERROR]${NC} %s\n" "$msg" >&2
	return 0
}

# Validate that jq is available — required for all mutations.
_require_jq() {
	if ! command -v jq &>/dev/null; then
		_print_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

# Validate that repos.json exists and is readable.
_require_repos_json() {
	if [[ ! -f "$REPOS_JSON" ]]; then
		_print_error "repos.json not found: $REPOS_JSON"
		_print_info "Run 'aidevops init' to create it."
		return 1
	fi
	return 0
}

# Validate a rate_limit_behavior value.
_validate_behavior() {
	local value="$1"
	case "$value" in
	pass | wait | unset) return 0 ;;
	*)
		_print_error "Invalid value '${value}'. Must be: pass, wait, or unset"
		return 1
		;;
	esac
}

# Warn if a bot login is not in the known list (but don't reject it —
# forward-compat with new bots added after this helper was written).
_warn_if_unknown_bot() {
	local bot="$1"
	local known
	known="$KNOWN_BOT_LOGINS"
	local found=0
	local b
	for b in $known; do
		if [[ "$b" == "$bot" ]]; then
			found=1
			break
		fi
	done
	if [[ "$found" -eq 0 ]]; then
		_print_warn "Unknown bot login '${bot}'. Known bots: ${KNOWN_BOT_LOGINS}"
		_print_warn "Proceeding anyway — new bots will work if the name is correct."
	fi
	return 0
}

# Look up a repo entry by slug (owner/repo) or by path.
# Prints the matched slug on success, empty on failure.
_resolve_slug() {
	local input="$1"
	_require_jq || return 1
	_require_repos_json || return 1

	local matched_slug=""

	# Try exact slug match first
	matched_slug=$(jq -r --arg input "$input" \
		'.initialized_repos[]? | select(.slug == $input) | .slug' \
		"$REPOS_JSON" 2>/dev/null | head -1)

	# Try path match if slug match failed
	if [[ -z "$matched_slug" ]]; then
		matched_slug=$(jq -r --arg input "$input" \
			'.initialized_repos[]? | select(.path == $input) | .slug' \
			"$REPOS_JSON" 2>/dev/null | head -1)
	fi

	printf '%s' "$matched_slug"
	return 0
}

# Print the effective rate_limit_behavior for a slug+bot combination,
# mirroring the resolution order in review-bot-gate-helper.sh.
_resolve_effective_behavior() {
	local slug="$1"
	local bot="${2:-}"

	local per_tool_val=""
	local per_repo_val=""

	if [[ -f "$REPOS_JSON" ]] && command -v jq &>/dev/null; then
		per_repo_val=$(jq -r --arg slug "$slug" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.rate_limit_behavior // empty' \
			"$REPOS_JSON" 2>/dev/null) || per_repo_val=""

		if [[ -n "$bot" ]]; then
			per_tool_val=$(jq -r --arg slug "$slug" --arg bot "$bot" \
				'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.tools[$bot].rate_limit_behavior // empty' \
				"$REPOS_JSON" 2>/dev/null) || per_tool_val=""
		fi
	fi

	local global_env="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"

	# Resolution order: per-tool > per-repo > env > "pass"
	if [[ -n "$bot" && -n "$per_tool_val" ]]; then
		printf '%s' "$per_tool_val"
	elif [[ -n "$per_repo_val" ]]; then
		printf '%s' "$per_repo_val"
	else
		printf '%s' "$global_env"
	fi
	return 0
}

# Error helper: called when a jq mutation pipeline fails.
_jq_mutation_failed() {
	_print_error "jq mutation failed — repos.json was not modified"
	return 1
}

# Safely write to repos.json: backup, apply mutation, validate, restore on failure.
_safe_write_repos_json() {
	local new_json="$1"
	local bak_file="${REPOS_JSON}.bak"

	# Validate the new JSON before writing
	if ! printf '%s' "$new_json" | jq . >/dev/null 2>&1; then
		_print_error "Generated JSON is invalid — not writing. This is a bug; please report it."
		return 1
	fi

	# Backup existing file
	cp "$REPOS_JSON" "$bak_file" || {
		_print_error "Could not create backup at ${bak_file}"
		return 1
	}

	# Write new content
	printf '%s\n' "$new_json" >"$REPOS_JSON"

	# Validate the written file
	if ! jq . "$REPOS_JSON" >/dev/null 2>&1; then
		_print_error "Validation failed after write. Restoring backup."
		cp "$bak_file" "$REPOS_JSON"
		rm -f "$bak_file"
		return 1
	fi

	rm -f "$bak_file"
	return 0
}

# ── List command ─────────────────────────────────────────────────────────────

cmd_list() {
	local filter_slug="${1:-}"

	_require_jq || return 1
	_require_repos_json || return 1

	local slugs
	if [[ -n "$filter_slug" ]]; then
		# Verify the slug is registered
		local resolved
		resolved=$(_resolve_slug "$filter_slug")
		if [[ -z "$resolved" ]]; then
			_print_error "No registered repo found matching '${filter_slug}'"
			_print_info "Run 'aidevops repos' to list registered repos."
			return 1
		fi
		slugs="$resolved"
	else
		slugs=$(jq -r '.initialized_repos[]? | .slug // empty' "$REPOS_JSON" 2>/dev/null) || slugs=""
	fi

	if [[ -z "$slugs" ]]; then
		_print_info "No repos registered. Run 'aidevops init' or 'aidevops repos'."
		return 0
	fi

	echo ""
	echo "Review Gate Configuration"
	echo "========================="
	echo ""

	local global_env="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"
	printf "  Global default (env / hardcoded): %s\n" "$global_env"
	echo ""

	local slug
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue

		local per_repo_val
		per_repo_val=$(jq -r --arg slug "$slug" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.rate_limit_behavior // empty' \
			"$REPOS_JSON" 2>/dev/null) || per_repo_val=""

		local effective
		effective=$(_resolve_effective_behavior "$slug")

		printf "  %s\n" "$slug"
		if [[ -n "$per_repo_val" ]]; then
			printf "    per-repo: %-6s  effective: %s\n" "$per_repo_val" "$effective"
		else
			printf "    per-repo: %-6s  effective: %s\n" "(unset)" "$effective"
		fi

		# List per-tool overrides if present
		local tools_json
		tools_json=$(jq -r --arg slug "$slug" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | .review_gate.tools // empty | to_entries[]? | "\(.key)=\(.value.rate_limit_behavior // "(unset)")"' \
			"$REPOS_JSON" 2>/dev/null) || tools_json=""

		if [[ -n "$tools_json" ]]; then
			local tool_entry
			while IFS= read -r tool_entry; do
				[[ -z "$tool_entry" ]] && continue
				local tool_name tool_val tool_effective
				tool_name="${tool_entry%%=*}"
				tool_val="${tool_entry#*=}"
				tool_effective=$(_resolve_effective_behavior "$slug" "$tool_name")
				printf "    tool %-24s per-tool: %-6s  effective: %s\n" \
					"${tool_name}:" "$tool_val" "$tool_effective"
			done <<<"$tools_json"
		fi

		echo ""
	done <<<"$slugs"

	return 0
}

# ── Set command ──────────────────────────────────────────────────────────────

cmd_set() {
	local slug="$1"
	local tool_login="${2:-}"
	local value="$3"

	_require_jq || return 1
	_require_repos_json || return 1

	# Validate the value
	_validate_behavior "$value" || return 1

	# Resolve and validate the slug
	local resolved_slug
	resolved_slug=$(_resolve_slug "$slug")
	if [[ -z "$resolved_slug" ]]; then
		_print_error "No registered repo found matching '${slug}'"
		_print_info "Run 'aidevops repos' to list registered repos."
		return 1
	fi

	# Warn if bot login is unknown (but proceed)
	if [[ -n "$tool_login" ]]; then
		_warn_if_unknown_bot "$tool_login"
	fi

	local current_json
	current_json=$(<"$REPOS_JSON")

	local new_json
	if [[ "$value" == "unset" ]]; then
		# Remove the field
		if [[ -n "$tool_login" ]]; then
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg bot "$tool_login" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.tools[$bot]) |= del(.rate_limit_behavior)' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
			# Clean up empty tools entries
			new_json=$(printf '%s' "$new_json" | jq \
				--arg slug "$resolved_slug" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.tools) |= if . == {} then del(.) else . end' \
				2>/dev/null) || true
		else
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate) |= del(.rate_limit_behavior)' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		fi
	else
		# Set the field
		if [[ -n "$tool_login" ]]; then
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg bot "$tool_login" \
				--arg val "$value" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.tools[$bot].rate_limit_behavior) |= $val' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		else
			new_json=$(printf '%s' "$current_json" | jq \
				--arg slug "$resolved_slug" \
				--arg val "$value" \
				'(.initialized_repos[] | select(.slug == $slug) | .review_gate.rate_limit_behavior) |= $val' \
				2>/dev/null) || { _jq_mutation_failed; return 1; }
		fi
	fi

	_safe_write_repos_json "$new_json" || return 1

	# Report what changed
	if [[ "$value" == "unset" ]]; then
		if [[ -n "$tool_login" ]]; then
			_print_ok "Removed per-tool override for '${tool_login}' on ${resolved_slug}"
			_print_info "Effective value now: $(_resolve_effective_behavior "$resolved_slug" "$tool_login")"
		else
			_print_ok "Removed per-repo override for ${resolved_slug}"
			_print_info "Effective value now: $(_resolve_effective_behavior "$resolved_slug")"
		fi
	else
		if [[ -n "$tool_login" ]]; then
			_print_ok "Set review_gate.tools.${tool_login}.rate_limit_behavior = ${value} for ${resolved_slug}"
		else
			_print_ok "Set review_gate.rate_limit_behavior = ${value} for ${resolved_slug}"
		fi
		_print_info "Effective value: $(_resolve_effective_behavior "$resolved_slug" "$tool_login")"
	fi

	return 0
}

# ── Help ─────────────────────────────────────────────────────────────────────

cmd_help() {
	echo "review-gate-config-helper.sh — Configure review_gate.rate_limit_behavior"
	echo ""
	echo "Controls what happens when a review bot is rate-limited during a merge check:"
	echo "  pass  (default) — treat rate-limit as a pass, preserve merge velocity"
	echo "  wait            — keep polling until the bot responds (strict review-before-merge)"
	echo ""
	echo "Commands:"
	echo "  list [<slug>]                          Show config for all repos (or one)"
	echo "  <slug> pass|wait|unset                 Set per-repo default"
	echo "  <slug> --tool <bot> pass|wait|unset    Set per-tool override"
	echo "  help                                   Show this help"
	echo ""
	echo "Arguments:"
	echo "  <slug>   owner/repo slug or local path (must be registered in repos.json)"
	echo "  <bot>    Bot login: coderabbitai, gemini-code-assist, augment-code, copilot"
	echo "           Unknown bot logins produce a warning but are accepted (forward-compat)"
	echo ""
	echo "Examples:"
	echo "  aidevops review-gate                              # list all repos"
	echo "  aidevops review-gate marcusquinn/myrepo          # show one repo"
	echo "  aidevops review-gate marcusquinn/myrepo wait     # block merges on rate-limit"
	echo "  aidevops review-gate marcusquinn/myrepo pass     # restore default (pass)"
	echo "  aidevops review-gate marcusquinn/myrepo unset    # remove per-repo override"
	echo "  aidevops review-gate marcusquinn/myrepo --tool coderabbitai wait"
	echo "  aidevops review-gate marcusquinn/myrepo --tool coderabbitai unset"
	echo ""
	echo "Resolution order (per-tool wins):"
	echo "  per-tool config > per-repo config > REVIEW_GATE_RATE_LIMIT_BEHAVIOR env > pass"
	echo ""
	echo "Reference: .agents/reference/repos-json-fields.md"
	return 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
	local command="${1:-list}"
	shift 2>/dev/null || true

	# Handle --help / -h as first arg
	case "$command" in
	--help | -h | help) cmd_help; return 0 ;;
	esac

	# Handle: bare (no args after binary) → list
	# Handle: list [slug]
	# Handle: <slug>                → show one repo
	# Handle: <slug> pass|wait|unset
	# Handle: <slug> --tool <bot> pass|wait|unset

	case "$command" in
	list)
		cmd_list "${1:-}"
		;;
	*)
		# command is a slug (or path). Determine subcommand.
		local slug="$command"
		local subcommand="${1:-}"

		# Bare slug → show that repo's config
		if [[ -z "$subcommand" ]]; then
			cmd_list "$slug"
			return $?
		fi

		# slug --tool <bot> pass|wait|unset
		if [[ "$subcommand" == "--tool" ]]; then
			local tool_login="${2:-}"
			local value="${3:-}"
			if [[ -z "$tool_login" ]]; then
				_print_error "Missing bot login after --tool"
				cmd_help
				return 1
			fi
			if [[ -z "$value" ]]; then
				_print_error "Missing value after --tool ${tool_login}. Expected: pass, wait, or unset"
				cmd_help
				return 1
			fi
			cmd_set "$slug" "$tool_login" "$value"
			return $?
		fi

		# slug pass|wait|unset
		case "$subcommand" in
		pass | wait | unset)
			cmd_set "$slug" "" "$subcommand"
			return $?
			;;
		*)
			_print_error "Unknown subcommand: ${subcommand}"
			cmd_help
			return 1
			;;
		esac
		;;
	esac
}

main "$@"
