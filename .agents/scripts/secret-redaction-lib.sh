#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Secret Redaction/Env Library -- value collection, output redaction, env build
# =============================================================================
# Extracted verbatim from secret-helper.sh (file-size split, GH#37726).
#
# Usage: source "${SCRIPT_DIR}/secret-redaction-lib.sh"
#
# Dependencies: secret-helper.sh globals and functions (CONFIG_DIR,
# CREDENTIALS_FILE, has_gopass, get_secret_value, ...), resolved at call time.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_SECRET_REDACTION_LIB_LOADED:-}" ]] && return 0
_SECRET_REDACTION_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

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

# Print usable redaction values from a NUL-delimited KEY=VALUE env file,
# NUL-terminated. Splits on the first '=' only: IFS='=' read drops a single
# trailing '=' from the value, e.g. base64 padding (GH#37408).
# Usage: collect_env_file_values ENV_FILE [quiet]
collect_env_file_values() {
	local env_file="$1"
	local warn_mode="${2:-warn}"
	local -a warned_names=()
	local record="" _key="" value=""
	while IFS= read -r -d '' record; do
		[[ "$record" == *=* ]] || continue
		_key="${record%%=*}"
		value="${record#*=}"
		if redaction_value_usable "$value"; then
			printf '%s\0' "$value"
		elif [[ "$warn_mode" != "quiet" && -n "$value" && ${#value} -lt 8 ]] && ! secret_env_name_emitted "$_key" "${warned_names[@]}"; then
			warn_short_redaction_value "$_key"
			warned_names+=("$_key")
		fi
	done <"$env_file"
	return 0
}

# Redact secret values from a stream
# Reads stdin, replaces any secret value with [REDACTED]
# Usage: redact_stream [ENV_FILE] [quiet]; "quiet" suppresses the names-only
# short-value warnings so a second (stderr) relay does not repeat them.
redact_stream() {
	local env_file="${1:-}"
	local warn_mode="${2:-warn}"
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
		collect_env_file_values "$env_file" "$warn_mode" >"$values_file"
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
			# Whole-store listing: an empty prefix folder is not an error.
			if ! available_secrets=$(gopass ls --flat 2>/dev/null); then
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

	local encrypted_name="" encrypted_value=""
	while IFS= read -r encrypted_name; do
		[[ -n "$encrypted_name" ]] || continue
		if [[ ${#specific_names[@]} -gt 0 ]] && ! secret_env_name_emitted "$encrypted_name" "${specific_names[@]}"; then
			continue
		fi
		secret_env_name_emitted "$encrypted_name" "${emitted_names[@]}" && continue
		# A listed but unreadable gopass entry must not fall through to this backend.
		if has_gopass && gopass_owns_secret "$encrypted_name"; then
			return 1
		fi
		encrypted_value=$(systemd_secret_read "$encrypted_name") || return 1
		[[ -n "$encrypted_value" ]] || return 1
		emit_secret_env_record "$encrypted_name" "$encrypted_value"
		emitted_names+=("$encrypted_name")
	done < <(systemd_secret_names)

	# Also load from credential files as fallback/supplement (handles multi-tenant)
	local cred_file
	while IFS= read -r cred_file; do
		[[ -z "$cred_file" ]] && continue
		while IFS= read -r line; do
			if [[ "$line" =~ ^export[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*) ]]; then
				local name="${BASH_REMATCH[1]}"
				if [[ ${#specific_names[@]} -gt 0 ]] && ! secret_env_name_emitted "$name" "${specific_names[@]}"; then
					continue
				fi
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
