#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPT_DIR}/pulse-dispatch-core.sh"

blocked='{"labels":[{"name":"status:available"},{"name":"needs-maintainer-permissions"}]}'
allowed='{"labels":[{"name":"status:available"},{"name":"auto-dispatch"}]}'

_dispatch_waiting_for_maintainer_permission "$blocked"
if _dispatch_waiting_for_maintainer_permission "$allowed"; then
	printf 'permission gate blocked metadata without the dedicated label\n' >&2
	exit 1
fi

printf 'pulse dispatch permission-gate tests passed\n'
