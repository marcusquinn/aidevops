#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/work"
cp "$REPO_DIR/.agents/scripts/session-distill-helper.sh" "$TMP_DIR/work/"
cat >"$TMP_DIR/work/shared-constants.sh" <<'EOF'
log_info() { return 0; }
log_success() { return 0; }
log_warn() { return 0; }
log_error() { return 0; }
EOF
cat >"$TMP_DIR/work/memory-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MEMORY_CALLS:?}"
[[ "${FAIL_MEMORY:-0}" == 0 ]]
EOF
cat >"$TMP_DIR/work/session-checkpoint-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf 'checkpoint-ok\n'
EOF
chmod +x "$TMP_DIR/work/"*.sh

cat >"$TMP_DIR/input.json" <<'EOF'
[
  {"type":"USER_PREFERENCE","content":"Email me at person@example.com and use concise summaries","tags":"preference","explicit":true,"risk":"low"},
  {"type":"DECISION","content":"Inferred deployment choice at /Users/example/private","tags":"decision","explicit":false,"risk":"consequential"}
]
EOF

export AIDEVOPS_WORKSPACE="$TMP_DIR/workspace"
export AIDEVOPS_SESSION_ID="session-27308"
export AIDEVOPS_OBSERVATION_SOURCE="conversation:turns-1-20"
export MEMORY_CALLS="$TMP_DIR/memory-calls"

"$TMP_DIR/work/session-distill-helper.sh" propose "$TMP_DIR/input.json" >/dev/null
ledger="$AIDEVOPS_WORKSPACE/sessions/session-27308/observation-proposals.json"
[[ -f "$ledger" ]] || fail "proposal ledger missing"
[[ "$(jq '.items | length' "$ledger")" == 2 ]] || fail "proposal count"
jq -e '.items[0].content | contains("[email]")' "$ledger" >/dev/null || fail "email not redacted"
jq -e '.items[1].content | contains("[local-path]")' "$ledger" >/dev/null || fail "path not redacted"

"$TMP_DIR/work/session-distill-helper.sh" propose "$TMP_DIR/input.json" >/dev/null
[[ "$(jq '.items | length' "$ledger")" == 2 ]] || fail "proposal idempotency"

FAIL_MEMORY=1 "$TMP_DIR/work/session-distill-helper.sh" finalize >/dev/null 2>&1 && fail "failed finalization returned success"
[[ "$(jq -r '.items[0].state' "$ledger")" == pending_review ]] || fail "failed item state changed"
[[ -f "$TMP_DIR/input.json" ]] || fail "pending input deleted"

: >"$MEMORY_CALLS"
"$TMP_DIR/work/session-distill-helper.sh" finalize >/dev/null
[[ "$(jq -r '.items[0].state' "$ledger")" == finalized ]] || fail "eligible preference not finalized"
[[ "$(jq -r '.items[1].state' "$ledger")" == pending_review ]] || fail "consequential proposal finalized"
[[ "$(wc -l <"$MEMORY_CALLS" | tr -d ' ')" == 1 ]] || fail "unexpected durable stores"
"$TMP_DIR/work/session-distill-helper.sh" finalize >/dev/null
[[ "$(wc -l <"$MEMORY_CALLS" | tr -d ' ')" == 1 ]] || fail "finished item retried"

printf 'PASS: session finalization proposals are private, resumable, and selective\n'
