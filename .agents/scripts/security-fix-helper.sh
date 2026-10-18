#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Interactive only: deterministic actions live beside the value-free auditor.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
if [[ ! -t 0 || ! -t 1 || "${FULL_LOOP_HEADLESS:-false}" == "true" ||
	"${AIDEVOPS_HEADLESS:-0}" == "1" || "${AIDEVOPS_HEADLESS:-false}" == "true" || -n "${WORKER_ISSUE_NUMBER:-}" ||
	-n "${AIDEVOPS_HEADLESS_SESSION:-}" ]]; then
	printf '%s\n' 'security fix requires an interactive terminal, outside a headless session.' \
		'Use: aidevops secret audit-credentials; import-credentials; prune-plaintext --dry-run; set NAME' >&2
	exit 1
fi
exec python3 "${SCRIPT_DIR}/credential_audit.py" fix "$SCRIPT_DIR"
