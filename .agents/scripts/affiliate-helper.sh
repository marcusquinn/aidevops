#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Offline affiliate CLI; never performs a network request or submits a form.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/shared-constants.sh"
main() {
	python3 "${SCRIPT_DIR}/affiliate_ledger.py" "$@"
	return 0
}
main "$@"
