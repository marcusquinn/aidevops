#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-simplification.sh — Codebase simplification subsystem orchestrator.
#
# Thin orchestrator that sources focused sub-libraries. All function
# implementations live in the sub-libraries; this file provides the
# include guard, SCRIPT_DIR fallback, and source calls.
#
# Sub-libraries (sourced in dependency order):
#   - pulse-simplification-scan.sh       — interval checks, repo discovery,
#     tree-hash detection, LLM sweep, violation collection, issue dedup,
#     permission gate, git pull helpers
#   - pulse-simplification-review.sh     — CodeRabbit codebase review,
#     post-merge review scanner, auto-decomposer scanner
#   - pulse-simplification-issues.sh     — issue body building and GitHub
#     issue creation for shell and markdown complexity findings
#   - pulse-simplification-orchestration.sh — dedup cleanup, CI nesting,
#     state refresh, per-language scan adapters, weekly scan orchestrator
#
# Previously extracted from pulse-wrapper.sh in Phase 6 of the phased
# decomposition (parent: GH#18356). Split into sub-libraries in GH#21306
# (parent #21146) to drop below the 1500-line file-size-debt threshold.
#
# Functions moved to pulse-simplification-state.sh (t2020, GH#18483):
#   - _simplification_state_check
#   - _simplification_state_record
#   - _simplification_state_refresh
#   - _simplification_state_prune
#   - _simplification_state_push
#   - _create_requeue_issue
#   - _simplification_state_backfill_closed
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / COMPLEXITY_* / SIMPLIFICATION_*
# configuration constants in the bootstrap section.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_SIMPLIFICATION_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# --- Source sub-libraries (dependency order) ---

# Core scanning infrastructure (interval checks, tree hash, LLM sweep, dedup helpers)
# shellcheck source=./pulse-simplification-scan.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-simplification-scan.sh"

# Review scanners (CodeRabbit, post-merge, auto-decomposer)
# shellcheck source=./pulse-simplification-review.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-simplification-review.sh"

# Issue creation for shell and markdown findings
# shellcheck source=./pulse-simplification-issues.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-simplification-issues.sh"

# Orchestration: dedup cleanup, CI nesting, weekly scan
# shellcheck source=./pulse-simplification-orchestration.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-simplification-orchestration.sh"
