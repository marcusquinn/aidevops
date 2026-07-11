#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared evidence-based repository verify detection and configuration helpers.

[[ -n "${_AIDEVOPS_REPO_VERIFY_CONFIG_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_REPO_VERIFY_CONFIG_LIB_LOADED=1

REPO_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || REPO_VERIFY_LIB_DIR=""
REPO_VERIFY_STATUS="none"
REPO_VERIFY_SOURCE=""
REPO_VERIFY_EVIDENCE=""
REPO_VERIFY_FORMAT=""
REPO_VERIFY_FORMAT_FIX=""
REPO_VERIFY_LINT=""
REPO_VERIFY_LINT_FIX=""
REPO_VERIFY_TYPECHECK=""
REPO_VERIFY_WARNING=""

repo_verify_reset() {
	REPO_VERIFY_STATUS="none"
	REPO_VERIFY_SOURCE=""
	REPO_VERIFY_EVIDENCE=""
	REPO_VERIFY_FORMAT=""
	REPO_VERIFY_FORMAT_FIX=""
	REPO_VERIFY_LINT=""
	REPO_VERIFY_LINT_FIX=""
	REPO_VERIFY_TYPECHECK=""
	REPO_VERIFY_WARNING=""
	return 0
}

_repo_verify_has_commands() {
	if [[ -n "$REPO_VERIFY_FORMAT$REPO_VERIFY_LINT$REPO_VERIFY_TYPECHECK" ]]; then
		return 0
	fi
	return 1
}

_repo_verify_load_explicit() {
	local repo_root="$1"
	local config_file="${repo_root}/.aidevops.json"
	[[ -f "$config_file" ]] || return 1
	if ! jq -e 'type == "object"' "$config_file" >/dev/null 2>&1; then
		REPO_VERIFY_STATUS="invalid"
		REPO_VERIFY_WARNING=".aidevops.json is not valid JSON"
		return 2
	fi
	if [[ "$(jq -r '.verify.enabled == false' "$config_file")" == "true" ]]; then
		REPO_VERIFY_STATUS="disabled"
		REPO_VERIFY_SOURCE="aidevops-json"
		REPO_VERIFY_EVIDENCE=".aidevops.json:verify.enabled=false"
		return 0
	fi
	REPO_VERIFY_FORMAT=$(jq -r '.verify.format // empty' "$config_file")
	REPO_VERIFY_FORMAT_FIX=$(jq -r '.verify.format_fix // empty' "$config_file")
	REPO_VERIFY_LINT=$(jq -r '.verify.lint // empty' "$config_file")
	REPO_VERIFY_LINT_FIX=$(jq -r '.verify.lint_fix // empty' "$config_file")
	REPO_VERIFY_TYPECHECK=$(jq -r '.verify.typecheck // empty' "$config_file")
	if _repo_verify_has_commands; then
		REPO_VERIFY_STATUS="ready"
		REPO_VERIFY_SOURCE="aidevops-json"
		REPO_VERIFY_EVIDENCE=".aidevops.json:verify"
		return 0
	fi
	return 1
}

_repo_verify_package_manager() {
	local repo_root="$1"
	local count=0 manager="npm"
	if [[ -f "${repo_root}/pnpm-lock.yaml" ]]; then
		count=$((count + 1))
		manager="pnpm"
	fi
	if [[ -f "${repo_root}/yarn.lock" ]]; then
		count=$((count + 1))
		manager="yarn"
	fi
	if [[ -f "${repo_root}/bun.lock" || -f "${repo_root}/bun.lockb" ]]; then
		count=$((count + 1))
		manager="bun"
	fi
	if [[ -f "${repo_root}/package-lock.json" || -f "${repo_root}/npm-shrinkwrap.json" ]]; then
		count=$((count + 1))
		manager="npm"
	fi
	if [[ "$count" -gt 1 ]]; then
		return 2
	fi
	printf '%s\n' "$manager"
	return 0
}

_repo_verify_load_package() {
	local repo_root="$1"
	local package_file="${repo_root}/package.json"
	[[ -f "$package_file" ]] || return 1
	jq -e 'type == "object" and (.scripts | type == "object")' "$package_file" >/dev/null 2>&1 || return 1
	local script_keys=""
	script_keys=$(jq -r '[.scripts | to_entries[] | select(.value | type == "string" and length > 0) | .key] | join(" ")' "$package_file" 2>/dev/null || true)
	case " $script_keys " in
	*" lint "* | *" format "* | *" format:check "* | *" format-check "* | *" typecheck "* | *" type-check "* | *" check-types "*) ;;
	*) return 1 ;;
	esac
	local manager=""
	if ! manager=$(_repo_verify_package_manager "$repo_root"); then
		REPO_VERIFY_STATUS="ambiguous"
		REPO_VERIFY_SOURCE="package-json"
		REPO_VERIFY_EVIDENCE="package.json:scripts"
		REPO_VERIFY_WARNING="multiple package-manager lockfiles"
		return 2
	fi
	local format_body=""
	if jq -e '.scripts."format:check" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT="$manager run format:check"
	elif jq -e '.scripts."format-check" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT="$manager run format-check"
	else
		format_body=$(jq -r '.scripts.format // empty' "$package_file")
		if [[ "$format_body" =~ --check|--check-only|--list-different|--dry-run ]]; then
			REPO_VERIFY_FORMAT="$manager run format"
		fi
	fi
	if jq -e '.scripts."format:fix" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT_FIX="$manager run format:fix"
	elif jq -e '.scripts.format_fix | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT_FIX="$manager run format_fix"
	fi
	if jq -e '.scripts.lint | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT="$manager run lint"
	fi
	if jq -e '.scripts."lint:fix" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT_FIX="$manager run lint:fix"
	elif jq -e '.scripts.lint_fix | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT_FIX="$manager run lint_fix"
	fi
	if jq -e '.scripts.typecheck | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run typecheck"
	elif jq -e '.scripts."type-check" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run type-check"
	elif jq -e '.scripts."check-types" | type == "string" and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run check-types"
	fi
	_repo_verify_has_commands || return 1
	REPO_VERIFY_STATUS="ready"
	REPO_VERIFY_SOURCE="package-json(${manager})"
	REPO_VERIFY_EVIDENCE="package.json:scripts"
	return 0
}

_repo_verify_predicate_matches() {
	local repo_root="$1"
	local predicate="$2"
	case "$predicate" in
	file:*) [[ -f "${repo_root}/${predicate#file:}" ]] || return 1 ;;
	contains:*)
		local payload="${predicate#contains:}"
		local relative_path="${payload%%:*}"
		local needle="${payload#*:}"
		[[ -f "${repo_root}/${relative_path}" ]] && grep -Fq "$needle" "${repo_root}/${relative_path}" 2>/dev/null || return 1
		;;
	*) [[ -f "${repo_root}/${predicate}" ]] || return 1 ;;
	esac
	return 0
}

_repo_verify_load_defaults() {
	local repo_root="$1"
	local defaults_file="${REPO_VERIFY_DEFAULTS_FILE:-${REPO_VERIFY_LIB_DIR}/../configs/repo-verify-defaults.conf}"
	[[ -f "$defaults_file" ]] || return 1
	local line toolchain predicate format format_fix lint lint_fix typecheck
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# || -z "${line//[[:space:]]/}" ]] && continue
		IFS='|' read -r toolchain predicate format format_fix lint lint_fix typecheck <<<"$line"
		toolchain="${toolchain# }"
		toolchain="${toolchain% }"
		predicate="${predicate# }"
		predicate="${predicate% }"
		_repo_verify_predicate_matches "$repo_root" "$predicate" || continue
		format="${format# }"
		format="${format% }"
		format_fix="${format_fix# }"
		format_fix="${format_fix% }"
		lint="${lint# }"
		lint="${lint% }"
		lint_fix="${lint_fix# }"
		lint_fix="${lint_fix% }"
		typecheck="${typecheck# }"
		typecheck="${typecheck% }"
		[[ -n "$format" && "$format" != "-" ]] && REPO_VERIFY_FORMAT="$format"
		[[ -n "$format_fix" && "$format_fix" != "-" ]] && REPO_VERIFY_FORMAT_FIX="$format_fix"
		[[ -n "$lint" && "$lint" != "-" ]] && REPO_VERIFY_LINT="$lint"
		[[ -n "$lint_fix" && "$lint_fix" != "-" ]] && REPO_VERIFY_LINT_FIX="$lint_fix"
		[[ -n "$typecheck" && "$typecheck" != "-" ]] && REPO_VERIFY_TYPECHECK="$typecheck"
		REPO_VERIFY_STATUS="ready"
		REPO_VERIFY_SOURCE="defaults(${toolchain})"
		REPO_VERIFY_EVIDENCE="$predicate"
		return 0
	done <"$defaults_file"
	return 1
}

repo_verify_detect() {
	local repo_root="$1"
	repo_verify_reset
	command -v jq >/dev/null 2>&1 || {
		REPO_VERIFY_STATUS="unavailable"
		REPO_VERIFY_WARNING="jq is required"
		return 1
	}
	_repo_verify_load_explicit "$repo_root"
	local explicit_status=$?
	[[ "$explicit_status" -eq 0 ]] && return 0
	[[ "$explicit_status" -eq 2 ]] && return 1
	_repo_verify_load_package "$repo_root"
	local package_status=$?
	[[ "$package_status" -eq 0 ]] && return 0
	[[ "$package_status" -eq 2 ]] && return 1
	_repo_verify_load_defaults "$repo_root" && return 0
	REPO_VERIFY_STATUS="none"
	return 1
}

repo_verify_emit_json() {
	local repo_root="$1"
	jq -n \
		--arg repo "$repo_root" --arg status "$REPO_VERIFY_STATUS" \
		--arg source "$REPO_VERIFY_SOURCE" --arg evidence "$REPO_VERIFY_EVIDENCE" \
		--arg warning "$REPO_VERIFY_WARNING" --arg format "$REPO_VERIFY_FORMAT" \
		--arg format_fix "$REPO_VERIFY_FORMAT_FIX" --arg lint "$REPO_VERIFY_LINT" \
		--arg lint_fix "$REPO_VERIFY_LINT_FIX" --arg typecheck "$REPO_VERIFY_TYPECHECK" \
		'{repo:$repo,status:$status,source:$source,evidence:$evidence,warning:$warning,verify:{format:$format,format_fix:$format_fix,lint:$lint,lint_fix:$lint_fix,typecheck:$typecheck}}'
	return 0
}

repo_verify_hook_status() {
	local repo_root="$1"
	local common_dir hook_file
	common_dir=$(git -C "$repo_root" rev-parse --git-common-dir 2>/dev/null) || {
		printf 'unavailable\n'
		return 1
	}
	[[ "$common_dir" != /* ]] && common_dir="${repo_root}/${common_dir}"
	hook_file="${common_dir}/hooks/pre-push"
	if [[ ! -f "$hook_file" ]]; then
		printf 'missing\n'
		return 0
	fi
	if grep -q '# aidevops-pre-push-guards' "$hook_file" 2>/dev/null; then
		if grep -q '# guard:repo-verify' "$hook_file" 2>/dev/null; then printf 'installed\n'; else printf 'missing\n'; fi
	else
		printf 'unmanaged-conflict\n'
	fi
	return 0
}

repo_verify_install_hook() {
	local repo_root="$1"
	local installer="${REPO_VERIFY_INSTALLER:-${REPO_VERIFY_LIB_DIR}/install-pre-push-guards.sh}"
	[[ -f "$installer" ]] || return 1
	(cd "$repo_root" && bash "$installer" install --guard repo-verify)
	return $?
}

repo_verify_registration_has_feature() {
	local repo_root="$1"
	local repos_file="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_file" ]] || return 1
	jq -e --arg path "$repo_root" '.initialized_repos[]? | select(.path == $path) | (.features // []) | index("code-quality") != null' "$repos_file" >/dev/null 2>&1 || return 1
	return 0
}

repo_verify_migrate_registration() {
	local repo_root="$1"
	local repos_file="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_file" ]] || return 2
	if [[ -f "${repo_root}/.aidevops.json" ]] &&
		[[ "$(jq -r '.features.code_quality == false or .verify.enabled == false' "${repo_root}/.aidevops.json" 2>/dev/null)" == "true" ]]; then
		return 4
	fi
	repo_verify_registration_has_feature "$repo_root" && return 2
	local temp_file
	temp_file=$(mktemp "${repos_file}.tmp.XXXXXX") || return 1
	if ! jq --arg path "$repo_root" '
		.initialized_repos = [(.initialized_repos // [])[] |
			if .path == $path then .features = (((.features // []) + ["code-quality"]) | unique) else . end]
	' "$repos_file" >"$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	mv "$temp_file" "$repos_file"
	return 0
}

repo_verify_config_is_safe_to_modify() {
	local repo_root="$1"
	local config_file="${repo_root}/.aidevops.json"
	[[ -f "$config_file" ]] || return 0
	if git -C "$repo_root" ls-files --error-unmatch .aidevops.json >/dev/null 2>&1; then
		local branch=""
		branch=$(git -C "$repo_root" branch --show-current 2>/dev/null || true)
		[[ "$branch" != "main" && "$branch" != "master" ]]
		return $?
	fi
	return 0
}

repo_verify_apply_config() {
	local repo_root="$1"
	local create_missing="${2:-false}"
	local config_file="${repo_root}/.aidevops.json"
	if [[ ! -f "$config_file" && "$create_missing" != "true" ]]; then return 2; fi
	repo_verify_config_is_safe_to_modify "$repo_root" || return 3
	if [[ -f "$config_file" ]] && [[ "$(jq -r '.features.code_quality == false or .verify.enabled == false' "$config_file" 2>/dev/null)" == "true" ]]; then
		return 4
	fi
	repo_verify_detect "$repo_root" || return 2
	[[ "$REPO_VERIFY_STATUS" == "ready" ]] || return 2
	local existing='{}'
	[[ -f "$config_file" ]] && existing=$(cat "$config_file")
	local temp_file
	temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || return 1
	if ! jq \
		--arg format "$REPO_VERIFY_FORMAT" --arg format_fix "$REPO_VERIFY_FORMAT_FIX" \
		--arg lint "$REPO_VERIFY_LINT" --arg lint_fix "$REPO_VERIFY_LINT_FIX" \
		--arg typecheck "$REPO_VERIFY_TYPECHECK" \
		'.features = (.features // {}) | .features.code_quality = true |
		 .verify = (.verify // {}) | .verify.enabled = true |
		 if $format != "" and (.verify.format // "") == "" then .verify.format = $format else . end |
		 if $format_fix != "" and (.verify.format_fix // "") == "" then .verify.format_fix = $format_fix else . end |
		 if $lint != "" and (.verify.lint // "") == "" then .verify.lint = $lint else . end |
		 if $lint_fix != "" and (.verify.lint_fix // "") == "" then .verify.lint_fix = $lint_fix else . end |
		 if $typecheck != "" and (.verify.typecheck // "") == "" then .verify.typecheck = $typecheck else . end' \
		<<<"$existing" >"$temp_file"; then
		rm -f "$temp_file"
		return 1
	fi
	mv "$temp_file" "$config_file"
	return 0
}

repo_verify_migrate_config() {
	local repo_root="$1"
	local config_file="${repo_root}/.aidevops.json"
	[[ -f "$config_file" ]] || return 2
	if [[ "$(jq -r 'has("features") and (.features | has("code_quality"))' "$config_file" 2>/dev/null)" == "true" ]]; then
		return 2
	fi
	if repo_verify_registration_has_feature "$repo_root"; then
		repo_verify_config_is_safe_to_modify "$repo_root" || return 3
		local temp_file
		temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || return 1
		jq '.features = (.features // {}) | .features.code_quality = true' "$config_file" >"$temp_file" && mv "$temp_file" "$config_file" || {
			rm -f "$temp_file"
			return 1
		}
		return 0
	fi
	repo_verify_apply_config "$repo_root" false
	return $?
}
