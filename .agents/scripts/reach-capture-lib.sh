#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Reach Capture Library
# =============================================================================
# Capture request parsing, artifact materialization, and performance telemetry.
#
# Usage: source "${SCRIPT_DIR}/reach-capture-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (when available)
#   - reach-helper.sh constants sourced before this library in normal use
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_REACH_CAPTURE_LIB_LOADED:-}" ]] && return 0
_REACH_CAPTURE_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi


# --- Sub-libraries ---

# shellcheck source=./reach-capture-materialize-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-capture-materialize-lib.sh"

# shellcheck source=./reach-capture-performance-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/reach-capture-performance-lib.sh"

