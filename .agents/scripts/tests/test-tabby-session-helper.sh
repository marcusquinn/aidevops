#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/../shared-constants.sh"
bash "${SCRIPT_DIR}/../tabby-helper.sh" sessions --help
exec python3 "${SCRIPT_DIR}/test-tabby-sessions.py" "$@"
