#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
REMOTE_HELPER="$REPO_ROOT/.agents/scripts/vault-remote-control-helper.sh"
MESSAGE_HELPER="$REPO_ROOT/.agents/scripts/vault-message-helper.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

controller_dir="$tmp_root/controller-vault"
target_dir="$tmp_root/target-vault"
transport_repo="$tmp_root/public-transport"
target_public="$tmp_root/target-public.json"
revoked_file="$tmp_root/revoked.json"
mkdir -p "$controller_dir" "$target_dir" "$transport_repo"
chmod 700 "$controller_dir" "$target_dir"

"$MESSAGE_HELPER" init --vault-dir "$controller_dir" >/dev/null
"$MESSAGE_HELPER" init --vault-dir "$target_dir" >/dev/null
"$MESSAGE_HELPER" public --vault-dir "$target_dir" --output "$target_public"

controller_device="$(python3 - "$controller_dir/message-device.json" <<'PY'
from __future__ import annotations
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["device_id"])
PY
)"
target_device="$(python3 - "$target_dir/message-device.json" <<'PY'
from __future__ import annotations
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["device_id"])
PY
)"

"$REMOTE_HELPER" trust-controller --vault-dir "$target_dir" --controller-device "$controller_device" --policy request-only >/dev/null
lock_id="$("$REMOTE_HELPER" send-lock --vault-dir "$controller_dir" --recipient "$target_public" --repo "$transport_repo" --target-device "$target_device" --reason "test lock")"
if [[ ! "$lock_id" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "lock command id is not opaque hex" >&2
	exit 1
fi

lock_result="$($REMOTE_HELPER receive --vault-dir "$target_dir" --repo "$transport_repo")"
if [[ "$lock_result" != *'"processed_count": 1'* || "$lock_result" != *'"result": "locked"'* ]]; then
	printf '%s\n' "trusted lock command was not processed" >&2
	exit 1
fi

set +e
"$REMOTE_HELPER" receive --vault-dir "$target_dir" --repo "$transport_repo" >/dev/null 2>"$tmp_root/replay.err"
replay_rc=$?
set -e
if [[ "$replay_rc" -eq 0 ]] || ! grep -q "VAULT_REMOTE_REPLAY" "$tmp_root/replay.err"; then
	printf '%s\n' "replay command was not rejected with a stable code" >&2
	exit 1
fi

stale_repo="$tmp_root/stale-transport"
mkdir -p "$stale_repo"
"$REMOTE_HELPER" send-lock --vault-dir "$controller_dir" --recipient "$target_public" --repo "$stale_repo" --target-device "$target_device" --reason "stale lock" --ttl 1 >/dev/null
sleep 2
rm -rf "$target_dir/message-encrypted-inbox"
rm -f "$target_dir/message-replay-cache.json" "$target_dir/message-inbox.json"
set +e
"$REMOTE_HELPER" receive --vault-dir "$target_dir" --repo "$stale_repo" >/dev/null 2>"$tmp_root/stale.err"
stale_rc=$?
set -e
if [[ "$stale_rc" -eq 0 ]] || ! grep -q "VAULT_MESSAGE_EXPIRED" "$tmp_root/stale.err"; then
	printf '%s\n' "stale command was not rejected before processing" >&2
	exit 1
fi

set +e
"$REMOTE_HELPER" send-unlock-grant --vault-dir "$controller_dir" --recipient "$target_public" --repo "$transport_repo" --target-device "$target_device" --reason "remote unlock" >/dev/null 2>"$tmp_root/sudo.err"
sudo_rc=$?
set -e
if [[ "$sudo_rc" -eq 0 ]] || ! grep -Eq "VAULT_REMOTE_(SUDO|TTY)_REQUIRED" "$tmp_root/sudo.err"; then
	printf '%s\n' "remote unlock grant did not require sudo and hidden TTY" >&2
	exit 1
fi

set +e
AIDEVOPS_VAULT_PASSPHRASE="wrong-passphrase" "$REMOTE_HELPER" send-unlock-grant --vault-dir "$controller_dir" --recipient "$target_public" --repo "$transport_repo" --target-device "$target_device" --reason "remote unlock" >/dev/null 2>"$tmp_root/passphrase.err"
passphrase_rc=$?
set -e
if [[ "$passphrase_rc" -eq 0 ]] || ! grep -Eq "VAULT_REMOTE_(SECRET_ENV_DENIED|SUDO_REQUIRED|TTY_REQUIRED)" "$tmp_root/passphrase.err"; then
	printf '%s\n' "remote unlock did not fail closed when a passphrase-like env var was present" >&2
	exit 1
fi
if grep -q "wrong-passphrase" "$tmp_root/passphrase.err"; then
	printf '%s\n' "remote unlock leaked the passphrase-like value" >&2
	exit 1
fi

python3 - "$controller_dir/message-device.json" "$revoked_file" <<'PY'
from __future__ import annotations
import json, sys
device = json.load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps({"revoked_devices": [device["device_id"]]}, sort_keys=True) + "\n")
PY
revoked_repo="$tmp_root/revoked-transport"
mkdir -p "$revoked_repo"
"$REMOTE_HELPER" send-lock --vault-dir "$controller_dir" --recipient "$target_public" --repo "$revoked_repo" --target-device "$target_device" --reason "revoked lock" >/dev/null
rm -rf "$target_dir/message-encrypted-inbox"
rm -f "$target_dir/message-replay-cache.json" "$target_dir/message-inbox.json"
set +e
"$REMOTE_HELPER" receive --vault-dir "$target_dir" --repo "$revoked_repo" --revoked-devices "$revoked_file" >/dev/null 2>"$tmp_root/revoked.err"
revoked_rc=$?
set -e
if [[ "$revoked_rc" -eq 0 ]] || ! grep -q "VAULT_MESSAGE_REVOKED_DEVICE" "$tmp_root/revoked.err"; then
	printf '%s\n' "revoked controller was not rejected" >&2
	exit 1
fi

printf '%s\n' "vault remote-control helper tests passed"
