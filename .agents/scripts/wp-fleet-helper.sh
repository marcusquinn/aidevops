#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Private, explicitly approved WordPress plugin fleet operations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
exec python3 "${SCRIPT_DIR}/wp-fleet-runner.py" "$@"
