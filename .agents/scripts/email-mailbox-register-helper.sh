#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC1091
set -euo pipefail

# email-mailbox-register-helper.sh
# Interactive helper for adding and removing IMAP mailboxes to/from mailboxes.json.
#
# Usage:
#   email-mailbox-register-helper.sh add             Interactive guided add
#   email-mailbox-register-helper.sh remove <id>     Remove a mailbox by ID
#   email-mailbox-register-helper.sh help            Show this help
#
# Config target (first-found, same search order as email-poll-helper.sh):
#   _config/mailboxes.json                 Per-repo
#   ~/.config/aidevops/mailboxes.json      Global
#
# Part of aidevops email system (t2855).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly PROVIDERS_TEMPLATE="${SCRIPT_DIR}/../configs/email-providers.json.txt"
readonly MAILBOXES_TEMPLATE="${SCRIPT_DIR}/../templates/mailboxes-config.json"

_REPO_CONFIG="_config/mailboxes.json"
_GLOBAL_CONFIG="${HOME}/.config/aidevops/mailboxes.json"

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

_find_or_create_config() {
	# If we're inside a git repo with a _config/ dir, prefer repo-level config
	if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
		local repo_root
		repo_root=$(git rev-parse --show-toplevel)
		local config_dir="${repo_root}/_config"
		if [[ -d "$config_dir" || ! -f "$_GLOBAL_CONFIG" ]]; then
			mkdir -p "$config_dir"
			echo "${repo_root}/_config/mailboxes.json"
			return 0
		fi
	fi
	mkdir -p "$(dirname "$_GLOBAL_CONFIG")"
	echo "$_GLOBAL_CONFIG"
	return 0
}

_load_or_init_config() {
	local config_path="$1"
	if [[ ! -f "$config_path" ]]; then
		if [[ -f "$MAILBOXES_TEMPLATE" ]]; then
			cp "$MAILBOXES_TEMPLATE" "$config_path"
			# Remove example entries from the template copy
			# Use env var to avoid shell-interpolation injection from the config path.
			AIDEVOPS_CONFIG_PATH="$config_path" python3 -c "
import json, os
config_path = os.environ['AIDEVOPS_CONFIG_PATH']
with open(config_path) as f:
    d = json.load(f)
# Strip entries with _comment fields (they are examples)
d['mailboxes'] = [m for m in d.get('mailboxes', []) if '_comment' not in m]
with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
"
		else
			echo '{"mailboxes":[]}' > "$config_path"
		fi
		log_info "Created config at $config_path"
	fi
	return 0
}

_provider_defaults() {
	local provider="$1"
	if [[ ! -f "$PROVIDERS_TEMPLATE" ]]; then
		echo "imap.${provider}.com 993"
		return 0
	fi
	python3 -c "
import json, sys
with open('$PROVIDERS_TEMPLATE') as f:
    data = json.load(f)
providers = data.get('providers', {})
p = providers.get('$provider', {})
imap = p.get('imap', {})
host = imap.get('host', 'imap.${provider}.com')
port = imap.get('port', 993)
print(host, port)
" 2>/dev/null || echo "imap.${provider}.com 993"
	return 0
}

_list_known_providers() {
	if [[ ! -f "$PROVIDERS_TEMPLATE" ]]; then
		echo "gmail icloud fastmail cloudron"
		return 0
	fi
	python3 -c "
import json
with open('$PROVIDERS_TEMPLATE') as f:
    data = json.load(f)
providers = list(data.get('providers', {}).keys())
print(' '.join(providers))
" 2>/dev/null || echo "gmail icloud fastmail cloudron"
	return 0
}

# ---------------------------------------------------------------------------
# add command
# ---------------------------------------------------------------------------

cmd_add() {
	local config_path
	config_path=$(_find_or_create_config)
	_load_or_init_config "$config_path"

	print_info "Add IMAP Mailbox"
	echo ""

	# List known providers
	local known_providers
	known_providers=$(_list_known_providers)
	echo "Known providers: $known_providers"
	echo ""

	# Prompt for all fields
	read -r -p "Mailbox ID (e.g. personal-icloud): " mb_id
	if [[ -z "$mb_id" ]]; then
		print_error "Mailbox ID is required"
		return 1
	fi

	read -r -p "Provider (e.g. icloud, gmail, fastmail): " provider
	provider="${provider:-custom}"

	# Auto-fill host/port from providers template
	local defaults host port
	defaults=$(_provider_defaults "$provider")
	host=$(echo "$defaults" | awk '{print $1}')
	port=$(echo "$defaults" | awk '{print $2}')

	read -r -p "IMAP host [$host]: " input_host
	host="${input_host:-$host}"

	read -r -p "IMAP port [$port]: " input_port
	port="${input_port:-$port}"

	read -r -p "Username / email address: " user
	if [[ -z "$user" ]]; then
		print_error "Username is required"
		return 1
	fi

	read -r -p "gopass path for password (e.g. aidevops/email/${mb_id}/password): " gopass_path
	if [[ -z "$gopass_path" ]]; then
		print_error "gopass path is required"
		return 1
	fi
	local password_ref="gopass:${gopass_path}"

	read -r -p "Folders to poll (comma-separated, default: INBOX): " folders_input
	folders_input="${folders_input:-INBOX}"

	read -r -p "Poll since date (YYYY-MM-DD, default: today): " since
	since="${since:-$(date +%Y-%m-%d)}"

	echo ""
	print_info "Summary:"
	echo "  ID:           $mb_id"
	echo "  Provider:     $provider"
	echo "  Host:         $host:$port"
	echo "  User:         $user"
	echo "  Password ref: $password_ref"
	echo "  Folders:      $folders_input"
	echo "  Since:        $since"
	echo ""
	read -r -p "Save and test connection? [Y/n]: " confirm
	confirm="${confirm:-y}"
	if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
		print_info "Cancelled"
		return 0
	fi

	# Build folders array
	# Use env var to avoid shell-interpolation injection (e.g. quotes in folder names).
	local folders_json
	folders_json=$(AIDEVOPS_FOLDERS_INPUT="$folders_input" python3 -c "
import json, os
folders = [f.strip() for f in os.environ['AIDEVOPS_FOLDERS_INPUT'].split(',') if f.strip()]
print(json.dumps(folders))
")

	# Add entry to config.
	# All user-controlled values are passed via env vars to avoid shell-interpolation
	# injection (e.g. quotes or backslashes in mailbox IDs, usernames, or paths).
	AIDEVOPS_CONFIG_PATH="$config_path" \
	AIDEVOPS_MB_ID="$mb_id" \
	AIDEVOPS_PROVIDER="$provider" \
	AIDEVOPS_HOST="$host" \
	AIDEVOPS_PORT="$port" \
	AIDEVOPS_USER="$user" \
	AIDEVOPS_PASSWORD_REF="$password_ref" \
	AIDEVOPS_FOLDERS_JSON="$folders_json" \
	AIDEVOPS_SINCE="$since" \
	python3 -c "
import json, os
config_path   = os.environ['AIDEVOPS_CONFIG_PATH']
mb_id         = os.environ['AIDEVOPS_MB_ID']
provider      = os.environ['AIDEVOPS_PROVIDER']
host          = os.environ['AIDEVOPS_HOST']
port          = int(os.environ['AIDEVOPS_PORT'])
user          = os.environ['AIDEVOPS_USER']
password_ref  = os.environ['AIDEVOPS_PASSWORD_REF']
folders       = json.loads(os.environ['AIDEVOPS_FOLDERS_JSON'])
since         = os.environ['AIDEVOPS_SINCE']
with open(config_path) as f:
    d = json.load(f)
entry = {
    'id': mb_id,
    'provider': provider,
    'host': host,
    'port': port,
    'user': user,
    'password_ref': password_ref,
    'folders': folders,
    'since': since,
}
# Remove existing entry with same id if present
d['mailboxes'] = [m for m in d.get('mailboxes', []) if m.get('id') != mb_id]
d['mailboxes'].append(entry)
with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print('Saved')
"
	print_success "Mailbox '$mb_id' registered in $config_path"

	# Test connection (dry-run)
	local poll_helper="${SCRIPT_DIR}/email-poll-helper.sh"
	if [[ -x "$poll_helper" ]]; then
		print_info "Testing connection..."
		if bash "$poll_helper" test "$mb_id" 2>&1; then
			print_success "Connection test passed"
		else
			print_warning "Connection test failed — check credentials and host settings"
		fi
	fi

	return 0
}

# ---------------------------------------------------------------------------
# remove command
# ---------------------------------------------------------------------------

cmd_remove() {
	local mailbox_id="${1:-}"
	if [[ -z "$mailbox_id" ]]; then
		print_error "Usage: email-mailbox-register-helper.sh remove <mailbox-id>"
		return 1
	fi

	# Find config
	local config_path=""
	if [[ -f "$_REPO_CONFIG" ]]; then
		config_path="$_REPO_CONFIG"
	elif [[ -f "$_GLOBAL_CONFIG" ]]; then
		config_path="$_GLOBAL_CONFIG"
	else
		print_error "No mailboxes.json config found"
		return 1
	fi

	# Use env vars to avoid shell-interpolation injection from mailbox_id or config_path.
	AIDEVOPS_CONFIG_PATH="$config_path" AIDEVOPS_MB_ID="$mailbox_id" python3 -c "
import json, sys, os
config_path = os.environ['AIDEVOPS_CONFIG_PATH']
mailbox_id  = os.environ['AIDEVOPS_MB_ID']
with open(config_path) as f:
    d = json.load(f)
before = len(d.get('mailboxes', []))
d['mailboxes'] = [m for m in d.get('mailboxes', []) if m.get('id') != mailbox_id]
after = len(d['mailboxes'])
if before == after:
    print('ERROR: mailbox not found', file=sys.stderr)
    sys.exit(1)
with open(config_path, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print('Removed')
" && print_success "Mailbox '$mailbox_id' removed from $config_path" || {
		print_error "Mailbox '$mailbox_id' not found in $config_path"
		return 1
	}
	return 0
}

cmd_help() {
	cat <<'EOF'
email-mailbox-register-helper.sh — IMAP mailbox registration (t2855)

Usage:
  email-mailbox-register-helper.sh add              Interactive guided mailbox setup
  email-mailbox-register-helper.sh remove <id>      Remove a mailbox from config
  email-mailbox-register-helper.sh help             Show this help

Invoked via: aidevops email mailbox add|remove
EOF
	return 0
}

main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	add)     cmd_add "$@" ;;
	remove)  cmd_remove "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
