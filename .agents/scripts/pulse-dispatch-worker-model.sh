#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker tier resolution, model selection and model A/B assignment.
# Sourced by pulse-dispatch-worker-launch.sh; uses _DLW_STANDARD_TIER and HEADLESS_RUNTIME_HELPER from the caller.
# Function bodies remain unchanged from the launch orchestrator (GH#28839).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_DISPATCH_WORKER_MODEL_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_MODEL_LOADED=1

#######################################
# Resolve the dispatch tier from labels and select a worker model.
# Populates three module-level globals so the orchestrator can read them
# without the complexity of multi-value stdout parsing (bash 3.2 has no
# namerefs — pattern from GH#18705 decomposition memory lesson):
#   _DLW_DISPATCH_TIER        — cascade tier name: simple|standard|thinking
#   _DLW_DISPATCH_MODEL_TIER  — runtime tier: simple|standard|thinking|bundle tier
#   _DLW_SELECTED_MODEL       — concrete model name, or empty for auto-select
#
# ORDERED HEALTHY MODEL SELECTION (owned by this helper, NOT the caller).
# When model_override is EMPTY, calls headless-runtime-helper.sh select
# --role worker, which resolves the worker model from the routing table /
# local override (respecting backoff DB, auth availability, provider
# allowlists, and configured candidate order). The resolved model name is shown in the
# dispatch comment so the audit trail records exactly which provider/model
# the worker used.
#
# IMPORTANT: Callers MUST NOT pass a model override for default dispatches.
# Only pass model_override when a specific model is required. Passing an
# arbitrary model here bypasses ordered candidate selection and pins that
# model. History: GH#17503 moved model resolution here from the worker.
#
# Arguments: issue_meta_json, model_override, repo_path, issue_title, prompt
#######################################
_dlw_resolve_tier_and_model() {
	local issue_meta_json="$1"
	local model_override="$2"
	local repo_path="${3:-}"
	local issue_title="${4:-}"
	local prompt="${5:-}"

	local issue_labels_csv
	issue_labels_csv=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""
	_DLW_TRUSTED_ISSUE_PRIORITY=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[]?.name | select(startswith("priority:"))][0] // "" | sub("^priority:"; "")' 2>/dev/null || true)
	# shellcheck disable=SC2016 # Backticks are literal optional Markdown delimiters.
	_DLW_TRUSTED_RELEASE_TYPE=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null | sed -nE 's/^\*\*Release scope:\*\*[[:space:]]*`?(patch|minor|major)`?[[:space:]]*$/\1/ip' | sed -n '1p')
	# shellcheck disable=SC2016 # Backticks are literal optional Markdown delimiters.
	_DLW_TRUSTED_DEPLOY_SCOPE=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null | sed -nE 's/^\*\*Deployment scope:\*\*[[:space:]]*`?(incremental|full)`?[[:space:]]*$/\1/ip' | sed -n '1p')
	_dlw_resolve_dispatch_tier "$issue_labels_csv" "$model_override" "$repo_path" "$issue_title" "$prompt"

	_DLW_SELECTED_MODEL=""
	if [[ -n "$model_override" ]]; then
		_DLW_SELECTED_MODEL="$model_override"
	else
		_DLW_SELECTED_MODEL=$("$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$_DLW_DISPATCH_MODEL_TIER" 2>/dev/null) || _DLW_SELECTED_MODEL=""
	fi
	return 0
}

#######################################
# Resolve the dispatch tier only, with no model selection or network call.
# Shared by _dlw_resolve_tier_and_model and the GH#40143 pre-gate deferral.
# Sets _DLW_DISPATCH_TIER and _DLW_DISPATCH_MODEL_TIER (see above).
# Arguments: labels_csv, model_override, repo_path, issue_title, prompt
#######################################
_dlw_resolve_dispatch_tier() {
	local issue_labels_csv="$1"
	local model_override="$2"
	local repo_path="${3:-}"
	local issue_title="${4:-}"
	local prompt="${5:-}"
	local standard_tier="${_DLW_STANDARD_TIER:-standard}"

	_DLW_DISPATCH_TIER="$standard_tier"
	_DLW_DISPATCH_MODEL_TIER="$standard_tier"
	local explicit_tier_label=0
	if _dlw_has_explicit_tier_label "$issue_labels_csv"; then
		explicit_tier_label=1
	fi

	# Resolve tier from labels, preferring highest rank when multiple present (t1997)
	local resolved_tier
	resolved_tier=$(_resolve_worker_tier "$issue_labels_csv")
	case "$resolved_tier" in
	tier:thinking)
		_DLW_DISPATCH_TIER="thinking"
		_DLW_DISPATCH_MODEL_TIER="thinking"
		;;
	tier:standard)
		_DLW_DISPATCH_TIER="$standard_tier"
		_DLW_DISPATCH_MODEL_TIER="$standard_tier"
		;;
	tier:simple)
		_DLW_DISPATCH_TIER="simple"
		_DLW_DISPATCH_MODEL_TIER="simple"
		;;
	esac

	# t1364.6: when issue labels do not force a tier, let project bundles
	# right-size worker model selection for the task type. Explicit model
	# overrides and tier:* labels still win.
	if [[ -z "$model_override" && "$explicit_tier_label" -eq 0 && -n "$repo_path" ]]; then
		local bundle_tier
		bundle_tier=$(_dlw_bundle_model_tier "$repo_path" "$issue_title" "$prompt") || bundle_tier=""
		if [[ -n "$bundle_tier" ]]; then
			_DLW_DISPATCH_TIER="bundle"
			_DLW_DISPATCH_MODEL_TIER="$bundle_tier"
		fi
	fi
	return 0
}

_dlw_assign_model_ab() {
	local repo_slug="$1" issue_number="$2" model_override="$3" issue_meta_json="${4:-}"
	_DLW_AB_ROUTING_TABLE=""
	_DLW_AB_EXPERIMENT=""
	_DLW_AB_ARM=""
	[[ -n "${AIDEVOPS_MODEL_AB_CONFIG:-}" ]] || return 0
	# Candidate dispatch supplies a tier default as an override. Only a model
	# differing from the current labels' default is an explicit A/B bypass.
	if [[ -n "$model_override" ]]; then
		local labels_csv="" tier_default=""
		labels_csv=$(jq -r '[.labels[]?.name] | join(",")' <<<"$issue_meta_json")
		if declare -F resolve_dispatch_model_for_labels >/dev/null; then
			tier_default=$(resolve_dispatch_model_for_labels "$labels_csv")
		fi
		[[ -n "$tier_default" && "$model_override" == "$tier_default" ]] || return 0
	fi
	local ab_json="" ab_helper="${BASH_SOURCE[0]%/*}/model-ab-helper.mjs"
	local -a ab_args=(assign "$repo_slug" "$issue_number")
	local created_at="" labels_json=""
	created_at=$(jq -r '.createdAt // .created_at // empty' <<<"$issue_meta_json") || created_at=""
	labels_json=$(jq -c '[.labels[]?.name]' <<<"$issue_meta_json") || labels_json="[]"
	[[ -z "$created_at" ]] || ab_args+=(--created-at "$created_at" --labels-json "$labels_json")
	# The helper decides whether this tier may start an assignment: standard-only
	# arms treat other tiers as continuation-only; provider-family arms route all.
	local routed_tier=""
	case "$_DLW_DISPATCH_MODEL_TIER" in
	simple | standard | thinking)
		routed_tier="$_DLW_DISPATCH_MODEL_TIER"
		ab_args+=(--tier "$routed_tier")
		;;
	*) ab_args+=(--continuation-only) ;;
	esac
	ab_json=$(node "$ab_helper" "${ab_args[@]}") || return 1
	[[ "$(jq -r '.active' <<<"$ab_json")" == "true" ]] || return 0
	_DLW_AB_ROUTING_TABLE=$(jq -r '.routing_table' <<<"$ab_json") || return 1
	_DLW_AB_EXPERIMENT=$(jq -r '.experiment' <<<"$ab_json") || return 1
	_DLW_AB_ARM=$(jq -r '.arm' <<<"$ab_json") || return 1
	local ab_scope=""
	ab_scope=$(jq -r '.scope // empty' <<<"$ab_json") || ab_scope=""
	[[ "$ab_scope" == "all-tiers" ]] || [[ "$routed_tier" == "$_DLW_STANDARD_TIER" ]] || return 0
	[[ -n "$routed_tier" ]] || return 0
	# Availability selection follows the arm-first table; a failed primary may
	# use its existing same-tier fallback without changing the assigned arm.
	_DLW_SELECTED_MODEL=$(AIDEVOPS_MODEL_ROUTING_TABLE="$_DLW_AB_ROUTING_TABLE" \
		"$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$routed_tier" 2>/dev/null) || _DLW_SELECTED_MODEL=""
	return 0
}

_dlw_append_model_ab_env() {
	[[ -n "${_DLW_AB_ROUTING_TABLE:-}" ]] || return 0
	worker_cmd+=(
		AIDEVOPS_MODEL_ROUTING_TABLE="$_DLW_AB_ROUTING_TABLE"
		AIDEVOPS_MODEL_AB_EXPERIMENT="$_DLW_AB_EXPERIMENT"
		AIDEVOPS_MODEL_AB_ARM="$_DLW_AB_ARM"
	)
	return 0
}

#######################################
# Check whether labels include an explicit worker tier.
# _resolve_worker_tier defaults unlabeled issues to tier:standard, so callers
# need this helper to distinguish an authored tier label from the fallback.
# Arguments:
#   $1 - comma-separated label list
# Returns: 0 when a tier:* label is present, 1 otherwise
#######################################
_dlw_has_explicit_tier_label() {
	local labels_csv="$1"
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	case "$labels_with_commas" in
	*,tier:thinking,* | *,tier:standard,* | *,tier:simple,*) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Resolve the task-specific model tier from the project bundle, if configured.
# Arguments:
#   $1 - repo_path
#   $2 - issue_title
#   $3 - prompt
# Stdout: tier name (empty if unavailable)
#######################################
_dlw_bundle_model_tier() {
	local repo_path="$1"
	local issue_title="${2:-}"
	local prompt="${3:-}"
	local bundle_helper="${_DLW_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/bundle-helper.sh"

	if [[ -z "$repo_path" || ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local workload_type="" tier=""
	workload_type=$(_dlw_bundle_workload_type "$issue_title" "$prompt")
	tier=$("$bundle_helper" get "model_defaults.${workload_type}" "$repo_path" 2>/dev/null) || tier=""
	if [[ -n "$tier" ]]; then
		printf '%s\n' "$tier"
	else
		"$bundle_helper" get model_defaults.implementation "$repo_path" 2>/dev/null || true
	fi
	return 0
}
