#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-model-routing.sh — Dispatch model resolution from GitHub label CSV.
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _provider_allowed_by_headless_allowlist
#   - _resolve_model_override_label
#   - resolve_dispatch_model_for_labels
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_MODEL_ROUTING_LOADED:-}" ]] && return 0
_PULSE_MODEL_ROUTING_LOADED=1

_provider_allowed_by_headless_allowlist() {
 local provider="$1"
 local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
 local -a allowlist=()
 local allowed_provider=""

 if [[ -z "$allowlist_raw" ]]; then
  return 0
 fi

 IFS=',' read -r -a allowlist <<<"$allowlist_raw"
 for allowed_provider in "${allowlist[@]}"; do
  allowed_provider=$(printf '%s' "$allowed_provider" | sed 's/^ *//;s/ *$//')
  if [[ "$allowed_provider" == "$provider" ]]; then
   return 0
  fi
 done

 return 1
}

_resolve_model_override_label() {
 local labels_csv="$1"
 local override_model=""
 local override_provider=""
 local fallback_tier=""
 local resolved_model=""

 # Model-override labels express intent, not an unconditional provider pin.
 # Prefer the named model when its provider is allowed and the availability
 # helper says it is usable; otherwise fall back through the same tier resolver
 # as normal tier labels.
	case ",${labels_csv}," in
	*,model:opus-4-7,*)
		override_model="${AIDEVOPS_OPUS_ESCALATION_MODEL:-openai/gpt-5.5}"
		fallback_tier="opus"
		;;
 *)
  return 1
  ;;
 esac

 if [[ ! -x "${MODEL_AVAILABILITY_HELPER:-}" ]]; then
  printf '%s' ""
  return 0
 fi

 override_provider="${override_model%%/*}"
 if _provider_allowed_by_headless_allowlist "$override_provider" && \
  "$MODEL_AVAILABILITY_HELPER" check "$override_model" --quiet 2>/dev/null; then
  printf '%s' "$override_model"
  return 0
 fi

 resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve "$fallback_tier" --quiet 2>/dev/null || true)
 printf '%s' "$resolved_model"
 return 0
}

resolve_dispatch_model_for_labels() {
 local labels_csv="$1"
 local tier=""
 local resolved_model=""

 # Model-override labels take precedence over tier:* labels (t2239), but must
 # still resolve through availability/fallback so cooldowns and provider
 # allowlists can route away from unavailable providers.
 resolved_model=$(_resolve_model_override_label "$labels_csv")
 if [[ -n "$resolved_model" ]]; then
  printf '%s' "$resolved_model"
  return 0
 fi

	# Tier label resolution — tier:thinking is the canonical opus-tier label
	case ",${labels_csv}," in
	*,tier:thinking,*) tier="opus" ;;
	*,tier:standard,*) tier="sonnet" ;;
	*,tier:simple,*) tier="haiku" ;;
	esac

	if [[ -z "$tier" || ! -x "$MODEL_AVAILABILITY_HELPER" ]]; then
		printf '%s' ""
		return 0
	fi

	resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve "$tier" --quiet 2>/dev/null || true)
	printf '%s' "$resolved_model"
	return 0
}
