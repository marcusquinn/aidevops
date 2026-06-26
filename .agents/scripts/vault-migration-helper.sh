#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Migrate aidevops data-plane files into encrypted Vault entries with verified rollback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=vault-storage-lib.sh
source "${SCRIPT_DIR}/vault-storage-lib.sh"

MIGRATION_ROOT="${AIDEVOPS_VAULT_MIGRATION_ROOT:-$HOME/.aidevops/.agent-workspace}"
MANIFEST_DIR="${AIDEVOPS_VAULT_MIGRATION_MANIFEST_DIR:-$(vault_storage_dir)/migration-manifests}"
MANIFEST_FILE="${AIDEVOPS_VAULT_MIGRATION_MANIFEST:-${MANIFEST_DIR}/aidevops-data-migration.tsv}"
MANIFEST_HEADER_COLLECTION="collection"

usage() {
	cat <<'EOF'
Usage: vault-migration-helper.sh <plan|migrate|verify|rollback|status>

Migrates memory, embeddings, knowledge, workspace, mail/messages, config
metadata, and audit files into encrypted Vault entries. Plaintext originals are
removed only after read-back hash verification. Rollback restores from Vault;
passphrases are never accepted via args, env, chat, logs, or fixtures.

Limits: best-effort file removal cannot erase historical SSD/APFS/journal,
filesystem snapshot, backup, swap, crash-dump, or committed Git remnants. Keep
full-disk encryption/FileVault enabled for historical plaintext exposure.
EOF
	return 0
}

collection_for_path() {
	local path="$1"
	case "$path" in
	*/memory.db | */memory.db-* ) printf '%s\n' "memory" ;;
	*/embeddings.db | */embeddings.db-* | */.embeddings-* ) printf '%s\n' "embeddings" ;;
	*/knowledge/* | */_knowledge/* ) printf '%s\n' "knowledge" ;;
	*/mail/* | */messages/* ) printf '%s\n' "mail-messages" ;;
	*/audit.log | */audit/* ) printf '%s\n' "audit" ;;
	*/config/* | */repos.json | */credentials.json ) printf '%s\n' "config-metadata" ;;
	*) printf '%s\n' "workspace" ;;
	esac
	return 0
}

hash_file() {
	local path="$1"
	sha256sum "$path" | cut -d' ' -f1
	return 0
}

entry_name() {
	local collection="$1"
	local digest="$2"
	printf 'migration:%s:%s\n' "$collection" "$digest"
	return 0
}

write_manifest_header() {
	mkdir -p "$MANIFEST_DIR"
	chmod 700 "$MANIFEST_DIR"
	printf '%s\tsha256\tentry\tstate\tpath\n' "$MANIFEST_HEADER_COLLECTION" >"$MANIFEST_FILE"
	chmod 600 "$MANIFEST_FILE"
	return 0
}

iter_sources() {
	local root="$MIGRATION_ROOT"
	[[ -d "$root" ]] || return 0
	find "$root" -type f \( \
		-name 'memory.db' -o -name 'memory.db-*' -o -name 'embeddings.db' -o -name 'embeddings.db-*' -o \
		-path '*/knowledge/*' -o -path '*/_knowledge/*' -o -path '*/mail/*' -o -path '*/messages/*' -o \
		-path '*/config/*' -o -path '*/audit/*' -o -name 'audit.log' \
	\) -print | sort
	return 0
}

cmd_plan() {
	local path collection digest entry
	write_manifest_header
	while IFS= read -r path; do
		[[ -f "$path" ]] || continue
		collection=$(collection_for_path "$path")
		digest=$(hash_file "$path")
		entry=$(entry_name "$collection" "$digest")
		printf '%s\t%s\t%s\tplanned\t%s\n' "$collection" "$digest" "$entry" "$path" >>"$MANIFEST_FILE"
	done < <(iter_sources)
	printf '%s\n' "$MANIFEST_FILE"
	return 0
}

verify_entry() {
	local entry="$1"
	local expected="$2"
	local tmp_file
	tmp_file=$(mktemp)
	if ! "$(vault_storage_helper_path)" read "$entry" >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	local actual
	actual=$(hash_file "$tmp_file")
	rm -f "$tmp_file"
	[[ "$actual" == "$expected" ]]
	return $?
}

scrub_plaintext_file() {
	local path="$1"
	chmod u+w "$path" 2>/dev/null || true
	if command -v shred >/dev/null 2>&1; then
		shred -u "$path" 2>/dev/null || rm -f "$path"
	else
		rm -f "$path"
	fi
	return 0
}

cmd_migrate() {
	vault_storage_require_unlocked "vault migration" || return $?
	[[ -f "$MANIFEST_FILE" ]] || cmd_plan >/dev/null
	local tmp_manifest="${MANIFEST_FILE}.tmp"
	local read_manifest="${MANIFEST_FILE}.read"
	local collection digest entry state path
	cp "$MANIFEST_FILE" "$read_manifest"
	printf '%s\tsha256\tentry\tstate\tpath\n' "$MANIFEST_HEADER_COLLECTION" >"$tmp_manifest"
	while IFS=$'\t' read -r collection digest entry state path; do
		[[ "$collection" == "$MANIFEST_HEADER_COLLECTION" ]] && continue
		[[ -f "$path" ]] || { printf '%s\t%s\t%s\tmissing\t%s\n' "$collection" "$digest" "$entry" "$path" >>"$tmp_manifest"; continue; }
		"$(vault_storage_helper_path)" update "$entry" <"$path" >/dev/null
		if verify_entry "$entry" "$digest"; then
			scrub_plaintext_file "$path"
			printf '%s\t%s\t%s\tverified-scrubbed\t%s\n' "$collection" "$digest" "$entry" "$path" >>"$tmp_manifest"
		else
			printf '%s\t%s\t%s\tverify-failed\t%s\n' "$collection" "$digest" "$entry" "$path" >>"$tmp_manifest"
			mv "$tmp_manifest" "$MANIFEST_FILE"
			return 1
		fi
	done <"$read_manifest"
	rm -f "$read_manifest"
	mv "$tmp_manifest" "$MANIFEST_FILE"
	return 0
}

cmd_verify() {
	vault_storage_require_unlocked "vault migration verify" || return $?
	local collection digest entry state path failures=0
	while IFS=$'\t' read -r collection digest entry state path; do
		[[ "$collection" == "$MANIFEST_HEADER_COLLECTION" ]] && continue
		if ! verify_entry "$entry" "$digest"; then
			printf '%s\n' "verify failed: ${entry}" >&2
			failures=$((failures + 1))
		fi
	done <"$MANIFEST_FILE"
	[[ "$failures" -eq 0 ]]
	return $?
}

cmd_rollback() {
	vault_storage_require_unlocked "vault migration rollback" || return $?
	local collection digest entry state path
	while IFS=$'\t' read -r collection digest entry state path; do
		[[ "$collection" == "$MANIFEST_HEADER_COLLECTION" ]] && continue
		mkdir -p "$(dirname "$path")"
		"$(vault_storage_helper_path)" read "$entry" >"$path"
		chmod 600 "$path"
	done <"$MANIFEST_FILE"
	return 0
}

cmd_status() {
	if [[ -f "$MANIFEST_FILE" ]]; then
		printf '%s\n' "$MANIFEST_FILE"
	else
		printf '%s\n' "no migration manifest"
	fi
	return 0
}

main() {
	local command="${1:-help}"
	case "$command" in
	help | --help | -h) usage ;;
	plan) cmd_plan ;;
	migrate) cmd_migrate ;;
	verify) cmd_verify ;;
	rollback) cmd_rollback ;;
	status) cmd_status ;;
	*) usage >&2; return 2 ;;
	esac
	return $?
}

main "$@"
