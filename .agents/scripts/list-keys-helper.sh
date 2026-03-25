#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155

# List Keys Helper - Show all API keys available in session with their sources
# This script NEVER exposes actual key values, only names and locations
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Key storage locations
readonly CREDENTIALS_FILE="$HOME/.config/aidevops/credentials.sh"
readonly CODERABBIT_KEY_FILE="$HOME/.config/coderabbit/api_key"
readonly REPO_CONFIGS_DIR="./configs"

# Counters
total_keys=0
total_sources=0

print_header() {
	echo ""
	echo -e "${BLUE}API Keys Available in Session${NC}"
	echo "==============================="
	echo ""
	return 0
}

print_source() {
	local source="$1"
	# Shorten home directory paths for readability
	source="${source/#$HOME/~}"
	echo -e "${BLUE}Source:${NC} $source"
	((++total_sources))
	return 0
}

print_key() {
	local key_name="$1"
	local status="$2"
	local status_color="${GREEN}"

	case "$status" in
	"not loaded")
		status_color="${YELLOW}"
		;;
	"placeholder")
		status_color="${RED}"
		;;
	"configured")
		status_color="${BLUE}"
		;;
	*)
		# Default: keep GREEN
		;;
	esac

	# Simple format: "  KEY_NAME [status]" - no fixed width padding
	echo -e "  ${key_name} ${status_color}[${status}]${NC}"
	((++total_keys))
	return 0
}

# Check if a value is a placeholder (not a real key)
is_placeholder() {
	local value="$1"

	# Empty or very short values
	if [[ -z "$value" || ${#value} -lt 4 ]]; then
		return 0
	fi

	# Common placeholder patterns (case-insensitive)
	local lower_value
	lower_value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

	case "$lower_value" in
	# Explicit placeholders
	*your*key* | *your*token* | *your*secret* | *your*password*)
		return 0
		;;
	*replace* | *changeme* | *change_me* | *fixme* | *todo*)
		return 0
		;;
	*example* | *sample* | *test*key* | *dummy* | *fake*)
		return 0
		;;
	*insert*here* | *put*here* | *add*here* | *enter*here*)
		return 0
		;;
	# Generic placeholders
	xxx* | yyy* | zzz* | aaa* | placeholder* | none | null | undefined)
		return 0
		;;
	# Template markers
	*\<*\>* | *\{*\}* | *\[*\]*)
		return 0
		;;
	*)
		# Not a placeholder pattern, continue checking
		;;
	esac

	# All same character (like "xxxx" or "0000")
	if [[ "$value" =~ ^(.)\1+$ ]]; then
		return 0
	fi

	return 1
}

check_key_loaded() {
	local key_name="$1"
	local value="${!key_name:-}"

	if [[ -z "$value" ]]; then
		echo "not loaded"
	elif is_placeholder "$value"; then
		echo "placeholder"
	else
		echo "loaded"
	fi
	return 0
}

# List keys from credentials.sh
list_mcp_env_keys() {
	if [[ ! -f "$CREDENTIALS_FILE" ]]; then
		return 0
	fi

	print_source "$CREDENTIALS_FILE"

	while IFS= read -r line; do
		# Extract variable name from export statements
		if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]]; then
			local key_name="${BASH_REMATCH[1]}"
			local status
			status=$(check_key_loaded "$key_name")
			print_key "$key_name" "$status"
		fi
	done <"$CREDENTIALS_FILE"

	echo ""
	return 0
}

# List environment-only keys (not from credentials.sh)
# Scans all env vars for credential patterns: *_KEY, *_TOKEN, *_SECRET, *_PASSWORD, *_API_*
list_env_only_keys() {
	local mcp_keys=""
	local found_env_only=0

	# Get list of keys from credentials.sh for comparison
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		mcp_keys=$(grep -oE '^export[[:space:]]+[A-Z_][A-Z0-9_]*' "$CREDENTIALS_FILE" 2>/dev/null | sed 's/export[[:space:]]*//' || true)
	fi

	# Scan all environment variables for credential patterns
	# Patterns: *_KEY, *_TOKEN, *_SECRET, *_PASSWORD, *_CREDENTIAL, *_API_*, *_AUTH_*
	local env_keys
	env_keys=$(env | grep -E '^[A-Z_][A-Z0-9_]*=.' | cut -d= -f1 | grep -E '(_KEY|_TOKEN|_SECRET|_PASSWORD|_CREDENTIAL|_API_|_AUTH_|_ACCESS_)' | sort || true)

	for key_name in $env_keys; do
		# Skip if already in credentials.sh
		if echo "$mcp_keys" | grep -q "^${key_name}$"; then
			continue
		fi

		# Skip common non-credential env vars that match patterns
		case "$key_name" in
		SSH_AUTH_SOCK | GPG_AGENT_* | DBUS_* | XDG_* | GNOME_* | KDE_*)
			continue
			;;
		*)
			# Process this key
			;;
		esac

		if [[ $found_env_only -eq 0 ]]; then
			print_source "Environment (shell session)"
			found_env_only=1
		fi

		local status
		status=$(check_key_loaded "$key_name")
		print_key "$key_name" "$status"
	done

	if [[ $found_env_only -eq 1 ]]; then
		echo ""
	fi

	return 0
}

# List keys from shell config files (.zshrc, .bashrc, .bash_profile)
# These are exports defined directly in shell configs, not via credentials.sh
list_shell_config_keys() {
	local mcp_keys=""
	local found_shell_keys=0

	# Get list of keys from credentials.sh for comparison
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		mcp_keys=$(grep -oE '^export[[:space:]]+[A-Z_][A-Z0-9_]*' "$CREDENTIALS_FILE" 2>/dev/null | sed 's/export[[:space:]]*//' || true)
	fi

	# Shell config files to scan
	local shell_configs=(
		"$HOME/.zshrc"
		"$HOME/.bashrc"
		"$HOME/.bash_profile"
		"$HOME/.profile"
		"$HOME/.zprofile"
	)

	for config_file in "${shell_configs[@]}"; do
		if [[ ! -f "$config_file" ]]; then
			continue
		fi

		# Find export statements with credential patterns
		local shell_keys
		shell_keys=$(grep -E '^[[:space:]]*export[[:space:]]+[A-Z_][A-Z0-9_]*=' "$config_file" 2>/dev/null |
			grep -E '(_KEY|_TOKEN|_SECRET|_PASSWORD|_CREDENTIAL|_API_|_AUTH_)' |
			sed 's/.*export[[:space:]]*//' | cut -d= -f1 | sort -u || true)

		for key_name in $shell_keys; do
			# Skip if already in credentials.sh
			if echo "$mcp_keys" | grep -q "^${key_name}$"; then
				continue
			fi

			if [[ $found_shell_keys -eq 0 ]]; then
				print_source "Shell configs (~/.zshrc, ~/.bashrc, etc.)"
				found_shell_keys=1
			fi

			local status
			status=$(check_key_loaded "$key_name")
			print_key "$key_name" "$status"
		done
	done

	if [[ $found_shell_keys -eq 1 ]]; then
		echo ""
	fi

	return 0
}

# List CodeRabbit key
list_coderabbit_key() {
	if [[ -f "$CODERABBIT_KEY_FILE" ]]; then
		print_source "$CODERABBIT_KEY_FILE"
		print_key "CODERABBIT_API_KEY" "loaded"
		echo ""
	fi
	return 0
}

# List keys from repository configs
list_repo_config_keys() {
	if [[ ! -d "$REPO_CONFIGS_DIR" ]]; then
		return 0
	fi

	local found_configs=0

	for config_file in "$REPO_CONFIGS_DIR"/*-config.json; do
		if [[ -f "$config_file" ]]; then
			if [[ $found_configs -eq 0 ]]; then
				print_source "$REPO_CONFIGS_DIR/*-config.json (gitignored)"
				found_configs=1
			fi

			# Extract key names from JSON (look for common patterns)
			local keys
			keys=$(grep -oE '"(api_key|apiKey|token|API_KEY|TOKEN|secret|SECRET)"' "$config_file" 2>/dev/null | tr -d '"' | sort -u || true)

			if [[ -n "$keys" ]]; then
				local basename
				basename=$(basename "$config_file" .json)
				for key in $keys; do
					print_key "${basename}:${key}" "configured"
				done
			fi
		fi
	done

	if [[ $found_configs -eq 1 ]]; then
		echo ""
	fi

	return 0
}

print_summary() {
	echo -e "${DIM}---${NC}"
	echo -e "Total: ${GREEN}${total_keys}${NC} keys, ${BLUE}${total_sources}${NC} sources"
	echo ""
	echo -e "${DIM}Key values never displayed.${NC}"
	return 0
}

show_help() {
	echo "List Keys - Show all API keys available in session"
	echo ""
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  --help, -h    Show this help message"
	echo "  --json        Output in JSON format (for programmatic use)"
	echo ""
	echo "Sources checked:"
	echo "  1. ~/.config/aidevops/credentials.sh  (primary credential store)"
	echo "  2. ~/.zshrc, ~/.bashrc, etc.      (shell config exports)"
	echo "  3. Environment variables          (session-only, pattern match)"
	echo "  4. ~/.config/coderabbit/api_key   (CodeRabbit CLI)"
	echo "  5. ./configs/*-config.json        (repo-specific configs)"
	echo ""
	echo "Patterns matched: *_KEY, *_TOKEN, *_SECRET, *_PASSWORD, *_API_*, *_AUTH_*"
	echo ""
	echo "Security: This script NEVER displays actual key values."
	return 0
}

# Build JSON source block for credentials.sh keys.
# Outputs a JSON source object to stdout. Returns 0 if emitted, 1 if skipped.
_output_json_credentials() {
	local mcp_keys="$1"
	if [[ ! -f "$CREDENTIALS_FILE" ]]; then
		return 1
	fi

	local keys_json=""
	local first_key=1
	while IFS= read -r line; do
		if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)= ]]; then
			local key_name="${BASH_REMATCH[1]}"
			local status
			status=$(check_key_loaded "$key_name")
			[[ $first_key -eq 0 ]] && keys_json+=","
			first_key=0
			keys_json+=$'\n'"        {\"name\": \"$key_name\", \"status\": \"$status\"}"
		fi
	done <"$CREDENTIALS_FILE"

	printf '    {\n      "path": "%s",\n      "keys": [%s\n      ]\n    }' \
		"$CREDENTIALS_FILE" "$keys_json"
	return 0
}

# Build JSON source block for shell config keys (not already in credentials.sh).
# Outputs a JSON source object to stdout. Returns 0 if emitted, 1 if skipped.
_output_json_shell_configs() {
	local mcp_keys="$1"
	local shell_configs=("$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.zprofile")
	local shell_keys_json=""
	local found_shell=0

	for config_file in "${shell_configs[@]}"; do
		if [[ ! -f "$config_file" ]]; then
			continue
		fi
		local shell_keys
		shell_keys=$(grep -E '^[[:space:]]*export[[:space:]]+[A-Z_][A-Z0-9_]*=' "$config_file" 2>/dev/null |
			grep -E '(_KEY|_TOKEN|_SECRET|_PASSWORD|_CREDENTIAL|_API_|_AUTH_)' |
			sed 's/.*export[[:space:]]*//' | cut -d= -f1 | sort -u || true)

		for key_name in $shell_keys; do
			if ! echo "$mcp_keys" | grep -q "^${key_name}$"; then
				local status
				status=$(check_key_loaded "$key_name")
				[[ $found_shell -eq 1 ]] && shell_keys_json+=","
				found_shell=1
				shell_keys_json+=$'\n'"        {\"name\": \"$key_name\", \"status\": \"$status\"}"
			fi
		done
	done

	if [[ $found_shell -eq 0 ]]; then
		return 1
	fi

	printf '    {\n      "path": "~/.zshrc, ~/.bashrc, etc.",\n      "keys": [%s\n      ]\n    }' \
		"$shell_keys_json"
	return 0
}

# Build JSON source block for environment-only keys (not in credentials.sh).
# Outputs a JSON source object to stdout. Returns 0 if emitted, 1 if skipped.
_output_json_env_keys() {
	local mcp_keys="$1"
	local env_keys
	env_keys=$(env | grep -E '^[A-Z_][A-Z0-9_]*=.' | cut -d= -f1 |
		grep -E '(_KEY|_TOKEN|_SECRET|_PASSWORD|_CREDENTIAL|_API_|_AUTH_|_ACCESS_)' | sort || true)
	local env_keys_json=""
	local found_env=0

	for key_name in $env_keys; do
		if echo "$mcp_keys" | grep -q "^${key_name}$"; then
			continue
		fi
		case "$key_name" in
		SSH_AUTH_SOCK | GPG_AGENT_* | DBUS_* | XDG_* | GNOME_* | KDE_*)
			continue
			;;
		*)
			# Process this key
			;;
		esac

		local status
		status=$(check_key_loaded "$key_name")
		[[ $found_env -eq 1 ]] && env_keys_json+=","
		found_env=1
		env_keys_json+=$'\n'"        {\"name\": \"$key_name\", \"status\": \"$status\"}"
	done

	if [[ $found_env -eq 0 ]]; then
		return 1
	fi

	printf '    {\n      "path": "Environment (session)",\n      "keys": [%s\n      ]\n    }' \
		"$env_keys_json"
	return 0
}

# Build JSON source block for the CodeRabbit API key file.
# Outputs a JSON source object to stdout. Returns 0 if emitted, 1 if skipped.
_output_json_coderabbit() {
	if [[ ! -f "$CODERABBIT_KEY_FILE" ]]; then
		return 1
	fi

	printf '    {\n      "path": "%s",\n      "keys": [\n        {"name": "CODERABBIT_API_KEY", "status": "loaded"}\n      ]\n    }' \
		"$CODERABBIT_KEY_FILE"
	return 0
}

output_json() {
	local mcp_keys=""

	# Get list of keys from credentials.sh for comparison
	if [[ -f "$CREDENTIALS_FILE" ]]; then
		mcp_keys=$(grep -oE '^export[[:space:]]+[A-Z_][A-Z0-9_]*' "$CREDENTIALS_FILE" 2>/dev/null | sed 's/export[[:space:]]*//' || true)
	fi

	# Collect each source block; join with ",\n" between non-empty blocks.
	# Each helper returns 0 if it emitted a block, 1 if it had nothing to emit.
	# Use `|| rc=$?` pattern to capture non-zero exit under set -e.
	local sources_json=""
	local block
	local rc

	rc=0
	block=$(_output_json_credentials "$mcp_keys") || rc=$?
	if [[ $rc -eq 0 ]]; then
		[[ -n "$sources_json" ]] && sources_json+=","$'\n'
		sources_json+="$block"
	fi

	rc=0
	block=$(_output_json_shell_configs "$mcp_keys") || rc=$?
	if [[ $rc -eq 0 ]]; then
		[[ -n "$sources_json" ]] && sources_json+=","$'\n'
		sources_json+="$block"
	fi

	rc=0
	block=$(_output_json_env_keys "$mcp_keys") || rc=$?
	if [[ $rc -eq 0 ]]; then
		[[ -n "$sources_json" ]] && sources_json+=","$'\n'
		sources_json+="$block"
	fi

	rc=0
	block=$(_output_json_coderabbit "$mcp_keys") || rc=$?
	if [[ $rc -eq 0 ]]; then
		[[ -n "$sources_json" ]] && sources_json+=","$'\n'
		sources_json+="$block"
	fi

	printf '{\n  "sources": [\n%s\n  ]\n}\n' "$sources_json"
	return 0
}

main() {
	case "${1:-}" in
	--help | -h)
		show_help
		return 0
		;;
	--json)
		output_json
		return 0
		;;
	*)
		# Default: run normal output
		;;
	esac

	print_header
	list_mcp_env_keys
	list_shell_config_keys
	list_env_only_keys
	list_coderabbit_key
	list_repo_config_keys
	print_summary

	return 0
}

main "$@"
