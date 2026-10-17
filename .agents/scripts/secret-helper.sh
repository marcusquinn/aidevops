#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# Secret Helper - AI-native secret management with gopass backend
# Keeps secret values out of AI agent context windows via subprocess
# injection and output redaction.
#
# Usage:
#   secret-helper.sh set NAME              # Interactive hidden input -> gopass
#   secret-helper.sh get NAME              # Get secret value (for scripts/piping)
#   secret-helper.sh list                  # List secret names (never values)
#   secret-helper.sh inventory             # Deterministic names-only JSON inventory
#   secret-helper.sh describe [NAME]       # Non-secret registry: account, reach, owner, expiry
#   secret-helper.sh record|account|default|alias|resolve ...  # Registry maintenance (GH#34680)
#   secret-helper.sh run CMD [ARGS...]     # Inject all secrets, redact output
#   secret-helper.sh NAME [NAME...] -- CMD # Inject specific secrets, redact output
#   secret-helper.sh init                  # Initialize gopass store
#   secret-helper.sh import-credentials    # Migrate from credentials.sh to gopass
#   secret-helper.sh migrate-loader        # Move tenant-loader exports into the active tenant
#   secret-helper.sh status                # Show backend status
#   secret-helper.sh help                  # Show help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/portable-stat.sh"

set -euo pipefail

readonly DIM='\033[2m'

# Paths
readonly CONFIG_DIR="$HOME/.config/aidevops"
readonly CREDENTIALS_FILE="$CONFIG_DIR/credentials.sh"
readonly TENANTS_DIR="$CONFIG_DIR/tenants"
readonly GOPASS_PREFIX="aidevops"
readonly INVENTORY_MAX_NAMES=512
readonly INVENTORY_MAX_NAME_LENGTH=128
readonly REDACTION_INIT_ERROR="Unable to initialize secret output redaction"

# Check if gopass is available and initialized
has_gopass() {
	if ! command -v gopass &>/dev/null; then
		return 1
	fi
	# Check if gopass store is initialized
	if ! gopass ls &>/dev/null; then
		return 1
	fi
	return 0
}

# Check if credentials.sh is a multi-tenant loader (not direct credentials)
# When multi-tenant is active, credentials.sh contains a source command
# pointing to tenants/{tenant}/credentials.sh instead of export lines.
is_tenant_loader() {
	[[ -f "$CREDENTIALS_FILE" ]] && grep -q 'AIDEVOPS_ACTIVE_TENANT=' "$CREDENTIALS_FILE" 2>/dev/null
}

# Active tenant for plaintext custody (GH#34806): the tenant the loader sources
# (its AIDEVOPS_ACTIVE_TENANT marker), then the active-tenant file, then
# "default". Parsed as text only; the loader is never sourced.
active_tenant_name() {
	local tenant="" marker=""
	local marker_re='^(export[[:space:]]+)?AIDEVOPS_ACTIVE_TENANT="?([A-Za-z0-9][A-Za-z0-9_-]*)"?[[:space:]]*$'
	marker=$(grep -m 1 -E '^(export[[:space:]]+)?AIDEVOPS_ACTIVE_TENANT=' "$CREDENTIALS_FILE" 2>/dev/null) || marker=""
	if [[ "$marker" =~ $marker_re ]]; then
		tenant="${BASH_REMATCH[2]}"
	fi
	if [[ -z "$tenant" && -f "$CONFIG_DIR/active-tenant" ]]; then
		tenant=$(tr -d '[:space:]' <"$CONFIG_DIR/active-tenant" 2>/dev/null) || tenant=""
		[[ "$tenant" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || tenant=""
	fi
	printf '%s\n' "${tenant:-default}"
	return 0
}

# File that plaintext `secret set` writes: the active tenant's credentials in
# tenant-loader mode, otherwise the single credentials.sh.
credential_store_file() {
	if is_tenant_loader; then
		printf '%s/%s/credentials.sh\n' "$TENANTS_DIR" "$(active_tenant_name)"
	else
		printf '%s\n' "$CREDENTIALS_FILE"
	fi
	return 0
}

# Resolve actual credential files to process, in precedence order.
# Single mode: credentials.sh. Tenant-loader mode: the active tenant's file
# first, then the other tenant files in name order, so the active tenant wins
# for duplicate names. The loader itself is never a store (GH#34806).
# Output: one file path per line
resolve_credential_files() {
	if is_tenant_loader; then
		local active_file=""
		active_file=$(credential_store_file)
		[[ -f "$active_file" ]] && printf '%s\n' "$active_file"
		local tenant_dir
		for tenant_dir in "$TENANTS_DIR"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local cred_file="${tenant_dir%/}/credentials.sh"
			if [[ -f "$cred_file" && "$cred_file" != "$active_file" ]]; then
				printf '%s\n' "$cred_file"
			fi
		done
	elif [[ -f "$CREDENTIALS_FILE" ]]; then
		echo "$CREDENTIALS_FILE"
	fi
	return 0
}

# Names exported directly in a tenant loader (stranded by earlier writers).
# Names only; the loader marker is excluded.
stranded_loader_names() {
	is_tenant_loader || return 0
	sed -n -E 's/^export[[:space:]]+([A-Z_][A-Z0-9_]*)=.*/\1/p' "$CREDENTIALS_FILE" 2>/dev/null |
		grep -vx 'AIDEVOPS_ACTIVE_TENANT' || true
	return 0
}

# Whether gopass should own NAME. A listed entry stays gopass-only, so a locked
# store fails closed instead of reading a stale plaintext value. An unreadable
# listing also counts as owned, preserving the historical gopass-first result.
gopass_owns_secret() {
	local name="$1"
	local listing=""
	listing=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null) || return 0
	if printf '%s\n' "$listing" | grep -Fxq -- "${GOPASS_PREFIX}/${name}"; then
		return 0
	fi
	return 1
}

# Get the scalar value from gopass, or from credential files for names absent
# from gopass. Matches build_secret_env so `secret check` (the dispatch
# capability gate) agrees with runtime injection (GH#33608).
# Used only by cmd_get, which preserves the historical first-line contract.
get_secret_value() {
	local name="$1"
	if has_gopass && gopass_owns_secret "$name"; then
		gopass show -o "${GOPASS_PREFIX}/${name}" 2>/dev/null || true
		return 0
	fi
	# Fallback to credential files (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		local value
		# Strip 'export NAME=', strip surrounding double quotes, then unescape
		# \" -> " and \\ -> \ (order matters: unescape \" before \\)
		value=$(grep "^export ${name}=" "$cred_file" 2>/dev/null | head -1 | sed 's/^export [^=]*=//' | sed 's/^"//' | sed 's/"$//' | sed 's/\\"/"/g' | sed 's/\\\\/\\/g')
		if [[ -n "$value" ]]; then
			echo "$value"
			return 0
		fi
	done < <(resolve_credential_files)
	return 0
}

# Get the complete raw gopass entry for subprocess injection.
# Bash command substitution consistently removes trailing newlines; embedded
# newlines are preserved byte-for-byte and encoded safely by build_secret_env.
get_gopass_entry_value() {
	local secret_path="$1"
	gopass show -n "$secret_path" 2>/dev/null || true
	return 0
}

# A headless pinentry can wait forever for a passphrase. Bound each requested
# decrypt, including its GPG children, without putting the value in argv/logs.
get_injected_gopass_value() {
	local secret_path="$1"
	if [[ -t 0 && -t 2 ]]; then
		gopass show -n "$secret_path" 2>/dev/null || return 1
	else
		python3 -c '
import os, signal, subprocess, sys

process = subprocess.Popen(["gopass", "show", "-n", sys.argv[1]],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           start_new_session=True)
try:
    value, _ = process.communicate(timeout=4)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    sys.exit(1)
if process.returncode:
    sys.exit(1)
sys.stdout.buffer.write(value)
' "$secret_path" || return 1
	fi
	return 0
}

# Collect all secret values for redaction as NUL-delimited literal data.
redaction_value_usable() {
	local value="$1"
	[[ ${#value} -ge 8 ]] || return 1
	case "$value" in
	'***' | '[redacted]' | '[REDACTED]' | 'not set' | 'none' | 'null' | 'undefined' | 'changeme') return 1 ;;
	esac
	return 0
}

warn_short_redaction_value() {
	local name="$1"
	printf 'WARN: secret %s value too short to redact safely; not masked\n' "$name" >&2
	return 0
}

collect_secret_values() {
	local -a values=()
	local -a warned_names=()

	if has_gopass; then
		local secrets
		secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
		while IFS= read -r secret_path; do
			[[ -z "$secret_path" ]] && continue
			local scalar_val=""
			local entry_val=""
			scalar_val=$(gopass show -o "$secret_path" 2>/dev/null || true)
			entry_val=$(get_gopass_entry_value "$secret_path")
			local name="${secret_path#"${GOPASS_PREFIX}"/}"
			if redaction_value_usable "$scalar_val"; then
				values+=("$scalar_val")
			elif [[ -n "$scalar_val" && ${#scalar_val} -lt 8 ]] && ! secret_env_name_emitted "$name" "${warned_names[@]}"; then
				warn_short_redaction_value "$name"
				warned_names+=("$name")
			fi
			if [[ "$entry_val" != "$scalar_val" ]] && redaction_value_usable "$entry_val"; then
				values+=("$entry_val")
			elif [[ -n "$entry_val" && ${#entry_val} -lt 8 ]] && ! secret_env_name_emitted "$name" "${warned_names[@]}"; then
				warn_short_redaction_value "$name"
				warned_names+=("$name")
			fi
		done <<<"$secrets"
	fi

	# Also collect from credential files as fallback (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+[A-Z_][A-Z0-9_]*= ]]; then
				local val=""
				val=$(decode_credential_value "${line#*=}")
				val="${val#\'}"
				val="${val%\'}"
				local name="${line%%=*}"
				name="${name##* }"
				if redaction_value_usable "$val"; then
					values+=("$val")
				elif [[ -n "$val" && ${#val} -lt 8 ]] && ! secret_env_name_emitted "$name" "${warned_names[@]}"; then
					warn_short_redaction_value "$name"
					warned_names+=("$name")
				fi
			fi
		done <"$cred_file"
	done < <(resolve_credential_files)

	if [[ ${#values[@]} -gt 0 ]]; then
		printf '%s\0' "${values[@]}"
	fi
	return 0
}

# Redact secret values from a stream
# Reads stdin, replaces any secret value with [REDACTED]
redact_stream() {
	local env_file="${1:-}"
	local values_file
	local previous_umask
	previous_umask=$(umask)
	umask 077
	if ! values_file=$(mktemp); then
		umask "$previous_umask"
		print_error "$REDACTION_INIT_ERROR" >&2
		return 1
	fi
	umask "$previous_umask"
	trap 'rm -f "$values_file"' RETURN

	if [[ -n "$env_file" ]]; then
		local -a warned_names=()
		while IFS='=' read -r -d '' _key value; do
			if redaction_value_usable "$value"; then
				printf '%s\0' "$value"
			elif [[ -n "$value" && ${#value} -lt 8 ]] && ! secret_env_name_emitted "$_key" "${warned_names[@]}"; then
				warn_short_redaction_value "$_key"
				warned_names+=("$_key")
			fi
		done <"$env_file" >"$values_file"
	else
		if ! collect_secret_values >"$values_file"; then
			print_error "$REDACTION_INIT_ERROR" >&2
			return 1
		fi
	fi

	if [[ ! -s "$values_file" ]]; then
		# No secrets to redact, pass through
		cat
		return 0
	fi

	if ! command -v python3 >/dev/null 2>&1; then
		print_error "$REDACTION_INIT_ERROR" >&2
		return 1
	fi

	local exit_code=0
	python3 -c '
import sys

with open(sys.argv[1], "rb") as values_handle:
    secret_values = sorted(
        {value for value in values_handle.read().split(b"\0") if len(value) >= 4},
        key=len,
        reverse=True,
    )

if not secret_values:
    raise SystemExit("redaction values were empty")

marker = b"[REDACTED]"
output = sys.stdout.buffer
pending = b""

def redact_available(data, final=False):
    pieces = []
    while data:
        match = next((value for value in secret_values if data.startswith(value)), None)
        if match is not None:
            if not final and any(
                len(value) > len(match) and value.startswith(data)
                for value in secret_values
            ):
                break
            pieces.append(marker)
            data = data[len(match):]
        elif not final and any(value.startswith(data) for value in secret_values):
            break
        else:
            pieces.append(data[:1])
            data = data[1:]
        if len(pieces) >= 8192:
            output.write(b"".join(pieces))
            output.flush()
            pieces.clear()
    if pieces:
        output.write(b"".join(pieces))
        output.flush()
    return data

while True:
    chunk = sys.stdin.buffer.read1(65536)
    if not chunk:
        break
    pending = redact_available(pending + chunk)

redact_available(pending, final=True)
' "$values_file" || exit_code=$?

	return "$exit_code"
}

# Return success when a secret name was already emitted.
secret_env_name_emitted() {
	local expected_name="$1"
	shift
	local emitted_name=""
	for emitted_name in "$@"; do
		[[ "$emitted_name" == "$expected_name" ]] && return 0
	done
	return 1
}

# Emit one NUL-delimited environment record. Environment values cannot contain
# NUL bytes, making NUL a safe record delimiter while preserving newlines.
emit_secret_env_record() {
	local name="$1"
	local value="$2"
	printf '%s=%s\0' "$name" "$value"
	return 0
}

# Value of a fallback `export NAME=VALUE` right-hand side. Double-quoted values
# undo the writer's \\ and \" escaping in one left-to-right pass, so injection
# and redaction see the stored value, as `get` does (GH#34806).
decode_credential_value() {
	local raw="$1"
	if [[ "$raw" != \"*\" || ${#raw} -lt 2 ]]; then
		raw="${raw#\"}"
		printf '%s' "${raw%\"}"
		return 0
	fi
	raw="${raw:1:${#raw}-2}"
	if [[ "$raw" != *\\* ]]; then
		printf '%s' "$raw"
		return 0
	fi
	local out="" char="" next="" i=0
	while ((i < ${#raw})); do
		char="${raw:i:1}"
		next="${raw:i+1:1}"
		if [[ "$char" == "\\" && ("$next" == "\\" || "$next" == '"') ]]; then
			char="$next"
			i=$((i + 1))
		fi
		out+="$char"
		i=$((i + 1))
	done
	printf '%s' "$out"
	return 0
}

# Build a NUL-delimited environment from gopass secrets.
build_secret_env() {
	local -a specific_names=("$@")
	local -a emitted_names=()

	if has_gopass; then
		if [[ ${#specific_names[@]} -gt 0 ]]; then
			# Inject only specific secrets
			local available_secrets=""
			if ! available_secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null); then
				print_error "Unable to list gopass secrets for injection" >&2
				return 1
			fi
			for name in "${specific_names[@]}"; do
				local secret_path=""
				local found=false
				while IFS= read -r secret_path; do
					if [[ "$secret_path" == "${GOPASS_PREFIX}/${name}" ]]; then
						found=true
						break
					fi
				done <<<"$available_secrets"
				# Names absent from gopass may still be in credentials.sh.
				[[ "$found" == true ]] || continue
				local val=""
				if ! val=$(get_injected_gopass_value "${GOPASS_PREFIX}/${name}") || [[ -z "$val" ]]; then
					print_error "secret $name unavailable: gopass/GPG locked or entry missing; unlock GPG in a terminal and retry" >&2
					return 1
				fi
				emit_secret_env_record "$name" "$val"
				emitted_names+=("$name")
			done
		else
			# Inject all secrets
			local secrets
			secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				local name="${secret_path#"${GOPASS_PREFIX}"/}"
				# Other tools may store nested paths or non-environment names.
				[[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
				local val
				val=$(get_gopass_entry_value "$secret_path")
				if [[ -n "$val" ]]; then
					emit_secret_env_record "$name" "$val"
					emitted_names+=("$name")
				fi
			done <<<"$secrets"
		fi
	fi

	# Also load from credential files as fallback/supplement (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
				local name="${BASH_REMATCH[1]}"
				local val=""
				val=$(decode_credential_value "${BASH_REMATCH[2]}")
				# Only add if not already set by gopass
				if [[ -n "$val" ]] && ! secret_env_name_emitted "$name" "${emitted_names[@]}"; then
					emit_secret_env_record "$name" "$val"
					emitted_names+=("$name")
				fi
			fi
		done <"$cred_file"
	done < <(resolve_credential_files)
	for name in "${specific_names[@]}"; do
		if ! secret_env_name_emitted "$name" "${emitted_names[@]}"; then
			print_error "secret $name unavailable: gopass/GPG locked or entry missing; unlock GPG in a terminal and retry" >&2
			return 1
		fi
	done

	return 0
}

# Register keyed digests of injected values so the OpenCode plugin can redact
# them from tool output, such as provider argv in process listings (GH#32362).
# Stores no plaintext; a registry failure never blocks the command.
register_redaction_digests() {
	local env_file="$1"
	local registry_helper="${SCRIPT_DIR}/redaction-digest-registry.py"
	[[ -s "$env_file" && -f "$registry_helper" ]] || return 0
	command -v python3 >/dev/null 2>&1 || return 0
	if ! python3 "$registry_helper" register <"$env_file" >/dev/null 2>&1; then
		print_warning "Secret redaction registry update failed; exact-value tool-output redaction may be incomplete" >&2
	fi
	return 0
}

# --- Commands ---

# Read a private regular file through one descriptor, avoiding check/open races.
# Values cannot contain NUL bytes because they will be injected into environments.
read_secret_file() {
	local path="$1"
	python3 -c '
import os, stat, sys
try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        metadata = os.fstat(source.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise ValueError()
        value = source.read()
        if b"\0" in value:
            raise ValueError()
    sys.stdout.buffer.write(value)
except (OSError, ValueError):
    sys.stderr.write("Unable to read secret file: require a readable regular non-symlink file, chmod 600, without NUL bytes\n")
    sys.exit(1)
' "$path" || return 1
	return 0
}

# Read and validate a secret value from file/stdin/tty. The subshell confines
# terminal restoration traps; stdout is exclusively secret data.
read_secret_input() (
	local name="$1"
	local source_file="${2:-}"
	local value=""

	# CRITICAL: All user-facing messages MUST go to stderr (>&2), not stdout.
	# This function's stdout is captured by $() in cmd_set — any print_info
	# or echo to stdout gets stored as part of the secret value. This was the
	# root cause of GH#4939: prompt text was stored in gopass instead of the
	# actual secret.
	if [[ -n "$source_file" ]]; then
		value=$(read_secret_file "$source_file") || return 1
	elif [[ -t 0 ]]; then
		print_info "Enter secret value for $name (input hidden):" >&2
		print_info "Single line only; for PEM/JSON or multi-line values use --from-file PATH" >&2
		local tty_settings=""
		tty_settings=$(stty -g) || return 1
		trap 'stty "$tty_settings" 2>/dev/null || true' EXIT
		trap 'exit 129' HUP
		trap 'exit 130' INT
		trap 'exit 143' TERM
		# Keep echo disabled across both the first read and the entire drain.
		stty -echo || return 1
		IFS= read -r value || true
		local extra="" pasted=false
		# Bash 3.2 (macOS system shell) accepts only integer read timeouts.
		local drain_timeout=1
		if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then drain_timeout=0.2; fi
		while IFS= read -r -n 1 -t "$drain_timeout" extra; do
			pasted=true
		done
		printf '\n' >&2
		if [[ "$pasted" == true ]]; then
			print_error "Multi-line paste discarded; nothing stored. Use --from-file PATH" >&2
			return 1
		fi
	else
		# An empty delimiter reads until EOF, retaining embedded newlines. A
		# successful read instead means a NUL was encountered: fail closed.
		if IFS= read -r -d '' value; then
			print_error "Secret input must not contain NUL bytes" >&2
			return 1
		fi
		# Match command substitution in file input and injection: trim trailing
		# newlines, not internal newlines (PEM remains valid without its final LF).
		while [[ "$value" == *$'\n' ]]; do value="${value%$'\n'}"; done
	fi

	[[ "$value" != *$'\n'* ]] && value="${value%$'\r'}"

	if [[ -z "$value" ]]; then
		print_error "No secret value received for $name" >&2
		print_info "Run again and paste only the secret value" >&2
		return 1
	fi

	if [[ "$value" =~ ^[[:space:]]*aidevops[[:space:]]+secret[[:space:]]+set([[:space:]]|$) ]]; then
		print_error "Input for $name looks like a command, not a secret value" >&2
		print_info "Paste the secret value itself, not 'aidevops secret set ...'" >&2
		return 1
	fi

	printf '%s' "$value"
	return 0
)

# Acquire an exclusive directory lock for fallback credential mutations.
# mkdir is atomic on local filesystems and portable across the supported shells.
acquire_credentials_lock() {
	local lock_dir="${CREDENTIALS_FILE}.lock"
	local attempts=0

	while ! mkdir "$lock_dir" 2>/dev/null; do
		((++attempts))
		if [[ "$attempts" -ge 300 ]]; then
			print_error "Timed out waiting to update credentials.sh"
			return 1
		fi
		sleep 0.1
	done

	printf '%s' "$lock_dir"
	return 0
}

# Release a lock acquired by acquire_credentials_lock.
release_credentials_lock() {
	local lock_dir="$1"
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

# Print NAME's first `export NAME=` line in FILE; exit 1 when absent.
credential_assignment() {
	local file="$1"
	local name="$2"
	grep -m 1 -- "$(printf '^export %s=' "$name")" "$file" 2>/dev/null
	return $?
}

# Atomically rewrite FILE without NAME's assignment, appending LINE when given.
# The caller holds the credentials lock. The result is mode 600.
rewrite_credential_file() {
	local file="$1"
	local name="$2"
	local line="${3:-}"
	local filter_status=0
	local tmp_file=""
	local previous_umask=""

	previous_umask=$(umask)
	umask 077
	if ! tmp_file=$(mktemp "${file}.tmp.XXXXXX"); then
		umask "$previous_umask"
		return 1
	fi
	umask "$previous_umask"

	grep -v -- "$(printf '^export %s=' "$name")" "$file" >"$tmp_file" || filter_status=$?
	if [[ "$filter_status" -gt 1 ]] ||
		{ [[ -n "$line" ]] && ! printf '%s\n' "$line" >>"$tmp_file"; } ||
		! chmod 600 "$tmp_file" ||
		! mv -f "$tmp_file" "$file"; then
		rm -f "$tmp_file" || true
		return 1
	fi
	return 0
}

# Create the active tenant's credentials file (dir 700, file 600). A symlinked
# target is refused rather than replaced, preserving explicit custody.
prepare_tenant_store() {
	local store_file="$1"
	local store_dir="${store_file%/*}"
	local previous_umask=""
	if [[ -L "$store_file" || -L "$store_dir" ]]; then
		return 1
	fi
	previous_umask=$(umask)
	umask 077
	if ! mkdir -p "$store_dir"; then
		umask "$previous_umask"
		return 1
	fi
	umask "$previous_umask"
	chmod 700 "$store_dir" || return 1
	return 0
}

# Atomically replace one fallback credential while preserving every other entry.
# Tenant-loader mode writes the active tenant's file and removes any stale
# loader assignment for the same name, which would otherwise shadow it (GH#34806).
update_fallback_credential() {
	local name="$1"
	local escaped_value="$2"
	local lock_dir=""
	local store_file=""
	store_file=$(credential_store_file)

	# The lock lives beside the credentials file, so its parent must exist before
	# acquisition. File creation remains inside the lock to avoid truncation races.
	if ! mkdir -p "$CONFIG_DIR" || ! chmod 700 "$CONFIG_DIR"; then
		print_error "Unable to prepare credentials directory"
		return 1
	fi

	if ! lock_dir=$(acquire_credentials_lock); then
		return 1
	fi

	if [[ "$store_file" != "$CREDENTIALS_FILE" ]] && ! prepare_tenant_store "$store_file"; then
		release_credentials_lock "$lock_dir"
		print_error "Unable to prepare the active tenant credentials file (symlinks are refused)"
		return 1
	fi

	if ! ensure_credentials_file "$store_file"; then
		release_credentials_lock "$lock_dir"
		return 1
	fi

	if ! rewrite_credential_file "$store_file" "$name" "export ${name}=\"${escaped_value}\""; then
		release_credentials_lock "$lock_dir"
		print_error "Unable to update credentials file"
		return 1
	fi

	if [[ "$store_file" != "$CREDENTIALS_FILE" ]] &&
		credential_assignment "$CREDENTIALS_FILE" "$name" >/dev/null &&
		! rewrite_credential_file "$CREDENTIALS_FILE" "$name"; then
		print_warning "Stored $name, but its stale loader entry remains; run: aidevops secret migrate-loader"
	fi

	release_credentials_lock "$lock_dir"
	return 0
}

# Move stranded loader exports into the active tenant (GH#34806). Lines move
# byte-for-byte; a name already in the tenant with a different line stays in
# the loader and is reported by name. Never prints values.
cmd_migrate_loader() {
	if ! is_tenant_loader; then
		print_info "credentials.sh is not a tenant loader; nothing to migrate"
		return 0
	fi
	local store_file="" lock_dir="" name="" line="" existing="" names=""
	local -a moved=() conflicts=()
	store_file=$(credential_store_file)
	if ! lock_dir=$(acquire_credentials_lock); then
		return 1
	fi
	names=$(stranded_loader_names)
	if ! prepare_tenant_store "$store_file" || ! ensure_credentials_file "$store_file"; then
		release_credentials_lock "$lock_dir"
		print_error "Unable to prepare the active tenant credentials file (symlinks are refused)"
		return 1
	fi
	while IFS= read -r name; do
		[[ -n "$name" ]] || continue
		line=$(credential_assignment "$CREDENTIALS_FILE" "$name") || continue
		existing=$(credential_assignment "$store_file" "$name") || existing=""
		if [[ -n "$existing" && "$existing" != "$line" ]]; then
			conflicts+=("$name")
			continue
		fi
		# Write the tenant copy before removing the loader copy: a failure
		# leaves a duplicate, never a loss.
		if { [[ -z "$existing" ]] && ! rewrite_credential_file "$store_file" "$name" "$line"; } ||
			! rewrite_credential_file "$CREDENTIALS_FILE" "$name"; then
			release_credentials_lock "$lock_dir"
			print_error "Unable to move $name; no entry was removed before its tenant copy existed"
			return 1
		fi
		moved+=("$name")
	done <<<"$names"
	release_credentials_lock "$lock_dir"

	print_info "Active tenant: $(active_tenant_name)"
	if [[ ${#moved[@]} -gt 0 ]]; then
		print_success "Moved ${#moved[@]} name(s) into the active tenant: ${moved[*]}"
	fi
	if [[ ${#conflicts[@]} -gt 0 ]]; then
		print_warning "Kept ${#conflicts[@]} name(s) in the loader; the tenant already holds a different value: ${conflicts[*]}"
		print_info "Choose the value with: aidevops secret set NAME (writes the tenant and removes the loader entry)"
		return 1
	fi
	[[ ${#moved[@]} -gt 0 ]] || print_info "No stranded loader entries"
	return 0
}

# Initialize gopass store for aidevops
cmd_init() {
	if ! command -v gopass &>/dev/null; then
		print_info "gopass not found. Installing..."
		if command -v brew &>/dev/null; then
			brew install gopass
		elif command -v apt-get &>/dev/null; then
			sudo apt-get install -y gopass
		elif command -v pacman &>/dev/null; then
			sudo pacman -S gopass
		else
			print_error "Cannot auto-install gopass. Install manually: https://github.com/gopasspw/gopass#installation"
			return 1
		fi
	fi

	if ! gopass ls &>/dev/null; then
		print_info "Initializing gopass store..."
		gopass setup
	fi

	# Create aidevops subfolder if it doesn't exist
	if ! gopass ls "${GOPASS_PREFIX}/" &>/dev/null; then
		print_info "Creating ${GOPASS_PREFIX}/ prefix in gopass store"
		# gopass creates folders implicitly when secrets are added
	fi

	print_success "gopass initialized for aidevops"
	print_info "Store secrets: aidevops secret set SECRET_NAME"
	print_info "Import existing: aidevops secret import-credentials"
	return 0
}

# Delegate non-secret credential registry commands (GH#34680). The registry
# stores names, accounts, reach and expiry only; it never reads secret values.
run_credential_inventory() {
	local inventory_cli="${SCRIPT_DIR}/credential_inventory.py"
	if ! command -v python3 >/dev/null 2>&1; then
		print_error "python3 is required for credential registry commands" >&2
		return 1
	fi
	if [[ ! -f "$inventory_cli" ]]; then
		print_error "Credential registry helper not found: credential_inventory.py" >&2
		return 1
	fi
	local exit_code=0
	python3 "$inventory_cli" "$@" || exit_code=$?
	return "$exit_code"
}

# True only when a registry file exists and its helper can run. Installs
# without a registry never invoke python, so injection is unchanged.
has_credential_inventory() {
	local inventory_file="${AIDEVOPS_CREDENTIAL_INVENTORY:-}"
	if [[ -z "$inventory_file" ]]; then
		inventory_file="${HOME}/.config/aidevops/credential-inventory.json"
	else
		inventory_file="${inventory_file/#\~/$HOME}"
	fi
	[[ -f "$inventory_file" ]] || return 1
	command -v python3 >/dev/null 2>&1 || return 1
	[[ -f "${SCRIPT_DIR}/credential_inventory.py" ]] || return 1
	return 0
}

# True when NAME is stored in gopass or a credential file (no decryption).
secret_name_stored() {
	local name="$1"
	if has_gopass && gopass_owns_secret "$name"; then
		return 0
	fi
	local cred_file
	local assignment="export ${name}="
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		if grep -q "^${assignment}" "$cred_file" 2>/dev/null; then
			return 0
		fi
	done < <(resolve_credential_files)
	return 1
}

# Print the stored source for a requested name that is not itself stored:
# a declared alias, or a provider's conventional variable with an explicit
# default (GH#34718). Returns 1 when nothing applies; defaults are never inferred.
resolve_injection_source() {
	local name="$1"
	has_credential_inventory || return 1
	secret_name_stored "$name" && return 1
	local source_name=""
	source_name=$(run_credential_inventory resolve-name "$name" 2>/dev/null) || return 1
	[[ "$source_name" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
	printf '%s\n' "$source_name"
	return 0
}

# Append NAME=value records for REQUESTED SOURCE pairs to a NUL-delimited env
# file, copying the value of SOURCE when it is present and REQUESTED is not.
append_alias_records() {
	local env_file="$1"
	shift
	[[ $# -ge 2 ]] || return 0
	local -a pairs=("$@")
	local -a keys=()
	local -a values=()
	local record=""
	while IFS= read -r -d '' record; do
		[[ "$record" == *=* ]] || continue
		keys+=("${record%%=*}")
		values+=("${record#*=}")
	done <"$env_file"
	local -a additions=()
	local i=0
	while [[ $i -lt ${#pairs[@]} ]]; do
		local requested="${pairs[$i]}"
		local source_name="${pairs[$((i + 1))]}"
		i=$((i + 2))
		local j=0 have_requested=false source_index=-1
		while [[ $j -lt ${#keys[@]} ]]; do
			[[ "${keys[$j]}" == "$requested" ]] && have_requested=true
			[[ "${keys[$j]}" == "$source_name" ]] && source_index=$j
			j=$((j + 1))
		done
		if [[ "$have_requested" == false && $source_index -ge 0 ]]; then
			additions+=("${requested}=${values[$source_index]}")
			keys+=("$requested")
			values+=("${values[$source_index]}")
		fi
	done
	[[ ${#additions[@]} -gt 0 ]] || return 0
	for record in "${additions[@]}"; do
		printf '%s\0' "$record" >>"$env_file"
	done
	return 0
}

# For `run` (inject all): add declared aliases and explicit provider defaults.
append_registry_aliases() {
	local env_file="$1"
	has_credential_inventory || return 0
	local mapping=""
	mapping=$(run_credential_inventory injection-map) || return 0
	[[ -n "$mapping" ]] || return 0
	local -a pairs=()
	local requested="" source_name=""
	while IFS=$'\t' read -r requested source_name; do
		[[ -n "$requested" && -n "$source_name" ]] || continue
		pairs+=("$requested" "$source_name")
	done <<<"$mapping"
	[[ ${#pairs[@]} -gt 0 ]] || return 0
	append_alias_records "$env_file" "${pairs[@]}"
	return 0
}

# Parse `set` options after SECRET_NAME into SET_SOURCE_FILE and
# SET_RECORD_ARGS (globals keep Bash 3.2 compatibility without namerefs).
parse_set_options() {
	SET_SOURCE_FILE=""
	SET_RECORD_ARGS=()
	while [[ $# -gt 0 ]]; do
		local flag="$1"
		local flag_value="${2:-}"
		case "$flag" in
		--from-file | --provider | --account | --purpose | --zones | --resources | --expires | --kind)
			[[ -n "$flag_value" ]] || return 1
			if [[ "$flag" == "--from-file" ]]; then
				SET_SOURCE_FILE="$flag_value"
			else
				SET_RECORD_ARGS+=("$flag" "$flag_value")
			fi
			shift 2
			;;
		*)
			return 1
			;;
		esac
	done
	return 0
}

# Set a secret (hidden single-line input, full stdin, or private file).
# Optional metadata flags record which account the secret opens (GH#34680);
# they are validated before the value is read so a rejection stores nothing.
cmd_set() {
	local name="${1:-}"
	local usage="Usage: aidevops secret set SECRET_NAME [--from-file PATH] [--provider P [--account REF] [--purpose TEXT] [--zones LIST] [--resources LIST] [--expires YYYY-MM-DD|never] [--kind KIND]]"

	if [[ -z "$name" || "$name" == -* ]]; then
		print_error "$usage"
		return 1
	fi
	shift
	if ! parse_set_options "$@"; then
		print_error "$usage"
		return 1
	fi
	local source_file="$SET_SOURCE_FILE"
	local -a record_args=()
	[[ ${#SET_RECORD_ARGS[@]} -eq 0 ]] || record_args=("${SET_RECORD_ARGS[@]}")

	# Normalize to uppercase
	name=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')
	if [[ ! "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
		print_error "Secret name must be a valid environment variable name"
		return 1
	fi
	if [[ "$name" == "AIDEVOPS_ACTIVE_TENANT" ]]; then
		print_error "AIDEVOPS_ACTIVE_TENANT is reserved; use: credential-helper.sh switch TENANT"
		return 1
	fi
	if [[ ${#record_args[@]} -gt 0 ]] && ! run_credential_inventory record "$name" "${record_args[@]}" --check; then
		print_error "Credential metadata rejected; nothing was stored"
		return 1
	fi

	print_info "Setting secret: $name"
	print_warning "WARNING: Never paste secret values into AI chat"
	print_warning "Run this command in your terminal and enter the value at the hidden prompt"
	echo ""
	echo "  1) When prompted, paste ONLY a single-line secret value"
	echo "  2) Do NOT paste the command, key name, or an export line"
	echo "  3) Input is hidden; press Enter when done"
	echo ""

	local value
	if ! value=$(read_secret_input "$name" "$source_file"); then
		return 1
	fi

	if has_gopass; then
		local gopass_output
		if ! gopass_output=$(printf '%s' "$value" | gopass insert --force "${GOPASS_PREFIX}/${name}" 2>&1); then
			if [[ "$gopass_output" == *"BLOCKED by canonical Git guard"* ]]; then
				print_error "Failed to store $name in gopass because the canonical Git guard blocked the password-store update"
			elif [[ "$gopass_output" == *"GPG"* || "$gopass_output" == *"gpg"* ]]; then
				print_error "Failed to store $name in gopass (GPG error)"
			elif [[ "$gopass_output" == *"not initialized"* ]]; then
				print_error "Failed to store $name in gopass (store not initialized)"
			else
				# Backend errors may include the submitted value; never print them.
				print_error "Failed to store $name in gopass; check store access and configuration"
			fi
			return 1
		fi
		print_success "Stored $name in gopass"
	else
		# All fallback readers are line-oriented; never write a partial or
		# executable multi-line assignment that they cannot safely round-trip.
		if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
			print_error "Multi-line secrets require gopass; run aidevops secret init, then retry with --from-file PATH" >&2
			return 1
		fi
		# Line-oriented fallback readers do not decode shell expansions. Refuse
		# these rather than creating an executable or non-round-tripping value.
		if [[ "$value" == *'$'* || "$value" == *'`'* ]]; then
			print_error "Secrets containing dollar signs or backticks require gopass; run aidevops secret init" >&2
			return 1
		fi
		print_warning "gopass not available, falling back to credentials.sh"

		# Escape backslashes then double quotes so the value can be safely embedded
		# in a double-quoted shell assignment.  get_secret_value() strips the
		# surrounding double quotes, so this round-trips correctly.
		local escaped_value="${value//\\/\\\\}"
		escaped_value="${escaped_value//\"/\\\"}"
		if ! update_fallback_credential "$name" "$escaped_value"; then
			return 1
		fi
		if is_tenant_loader; then
			print_success "Stored $name in tenant '$(active_tenant_name)' credentials"
		else
			print_success "Stored $name in credentials.sh"
		fi
		print_info "Recommend: aidevops secret init (to enable encrypted storage)"
		print_info "Do not run concurrent refreshes for the same rotating refresh token"
	fi
	record_set_metadata "$name" ${record_args[@]+"${record_args[@]}"}
	print_info "Verify key name only: aidevops secret list"

	return 0
}

# Record registry metadata after a successful store, or hint how to add it.
# A metadata failure never undoes the stored secret; it reports the retry.
record_set_metadata() {
	local name="$1"
	shift
	if [[ $# -eq 0 ]]; then
		print_info "Record which account it opens: aidevops secret record $name --provider PROVIDER --account REF"
		return 0
	fi
	if ! run_credential_inventory record "$name" "$@"; then
		print_warning "Stored $name, but recording its metadata failed; retry with: aidevops secret record $name $*"
	fi
	return 0
}

# Get a secret value by name (for programmatic/script use)
# Outputs raw value to stdout for piping into commands
cmd_get() {
	local name="${1:-}"

	if [[ -z "$name" ]]; then
		print_error "Usage: aidevops secret get SECRET_NAME"
		return 1
	fi

	# Normalize to uppercase
	name=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')

	local value
	value=$(get_secret_value "$name")
	if [[ -z "$value" ]]; then
		# Declared alias or explicit provider default (GH#34718)
		local source_name=""
		if source_name=$(resolve_injection_source "$name"); then
			value=$(get_secret_value "$source_name")
		fi
	fi

	if [[ -z "$value" ]]; then
		print_error "Secret not found: $name" >&2
		return 1
	fi

	if [[ -t 1 ]]; then
		printf '%s\n' "$value"
	else
		printf '%s' "$value"
	fi
	return 0
}

# Status-only resolution for dispatch: 0 readable, 1 missing/empty plaintext,
# 3 gopass-owned but unreadable/empty. Decrypt once; never emit values/errors.
cmd_check() {
	local name="${1:-}"
	[[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
	# Resolve aliases/explicit defaults exactly as injection does (GH#34718)
	local source_name=""
	if source_name=$(resolve_injection_source "$name" 2>/dev/null); then
		name="$source_name"
	fi
	if has_gopass && gopass_owns_secret "$name"; then
		local value=""
		value=$(get_injected_gopass_value "${GOPASS_PREFIX}/${name}" </dev/null 2>/dev/null) || return 3
		[[ -n "$value" ]] || return 3
		return 0
	fi
	local plain_value=""
	plain_value=$(get_secret_value "$name" 2>/dev/null) || return 1
	[[ -n "$plain_value" ]] || return 1
	return 0
}

# List secret names (NEVER values)
cmd_list() {
	local has_secrets=false

	if has_gopass; then
		local secrets
		secrets=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null || true)
		if [[ -n "$secrets" ]]; then
			print_info "Secrets in gopass (${GOPASS_PREFIX}/):"
			echo ""
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				local name="${secret_path#"${GOPASS_PREFIX}"/}"
				echo "  $name"
				has_secrets=true
			done <<<"$secrets"
			echo ""
		fi
	fi

	local credential_file=""
	local credential_names=""
	while IFS= read -r credential_file; do
		[[ -z "$credential_file" ]] && continue
		if [[ -L "$credential_file" ]] || [[ ! -f "$credential_file" ]]; then
			print_error "Credentials listing source must be a regular non-symlink file" >&2
			return 1
		fi
		if [[ ! -r "$credential_file" ]]; then
			print_error "Unable to read credentials listing source" >&2
			return 1
		fi
		local permissions=""
		permissions=$(_file_perms "$credential_file" 2>/dev/null || true)
		if [[ ! "$permissions" =~ ^[046]00$ ]]; then
			print_error "Credentials listing source must be owner-only" >&2
			return 1
		fi
		local line=""
		# Suppress shell redirection diagnostics: unreadable paths are private too.
		if ! {
			while IFS= read -r line || [[ -n "$line" ]]; do
				if [[ "$line" =~ ^export[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)= ]]; then
					credential_names+="${BASH_REMATCH[1]}"$'\n'
				fi
			done <"$credential_file"
		} 2>/dev/null; then
			print_error "Unable to read credentials listing source" >&2
			return 1
		fi
	done < <(resolve_credential_files)

	if [[ -n "$credential_names" ]]; then
		local cred_keys=""
		cred_keys=$(printf '%s' "$credential_names" | sort -u)
		if [[ -n "$cred_keys" ]]; then
			print_info "Secrets in credentials.sh:"
			echo ""
			while IFS= read -r key; do
				[[ -z "$key" ]] && continue
				echo "  $key"
				has_secrets=true
			done <<<"$cred_keys"
			echo ""
		fi
	fi

	if [[ "$has_secrets" == "false" ]]; then
		print_info "No secrets configured"
		print_info "Add secrets: aidevops secret set SECRET_NAME"
	fi

	return 0
}

# Emit validated secret-name metadata without invoking any value-reading command.
# A subshell keeps the EXIT trap and its local paths scoped to this command.
cmd_inventory() (
	local gopass_status="missing"
	local credentials_status="missing"
	local names_file=""
	local sorted_file=""
	local count=0

	names_file=$(mktemp) || return 1
	sorted_file="${names_file}.sorted"
	trap 'rm -f "${names_file:-}" "${sorted_file:-}"' EXIT

	if command -v gopass &>/dev/null; then
		gopass_status="error"
		local listing=""
		if listing=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null); then
			gopass_status="available"
			local secret_path=""
			while IFS= read -r secret_path; do
				[[ -z "$secret_path" ]] && continue
				case "$secret_path" in
				"${GOPASS_PREFIX}/"*) inventory_add_name "${secret_path#"${GOPASS_PREFIX}/"}" "$names_file" || return 1 ;;
				*)
					print_error "Invalid gopass inventory path" >&2
					return 1
					;;
				esac
			done <<<"$listing"
		fi
	fi

	local credential_file=""
	while IFS= read -r credential_file; do
		[[ -z "$credential_file" ]] && continue
		credentials_status="error"
		if [[ -L "$credential_file" ]] || [[ ! -f "$credential_file" ]]; then
			print_error "Credentials inventory source must be a regular non-symlink file" >&2
			return 1
		fi
		local permissions=""
		permissions=$(_file_perms "$credential_file" 2>/dev/null || true)
		if [[ ! "$permissions" =~ ^[046]00$ ]]; then
			print_error "Credentials inventory source must be owner-only" >&2
			return 1
		fi
		credentials_status="available"
		local line=""
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+([A-Z][A-Z0-9_]*)= ]]; then
				inventory_add_name "${BASH_REMATCH[1]}" "$names_file" || return 1
			fi
		done <"$credential_file"
	done < <(resolve_credential_files)

	sort -u "$names_file" >"$sorted_file"
	mv "$sorted_file" "$names_file"
	count=$(wc -l <"$names_file" | tr -d ' ')
	if [[ "$count" -gt "$INVENTORY_MAX_NAMES" ]]; then
		print_error "Secret inventory exceeds ${INVENTORY_MAX_NAMES} names" >&2
		return 1
	fi

	printf '{"version":1,"backends":{"gopass":"%s","credentials":"%s"},"secrets":[' "$gopass_status" "$credentials_status"
	local separator=""
	local name=""
	while IFS= read -r name; do
		[[ -z "$name" ]] && continue
		printf '%s{"name":"%s","status":"configured"}' "$separator" "$name"
		separator=","
	done <"$names_file"
	printf ']}\n'

	return 0
)

inventory_add_name() {
	local name="$1"
	local output_file="$2"

	if [[ ${#name} -gt "$INVENTORY_MAX_NAME_LENGTH" ]] || [[ ! "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
		print_error "Invalid secret inventory name" >&2
		return 1
	fi
	printf '%s\n' "$name" >>"$output_file"
	return 0
}

# Run a command with secrets injected and output redacted
cmd_run() {
	local -a cmd_args=("$@")

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		print_error "Usage: aidevops secret run COMMAND [ARGS...]"
		return 1
	fi

	# Build environment in temp file with trap cleanup for security
	local env_file
	env_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$env_file'" EXIT

	build_secret_env >"$env_file"
	append_registry_aliases "$env_file"
	register_redaction_digests "$env_file"

	# Execute command with secrets in environment, redact output
	local exit_code=0
	(
		# Load secrets into subprocess environment
		while IFS='=' read -r -d '' key val; do
			[[ -z "$key" ]] && continue
			export "$key=$val"
		done <"$env_file"

		# Execute the command
		"${cmd_args[@]}"
	) 2>&1 | redact_stream "$env_file" || exit_code=$?

	# Clean up (also handled by trap on abnormal exit)
	rm -f "$env_file"
	trap - EXIT

	return "$exit_code"
}

# Run with specific secrets: secret NAME1 NAME2 -- command args
cmd_run_specific() {
	local -a secret_names=()
	local -a cmd_args=()
	local found_separator=false

	for arg in "$@"; do
		if [[ "$arg" == "--" ]]; then
			found_separator=true
			continue
		fi
		if [[ "$found_separator" == "true" ]]; then
			cmd_args+=("$arg")
		else
			secret_names+=("$arg")
		fi
	done

	if [[ ${#cmd_args[@]} -eq 0 ]]; then
		print_error "Usage: aidevops secret NAME [NAME...] -- COMMAND [ARGS...]"
		return 1
	fi

	# Build environment with specific secrets only, trap cleanup for security
	local env_file
	env_file=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$env_file'" EXIT

	# Requested names that are not stored may resolve to a declared alias
	# source or an explicit provider default (GH#34718).
	local -a source_names=()
	local -a alias_pairs=()
	local requested_name=""
	for requested_name in ${secret_names[@]+"${secret_names[@]}"}; do
		local source_name=""
		if source_name=$(resolve_injection_source "$requested_name"); then
			source_names+=("$source_name")
			alias_pairs+=("$requested_name" "$source_name")
		else
			source_names+=("$requested_name")
		fi
	done

	if ! build_secret_env ${source_names[@]+"${source_names[@]}"} >"$env_file"; then
		return 1
	fi
	append_alias_records "$env_file" ${alias_pairs[@]+"${alias_pairs[@]}"}
	register_redaction_digests "$env_file"

	# Execute command with secrets in environment, redact output
	local exit_code=0
	(
		while IFS='=' read -r -d '' key val; do
			[[ -z "$key" ]] && continue
			export "$key=$val"
		done <"$env_file"

		"${cmd_args[@]}"
	) 2>&1 | redact_stream "$env_file" || exit_code=$?

	rm -f "$env_file"
	trap - EXIT

	return "$exit_code"
}

# Explicit, read-only provider verification (GH#34722). Each token reaches
# the verifier only through cmd_run_specific (environment, never argv; output
# redacted); the verifier caches value-free observations in the registry.
cmd_verify() {
	local provider="${1:-}"
	if [[ "$provider" != "cloudflare" ]]; then
		print_error "Usage: aidevops secret verify cloudflare [NAME...]"
		return 1
	fi
	shift
	local targets=""
	local targets_rc=0
	targets=$(run_credential_inventory verify-targets "$provider" "$@") || targets_rc=$?
	if [[ "$targets_rc" -ne 0 ]]; then
		[[ "$targets_rc" -eq 1 ]] && print_error "No recorded $provider credentials; record them with: aidevops secret record NAME --provider $provider --account REF"
		return 1
	fi
	local -a names=()
	local name=""
	while IFS= read -r name; do
		[[ -n "$name" ]] && names+=("$name")
	done <<<"$targets"
	local verifier="${SCRIPT_DIR}/credential_inventory_${provider}.py"
	local failures=0
	for name in "${names[@]}"; do
		cmd_run_specific "$name" -- python3 "$verifier" verify "$name" </dev/null || failures=$((failures + 1))
	done
	if [[ "$failures" -gt 0 ]]; then
		print_warning "$failures of ${#names[@]} $provider credential(s) did not verify as active"
		return 1
	fi
	return 0
}

# Migrate only the active plaintext store into the resolver's flat namespace.
# Both operations share the writer lock and a conservative literal-only parser.
credential_migration() (
	local operation="$1"
	local dry_run="${2:-false}"
	if ! has_gopass; then
		print_error "gopass not initialized. Run: aidevops secret init"
		return 1
	fi
	local file="" lock_dir=""
	file=$(credential_store_file)
	if [[ ! -e "$file" && ! -L "$file" ]]; then
		print_info "No active credentials file found"
		return 0
	fi
	lock_dir=$(acquire_credentials_lock) || return 1
	trap 'release_credentials_lock "$lock_dir"' EXIT
	python3 - "$file" "$operation" "$dry_run" "${SCRIPT_DIR}/secret-helper.sh" <<'PY'
import os
import re
import stat
import subprocess
import sys
import tempfile

path, operation, dry_run, helper = sys.argv[1:]

def run(args, data=None):
    return subprocess.run(args, input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=5, check=False)

def literal(raw):
    # Never evaluate shell code. Only forms that injection and shell sourcing
    # interpret identically are eligible; leave everything else untouched.
    if raw.startswith('"') and raw.endswith('"'):
        if len(raw) < 2:
            return None
        raw = raw[1:-1]
        result = []
        index = 0
        while index < len(raw):
            char = raw[index]
            if char == '\\':
                index += 1
                if index == len(raw) or raw[index] not in '\\"':
                    return None
                char = raw[index]
            elif char in '"$`':
                return None
            result.append(char)
            index += 1
        return ''.join(result)
    if re.fullmatch(r'[A-Za-z0-9_./:@%+,=-]+', raw):
        return raw
    return None

def migrate():
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'r', encoding='utf-8', newline='') as source:
        info = os.fstat(source.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077):
            raise ValueError('unsafe source')
        original = source.read()
    # The prefix may not exist yet in a newly initialized store; listing the
    # root distinguishes that normal case from a genuine listing failure.
    listing = run(['gopass', 'ls', '--flat'])
    if listing.returncode:
        raise ValueError('unavailable listing')
    owned = set(listing.stdout.decode().splitlines())
    lines = original.splitlines(keepends=True)
    assignments = []
    for index, line in enumerate(lines):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = re.fullmatch(r'export ([A-Z_][A-Z0-9_]*)=(.*)', line.rstrip('\n'))
        # Validate the entire file BEFORE any writes. Otherwise an apparent
        # export could actually be text inside a multiline quote or heredoc.
        if not match or '\0' in line or (match[2] and literal(match[2]) is None):
            raise ValueError('unsupported shell structure')
        assignments.append((index, match[1], match[2]))
    counts = {}
    for _, name, _ in assignments:
        counts[name] = counts.get(name, 0) + 1
    removed = set()
    for index, name, raw in assignments:
        # Positive secret-name classification keeps configuration (including
        # project IDs, key-file paths and provider allowlists) in plaintext.
        if not re.search(r'(?:^|_)(?:KEY|TOKEN|SECRET|PASSWORD|PASS|CREDENTIALS?)$', name):
            continue
        value = literal(raw)
        if counts[name] != 1 or not value or value.startswith(('YOUR_', 'CHANGE_ME')):
            print(f'Keeping {name} (ambiguous, empty or unsupported assignment)')
            continue
        target = 'aidevops/' + name
        if target in owned:
            stored = run(['gopass', 'show', '-n', target])
            # Match Bash command substitution in the runtime resolver: embedded
            # newlines remain significant, trailing newlines are normalized.
            equal = stored.returncode == 0 and stored.stdout.rstrip(b'\n') == value.encode()
            if operation == 'import':
                state = 'value-equal' if equal else 'differing or unreadable'
                print(f'Skipping {name} (already in gopass; {state})')
            elif equal and run(['bash', helper, 'check', name]).returncode == 0:
                removed.add(index)
                print(f'{"Would prune" if dry_run == "true" else "Pruning"} {name}')
            else:
                print(f'Keeping {name} (gopass differs or is unreadable)')
        elif operation == 'import':
            # Piped insert without --force refuses existing entries (verified
            # against gopass 1.16.1 insert's IsStdin/Exists branch).
            result = run(['gopass', 'insert', target], (value + '\n').encode())
            if result.returncode:
                raise ValueError('insert failed')
            owned.add(target)
            print(f'Imported {name}')
        else:
            print(f'Keeping {name} (not owned by gopass)')
    if removed and dry_run != 'true':
        fd, temporary = tempfile.mkstemp(prefix='.credentials-prune-', dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, 'w', encoding='utf-8', newline='') as output:
                output.write(''.join(line for index, line in enumerate(lines) if index not in removed))
                output.flush()
                os.fsync(output.fileno())
            current = os.stat(path, follow_symlinks=False)
            if (current.st_dev, current.st_ino, current.st_mtime_ns, current.st_size) != (
                    info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size):
                raise ValueError('source changed')
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

try:
    migrate()
except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
    print('Credential migration failed safely; use a private regular file containing only comments and simple one-line literal exports, with readable gopass', file=sys.stderr)
    sys.exit(1)
PY
	return $?
)

cmd_import_credentials() {
	credential_migration import || return 1
	print_info "Env-only helpers must run via: aidevops secret NAME -- cmd"
	print_info "Keep plaintext until callers use injection; preview with: aidevops secret prune-plaintext --dry-run"
	return 0
}

cmd_prune_plaintext() {
	local dry_run=false
	local option="${1:-}"
	if [[ $# -eq 1 && "$option" == "--dry-run" ]]; then
		dry_run=true
	elif [[ $# -ne 0 ]]; then
		print_error "Usage: aidevops secret prune-plaintext [--dry-run]"
		return 1
	fi
	print_info "Env-only helpers must run via: aidevops secret NAME -- cmd"
	credential_migration prune "$dry_run" || return 1
	return 0
}

# Names/permissions only: old copies remain plaintext even after pruning.
warn_credential_backups() {
	local backup="" permissions=""
	for backup in "$CONFIG_DIR"/credentials.sh.bak-* "$TENANTS_DIR"/*/credentials.sh.bak-*; do
		[[ -e "$backup" || -L "$backup" ]] || continue
		permissions=$(_file_perms "$backup" 2>/dev/null) || permissions="unknown"
		print_warning "Plaintext credentials.sh.bak-* backup remains (mode $permissions); review under your secure-deletion policy"
		if [[ ! "$permissions" =~ ^[046]00$ ]]; then
			print_warning "Credential backup may be group/world-readable or unsafe"
		fi
	done
	return 0
}

# Show backend status
cmd_status() {
	echo ""
	print_info "Secret Management Status"
	echo "========================="
	echo ""

	# gopass status
	if command -v gopass &>/dev/null; then
		local gopass_version
		gopass_version=$(gopass version 2>/dev/null | head -1 || echo "unknown")
		echo -e "  gopass:       ${GREEN}installed${NC} ($gopass_version)"

		if gopass ls &>/dev/null; then
			local secret_count
			secret_count=$(gopass ls --flat "${GOPASS_PREFIX}/" 2>/dev/null | wc -l | tr -d ' ')
			echo -e "  gopass store: ${GREEN}initialized${NC} ($secret_count secrets in ${GOPASS_PREFIX}/)"
		else
			echo -e "  gopass store: ${YELLOW}not initialized${NC}"
			echo -e "                Run: aidevops secret init"
		fi
	else
		echo -e "  gopass:       ${YELLOW}not installed${NC}"
		echo -e "                Install: brew install gopass"
	fi

	# GPG status
	if command -v gpg &>/dev/null; then
		local gpg_keys
		gpg_keys=$(gpg --list-secret-keys 2>/dev/null | safe_grep_count "^sec")
		echo -e "  GPG:          ${GREEN}installed${NC} ($gpg_keys secret key(s))"
	else
		echo -e "  GPG:          ${YELLOW}not installed${NC}"
	fi

	# credentials.sh status (names and counts only)
	if is_tenant_loader; then
		local store_file="" key_count=0 stranded=""
		store_file=$(credential_store_file)
		[[ -f "$store_file" ]] && key_count=$(safe_grep_count "^export " "$store_file" 2>/dev/null)
		echo -e "  credentials:  tenant loader; active tenant '$(active_tenant_name)' has ${GREEN}$key_count key(s)${NC}"
		stranded=$(stranded_loader_names | tr '\n' ' ')
		if [[ -n "$stranded" ]]; then
			echo -e "  ${YELLOW}stranded:${NC}     ${stranded}(exported in the loader, outside any tenant)"
			echo -e "                Move: aidevops secret migrate-loader (tenant switch rewrites the loader)"
		fi
	elif [[ -f "$CREDENTIALS_FILE" ]]; then
		local key_count
		key_count=$(safe_grep_count "^export " "$CREDENTIALS_FILE" 2>/dev/null)
		echo -e "  credentials:  ${GREEN}$key_count key(s)${NC} in $CREDENTIALS_FILE"
	else
		echo -e "  credentials:  ${DIM}no file${NC}"
	fi

	warn_credential_backups
	echo ""
	return 0
}

# Show help
cmd_help() {
	echo ""
	print_info "AI DevOps - Secret Management"
	echo ""
	echo "  Manage secrets with gopass (encrypted) or credentials.sh (plaintext fallback)."
	echo "  Secret values are NEVER exposed to AI agent context windows."
	echo ""
	print_info "Commands:"
	echo ""
	echo "  init                              Initialize gopass store"
	echo "  set <NAME>                        Store a secret (interactive hidden input)"
	echo "  set <NAME> --from-file PATH       Store a private regular file (chmod 600)"
	echo "                                    Piped stdin is read in full until EOF"
	echo "  get <NAME>                        Get a secret value (for scripts/piping)"
	echo "  check <NAME>                      Resolve by name; exit status only, no output"
	echo "  list                              List secret names (never values)"
	echo "  inventory                         Names-only structured local inventory"
	echo "  status                            Show backend status"
	echo ""
	print_info "Credential registry (non-secret; which account each secret opens):"
	echo ""
	echo "  set <NAME> --provider P --account REF [--purpose T] [--zones LIST] [--expires DATE|never]"
	echo "  record <NAME> --provider P [--account REF] [...]   Describe an already stored secret"
	echo "  describe [NAME] [--json]          Account, reach, owner, expiry, default"
	echo "  account add REF --provider P --name NAME [--ownership-type T --owner O --confirmed]"
	echo "  account list [--json]             List provider accounts"
	echo "  default PROVIDER [NAME|--none]    Show or declare the provider default"
	echo "  alias NAME OLD_NAME               Keep a retired name working (no rename)"
	echo "  resolve PROVIDER                  Print default name (exit 3 none, 4 undeclared)"
	echo "  validate                          Check the credential registry file"
	echo "  dependents NAME [--json]          What uses NAME (+aliases) before rename/rotation"
	echo "  verify cloudflare [NAME...]       Read-only provider check; caches accounts/zones"
	echo "  drift [--json]                    Offline expiry/overlap/ownership/freshness report"
	echo "  owner RESOURCE [--json]           Which account/credentials hold a zone or resource"
	echo "  organise [--json] [--apply-drafts] Plan cleanup; drafts only, never renames/deletes"
	echo ""
	echo "  run CMD [ARGS...]                 Run command with all secrets injected"
	echo "  NAME [NAME...] -- CMD [ARGS...]   Run command with specific secrets"
	echo "  import-credentials                Import from credentials.sh to gopass"
	echo "  prune-plaintext [--dry-run]        Remove matching active-store secrets; keep config"
	echo "  migrate-loader                    Move exports stranded in a tenant loader into the active tenant"
	echo ""
	print_info "Examples:"
	echo ""
	echo "  # WARNING: Never paste secret values into AI chat"
	echo "  # Run secret set in your terminal and enter the value at hidden prompt"
	echo ""
	echo "  # Store a secret (value entered at terminal, hidden)"
	echo "  aidevops secret set STRIPE_KEY"
	echo ""
	echo "  # Multi-line PEM/JSON requires gopass; never paste it at the prompt"
	echo "  aidevops secret set APP_KEY --from-file /secure/path/app.pem"
	echo "  # Delete the source file securely after successful storage/verification"
	echo "  # Trailing newlines are trimmed; embedded newlines are preserved"
	echo ""
	echo "  # Secret set flow"
	echo "  # 1) Run set command"
	echo "  # 2) At hidden prompt, paste only the secret value"
	echo "  # 3) Press Enter"
	echo "  # 4) Verify key name only"
	echo "  aidevops secret list"
	echo ""
	echo "  # Run a command with secrets injected (output redacted)"
	echo "  aidevops secret run curl -H 'Authorization: Bearer \$STRIPE_KEY' https://api.stripe.com/v1/charges"
	echo ""
	echo "  # Inject specific secrets only"
	echo "  aidevops secret GITHUB_TOKEN -- gh api /user"
	echo ""
	echo "  # Import existing credentials to gopass"
	echo "  aidevops secret import-credentials"
	echo ""
	print_info "Security:"
	echo ""
	echo "  - Secret values are injected via subprocess environment (never in agent context)"
	echo "  - All command output is automatically redacted (secret values -> [REDACTED])"
	echo "  - gopass encrypts secrets at rest with GPG"
	echo "  - credentials.sh is plaintext fallback (chmod 600)"
	echo "  - With a tenant loader, plaintext writes go to the active tenant; reads try"
	echo "    the active tenant first, then other tenants"
	echo ""
	return 0
}

# Main dispatch
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	init)
		cmd_init "$@"
		;;
	set)
		cmd_set "$@"
		;;
	get)
		cmd_get "$@"
		;;
	check)
		cmd_check "$@"
		;;
	list | ls)
		cmd_list "$@"
		;;
	inventory)
		cmd_inventory "$@"
		;;
	drift)
		warn_credential_backups
		run_credential_inventory "$command" "$@" || return $?
		;;
	describe | record | account | default | alias | resolve | validate | dependents | owner | organise | organize)
		run_credential_inventory "$command" "$@" || return $?
		;;
	verify)
		cmd_verify "$@" || return $?
		;;
	run)
		cmd_run "$@"
		;;
	import-credentials | import)
		cmd_import_credentials "$@"
		;;
	prune-plaintext)
		cmd_prune_plaintext "$@"
		;;
	migrate-loader)
		cmd_migrate_loader "$@"
		;;
	status)
		cmd_status "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		# Check if it looks like "NAME [NAME...] -- CMD"
		# (specific secret injection pattern)
		if [[ "$command" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
			cmd_run_specific "$command" "$@"
		else
			print_error "Unknown command: $command"
			echo ""
			cmd_help
			return 1
		fi
		;;
	esac

	return 0
}

main "$@"
