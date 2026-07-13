#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit
HEADLESS_RUNTIME_HELPER=/usr/bin/false

_resolve_worker_tier() {
	local labels_csv="$1"
	printf 'tier:standard\n'
	return 0
}

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-worker-launch.sh"

# shellcheck disable=SC2016 # Backticks are literal Markdown delimiters in the fixture.
trusted_json='{"labels":[{"name":"priority:high"}],"body":"**Release scope:** `minor`\n**Deployment scope:** `full`"}'
_dlw_resolve_tier_and_model "$trusted_json" "test-model" ""
[[ "$_DLW_TRUSTED_ISSUE_PRIORITY" == "high" ]]
[[ "$_DLW_TRUSTED_RELEASE_TYPE" == "minor" ]]
[[ "$_DLW_TRUSTED_DEPLOY_SCOPE" == "full" ]]
printf 'PASS trusted worker priority and explicit release scope propagate\n'

generic_json='{"labels":[{"name":"priority:critical"}],"body":"Please discuss a major release and full deployment."}'
_dlw_resolve_tier_and_model "$generic_json" "test-model" ""
[[ "$_DLW_TRUSTED_ISSUE_PRIORITY" == "critical" ]]
[[ -z "$_DLW_TRUSTED_RELEASE_TYPE" ]]
[[ -z "$_DLW_TRUSTED_DEPLOY_SCOPE" ]]
printf 'PASS generic brief prose does not grant release authority\n'

exit 0
