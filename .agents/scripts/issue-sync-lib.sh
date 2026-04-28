#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Using /bin/bash directly (not #!/usr/bin/env bash) for compatibility with
# headless environments where a stripped PATH can prevent env from finding bash.
# See issue #2610. This is an intentional exception to the repo's env-bash standard (t135.14).
# =============================================================================
# aidevops Issue Sync Library — Platform-Agnostic Functions (t1120.1)
# =============================================================================
# Orchestrator that sources three focused sub-libraries. Existing callers
# continue to `source issue-sync-lib.sh` and get all functions — the split
# is invisible to consumers.
#
# Sub-libraries:
#   1. issue-sync-lib-parse.sh   — TODO.md / PLANS.md / PRD file parsing
#   2. issue-sync-lib-compose.sh — Tag/label mapping + issue body composition
#   3. issue-sync-lib-ref.sh     — ref:GH# / pr:# management, relationships,
#                                  tier extraction, orphan TODO seeding
#
# Usage: source "${SCRIPT_DIR}/issue-sync-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_verbose, sed_inplace)
#   - bash 3.2+, awk, sed, grep
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced — would affect caller)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_LIB_LOADED:-}" ]] && return 0
_ISSUE_SYNC_LIB_LOADED=1

# Source shared-constants.sh to make the library self-contained.
# Resolves SCRIPT_DIR from BASH_SOURCE so it works when sourced from any location.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
source "${SCRIPT_DIR}/shared-constants.sh"

# --- Source sub-libraries ---

# shellcheck source=./issue-sync-lib-parse.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/issue-sync-lib-parse.sh"

# shellcheck source=./issue-sync-lib-compose.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/issue-sync-lib-compose.sh"

# shellcheck source=./issue-sync-lib-ref.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/issue-sync-lib-ref.sh"
