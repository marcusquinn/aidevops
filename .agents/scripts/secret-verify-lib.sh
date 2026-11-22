#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Secret Verify/Migration Library -- provider verification and plaintext migration
# =============================================================================
# Extracted verbatim from secret-helper.sh (file-size split, GH#37726).
#
# Usage: source "${SCRIPT_DIR}/secret-verify-lib.sh"
#
# Dependencies: secret-helper.sh globals and functions (CONFIG_DIR,
# CREDENTIALS_FILE, TENANTS_DIR, has_gopass, cmd_run_specific, ...), resolved at
# call time.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_SECRET_VERIFY_LIB_LOADED:-}" ]] && return 0
_SECRET_VERIFY_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Explicit, read-only provider verification (GH#34722). Each token reaches
# the verifier only through cmd_run_specific (environment, never argv; output
# redacted); the verifier caches value-free observations in the registry.
cmd_verify() {
	local provider="${1:-}"
	if [[ "$provider" == "aws" ]]; then
		shift
		cmd_verify_aws "$@"
		return $?
	fi
	if [[ "$provider" != "cloudflare" ]]; then
		print_error "Usage: aidevops secret verify {cloudflare|aws} [NAME...]"
		return 1
	fi
	shift
	local targets=""
	local targets_rc=0
	targets=$(run_credential_inventory verify-targets "$provider" "$@") || targets_rc=$?
	if [[ "$targets_rc" -ne 0 ]]; then
		[[ "$targets_rc" -eq 1 ]] && print_error "No recorded $provider API tokens; record them with: aidevops secret record NAME --provider $provider --kind api_token --account REF"
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

# AWS uses paired credentials, not the single-token Cloudflare target model.
cmd_verify_aws() {
	local verifier="${SCRIPT_DIR}/credential_inventory_aws.py"
	local targets="" prefix="" names_output="" name=""
	local failures=0
	targets=$(python3 "$verifier" targets "$@") || return 1
	while IFS= read -r prefix; do
		local -a names=()
		names_output=$(python3 "$verifier" names "$prefix") || return 1
		while IFS= read -r name; do
			names+=("$name")
		done <<<"$names_output"
		cmd_run_specific "${names[@]}" -- python3 "$verifier" verify "$prefix" </dev/null || failures=$((failures + 1))
	done <<<"$targets"
	if [[ "$failures" -gt 0 ]]; then
		print_warning "$failures AWS credential pair(s) did not verify"
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
	python3 "${SCRIPT_DIR}/credential_migration.py" "$file" "$operation" "$dry_run" "${SCRIPT_DIR}/secret-helper.sh"
	return $?
)

# JSON Lines, names only. File resolution stays shared with the runtime resolver.
cmd_audit_credentials() {
	local loader="" file=""
	local -a files=("$CREDENTIALS_FILE")
	is_tenant_loader && loader="$CREDENTIALS_FILE"
	while IFS= read -r file; do
		[[ -n "$file" ]] && files+=("$file")
	done < <(resolve_credential_files)
	python3 "${SCRIPT_DIR}/credential_audit.py" audit "${SCRIPT_DIR}/secret-helper.sh" "$loader" "$(credential_store_file)" "${files[@]}" || return 1
	return 0
}

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
