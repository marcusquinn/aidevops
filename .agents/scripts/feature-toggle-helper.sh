#!/usr/bin/env bash
# feature-toggle-helper.sh - Manage aidevops feature toggles
#
# Provides get/set/list/reset operations on ~/.config/aidevops/feature-toggles.conf.
# Called by `aidevops config <command>` CLI.
#
# Usage:
#   feature-toggle-helper.sh list              List all toggles with current values
#   feature-toggle-helper.sh get <key>         Get a single toggle value
#   feature-toggle-helper.sh set <key> <value> Set a toggle (creates user config if needed)
#   feature-toggle-helper.sh reset [key]       Reset one or all toggles to defaults
#   feature-toggle-helper.sh path              Show config file paths
#   feature-toggle-helper.sh help              Show this help
#
# The user config file is: ~/.config/aidevops/feature-toggles.conf
# Defaults are in: ~/.aidevops/agents/configs/feature-toggles.conf.defaults

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly USER_CONFIG="${HOME}/.config/aidevops/feature-toggles.conf"
readonly DEFAULTS_CONFIG="${HOME}/.aidevops/agents/configs/feature-toggles.conf.defaults"

# Get all known toggle keys from the defaults file
_get_all_keys() {
	if [[ ! -r "$DEFAULTS_CONFIG" ]]; then
		echo ""
		return 0
	fi
	grep -E '^[a-zA-Z_][a-zA-Z0-9_]*=' "$DEFAULTS_CONFIG" | cut -d= -f1 | sort
	return 0
}

# Get the default value for a key
_get_default() {
	local key="$1"
	if [[ ! -r "$DEFAULTS_CONFIG" ]]; then
		echo ""
		return 0
	fi
	grep -E "^${key}=" "$DEFAULTS_CONFIG" | head -1 | cut -d= -f2
	return 0
}

# Get the user override value for a key (empty if not overridden)
_get_user_override() {
	local key="$1"
	if [[ ! -r "$USER_CONFIG" ]]; then
		echo ""
		return 0
	fi
	grep -E "^${key}=" "$USER_CONFIG" | tail -1 | cut -d= -f2
	return 0
}

# Get the env var override for a key (empty if not set)
_get_env_override() {
	local key="$1"
	local env_var
	env_var=$(_ft_env_map "$key")
	if [[ -n "$env_var" ]]; then
		echo "${!env_var:-}"
	else
		echo ""
	fi
	return 0
}

# Get the effective value for a key (env > user > default)
_get_effective() {
	local key="$1"
	local env_val user_val default_val

	env_val=$(_get_env_override "$key")
	if [[ -n "$env_val" ]]; then
		echo "$env_val"
		return 0
	fi

	user_val=$(_get_user_override "$key")
	if [[ -n "$user_val" ]]; then
		echo "$user_val"
		return 0
	fi

	default_val=$(_get_default "$key")
	echo "$default_val"
	return 0
}

# Get the description comment for a key from the defaults file
_get_description() {
	local key="$1"
	if [[ ! -r "$DEFAULTS_CONFIG" ]]; then
		echo ""
		return 0
	fi
	# Find the key line, then look backwards for the comment block
	local line_num
	line_num=$(grep -n "^${key}=" "$DEFAULTS_CONFIG" | head -1 | cut -d: -f1)
	if [[ -z "$line_num" ]]; then
		echo ""
		return 0
	fi
	# Get the comment line immediately before the key
	local prev_line=$((line_num - 1))
	if [[ $prev_line -gt 0 ]]; then
		local comment
		comment=$(sed -n "${prev_line}p" "$DEFAULTS_CONFIG")
		if [[ "$comment" == \#* ]]; then
			# Strip leading "# " and "Env override: ..." suffix
			echo "$comment" | sed 's/^# *//' | sed 's/ *Env override:.*//'
		fi
	fi
	return 0
}

cmd_list() {
	local keys
	keys=$(_get_all_keys)

	if [[ -z "$keys" ]]; then
		print_error "No feature toggles found. Run 'aidevops update' to install defaults."
		return 1
	fi

	echo ""
	echo -e "${BOLD:-\033[1m}Feature Toggles${NC}"
	echo "================"
	echo ""
	printf "  %-28s %-10s %-10s %s\n" "KEY" "VALUE" "SOURCE" "DESCRIPTION"
	printf "  %-28s %-10s %-10s %s\n" "---" "-----" "------" "-----------"

	local key
	for key in $keys; do
		local effective default_val user_val env_val source desc

		default_val=$(_get_default "$key")
		user_val=$(_get_user_override "$key")
		env_val=$(_get_env_override "$key")
		desc=$(_get_description "$key")

		# Determine source and effective value
		if [[ -n "$env_val" ]]; then
			effective="$env_val"
			source="env"
		elif [[ -n "$user_val" ]]; then
			effective="$user_val"
			source="user"
		else
			effective="$default_val"
			source="default"
		fi

		# Color the value based on source
		local value_display
		case "$source" in
		env) value_display="${YELLOW}${effective}${NC}" ;;
		user) value_display="${GREEN}${effective}${NC}" ;;
		default) value_display="${effective}" ;;
		esac

		printf "  %-28s %-10b %-10s %s\n" "$key" "$value_display" "$source" "$desc"
	done

	echo ""
	echo -e "  ${GREEN}green${NC} = user override  ${YELLOW}yellow${NC} = env override  plain = default"
	echo ""
	echo "  Config file: $USER_CONFIG"
	echo "  Defaults:    $DEFAULTS_CONFIG"
	echo ""
	echo "  Set a toggle:   aidevops config set <key> <value>"
	echo "  Reset a toggle: aidevops config reset <key>"
	echo "  Reset all:      aidevops config reset"
	echo ""
	return 0
}

cmd_get() {
	local key="$1"

	if [[ -z "$key" ]]; then
		print_error "Usage: aidevops config get <key>"
		return 1
	fi

	# Validate key exists in defaults
	local default_val
	default_val=$(_get_default "$key")
	if [[ -z "$default_val" ]] && ! grep -qE "^${key}=" "$DEFAULTS_CONFIG" 2>/dev/null; then
		print_error "Unknown toggle: $key"
		echo "  Run 'aidevops config list' to see available toggles."
		return 1
	fi

	local effective
	effective=$(_get_effective "$key")
	echo "$effective"
	return 0
}

cmd_set() {
	local key="$1"
	local value="$2"

	if [[ -z "$key" || -z "$value" ]]; then
		print_error "Usage: aidevops config set <key> <value>"
		return 1
	fi

	# Validate key exists in defaults
	if ! grep -qE "^${key}=" "$DEFAULTS_CONFIG" 2>/dev/null; then
		print_error "Unknown toggle: $key"
		echo "  Run 'aidevops config list' to see available toggles."
		return 1
	fi

	# Validate boolean values for boolean toggles
	local default_val
	default_val=$(_get_default "$key")
	if [[ "$default_val" == "true" || "$default_val" == "false" ]]; then
		local lower_value
		lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower_value" != "true" && "$lower_value" != "false" ]]; then
			print_error "Toggle '$key' expects true or false, got: $value"
			return 1
		fi
		value="$lower_value"
	fi

	# Create user config directory if needed
	mkdir -p "$(dirname "$USER_CONFIG")"

	# Create user config file with header if it doesn't exist
	if [[ ! -f "$USER_CONFIG" ]]; then
		cat >"$USER_CONFIG" <<'HEADER'
# aidevops Feature Toggles — User Overrides
# ===========================================
# This file overrides the defaults in:
#   ~/.aidevops/agents/configs/feature-toggles.conf.defaults
#
# Format: key=value (one per line). Lines starting with # are comments.
# Run 'aidevops config list' to see all available toggles.
# Run 'aidevops config reset' to remove all overrides.

HEADER
	fi

	# Update or add the key
	if grep -qE "^${key}=" "$USER_CONFIG" 2>/dev/null; then
		# Update existing entry
		if [[ "$(uname)" == "Darwin" ]]; then
			sed -i '' "s|^${key}=.*|${key}=${value}|" "$USER_CONFIG"
		else
			sed -i "s|^${key}=.*|${key}=${value}|" "$USER_CONFIG"
		fi
	else
		# Add new entry
		echo "${key}=${value}" >>"$USER_CONFIG"
	fi

	print_success "Set ${key}=${value}"

	# Show if an env var would override this
	local env_val
	env_val=$(_get_env_override "$key")
	if [[ -n "$env_val" ]]; then
		local env_var
		env_var=$(_ft_env_map "$key")
		print_warning "Note: environment variable ${env_var}=${env_val} will override this setting"
	fi

	# Hint about when the change takes effect
	echo "  Change takes effect on next setup.sh run or script invocation."
	return 0
}

cmd_reset() {
	local key="${1:-}"

	if [[ -n "$key" ]]; then
		# Reset a single key
		if [[ ! -f "$USER_CONFIG" ]]; then
			print_info "No user overrides file exists — already using defaults"
			return 0
		fi

		if grep -qE "^${key}=" "$USER_CONFIG" 2>/dev/null; then
			if [[ "$(uname)" == "Darwin" ]]; then
				sed -i '' "/^${key}=/d" "$USER_CONFIG"
			else
				sed -i "/^${key}=/d" "$USER_CONFIG"
			fi
			local default_val
			default_val=$(_get_default "$key")
			print_success "Reset ${key} to default (${default_val})"
		else
			print_info "${key} is already using the default value"
		fi
	else
		# Reset all — remove user config file
		if [[ -f "$USER_CONFIG" ]]; then
			rm -f "$USER_CONFIG"
			print_success "Removed all user overrides — using defaults"
		else
			print_info "No user overrides file exists — already using defaults"
		fi
	fi
	return 0
}

cmd_path() {
	echo "User config:  $USER_CONFIG"
	echo "Defaults:     $DEFAULTS_CONFIG"
	if [[ -f "$USER_CONFIG" ]]; then
		echo "User config exists: yes"
	else
		echo "User config exists: no (using defaults only)"
	fi
	return 0
}

cmd_help() {
	cat <<'EOF'
feature-toggle-helper.sh - Manage aidevops feature toggles

USAGE:
    aidevops config <command> [args]

COMMANDS:
    list              List all toggles with current values and sources
    get <key>         Get the effective value of a toggle
    set <key> <value> Set a toggle (persists in user config file)
    reset [key]       Reset one toggle or all toggles to defaults
    path              Show config file paths
    help              Show this help

EXAMPLES:
    aidevops config list
    aidevops config set auto_update false
    aidevops config set manage_opencode_config false
    aidevops config get supervisor_pulse
    aidevops config reset auto_update
    aidevops config reset                    # reset all to defaults

PRIORITY ORDER:
    1. Environment variables (e.g. AIDEVOPS_AUTO_UPDATE=false)
    2. User config (~/.config/aidevops/feature-toggles.conf)
    3. Defaults (~/.aidevops/agents/configs/feature-toggles.conf.defaults)

FILES:
    ~/.config/aidevops/feature-toggles.conf              User overrides
    ~/.aidevops/agents/configs/feature-toggles.conf.defaults  Shipped defaults

EOF
	return 0
}

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	list | ls) cmd_list ;;
	get) cmd_get "${1:-}" ;;
	set) cmd_set "${1:-}" "${2:-}" ;;
	reset) cmd_reset "${1:-}" ;;
	path | paths) cmd_path ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
