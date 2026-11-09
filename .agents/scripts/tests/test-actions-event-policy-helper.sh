#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Offline test for actions-event-policy-helper.sh using a gh shim.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../actions-event-policy-helper.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fx"
FAILS=0

assert() {
	local name="$1"
	local cond="$2"
	if [[ "$cond" == "0" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		FAILS=$((FAILS + 1))
	fi
	return 0
}

cat >"$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
# Fixture-driven gh shim: maps the endpoint to $FX/<slug-with-underscores>/<name>.
fx="${FX_DIR:?}"
method="GET"
endpoint=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	api) shift ;;
	--method) method="$2"; shift 2 ;;
	-H | --input) shift 2 ;;
	*) endpoint="$1"; shift ;;
	esac
done
if [[ "$method" != "GET" ]]; then
	printf '%s %s\n' "$method" "$endpoint" >>"$fx/writes.log"
	cat >"$fx/last-body.json"
	exit 0
fi
key="${endpoint%%\?*}"
key="${key//\//__}"
if [[ -f "$fx/$key" ]]; then
	cat "$fx/$key"
	exit 0
fi
exit 1
SHIM
chmod +x "$TMP/bin/gh"

wf="repos/o/pub/contents/.github/workflows"
fx="$TMP/fx"
printf '{"default_branch":"main","visibility":"public"}' >"$fx/repos__o__pub"
printf '{"default_branch":"main","visibility":"private"}' >"$fx/repos__o__priv"
printf '{"default_branch":"main","visibility":"public"}' >"$fx/repos__o__none"
printf '[{"type":"file","path":".github/workflows/gate.yml"},{"type":"file","path":".github/workflows/ci.yml"}]' \
	>"$fx/${wf//\//__}"
printf '[{"type":"file","path":".github/workflows/ci.yml"}]' >"$fx/repos__o__none__contents__.github__workflows"
cat >"$fx/${wf//\//__}__gate.yml" <<'YML'
name: gate
on:
  pull_request_target:
    types: [opened]
  issues:
    types: [labeled]
  schedule:
    - cron: "0 0 * * 0"
  workflow_dispatch:
jobs:
  a:
    uses: ./.github/workflows/local.yml
YML
cat >"$fx/${wf//\//__}__ci.yml" <<'YML'
name: ci
on: [push, pull_request]
jobs: {}
YML
cp "$fx/${wf//\//__}__ci.yml" "$fx/repos__o__none__contents__.github__workflows__ci.yml"
printf '{"total_count":0,"policies":[]}' >"$fx/repos__o__pub__actions__policies"

export FX_DIR="$fx"
export PATH="$TMP/bin:$PATH"

"$HELPER" status --repo o/pub >"$TMP/out" 2>&1
assert "status uncovered exits 1" "$([[ $? -eq 1 ]] && echo 0 || echo 1)"
assert "status lists gate.yml only" "$(grep -q 'gate.yml' "$TMP/out" && ! grep -q 'ci.yml' "$TMP/out" && echo 0 || echo 1)"

"$HELPER" plan --repo o/pub >"$TMP/plan.json" 2>&1
plan_rc=$?
assert "plan exits 0" "$plan_rc"
[[ "$plan_rc" -eq 0 ]] || cat "$TMP/plan.json"
assert "plan include is exact path" "$(jq -e '.conditions.workflow_path.include == [".github/workflows/gate.yml"] and .conditions.workflow_path.exclude == []' "$TMP/plan.json" >/dev/null && echo 0 || echo 1)"
assert "plan allowed_events is full union" "$(jq -e '.rules[0].parameters.allowed_events == ["issues","pull_request_target","schedule","workflow_call","workflow_dispatch"]' "$TMP/plan.json" >/dev/null && echo 0 || echo 1)"
assert "plan enforcement active" "$(jq -e '.enforcement == "active" and .name == "aidevops-pull-request-target-gates"' "$TMP/plan.json" >/dev/null && echo 0 || echo 1)"

"$HELPER" status --repo o/priv >/dev/null 2>&1
assert "private repo exits 0" "$?"
"$HELPER" status --repo o/none >/dev/null 2>&1
assert "public repo without event exits 0" "$?"

"$HELPER" apply --repo o/pub >/dev/null 2>&1
assert "apply creates via POST" "$(grep -q '^POST repos/o/pub/actions/policies$' "$fx/writes.log" && echo 0 || echo 1)"

jq -c --slurpfile b "$fx/last-body.json" '{total_count:1, policies:[($b[0] + {id:7})]}' <<<'null' >"$fx/repos__o__pub__actions__policies"
"$HELPER" status --repo o/pub >/dev/null 2>&1
assert "status covered after apply exits 0" "$?"
"$HELPER" apply --repo o/pub >/dev/null 2>&1
assert "apply updates in place via PUT" "$(grep -q '^PUT repos/o/pub/actions/policies/7$' "$fx/writes.log" && echo 0 || echo 1)"

"$HELPER" status --repo 'bad slug' >/dev/null 2>&1
assert "invalid slug exits 2" "$([[ $? -eq 2 ]] && echo 0 || echo 1)"

if [[ "$FAILS" -ne 0 ]]; then
	printf '%s failure(s)\n' "$FAILS"
	exit 1
fi
printf 'all passed\n'
exit 0
