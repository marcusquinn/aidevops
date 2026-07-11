#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Setup module: migrate eligible lint policy and install repo-verify hooks.

readonly REPO_VERIFY_GUARD_LABEL="Repo verify guard"

setup_repo_verify_guard() {
	if [[ "${AIDEVOPS_REPO_VERIFY_GUARD:-true}" == "false" ]]; then
		print_info "Repo verify rollout disabled via AIDEVOPS_REPO_VERIFY_GUARD=false"
		setup_track_skipped "$REPO_VERIFY_GUARD_LABEL" "explicitly disabled"
		return 0
	fi
	local library_path="${INSTALL_DIR}/.agents/scripts/repo-verify-config-lib.sh"
	[[ -f "$library_path" ]] || library_path="${HOME}/.aidevops/agents/scripts/repo-verify-config-lib.sh"
	if [[ ! -f "$library_path" ]]; then
		print_warning "Repo verify configuration library unavailable"
		setup_track_skipped "$REPO_VERIFY_GUARD_LABEL" "library unavailable"
		return 0
	fi
	# shellcheck source=/dev/null
	source "$library_path"
	local repos_file="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_file" ]] || ! command -v jq >/dev/null 2>&1; then
		setup_track_skipped "$REPO_VERIFY_GUARD_LABEL" "repos.json or jq unavailable"
		return 0
	fi
	local repo_list_file
	repo_list_file=$(mktemp) || return 1
	if ! jq -r '.initialized_repos[]?.path // empty' "$repos_file" >"$repo_list_file" 2>/dev/null; then
		rm -f "$repo_list_file"
		print_warning "Repo verify rollout skipped: repos.json is invalid"
		return 1
	fi
	print_info "Migrating lint policy and refreshing repo-verify hooks..."
	local repo_root feature_state hook_output
	local registration_status=0 migration_status=0 installed=0 registered=0 migrated=0 skipped=0 conflicts=0 errors=0
	while IFS= read -r repo_root; do
		[[ -n "$repo_root" && -e "$repo_root/.git" ]] || {
			skipped=$((skipped + 1))
			continue
		}
		registration_status=0
		repo_verify_migrate_registration "$repo_root" >/dev/null 2>&1 || registration_status=$?
		[[ "$registration_status" -eq 0 ]] && registered=$((registered + 1))
		case "$registration_status" in 0 | 2 | 3 | 4) ;; *) errors=$((errors + 1)) ;; esac
		migration_status=0
		repo_verify_migrate_config "$repo_root" >/dev/null 2>&1 || migration_status=$?
		[[ "$migration_status" -eq 0 ]] && migrated=$((migrated + 1))
		case "$migration_status" in 0 | 2 | 3 | 4) ;; *) errors=$((errors + 1)) ;; esac
		feature_state=$(repo_verify_feature_state "$repo_root")
		if [[ "$feature_state" == "false" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		repo_verify_detect "$repo_root" >/dev/null 2>&1 || true
		if [[ "$REPO_VERIFY_STATUS" != "ready" && "$feature_state" != "true" && "$feature_state" != "legacy" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		hook_output=$(repo_verify_install_hook "$repo_root" 2>&1) || true
		case "$hook_output" in
		*"installed guards:"*) installed=$((installed + 1)) ;;
		*"Refusing to overwrite"* | *"NOT managed"*) conflicts=$((conflicts + 1)) ;;
		*) errors=$((errors + 1)) ;;
		esac
	done <"$repo_list_file"
	rm -f "$repo_list_file"
	print_info "Repo verify guard: installed=$installed registered=$registered migrated=$migrated skipped=$skipped conflict=$conflicts err=$errors"
	if [[ "$errors" -gt 0 ]]; then
		print_warning "Repo verify rollout incomplete: $errors persistent-state or hook installation error(s)"
		return 1
	fi
	setup_track_configured "Repo verify guard (${installed} repos, ${registered} registrations, ${migrated} config migrations)"
	return 0
}
