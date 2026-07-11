#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared evidence-based repository verify detection and configuration helpers.

[[ -n "${_AIDEVOPS_REPO_VERIFY_CONFIG_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_REPO_VERIFY_CONFIG_LIB_LOADED=1

REPO_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || REPO_VERIFY_LIB_DIR=""
readonly REPO_VERIFY_VALUE_TRUE="true"
readonly REPO_VERIFY_VALUE_NONE="none"
readonly REPO_VERIFY_VALUE_READY="ready"
REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_NONE"
REPO_VERIFY_SOURCE=""
REPO_VERIFY_EVIDENCE=""
REPO_VERIFY_FORMAT=""
REPO_VERIFY_FORMAT_FIX=""
REPO_VERIFY_LINT=""
REPO_VERIFY_LINT_FIX=""
REPO_VERIFY_TYPECHECK=""
REPO_VERIFY_WARNING=""
REPO_VERIFY_LOCK_FILE=""
REPO_VERIFY_LOCK_TOKEN=""
REPO_VERIFY_LOCK_PID=""

_repo_verify_lock_acquire() {
	local target_file="$1"
	local attempts=0 owner_pid=""
	command -v python3 >/dev/null 2>&1 || return 1
	REPO_VERIFY_LOCK_FILE="${target_file}.aidevops-lock"
	REPO_VERIFY_LOCK_TOKEN=$(mktemp "${target_file}.aidevops-ready.XXXXXX") || return 1
	rm -f "$REPO_VERIFY_LOCK_TOKEN"
	owner_pid=$(sh -c 'printf "%s\n" "$PPID"') || return 1
	python3 "${REPO_VERIFY_LIB_DIR}/repo-verify-lock.py" "$REPO_VERIFY_LOCK_FILE" "$REPO_VERIFY_LOCK_TOKEN" "$owner_pid" &
	REPO_VERIFY_LOCK_PID=$!
	while [[ ! -f "$REPO_VERIFY_LOCK_TOKEN" ]]; do
		if ! kill -0 "$REPO_VERIFY_LOCK_PID" 2>/dev/null; then
			wait "$REPO_VERIFY_LOCK_PID" 2>/dev/null || true
			REPO_VERIFY_LOCK_FILE=""
			REPO_VERIFY_LOCK_TOKEN=""
			REPO_VERIFY_LOCK_PID=""
			return 1
		fi
		attempts=$((attempts + 1))
		if [[ "$attempts" -ge 120 ]]; then
			kill "$REPO_VERIFY_LOCK_PID" 2>/dev/null || true
			wait "$REPO_VERIFY_LOCK_PID" 2>/dev/null || true
			rm -f "$REPO_VERIFY_LOCK_TOKEN"
			REPO_VERIFY_LOCK_FILE=""
			REPO_VERIFY_LOCK_TOKEN=""
			REPO_VERIFY_LOCK_PID=""
			return 1
		fi
		sleep 0.05
	done
	return 0
}

_repo_verify_lock_release() {
	[[ -n "$REPO_VERIFY_LOCK_TOKEN" ]] && rm -f "$REPO_VERIFY_LOCK_TOKEN"
	[[ -n "$REPO_VERIFY_LOCK_PID" ]] && wait "$REPO_VERIFY_LOCK_PID" 2>/dev/null || true
	REPO_VERIFY_LOCK_FILE=""
	REPO_VERIFY_LOCK_TOKEN=""
	REPO_VERIFY_LOCK_PID=""
	return 0
}

_repo_verify_preserve_mode() {
	local source_file="$1"
	local target_file="$2"
	local mode=""
	[[ -f "$source_file" ]] || return 0
	mode=$(stat -f '%Lp' "$source_file" 2>/dev/null || stat -c '%a' "$source_file" 2>/dev/null || true)
	[[ -n "$mode" ]] && chmod "$mode" "$target_file" 2>/dev/null || true
	return 0
}

repo_verify_reset() {
	REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_NONE"
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

_repo_verify_config_path() {
	local repo_root="$1"
	printf '%s\n' "${repo_root}/.aidevops.json"
	return 0
}

_repo_verify_config_opted_out() {
	local config_file="$1"
	jq -e '.features.code_quality == false or .verify.enabled == false' "$config_file" >/dev/null 2>&1 || return 1
	return 0
}

_repo_verify_config_has_feature_key() {
	local config_file="$1"
	jq -e 'has("features") and (.features | has("code_quality"))' "$config_file" >/dev/null 2>&1 || return 1
	return 0
}

_repo_verify_load_explicit() {
	local repo_root="$1"
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	[[ -f "$config_file" ]] || return 1
	if ! jq -e 'type == ({} | type)' "$config_file" >/dev/null 2>&1; then
		REPO_VERIFY_STATUS="invalid"
		REPO_VERIFY_WARNING=".aidevops.json is not valid JSON"
		return 2
	fi
	if _repo_verify_config_opted_out "$config_file"; then
		REPO_VERIFY_STATUS="disabled"
		REPO_VERIFY_SOURCE="aidevops-json"
		REPO_VERIFY_EVIDENCE=".aidevops.json:explicit-opt-out"
		return 0
	fi
	REPO_VERIFY_FORMAT=$(jq -r '.verify.format // empty' "$config_file")
	REPO_VERIFY_FORMAT_FIX=$(jq -r '.verify.format_fix // empty' "$config_file")
	REPO_VERIFY_LINT=$(jq -r '.verify.lint // empty' "$config_file")
	REPO_VERIFY_LINT_FIX=$(jq -r '.verify.lint_fix // empty' "$config_file")
	REPO_VERIFY_TYPECHECK=$(jq -r '.verify.typecheck // empty' "$config_file")
	if _repo_verify_has_commands; then
		REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_READY"
		REPO_VERIFY_SOURCE="aidevops-json"
		REPO_VERIFY_EVIDENCE=".aidevops.json:verify"
		return 0
	fi
	return 1
}

_repo_verify_package_manager() {
	local repo_root="$1"
	local package_file="${repo_root}/package.json"
	local count=0 manager="npm" declared=""
	declared=$(jq -r '.packageManager // empty | split("@")[0]' "$package_file" 2>/dev/null || true)
	if [[ -f "${repo_root}/pnpm-lock.yaml" ]] && _repo_verify_evidence_is_tracked "$repo_root" "pnpm-lock.yaml"; then
		count=$((count + 1))
		manager="pnpm"
	fi
	if [[ -f "${repo_root}/yarn.lock" ]] && _repo_verify_evidence_is_tracked "$repo_root" "yarn.lock"; then
		count=$((count + 1))
		manager="yarn"
	fi
	if { [[ -f "${repo_root}/bun.lock" ]] && _repo_verify_evidence_is_tracked "$repo_root" "bun.lock"; } ||
		{ [[ -f "${repo_root}/bun.lockb" ]] && _repo_verify_evidence_is_tracked "$repo_root" "bun.lockb"; }; then
		count=$((count + 1))
		manager="bun"
	fi
	if { [[ -f "${repo_root}/package-lock.json" ]] && _repo_verify_evidence_is_tracked "$repo_root" "package-lock.json"; } ||
		{ [[ -f "${repo_root}/npm-shrinkwrap.json" ]] && _repo_verify_evidence_is_tracked "$repo_root" "npm-shrinkwrap.json"; }; then
		count=$((count + 1))
		manager="npm"
	fi
	if [[ "$count" -gt 1 ]]; then
		return 2
	fi
	if [[ -n "$declared" ]]; then
		case "$declared" in npm | pnpm | yarn | bun) ;; *) return 2 ;; esac
		if [[ "$count" -eq 1 && "$declared" != "$manager" ]]; then
			return 2
		fi
		manager="$declared"
	fi
	printf '%s\n' "$manager"
	return 0
}

_repo_verify_format_script_is_check() {
	local script_body="$1"
	if [[ "$script_body" =~ --write|--fix|(^|[[:space:]])-w([[:space:]]|$)|(^|[[:space:]])write([[:space:]]|$) ]]; then
		return 1
	fi
	if [[ "$script_body" =~ --check|--check-only|--list-different|--dry-run ]]; then
		return 0
	fi
	return 1
}

_repo_verify_load_package() {
	local repo_root="$1"
	local package_file="${repo_root}/package.json"
	[[ -f "$package_file" ]] || return 1
	_repo_verify_evidence_is_tracked "$repo_root" "package.json" || return 1
	jq -e 'type == ({} | type) and (.scripts | type == ({} | type))' "$package_file" >/dev/null 2>&1 || return 1
	local script_keys=""
	script_keys=$(jq -r '[.scripts | to_entries[] | select(.value | type == ("" | type) and length > 0) | .key] | join(" ")' "$package_file" 2>/dev/null || true)
	case " $script_keys " in
	*" lint "* | *" format "* | *" format:check "* | *" format-check "* | *" typecheck "* | *" type-check "* | *" check-types "*) ;;
	*) return 1 ;;
	esac
	local manager=""
	if ! manager=$(_repo_verify_package_manager "$repo_root"); then
		REPO_VERIFY_STATUS="ambiguous"
		REPO_VERIFY_SOURCE="package-json"
		REPO_VERIFY_EVIDENCE="package.json:scripts"
		REPO_VERIFY_WARNING="package-manager declaration/lockfiles are ambiguous"
		return 2
	fi
	local format_body=""
	if jq -e '.scripts."format:check" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT="$manager run format:check"
	elif jq -e '.scripts."format-check" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT="$manager run format-check"
	else
		format_body=$(jq -r '.scripts.format // empty' "$package_file")
		if _repo_verify_format_script_is_check "$format_body"; then
			REPO_VERIFY_FORMAT="$manager run format"
		fi
	fi
	if jq -e '.scripts."format:fix" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT_FIX="$manager run format:fix"
	elif jq -e '.scripts.format_fix | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_FORMAT_FIX="$manager run format_fix"
	fi
	if jq -e '.scripts.lint | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT="$manager run lint"
	fi
	if jq -e '.scripts."lint:fix" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT_FIX="$manager run lint:fix"
	elif jq -e '.scripts.lint_fix | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_LINT_FIX="$manager run lint_fix"
	fi
	if jq -e '.scripts.typecheck | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run typecheck"
	elif jq -e '.scripts."type-check" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run type-check"
	elif jq -e '.scripts."check-types" | type == ("" | type) and length > 0' "$package_file" >/dev/null 2>&1; then
		REPO_VERIFY_TYPECHECK="$manager run check-types"
	fi
	_repo_verify_has_commands || return 1
	REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_READY"
	REPO_VERIFY_SOURCE="package-json(${manager})"
	REPO_VERIFY_EVIDENCE="package.json:scripts"
	return 0
}

_repo_verify_predicate_matches() {
	local repo_root="$1"
	local predicate="$2"
	case "$predicate" in
	file:*)
		local file_path="${predicate#file:}"
		[[ -f "${repo_root}/${file_path}" ]] || return 1
		_repo_verify_evidence_is_tracked "$repo_root" "$file_path" || return 1
		;;
	contains:*)
		local payload="${predicate#contains:}"
		local relative_path="${payload%%:*}"
		local needle="${payload#*:}"
		[[ -f "${repo_root}/${relative_path}" ]] && grep -Fq "$needle" "${repo_root}/${relative_path}" 2>/dev/null || return 1
		_repo_verify_evidence_is_tracked "$repo_root" "$relative_path" || return 1
		;;
	section:*)
		local section_payload="${predicate#section:}"
		local section_path="${section_payload%%:*}"
		local section_name="${section_payload#*:}"
		local section_line=""
		[[ -f "${repo_root}/${section_path}" ]] || return 1
		_repo_verify_evidence_is_tracked "$repo_root" "$section_path" || return 1
		while IFS= read -r section_line; do
			section_line="${section_line%%#*}"
			while [[ "$section_line" == *[[:space:]] ]]; do section_line="${section_line%?}"; done
			section_line="${section_line#"${section_line%%[![:space:]]*}"}"
			[[ "$section_line" == "[${section_name}]" ]] && return 0
		done <"${repo_root}/${section_path}"
		return 1
		;;
	*)
		[[ -f "${repo_root}/${predicate}" ]] || return 1
		_repo_verify_evidence_is_tracked "$repo_root" "$predicate" || return 1
		;;
	esac
	return 0
}

_repo_verify_evidence_is_tracked() {
	local repo_root="$1"
	local relative_path="$2"
	git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || return 1
	git -C "$repo_root" ls-files --error-unmatch -- "$relative_path" >/dev/null 2>&1 || return 1
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
		REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_READY"
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
	REPO_VERIFY_STATUS="$REPO_VERIFY_VALUE_NONE"
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

repo_verify_feature_state() {
	local repo_root="$1"
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	if [[ -f "$config_file" ]]; then
		jq -r '
			if (.features.code_quality == false or .verify.enabled == false) then "false"
			elif .features.code_quality == true then "true"
			else "missing" end
		' "$config_file" 2>/dev/null || printf 'invalid\n'
		return 0
	fi
	if repo_verify_registration_has_feature "$repo_root"; then printf 'legacy\n'; else printf 'missing\n'; fi
	return 0
}

repo_verify_migrate_registration() {
	local repo_root="$1"
	local repos_file="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
	[[ -f "$repos_file" ]] || return 2
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	if [[ -f "$config_file" ]] && _repo_verify_config_opted_out "$config_file"; then
		return 4
	fi
	repo_verify_detect "$repo_root" >/dev/null 2>&1 || return 2
	[[ "$REPO_VERIFY_STATUS" == "$REPO_VERIFY_VALUE_READY" ]] || return 2
	_repo_verify_lock_acquire "$repos_file" || return 1
	repo_verify_registration_has_feature "$repo_root" && {
		_repo_verify_lock_release
		return 2
	}
	local temp_file
	temp_file=$(mktemp "${repos_file}.tmp.XXXXXX") || {
		_repo_verify_lock_release
		return 1
	}
	if ! jq --arg path "$repo_root" '
		.initialized_repos = [(.initialized_repos // [])[] |
			if .path == $path then .features = (((.features // []) + ["code-quality"]) | unique) else . end]
	' "$repos_file" >"$temp_file"; then
		rm -f "$temp_file"
		_repo_verify_lock_release
		return 1
	fi
	_repo_verify_preserve_mode "$repos_file" "$temp_file"
	mv "$temp_file" "$repos_file"
	_repo_verify_lock_release
	return 0
}

repo_verify_config_is_safe_to_modify() {
	local repo_root="$1"
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	[[ -f "$config_file" ]] || return 0
	if git -C "$repo_root" ls-files --error-unmatch .aidevops.json >/dev/null 2>&1; then
		local canonical_path="" resolved_repo=""
		canonical_path=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | awk '/^worktree / {sub(/^worktree /, ""); print; exit}')
		resolved_repo=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 1
		[[ -n "$canonical_path" ]] || return 1
		canonical_path=$(cd "$canonical_path" 2>/dev/null && pwd -P) || return 1
		[[ "$resolved_repo" != "$canonical_path" ]] || return 1
	fi
	return 0
}

repo_verify_apply_config() {
	local repo_root="$1"
	local create_missing="${2:-false}"
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	if [[ ! -f "$config_file" && "$create_missing" != "$REPO_VERIFY_VALUE_TRUE" ]]; then return 2; fi
	repo_verify_config_is_safe_to_modify "$repo_root" || return 3
	if [[ -f "$config_file" ]] && _repo_verify_config_opted_out "$config_file"; then
		return 4
	fi
	repo_verify_detect "$repo_root" || return 2
	[[ "$REPO_VERIFY_STATUS" == "$REPO_VERIFY_VALUE_READY" ]] || return 2
	_repo_verify_lock_acquire "$config_file" || return 1
	if [[ -f "$config_file" ]] && _repo_verify_config_opted_out "$config_file"; then
		_repo_verify_lock_release
		return 4
	fi
	local existing='{}'
	[[ -f "$config_file" ]] && existing=$(<"$config_file")
	local temp_file
	temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || {
		_repo_verify_lock_release
		return 1
	}
	if ! jq \
		--arg format "$REPO_VERIFY_FORMAT" --arg format_fix "$REPO_VERIFY_FORMAT_FIX" \
		--arg lint "$REPO_VERIFY_LINT" --arg lint_fix "$REPO_VERIFY_LINT_FIX" \
		--arg typecheck "$REPO_VERIFY_TYPECHECK" \
		'.features = (.features // {}) | .features.code_quality = true |
		 .verify = (.verify // {}) | .verify.enabled = true |
		 if ($format | length) > 0 and ((.verify.format?) | length) == 0 then .verify.format = $format else . end |
		 if ($format_fix | length) > 0 and ((.verify.format_fix?) | length) == 0 then .verify.format_fix = $format_fix else . end |
		 if ($lint | length) > 0 and ((.verify.lint?) | length) == 0 then .verify.lint = $lint else . end |
		 if ($lint_fix | length) > 0 and ((.verify.lint_fix?) | length) == 0 then .verify.lint_fix = $lint_fix else . end |
		 if ($typecheck | length) > 0 and ((.verify.typecheck?) | length) == 0 then .verify.typecheck = $typecheck else . end' \
		<<<"$existing" >"$temp_file"; then
		rm -f "$temp_file"
		_repo_verify_lock_release
		return 1
	fi
	_repo_verify_preserve_mode "$config_file" "$temp_file"
	mv "$temp_file" "$config_file"
	_repo_verify_lock_release
	return 0
}

repo_verify_migrate_config() {
	local repo_root="$1"
	local config_file
	config_file=$(_repo_verify_config_path "$repo_root")
	[[ -f "$config_file" ]] || return 2
	_repo_verify_config_opted_out "$config_file" && return 4
	if _repo_verify_config_has_feature_key "$config_file"; then
		return 2
	fi
	if repo_verify_registration_has_feature "$repo_root"; then
		repo_verify_config_is_safe_to_modify "$repo_root" || return 3
		_repo_verify_lock_acquire "$config_file" || return 1
		if _repo_verify_config_opted_out "$config_file"; then
			_repo_verify_lock_release
			return 4
		fi
		if _repo_verify_config_has_feature_key "$config_file"; then
			_repo_verify_lock_release
			return 2
		fi
		local temp_file
		temp_file=$(mktemp "${config_file}.tmp.XXXXXX") || {
			_repo_verify_lock_release
			return 1
		}
		if jq '.features = (.features // {}) | .features.code_quality = true' "$config_file" >"$temp_file"; then
			_repo_verify_preserve_mode "$config_file" "$temp_file"
			mv "$temp_file" "$config_file"
		else
			rm -f "$temp_file"
			_repo_verify_lock_release
			return 1
		fi
		_repo_verify_lock_release
		return 0
	fi
	repo_verify_apply_config "$repo_root" false
	return $?
}
