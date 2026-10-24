#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Standard-library backend: no dependency bootstrap during session operations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=tabby-python-lib.sh
source "${SCRIPT_DIR}/tabby-python-lib.sh"
python_bin="$(tabby_python 2>/dev/null || command -v python3)" || {
	printf '%s\n' 'Python 3.9+ is required; no packages will be installed' >&2
	exit 1
}
exec "$python_bin" "${SCRIPT_DIR}/tabby_sessions.py" "$@"
