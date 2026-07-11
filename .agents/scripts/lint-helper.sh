#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Audit and configure repository-native lint/format/typecheck integration.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/repo-verify-config-lib.sh"

LINT_ACTION="audit"
LINT_REPO=""
LINT_ALL=false
LINT_JSON=false
LINT_STRICT=false
LINT_APPLY=false
LINT_INSTALL_HOOK=true
LINT_WRITE_PR_PLAN=false
readonly LINT_TRUE="true"
readonly LINT_REPO_LIST_ERROR="Unable to read repository list"

lint_usage() {
	cat <<'EOF'
Usage: aidevops lint [audit|configure] [options]

Audit options:
  --repo PATH       Audit one repository (default: current repository)
  --all             Audit every repository registered in repos.json
  --json            Emit machine-readable JSON
  --strict          Exit non-zero when actionable gaps are found

Configure options:
  --repo PATH       Configure one repository (default: current repository)
  --all             Produce a safe plan for every registered repository
  --apply           Apply exact detected configuration in the current repo
  --no-hook         Do not install/refresh the repo-verify pre-push hook
  --write-pr-plan   With --all, write worker-ready PR plans; never edit canonical repos
  --dry-run         Explicitly retain the default preview-only behaviour
EOF
	return 0
}

lint_parse_args() {
	if [[ "${1:-}" == "audit" || "${1:-}" == "configure" || "${1:-}" == "reconcile" ]]; then
		LINT_ACTION="$1"
		shift
	fi
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--repo)
			[[ $# -ge 2 && -n "$2" ]] || {
				print_error "--repo requires a path"
				return 2
			}
			LINT_REPO="$2"
			shift 2
			;;
		--all)
			LINT_ALL=true
			shift
			;;
		--json)
			LINT_JSON=true
			shift
			;;
		--strict)
			LINT_STRICT=true
			shift
			;;
		--apply)
			LINT_APPLY=true
			shift
			;;
		--no-hook)
			LINT_INSTALL_HOOK=false
			shift
			;;
		--install-hook)
			LINT_INSTALL_HOOK=true
			shift
			;;
		--write-pr-plan)
			LINT_WRITE_PR_PLAN=true
			shift
			;;
		--dispatch-prs)
			print_error "--dispatch-prs is not implemented; use --write-pr-plan for a safe worker-ready plan"
			return 2
			;;
		--dry-run)
			LINT_APPLY=false
			shift
			;;
		-h | --help | help)
			lint_usage
			exit 0
			;;
		*)
			print_error "Unknown lint option: $option"
			lint_usage
			return 2
			;;
		esac
	done
	if [[ "$LINT_ALL" == "$LINT_TRUE" && -n "$LINT_REPO" ]]; then
		print_error "--all and --repo are mutually exclusive"
		return 2
	fi
	if [[ "$LINT_ALL" == "$LINT_TRUE" && "$LINT_APPLY" == "$LINT_TRUE" ]]; then
		print_error "--all --apply is unsafe; use --write-pr-plan to create isolated PR plans"
		return 2
	fi
	if [[ "$LINT_WRITE_PR_PLAN" == "$LINT_TRUE" && "$LINT_ALL" != "$LINT_TRUE" ]]; then
		print_error "--write-pr-plan requires --all"
		return 2
	fi
	return 0
}

lint_registered_feature_state() {
	local repo_root="$1"
	repo_verify_feature_state "$repo_root"
	return 0
}

lint_classification() {
	local feature_state="$1"
	local hook_state="$2"
	if [[ "$feature_state" == "false" || "$REPO_VERIFY_STATUS" == "disabled" ]]; then
		printf 'EXPLICITLY-DISABLED\n'
		return 0
	fi
	if [[ "$REPO_VERIFY_STATUS" == "invalid" ]]; then
		printf 'CONFIG-INVALID\n'
		return 0
	fi
	if [[ "$REPO_VERIFY_STATUS" == "ambiguous" ]]; then
		printf 'VERIFY-AMBIGUOUS\n'
		return 0
	fi
	if [[ "$REPO_VERIFY_STATUS" == "none" ]]; then
		printf 'VERIFY-MISSING\n'
		return 0
	fi
	if [[ "$hook_state" == "unmanaged-conflict" ]]; then
		printf 'UNMANAGED-HOOK\n'
		return 0
	fi
	if [[ "$hook_state" != "installed" ]]; then
		printf 'HOOK-MISSING\n'
		return 0
	fi
	if [[ "$feature_state" == "missing" ]]; then
		printf 'FEATURE-MISSING\n'
		return 0
	fi
	printf 'READY\n'
	return 0
}

lint_audit_record() {
	local repo_root="$1"
	local feature_state hook_state classification
	repo_verify_detect "$repo_root" || true
	feature_state=$(lint_registered_feature_state "$repo_root")
	hook_state=$(repo_verify_hook_status "$repo_root" 2>/dev/null || printf 'unavailable')
	classification=$(lint_classification "$feature_state" "$hook_state")
	jq -n --arg repo "$repo_root" --arg classification "$classification" \
		--arg feature "$feature_state" --arg hook "$hook_state" \
		--arg status "$REPO_VERIFY_STATUS" --arg source "$REPO_VERIFY_SOURCE" \
		--arg evidence "$REPO_VERIFY_EVIDENCE" --arg warning "$REPO_VERIFY_WARNING" \
		--arg format "$REPO_VERIFY_FORMAT" --arg format_fix "$REPO_VERIFY_FORMAT_FIX" \
		--arg lint "$REPO_VERIFY_LINT" --arg lint_fix "$REPO_VERIFY_LINT_FIX" \
		--arg typecheck "$REPO_VERIFY_TYPECHECK" \
		'{repo:$repo,classification:$classification,feature:$feature,hook:$hook,detection:{status:$status,source:$source,evidence:$evidence,warning:$warning},verify:{format:$format,format_fix:$format_fix,lint:$lint,lint_fix:$lint_fix,typecheck:$typecheck}}'
	return 0
}

lint_repo_list() {
	if [[ "$LINT_ALL" == "$LINT_TRUE" ]]; then
		local repos_file="${AIDEVOPS_REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
		[[ -f "$repos_file" ]] || return 1
		jq -r '.initialized_repos[]?.path // empty' "$repos_file"
		return 0
	fi
	local target="${LINT_REPO:-$PWD}"
	target=$(cd "$target" 2>/dev/null && pwd) || return 1
	printf '%s\n' "$target"
	return 0
}

lint_audit() {
	local records_file repo_list_file actionable=0 repo_root record classification
	records_file=$(mktemp)
	repo_list_file=$(mktemp)
	if ! lint_repo_list >"$repo_list_file"; then
		rm -f "$records_file" "$repo_list_file"
		print_error "$LINT_REPO_LIST_ERROR"
		return 1
	fi
	while IFS= read -r repo_root; do
		[[ -d "$repo_root" ]] || continue
		record=$(lint_audit_record "$repo_root")
		printf '%s\n' "$record" >>"$records_file"
		classification=$(printf '%s' "$record" | jq -r '.classification')
		case "$classification" in
		READY | EXPLICITLY-DISABLED) ;;
		*) actionable=$((actionable + 1)) ;;
		esac
	done <"$repo_list_file"
	if [[ "$LINT_JSON" == "$LINT_TRUE" ]]; then
		jq -s '.' "$records_file"
	else
		printf '%-22s %-18s %-12s %s\n' "CLASSIFICATION" "VERIFY SOURCE" "HOOK" "REPOSITORY"
		jq -r '. | [.classification, (.detection.source // "none"), .hook, .repo] | @tsv' "$records_file" |
			while IFS=$'\t' read -r classification source hook repo; do
				printf '%-22s %-18s %-12s %s\n' "$classification" "${source:-none}" "$hook" "$repo"
			done
		printf '\nActionable repositories: %s\n' "$actionable"
	fi
	rm -f "$records_file" "$repo_list_file"
	if [[ "$LINT_STRICT" == "$LINT_TRUE" && "$actionable" -gt 0 ]]; then
		return 1
	fi
	return 0
}

lint_write_dispatch_plan() {
	local records_file="$1"
	local plan_dir="${HOME}/.aidevops/.agent-workspace/work"
	local temp_file plan_file
	mkdir -p "$plan_dir"
	temp_file=$(mktemp "${plan_dir}/lint-configure-pr-plan.XXXXXX") || return 1
	plan_file="${temp_file}.json"
	jq '[.[] | select(.classification != "READY" and .classification != "EXPLICITLY-DISABLED") |
		{repo:.repo,classification:.classification,evidence:.detection.evidence,
		files:[".aidevops.json",".gitignore"],
		worker_brief:"Run aidevops lint configure --apply in an isolated linked worktree; preserve opt-outs and unknown keys; commit only tracked policy changes; verify native lint/typecheck; open a PR."}]' \
		"$records_file" >"$temp_file" || {
		rm -f "$temp_file"
		return 1
	}
	chmod 600 "$temp_file"
	mv "$temp_file" "$plan_file"
	printf 'Worker-ready PR plan written: %s\n' "$plan_file" >&2
	return 0
}

lint_configure_all() {
	local records_file repo_list_file repo_root
	records_file=$(mktemp)
	repo_list_file=$(mktemp)
	if ! lint_repo_list >"$repo_list_file"; then
		rm -f "$records_file" "$repo_list_file"
		print_error "$LINT_REPO_LIST_ERROR"
		return 1
	fi
	while IFS= read -r repo_root; do
		[[ -d "$repo_root" ]] || continue
		lint_audit_record "$repo_root" >>"$records_file"
	done <"$repo_list_file"
	local array_file
	array_file=$(mktemp)
	jq -s '.' "$records_file" >"$array_file"
	if [[ "$LINT_JSON" == "$LINT_TRUE" ]]; then
		jq '.' "$array_file"
	else
		jq -r '.[] | "\(.classification)\t\(.repo)\t\(.detection.evidence)"' "$array_file"
	fi
	if [[ "$LINT_WRITE_PR_PLAN" == "$LINT_TRUE" ]]; then
		lint_write_dispatch_plan "$array_file"
	fi
	rm -f "$records_file" "$repo_list_file" "$array_file"
	return 0
}

lint_configure_current() {
	local repo_root
	repo_root=$(lint_repo_list)
	repo_verify_detect "$repo_root" || true
	if [[ "$LINT_APPLY" != "$LINT_TRUE" ]]; then
		lint_audit_record "$repo_root"
		printf 'Dry run only. Re-run with --apply to write exact detected commands.\n' >&2
		return 0
	fi
	local apply_status=0
	repo_verify_apply_config "$repo_root" true || apply_status=$?
	case "$apply_status" in
	0) print_success "Configured repository verify policy from ${REPO_VERIFY_EVIDENCE}" ;;
	2) print_warning "No exact verify commands detected; configuration unchanged" ;;
	3)
		print_error "Tracked .aidevops.json cannot be changed in the canonical worktree; use a linked worktree PR"
		return 1
		;;
	4) print_info "Explicit code-quality/verify opt-out preserved" ;;
	*)
		print_error "Failed to configure repository verify policy"
		return 1
		;;
	esac
	if [[ "$LINT_INSTALL_HOOK" == "$LINT_TRUE" && "$apply_status" -eq 0 ]]; then
		repo_verify_install_hook "$repo_root" || print_warning "Repo-verify hook could not be installed; inspect unmanaged hook conflicts"
	fi
	return 0
}

lint_reconcile() {
	local repo_root registration_status migration_status feature_state hook_status repo_list_file
	local registered=0 migrated=0 installed=0 skipped=0 failed=0
	LINT_ALL=true
	repo_list_file=$(mktemp)
	if ! lint_repo_list >"$repo_list_file"; then
		rm -f "$repo_list_file"
		print_error "$LINT_REPO_LIST_ERROR"
		return 1
	fi
	while IFS= read -r repo_root; do
		[[ -n "$repo_root" && -e "$repo_root/.git" ]] || {
			skipped=$((skipped + 1))
			continue
		}
		registration_status=0
		repo_verify_migrate_registration "$repo_root" >/dev/null 2>&1 || registration_status=$?
		[[ "$registration_status" -eq 0 ]] && registered=$((registered + 1))
		case "$registration_status" in
		0 | 2 | 4) ;;
		*) failed=$((failed + 1)) ;;
		esac
		migration_status=0
		repo_verify_migrate_config "$repo_root" >/dev/null 2>&1 || migration_status=$?
		[[ "$migration_status" -eq 0 ]] && migrated=$((migrated + 1))
		case "$migration_status" in
		0 | 2 | 4) ;;
		*) failed=$((failed + 1)) ;;
		esac
		feature_state=$(lint_registered_feature_state "$repo_root")
		if [[ "$feature_state" == "false" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		repo_verify_detect "$repo_root" >/dev/null 2>&1 || true
		if [[ "$REPO_VERIFY_STATUS" != "ready" && "$feature_state" != "$LINT_TRUE" && "$feature_state" != "legacy" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		hook_status=$(repo_verify_hook_status "$repo_root" 2>/dev/null || printf 'unavailable')
		if [[ "$hook_status" == "installed" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		if repo_verify_install_hook "$repo_root" >/dev/null 2>&1; then
			installed=$((installed + 1))
		else
			failed=$((failed + 1))
		fi
	done <"$repo_list_file"
	rm -f "$repo_list_file"
	printf 'Lint reconciliation: registered=%s migrated=%s installed=%s skipped=%s failed=%s\n' "$registered" "$migrated" "$installed" "$skipped" "$failed"
	[[ "$failed" -eq 0 ]] || return 1
	return 0
}

main() {
	lint_parse_args "$@" || return $?
	command -v jq >/dev/null 2>&1 || {
		print_error "jq is required"
		return 1
	}
	case "$LINT_ACTION" in
	audit) lint_audit ;;
	configure)
		if [[ "$LINT_ALL" == "$LINT_TRUE" ]]; then
			lint_configure_all
		else
			lint_configure_current
		fi
		;;
	reconcile) lint_reconcile ;;
	*)
		lint_usage
		return 2
		;;
	esac
	return $?
}

main "$@"
