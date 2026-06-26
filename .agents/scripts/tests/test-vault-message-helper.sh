#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
MESSAGE_HELPER="$REPO_ROOT/.agents/scripts/vault-message-helper.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

sender_dir="$tmp_root/sender-vault"
recipient_dir="$tmp_root/recipient-vault"
transport_repo="$tmp_root/public-transport"
recipient_public="$tmp_root/recipient-public.json"
message_body="$tmp_root/body.txt"
revoked_file="$tmp_root/revoked.json"

mkdir -p "$sender_dir" "$recipient_dir" "$transport_repo"
chmod 700 "$sender_dir" "$recipient_dir"

"$MESSAGE_HELPER" init --vault-dir "$sender_dir" >/dev/null
"$MESSAGE_HELPER" init --vault-dir "$recipient_dir" >/dev/null
"$MESSAGE_HELPER" public --vault-dir "$recipient_dir" --output "$recipient_public"

printf '%s\n' "operator message with private payload" >"$message_body"
message_id="$("$MESSAGE_HELPER" send --vault-dir "$sender_dir" --recipient "$recipient_public" --class human --body-file "$message_body" --repo "$transport_repo" --pad-bytes 48)"

if [[ ! "$message_id" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "message id is not opaque hex" >&2
	exit 1
fi

if grep -R "operator message\|private payload\|human" "$transport_repo" >/dev/null 2>&1; then
	printf '%s\n' "public transport leaked plaintext body or subject/class" >&2
	exit 1
fi

locked_result="$("$MESSAGE_HELPER" receive --vault-dir "$recipient_dir" --repo "$transport_repo")"
if [[ "$locked_result" != *'"locked": true'* || "$locked_result" != *'"decrypted": 0'* ]]; then
	printf '%s\n' "locked receive did not preserve encrypted-only inbox" >&2
	exit 1
fi

locked_inbox="$("$MESSAGE_HELPER" inbox --vault-dir "$recipient_dir" --json)"
if [[ "$locked_inbox" != *'"encrypted_count": 1'* || "$locked_inbox" != *'"decrypted_count": 0'* ]]; then
	printf '%s\n' "locked inbox counts are incorrect" >&2
	exit 1
fi

rm -f "$recipient_dir/message-replay-cache.json" "$recipient_dir/message-inbox.json"
unlocked_result="$(AIDEVOPS_VAULT_MESSAGE_UNLOCKED=1 "$MESSAGE_HELPER" receive --vault-dir "$recipient_dir" --repo "$transport_repo")"
if [[ "$unlocked_result" != *'"locked": false'* || "$unlocked_result" != *'"decrypted": 1'* ]]; then
	printf '%s\n' "unlocked receive did not decrypt exactly one message" >&2
	exit 1
fi

if ! AIDEVOPS_VAULT_MESSAGE_UNLOCKED=1 "$MESSAGE_HELPER" receive --vault-dir "$recipient_dir" --repo "$transport_repo" >/dev/null; then
	printf '%s\n' "replay receive should be ignored idempotently" >&2
	exit 1
fi

ack_id="$("$MESSAGE_HELPER" ack --vault-dir "$recipient_dir" --message-id "$message_id" --repo "$transport_repo")"
if [[ ! "$ack_id" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "ack id is not opaque hex" >&2
	exit 1
fi

python3 - "$sender_dir/message-device.json" "$revoked_file" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

device = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(json.dumps({"revoked_devices": [device["device_id"]]}, sort_keys=True) + "\n", encoding="utf-8")
PY

rm -f "$recipient_dir/message-replay-cache.json" "$recipient_dir/message-inbox.json"
if "$MESSAGE_HELPER" receive --vault-dir "$recipient_dir" --repo "$transport_repo" --revoked-devices "$revoked_file" >/dev/null 2>"$tmp_root/revoked.err"; then
	printf '%s\n' "revoked sender receive unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_MESSAGE_REVOKED_DEVICE" "$tmp_root/revoked.err"; then
	printf '%s\n' "revoked sender failure did not use stable error code" >&2
	exit 1
fi

if "$MESSAGE_HELPER" send --vault-dir "$sender_dir" --recipient "$recipient_public" --class human --body-file "$message_body" --repo "$transport_repo" --transport simplex >/dev/null 2>"$tmp_root/simplex.err"; then
	printf '%s\n' "SimpleX transport unexpectedly succeeded without adapter" >&2
	exit 1
fi
if ! grep -q "VAULT_MESSAGE_SIMPLEX_UNAVAILABLE" "$tmp_root/simplex.err"; then
	printf '%s\n' "SimpleX failure did not use stable error code" >&2
	exit 1
fi

printf '%s\n' "vault message helper tests passed"
