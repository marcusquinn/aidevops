#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-prefetch.sh — Pre-flight state gathering orchestrator.
#
# Thin orchestrator that sources focused prefetch sub-libraries. Function
# implementations live in the sub-libraries; this file provides the include
# guard, SCRIPT_DIR fallback, and source calls.
#
# Split from the Phase 7 monolith and completed for GH#18400/t1987.

[[ -n "${_PULSE_PREFETCH_LOADED:-}" ]] && return 0
_PULSE_PREFETCH_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_pp_path="${BASH_SOURCE[0]%/*}"
	[[ "$_pp_path" == "${BASH_SOURCE[0]}" ]] && _pp_path="."
	SCRIPT_DIR="$(cd "$_pp_path" && pwd)"
	unset _pp_path
fi

# Source sub-libraries in dependency order.
# shellcheck source=./pulse-prefetch-infra.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-infra.sh"

# shellcheck source=./pulse-prefetch-fetch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-fetch.sh"

# shellcheck source=./pulse-prefetch-repo.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-repo.sh"

# shellcheck source=./pulse-prefetch-orchestration.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-orchestration.sh"

# shellcheck source=./pulse-prefetch-secondary.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-secondary.sh"

# shellcheck source=./pulse-prefetch-workers.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-prefetch-workers.sh"
