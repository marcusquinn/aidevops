#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
# shellcheck source=../shared-constants.sh
source "${SCRIPT_DIR}/../shared-constants.sh"
# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPT_DIR}/../pulse-dispatch-worker-launch.sh"

test_root=$(mktemp -d "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/model-ab-dispatch.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
export HOME="$test_root"
export AIDEVOPS_MODEL_AB_CONFIG="${test_root}/experiment.json"
node -e '
const fs = require("node:fs");
const now = Date.now();
fs.writeFileSync(process.argv[1], JSON.stringify({
  id: "worker-test", repo: "example/repo", seed: "test-cohort",
  starts_at: new Date(now - 60000).toISOString(),
  ends_at: new Date(now + 3600000).toISOString(),
  issues: [12, 13], arms: [
    { name: "luna", model: "openai/gpt-6-luna", variant: "max" },
    { name: "terra", model: "openai/gpt-5.6-terra", variant: "low" },
  ],
}));
' "$AIDEVOPS_MODEL_AB_CONFIG"

HEADLESS_RUNTIME_HELPER="${test_root}/select-model.sh"
cat >"$HEADLESS_RUNTIME_HELPER" <<'HELPER'
#!/usr/bin/env bash
[[ "${AIDEVOPS_MODEL_ROUTING_TABLE:-}" == "" ]] && exit 1
jq -er '.tiers.standard.models[0]' "$AIDEVOPS_MODEL_ROUTING_TABLE"
HELPER
chmod +x "$HEADLESS_RUNTIME_HELPER"

_DLW_DISPATCH_MODEL_TIER=standard
_DLW_SELECTED_MODEL="openai/gpt-5.6-terra"
_dlw_assign_model_ab example/repo 12 ""
[[ -f "$_DLW_AB_ROUTING_TABLE" && -n "$_DLW_AB_ARM" && -n "$_DLW_AB_EXPERIMENT" ]]
[[ "$_DLW_SELECTED_MODEL" == "$(jq -r '.tiers.standard.models[0]' "$_DLW_AB_ROUTING_TABLE")" ]]
worker_cmd=(env)
_dlw_append_model_ab_env
[[ " ${worker_cmd[*]} " == *" AIDEVOPS_MODEL_ROUTING_TABLE=${_DLW_AB_ROUTING_TABLE} "* ]]
[[ " ${worker_cmd[*]} " == *" AIDEVOPS_MODEL_AB_ARM=${_DLW_AB_ARM} "* ]]
_DLW_DISPATCH_MODEL_TIER=thinking
_DLW_SELECTED_MODEL="openai/gpt-6-sol"
_dlw_assign_model_ab example/repo 12 ""
[[ "$_DLW_SELECTED_MODEL" == "openai/gpt-6-sol" && -n "$_DLW_AB_ROUTING_TABLE" ]]
_dlw_assign_model_ab example/repo 13 ""
[[ -z "$_DLW_AB_ROUTING_TABLE" && "$_DLW_SELECTED_MODEL" == "openai/gpt-6-sol" ]]
_dlw_assign_model_ab example/repo 12 "explicit/model"
[[ -z "$_DLW_AB_ROUTING_TABLE" && "$_DLW_SELECTED_MODEL" == "openai/gpt-6-sol" ]]
printf 'PASS: issue arm follows worker, but escalation and explicit overrides retain their own model\n'
