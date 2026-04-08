#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
set -euo pipefail

# Thunderbird Integration Helper
# Auto-generate IMAP account configs, deploy Sieve rules, OpenPGP key import guidance.
#
# Usage:
#   thunderbird-helper.sh gen-config --provider <name> --email <addr> [--output <file>]
#   thunderbird-helper.sh gen-config --imap-host <host> --imap-port <port> --smtp-host <host> --smtp-port <port> --email <addr> [--output <file>]
#   thunderbird-helper.sh deploy-sieve --server <host> --user <user> --script <file> [--port <port>]
#   thunderbird-helper.sh list-sieve --server <host> --user <user> [--port <port>]
#   thunderbird-helper.sh openpgp-guide --email <addr> [--key-file <file>]
#   thunderbird-helper.sh status
#   thunderbird-helper.sh help
#
# Requires: jq, python3 (for XML generation), sieve-connect (optional, for Sieve deployment)
# Config: configs/email-providers.json (from email-providers.json.txt template)
# Credentials: IMAP/SMTP passwords via env vars, never as arguments
#
# Part of aidevops email system (t1518)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# ============================================================================
# Constants
# ============================================================================

readonly CONFIG_DIR="${SCRIPT_DIR}/../configs"
readonly PROVIDERS_CONFIG="${CONFIG_DIR}/email-providers.json"
readonly WORKSPACE_DIR="${THUNDERBIRD_WORKSPACE:-${HOME}/.aidevops/.agent-workspace/thunderbird}"
readonly AUTOCONFIG_SCHEMA_VERSION="1.1"

# ============================================================================
# Dependency checks
# ============================================================================

check_deps() {
	local missing=0
	local dep=""
	for dep in jq python3; do
		if ! command -v "$dep" >/dev/null 2>&1; then
			printf 'ERROR: required command not found: %s\n' "$dep" >&2
			missing=1
		fi
	done
	if [[ "$missing" -eq 1 ]]; then
		return 1
	fi
	return 0
}

check_sieve_connect() {
	if ! command -v sieve-connect >/dev/null 2>&1; then
		printf 'WARNING: sieve-connect not found. Install with: brew install sieve-connect\n' >&2
		printf 'Sieve deployment requires sieve-connect or equivalent ManageSieve client.\n' >&2
		return 1
	fi
	return 0
}

# ============================================================================
# Provider config lookup
# ============================================================================

# Load provider settings from email-providers.json
# Args: $1 = provider name (case-insensitive)
# Outputs: sets IMAP_HOST, IMAP_PORT, SMTP_HOST, SMTP_PORT, AUTH_METHOD, DISPLAY_NAME
load_provider_config() {
	local provider_name="$1"
	local provider_key
	provider_key=$(printf '%s' "$provider_name" | tr '[:upper:]' '[:lower:]')

	if [[ ! -f "$PROVIDERS_CONFIG" ]]; then
		printf 'ERROR: providers config not found: %s\n' "$PROVIDERS_CONFIG" >&2
		printf 'Copy template: cp configs/email-providers.json.txt configs/email-providers.json\n' >&2
		return 1
	fi

	# Extract provider block — providers are keyed by lowercase name
	local provider_json
	provider_json=$(jq -r --arg key "$provider_key" '.[$key] // empty' "$PROVIDERS_CONFIG" 2>/dev/null)

	if [[ -z "$provider_json" ]]; then
		printf 'ERROR: provider not found in config: %s\n' "$provider_name" >&2
		printf 'Available providers:\n' >&2
		jq -r 'keys[]' "$PROVIDERS_CONFIG" >&2
		return 1
	fi

	IMAP_HOST=$(printf '%s' "$provider_json" | jq -r '.imap.host // empty')
	IMAP_PORT=$(printf '%s' "$provider_json" | jq -r '.imap.port // "993"')
	IMAP_SSL=$(printf '%s' "$provider_json" | jq -r '.imap.ssl // "SSL/TLS"')
	SMTP_HOST=$(printf '%s' "$provider_json" | jq -r '.smtp.host // empty')
	SMTP_PORT=$(printf '%s' "$provider_json" | jq -r '.smtp.port // "465"')
	SMTP_SSL=$(printf '%s' "$provider_json" | jq -r '.smtp.ssl // "SSL/TLS"')
	AUTH_METHOD=$(printf '%s' "$provider_json" | jq -r '.auth_method // "password-cleartext"')
	DISPLAY_NAME=$(printf '%s' "$provider_json" | jq -r '.display_name // empty')

	if [[ -z "$IMAP_HOST" || -z "$SMTP_HOST" ]]; then
		printf 'ERROR: incomplete provider config for: %s (missing imap.host or smtp.host)\n' "$provider_name" >&2
		return 1
	fi

	return 0
}

# Map provider auth method to Thunderbird autoconfig auth type
# Args: $1 = auth_method string from providers.json
map_auth_type() {
	local auth_method="$1"
	case "$auth_method" in
	oauth2)
		printf 'OAuth2'
		;;
	app-password | app_password)
		printf 'password-cleartext'
		;;
	password | password-cleartext)
		printf 'password-cleartext'
		;;
	bridge | bridge-password)
		printf 'password-cleartext'
		;;
	*)
		printf 'password-cleartext'
		;;
	esac
	return 0
}

# Map SSL type to Thunderbird socketType
# Args: $1 = ssl string
map_socket_type() {
	local ssl="$1"
	case "$ssl" in
	SSL/TLS | ssl | tls)
		printf 'SSL'
		;;
	STARTTLS | starttls)
		printf 'STARTTLS'
		;;
	none | plain)
		printf 'plain'
		;;
	*)
		printf 'SSL'
		;;
	esac
	return 0
}

# ============================================================================
# Autoconfig XML generation
# ============================================================================

# Generate Thunderbird autoconfig XML (Mozilla ISPDB format)
# Args: $1 = email address, $2 = display name, $3 = imap_host, $4 = imap_port,
#       $5 = imap_ssl, $6 = smtp_host, $7 = smtp_port, $8 = smtp_ssl,
#       $9 = auth_method, $10 = output file (or "-" for stdout)
generate_autoconfig_xml() {
	local email="$1"
	local display_name="$2"
	local imap_host="$3"
	local imap_port="$4"
	local imap_ssl="$5"
	local smtp_host="$6"
	local smtp_port="$7"
	local smtp_ssl="$8"
	local auth_method="$9"
	local output_file="${10}"

	local domain
	domain=$(printf '%s' "$email" | cut -d@ -f2)

	local imap_socket smtp_socket imap_auth smtp_auth
	imap_socket=$(map_socket_type "$imap_ssl")
	smtp_socket=$(map_socket_type "$smtp_ssl")
	imap_auth=$(map_auth_type "$auth_method")
	smtp_auth=$(map_auth_type "$auth_method")

	# Use python3 for XML generation to avoid bash escape complexity
	python3 - <<PYEOF
import sys

email = "${email}"
domain = "${domain}"
display_name = "${display_name}"
imap_host = "${imap_host}"
imap_port = "${imap_port}"
imap_socket = "${imap_socket}"
smtp_host = "${smtp_host}"
smtp_port = "${smtp_port}"
smtp_socket = "${smtp_socket}"
imap_auth = "${imap_auth}"
smtp_auth = "${smtp_auth}"
schema_version = "${AUTOCONFIG_SCHEMA_VERSION}"

xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!-- Thunderbird autoconfig (Mozilla ISPDB format v{schema_version}) -->
<!-- Generated by aidevops thunderbird-helper.sh (t1518) -->
<!-- https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat -->
<clientConfig version="{schema_version}">
  <emailProvider id="{domain}">
    <domain>{domain}</domain>
    <displayName>{display_name or domain}</displayName>
    <displayShortName>{domain.split('.')[0].capitalize()}</displayShortName>

    <!-- IMAP incoming mail server -->
    <incomingServer type="imap">
      <hostname>{imap_host}</hostname>
      <port>{imap_port}</port>
      <socketType>{imap_socket}</socketType>
      <authentication>{imap_auth}</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>

    <!-- SMTP outgoing mail server -->
    <outgoingServer type="smtp">
      <hostname>{smtp_host}</hostname>
      <port>{smtp_port}</port>
      <socketType>{smtp_socket}</socketType>
      <authentication>{smtp_auth}</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>
  </emailProvider>
</clientConfig>
"""
print(xml.strip())
PYEOF

	return 0
}

# ============================================================================
# Commands
# ============================================================================

cmd_gen_config() {
	local provider="" email="" output="-"
	local imap_host="" imap_port="" imap_ssl="SSL/TLS"
	local smtp_host="" smtp_port="" smtp_ssl="SSL/TLS"
	local auth_method="password-cleartext"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--provider)
			provider="$2"
			shift 2
			;;
		--email)
			email="$2"
			shift 2
			;;
		--imap-host)
			imap_host="$2"
			shift 2
			;;
		--imap-port)
			imap_port="$2"
			shift 2
			;;
		--smtp-host)
			smtp_host="$2"
			shift 2
			;;
		--smtp-port)
			smtp_port="$2"
			shift 2
			;;
		--auth)
			auth_method="$2"
			shift 2
			;;
		--output)
			output="$2"
			shift 2
			;;
		*)
			printf 'ERROR: unknown option: %s\n' "$1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$email" ]]; then
		printf 'ERROR: --email is required\n' >&2
		return 1
	fi

	# Load from provider template if specified
	if [[ -n "$provider" ]]; then
		if ! load_provider_config "$provider"; then
			return 1
		fi
		# Allow CLI overrides of provider defaults
		[[ -n "$imap_host" ]] || imap_host="$IMAP_HOST"
		[[ -n "$imap_port" ]] || imap_port="$IMAP_PORT"
		[[ -n "$imap_ssl" ]] || imap_ssl="$IMAP_SSL"
		[[ -n "$smtp_host" ]] || smtp_host="$SMTP_HOST"
		[[ -n "$smtp_port" ]] || smtp_port="$SMTP_PORT"
		[[ -n "$smtp_ssl" ]] || smtp_ssl="$SMTP_SSL"
		[[ "$auth_method" != "password-cleartext" ]] || auth_method="$AUTH_METHOD"
		local display_name="$DISPLAY_NAME"
	else
		local display_name=""
		if [[ -z "$imap_host" || -z "$smtp_host" ]]; then
			printf 'ERROR: either --provider or both --imap-host and --smtp-host are required\n' >&2
			return 1
		fi
		[[ -n "$imap_port" ]] || imap_port="993"
		[[ -n "$smtp_port" ]] || smtp_port="465"
	fi

	local xml_content
	xml_content=$(generate_autoconfig_xml \
		"$email" "$display_name" \
		"$imap_host" "$imap_port" "$imap_ssl" \
		"$smtp_host" "$smtp_port" "$smtp_ssl" \
		"$auth_method" "-")

	if [[ "$output" == "-" ]]; then
		printf '%s\n' "$xml_content"
	else
		mkdir -p "$(dirname "$output")"
		printf '%s\n' "$xml_content" >"$output"
		printf 'Autoconfig written to: %s\n' "$output"
		printf '\nTo use in Thunderbird:\n'
		printf '  1. Open Thunderbird > Account Settings > Account Actions > Add Mail Account\n'
		printf '  2. Enter email address and password\n'
		printf '  3. Click "Configure manually" if auto-detection fails\n'
		printf '  4. Or host the XML at: https://autoconfig.%s/mail/config-v1.1.xml\n' "$(printf '%s' "$email" | cut -d@ -f2)"
		printf '     Thunderbird checks this URL automatically during account setup\n'
	fi

	return 0
}

cmd_deploy_sieve() {
	local server="" user="" script_file="" port="4190"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--server)
			server="$2"
			shift 2
			;;
		--user)
			user="$2"
			shift 2
			;;
		--script)
			script_file="$2"
			shift 2
			;;
		--port)
			port="$2"
			shift 2
			;;
		*)
			printf 'ERROR: unknown option: %s\n' "$1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$server" || -z "$user" || -z "$script_file" ]]; then
		printf 'ERROR: --server, --user, and --script are required\n' >&2
		return 1
	fi

	if [[ ! -f "$script_file" ]]; then
		printf 'ERROR: script file not found: %s\n' "$script_file" >&2
		return 1
	fi

	local script_name
	script_name=$(basename "$script_file" .sieve)

	if ! check_sieve_connect; then
		printf '\nManual deployment instructions:\n'
		printf '  Fastmail:    Settings > Filters > Edit custom Sieve\n'
		printf '  Proton Mail: Settings > Filters > Add Sieve filter\n'
		printf '  Dovecot:     Place script at ~/.dovecot.sieve\n'
		printf '  Cloudron:    Manage via Cloudron admin panel > Mail > Sieve\n'
		printf '\nScript content to paste:\n'
		printf '---\n'
		cat "$script_file"
		printf '---\n'
		return 0
	fi

	printf 'Deploying Sieve script "%s" to %s@%s:%s...\n' "$script_name" "$user" "$server" "$port"

	# sieve-connect requires password via stdin or IMAP_PASSWORD env var
	# Never pass password as argument (security rule 8.2)
	if [[ -z "${IMAP_PASSWORD:-}" ]]; then
		printf 'ERROR: set IMAP_PASSWORD env var before running deploy-sieve\n' >&2
		# shellcheck disable=SC2016
		printf 'Example: IMAP_PASSWORD=$(gopass show -o mail/%s) thunderbird-helper.sh deploy-sieve ...\n' "$user" >&2
		return 1
	fi

	# Upload and activate the script
	IMAP_PASSWORD="$IMAP_PASSWORD" sieve-connect \
		--server "$server" \
		--port "$port" \
		--user "$user" \
		--upload "$script_file" \
		--name "$script_name" \
		--activate "$script_name" 2>&1

	printf 'Sieve script "%s" deployed and activated.\n' "$script_name"
	return 0
}

cmd_list_sieve() {
	local server="" user="" port="4190"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--server)
			server="$2"
			shift 2
			;;
		--user)
			user="$2"
			shift 2
			;;
		--port)
			port="$2"
			shift 2
			;;
		*)
			printf 'ERROR: unknown option: %s\n' "$1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$server" || -z "$user" ]]; then
		printf 'ERROR: --server and --user are required\n' >&2
		return 1
	fi

	if ! check_sieve_connect; then
		return 1
	fi

	if [[ -z "${IMAP_PASSWORD:-}" ]]; then
		printf 'ERROR: set IMAP_PASSWORD env var before running list-sieve\n' >&2
		return 1
	fi

	IMAP_PASSWORD="$IMAP_PASSWORD" sieve-connect \
		--server "$server" \
		--port "$port" \
		--user "$user" \
		--list 2>&1

	return 0
}

cmd_openpgp_guide() {
	local email="" key_file=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--email)
			email="$2"
			shift 2
			;;
		--key-file)
			key_file="$2"
			shift 2
			;;
		*)
			printf 'ERROR: unknown option: %s\n' "$1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$email" ]]; then
		printf 'ERROR: --email is required\n' >&2
		return 1
	fi

	printf '=== OpenPGP Key Import Guide for Thunderbird ===\n\n'
	printf 'Account: %s\n\n' "$email"

	if [[ -n "$key_file" ]]; then
		if [[ ! -f "$key_file" ]]; then
			printf 'WARNING: key file not found: %s\n\n' "$key_file" >&2
		else
			# Show key fingerprint only — never the key material
			if command -v gpg >/dev/null 2>&1; then
				printf 'Key fingerprint:\n'
				gpg --with-fingerprint --import-options show-only --import "$key_file" 2>/dev/null |
					grep -E '(fingerprint|uid)' || printf '  (run: gpg --with-fingerprint --import-options show-only --import %s)\n' "$key_file"
				printf '\n'
			fi
		fi
	fi

	printf 'Step 1: Open Thunderbird Account Settings\n'
	printf '  Tools > Account Settings > End-To-End Encryption\n\n'

	printf 'Step 2: Import your key\n'
	printf '  Option A — Import from file:\n'
	printf '    Click "Add Key..." > "Import a Personal OpenPGP Key"\n'
	if [[ -n "$key_file" ]]; then
		printf '    Select: %s\n' "$key_file"
	else
		printf '    Select your .asc or .gpg key file\n'
	fi
	printf '\n'
	printf '  Option B — Import from GnuPG keyring (if gpg is installed):\n'
	printf '    Thunderbird 78+ can read keys directly from the system GnuPG keyring\n'
	printf '    Tools > Account Settings > End-To-End Encryption > "Add Key..."\n'
	printf '    Select "Use your external key through GnuPG"\n\n'

	printf 'Step 3: Set as default key\n'
	printf '  After import, select the key and click "Use this key by default"\n\n'

	printf 'Step 4: Configure encryption behaviour\n'
	printf '  Recommended settings:\n'
	printf '  - Require encryption: OFF (allow unencrypted for contacts without keys)\n'
	printf '  - Sign unencrypted messages: ON (proves authenticity)\n'
	printf '  - Encrypt drafts: ON (protects unsent messages)\n\n'

	printf 'Step 5: Publish your public key (optional)\n'
	printf '  Click "Publish" to upload to keys.openpgp.org\n'
	printf '  Or share your public key manually:\n'
	if command -v gpg >/dev/null 2>&1; then
		printf '    gpg --armor --export %s > %s-public.asc\n' "$email" "$(printf '%s' "$email" | cut -d@ -f1)"
	fi
	printf '\n'

	printf 'Step 6: Verify with a test message\n'
	printf '  Send a signed/encrypted test to yourself or a trusted contact\n'
	printf '  Confirm the lock/shield icon appears in the compose window\n\n'

	printf 'Troubleshooting:\n'
	printf '  Key not found for recipient: ask them to share their public key or\n'
	printf '    search keys.openpgp.org via Tools > OpenPGP Key Manager > Keyserver\n'
	printf '  Decryption fails: ensure the private key is imported (not just public)\n'
	printf '  Signature invalid: check system clock is accurate (NTP sync)\n'

	return 0
}

cmd_status() {
	printf '=== Thunderbird Helper Status ===\n\n'

	printf 'Dependencies:\n'
	for cmd in jq python3 sieve-connect gpg; do
		if command -v "$cmd" >/dev/null 2>&1; then
			printf '  %-20s OK (%s)\n' "$cmd" "$(command -v "$cmd")"
		else
			if [[ "$cmd" == "sieve-connect" || "$cmd" == "gpg" ]]; then
				printf '  %-20s not found (optional)\n' "$cmd"
			else
				printf '  %-20s MISSING (required)\n' "$cmd"
			fi
		fi
	done

	printf '\nConfig:\n'
	if [[ -f "$PROVIDERS_CONFIG" ]]; then
		local provider_count
		provider_count=$(jq 'keys | length' "$PROVIDERS_CONFIG" 2>/dev/null || printf '?')
		printf '  email-providers.json  OK (%s providers)\n' "$provider_count"
	else
		printf '  email-providers.json  not found\n'
		printf '  Run: cp configs/email-providers.json.txt configs/email-providers.json\n'
	fi

	printf '\nWorkspace: %s\n' "$WORKSPACE_DIR"

	return 0
}

cmd_help() {
	cat <<'EOF'
thunderbird-helper.sh — Thunderbird email client integration

COMMANDS

  gen-config    Generate Thunderbird autoconfig XML from provider template or manual settings
  deploy-sieve  Deploy a Sieve script to a ManageSieve-compatible server
  list-sieve    List Sieve scripts on a ManageSieve server
  openpgp-guide Step-by-step OpenPGP key import guidance for Thunderbird
  status        Check dependencies and config
  help          Show this help

USAGE

  # Generate config from provider template (uses email-providers.json)
  thunderbird-helper.sh gen-config --provider cloudron --email user@example.com

  # Generate config with manual server settings
  thunderbird-helper.sh gen-config \
    --imap-host mail.example.com --imap-port 993 \
    --smtp-host mail.example.com --smtp-port 465 \
    --email user@example.com --output ~/thunderbird-config.xml

  # Deploy Sieve rules (requires IMAP_PASSWORD env var)
  IMAP_PASSWORD="$(gopass show -o mail/user)" \
    thunderbird-helper.sh deploy-sieve \
      --server mail.example.com --user user@example.com \
      --script ~/.aidevops/sieve/sort-rules.sieve

  # List active Sieve scripts
  IMAP_PASSWORD="$(gopass show -o mail/user)" \
    thunderbird-helper.sh list-sieve \
      --server mail.example.com --user user@example.com

  # OpenPGP import guide
  thunderbird-helper.sh openpgp-guide --email user@example.com --key-file ~/keys/user.asc

AUTOCONFIG XML HOSTING

  Thunderbird auto-discovers config by fetching (in order):
    1. https://autoconfig.<domain>/mail/config-v1.1.xml
    2. https://<domain>/.well-known/autoconfig/mail/config-v1.1.xml
    3. https://autoconfig.thunderbird.net/v1.1/<domain>

  Host the generated XML at one of these URLs to enable zero-config account setup.

SIEVE DEPLOYMENT

  Requires sieve-connect: brew install sieve-connect
  Password must be in IMAP_PASSWORD env var (never as CLI argument).
  Supported servers: Dovecot, Cyrus, Fastmail, Cloudron, mailbox.org.
  Proton Mail and Tuta do not support ManageSieve.

OPENPGP

  Thunderbird 78+ has built-in OpenPGP support (no Enigmail needed).
  Keys are stored in Thunderbird's own keyring, separate from system GnuPG.
  Use "openpgp-guide" to get step-by-step import instructions.

PROVIDERS

  Run: thunderbird-helper.sh status
  To see available providers from email-providers.json.

EOF
	return 0
}

# ============================================================================
# Main
# ============================================================================

main() {
	local cmd="${1:-help}"
	shift || true

	check_deps || exit 1

	case "$cmd" in
	gen-config)
		cmd_gen_config "$@"
		;;
	deploy-sieve)
		cmd_deploy_sieve "$@"
		;;
	list-sieve)
		cmd_list_sieve "$@"
		;;
	openpgp-guide)
		cmd_openpgp_guide "$@"
		;;
	status)
		cmd_status
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		printf 'ERROR: unknown command: %s\n' "$cmd" >&2
		printf 'Run: thunderbird-helper.sh help\n' >&2
		exit 1
		;;
	esac

	return 0
}

main "$@"
