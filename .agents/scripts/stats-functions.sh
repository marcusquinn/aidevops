#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-functions.sh - Statistics orchestrator (sources sibling modules)
#
# Originally extracted from pulse-wrapper.sh (t1431). Decomposed into
# three modules via todo/plans/stats-functions-decomposition.md (t2010):
#   - stats-shared.sh          (Phase 1: slug validation, runner role)
#   - stats-quality-sweep.sh   (Phase 2: daily code quality sweeps)
#   - stats-health-dashboard.sh (Phase 3: per-repo health dashboards)
#
# This file is the orchestrator residual. It defines configuration
# constants and sources the three modules in dependency order. Callers
# (stats-wrapper.sh, test harnesses) continue to source only this file.
#
# Dependencies:
#   - shared-constants.sh (sourced by caller)
#   - worker-lifecycle-common.sh (sourced by caller)
#   - gh CLI (GitHub API)
#   - jq (JSON processing)

# Include guard — prevent double-sourcing
[[ -n "${_STATS_FUNCTIONS_LOADED:-}" ]] && return 0
_STATS_FUNCTIONS_LOADED=1

#######################################
# Configuration — stats-specific variables
#
# These were previously defined in pulse-wrapper.sh but are only used
# by the functions in this file. Callers can override via environment.
#######################################
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/stats.log}"
QUALITY_SWEEP_INTERVAL="${QUALITY_SWEEP_INTERVAL:-86400}"
PERSON_STATS_INTERVAL="${PERSON_STATS_INTERVAL:-3600}"
QUALITY_SWEEP_LAST_RUN="${QUALITY_SWEEP_LAST_RUN:-${HOME}/.aidevops/logs/quality-sweep-last-run}"
PERSON_STATS_LAST_RUN="${PERSON_STATS_LAST_RUN:-${HOME}/.aidevops/logs/person-stats-last-run}"
PERSON_STATS_CACHE_DIR="${PERSON_STATS_CACHE_DIR:-${HOME}/.aidevops/logs}"
QUALITY_SWEEP_STATE_DIR="${QUALITY_SWEEP_STATE_DIR:-${HOME}/.aidevops/logs/quality-sweep-state}"
CODERABBIT_ISSUE_SPIKE="${CODERABBIT_ISSUE_SPIKE:-10}"
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"

# Validate numeric config if _validate_int is available (from worker-lifecycle-common.sh)
if type _validate_int &>/dev/null; then
	QUALITY_SWEEP_INTERVAL=$(_validate_int QUALITY_SWEEP_INTERVAL "$QUALITY_SWEEP_INTERVAL" 86400)
	PERSON_STATS_INTERVAL=$(_validate_int PERSON_STATS_INTERVAL "$PERSON_STATS_INTERVAL" 3600)
	CODERABBIT_ISSUE_SPIKE=$(_validate_int CODERABBIT_ISSUE_SPIKE "$CODERABBIT_ISSUE_SPIKE" 10 1)
	SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)
fi

#######################################
# Module sourcing — extract sibling modules in dependency order.
# This file is the orchestrator residual; function definitions live in the
# extracted modules. Callers continue to source only stats-functions.sh.
# Extraction plan: todo/plans/stats-functions-decomposition.md
#######################################
STATS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Phase 1: shared utility functions (slug validation, runner role)
# shellcheck source=stats-shared.sh
source "${STATS_SCRIPT_DIR}/stats-shared.sh"

# Phase 2: daily code quality sweep (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit)
# shellcheck source=stats-quality-sweep.sh
source "${STATS_SCRIPT_DIR}/stats-quality-sweep.sh"

# Phase 3: health dashboard (per-repo pinned issues, person stats, system resources)
# shellcheck source=stats-health-dashboard.sh
source "${STATS_SCRIPT_DIR}/stats-health-dashboard.sh"
