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

resolve_dispatch_model_for_labels() {
	local labels_csv="$1"
	local tier=""
	local resolved_model=""

	# Tier label resolution — tier:thinking is backward-compat alias for tier:reasoning
	case ",${labels_csv}," in
	*,tier:reasoning,* | *,tier:thinking,*) tier="opus" ;;
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
