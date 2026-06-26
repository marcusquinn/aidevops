#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
SYNC_HELPER="$REPO_ROOT/.agents/scripts/vault-sync-helper.sh"
GIT_TRANSPORT_HELPER="$REPO_ROOT/.agents/scripts/vault-git-transport-helper.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

vault_dir="$tmp_root/vault"
transport_repo="$tmp_root/public-transport"
collected_dir="$tmp_root/collected"
record_file="$tmp_root/record.json"
revoked_file="$tmp_root/revoked.json"

mkdir -p "$vault_dir" "$transport_repo"
chmod 700 "$vault_dir"

python3 - "$vault_dir" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

vault_dir = Path(sys.argv[1])
store = {
    "entries": {
        "client/private/path.txt": {
            "aead": "AES-256-GCM",
            "nonce": "opaque-nonce",
            "ciphertext": "opaque-ciphertext-without-client-secret",
        }
    }
}
(vault_dir / "vault-store.json").write_text(json.dumps(store, sort_keys=True) + "\n", encoding="utf-8")
PY

"$SYNC_HELPER" init --vault-dir "$vault_dir" >/dev/null
record_id="$("$SYNC_HELPER" export --vault-dir "$vault_dir" --collection memory --namespace "client/private namespace" --entry "client/private/path.txt" --output "$record_file" --pad-bytes 32)"

if [[ ! "$record_id" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "record id is not opaque hex" >&2
	exit 1
fi

if grep -R "client/private" "$record_file" "$transport_repo" >/dev/null 2>&1; then
	printf '%s\n' "export leaked a private path or namespace" >&2
	exit 1
fi

staged_path="$("$GIT_TRANSPORT_HELPER" stage --repo "$transport_repo" --record "$record_file")"
case "$staged_path" in
	.vault/records/[0-9a-f][0-9a-f]/*.json) ;;
	*)
		printf '%s\n' "transport path is not opaque: $staged_path" >&2
		exit 1
		;;
esac

"$GIT_TRANSPORT_HELPER" collect --repo "$transport_repo" --output "$collected_dir" >/dev/null
"$SYNC_HELPER" import --vault-dir "$vault_dir" --input "$collected_dir/$record_id.json" >/dev/null

if "$SYNC_HELPER" import --vault-dir "$vault_dir" --input "$collected_dir/$record_id.json" >/dev/null 2>"$tmp_root/replay.err"; then
	printf '%s\n' "replay import unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_SYNC_REPLAY" "$tmp_root/replay.err"; then
	printf '%s\n' "replay failure did not use stable error code" >&2
	exit 1
fi

python3 - "$collected_dir/$record_id.json" "$tmp_root/tampered.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
data["record"]["collection"] = "knowledge"
target.write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")
PY

rm -f "$vault_dir/sync-manifest.json"
if "$SYNC_HELPER" import --vault-dir "$vault_dir" --input "$tmp_root/tampered.json" >/dev/null 2>"$tmp_root/tampered.err"; then
	printf '%s\n' "tampered import unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_SYNC_BAD_SIGNATURE" "$tmp_root/tampered.err"; then
	printf '%s\n' "tampered failure did not use stable error code" >&2
	exit 1
fi

python3 - "$record_file" "$tmp_root/impersonated.json" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
data = json.loads(source.read_text(encoding="utf-8"))
data["record"]["author_device"] = "0" * 64
target.write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")
PY

if "$SYNC_HELPER" import --vault-dir "$vault_dir" --input "$tmp_root/impersonated.json" >/dev/null 2>"$tmp_root/impersonated.err"; then
	printf '%s\n' "impersonated author import unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_SYNC_BAD_SIGNATURE" "$tmp_root/impersonated.err"; then
	printf '%s\n' "impersonated author failure did not use stable error code" >&2
	exit 1
fi

wrong_key_vault_dir="$tmp_root/wrong-key-vault"
mkdir -p "$wrong_key_vault_dir"
chmod 700 "$wrong_key_vault_dir"
"$SYNC_HELPER" init --vault-dir "$wrong_key_vault_dir" >/dev/null
if "$SYNC_HELPER" import --vault-dir "$wrong_key_vault_dir" --input "$record_file" >/dev/null 2>"$tmp_root/decrypt.err"; then
	printf '%s\n' "wrong-key import unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_SYNC_DECRYPT_FAILED" "$tmp_root/decrypt.err"; then
	printf '%s\n' "wrong-key decrypt failure did not use stable error code" >&2
	exit 1
fi

python3 - "$record_file" "$revoked_file" <<'PY'
from __future__ import annotations

import json
import sys
from pathlib import Path

record = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["record"]
Path(sys.argv[2]).write_text(json.dumps({"revoked_devices": [record["author_device"]]}, sort_keys=True) + "\n", encoding="utf-8")
PY

rm -f "$vault_dir/sync-manifest.json"
if "$SYNC_HELPER" import --vault-dir "$vault_dir" --input "$record_file" --revoked-devices "$revoked_file" >/dev/null 2>"$tmp_root/revoked.err"; then
	printf '%s\n' "revoked-device import unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_SYNC_REVOKED_DEVICE" "$tmp_root/revoked.err"; then
	printf '%s\n' "revoked-device failure did not use stable error code" >&2
	exit 1
fi

if "$SYNC_HELPER" rekey >/dev/null 2>"$tmp_root/rekey.err"; then
	printf '%s\n' "non-TTY rekey unexpectedly succeeded" >&2
	exit 1
fi
if ! grep -q "VAULT_TTY_REQUIRED\|VAULT_UNINITIALIZED" "$tmp_root/rekey.err"; then
	printf '%s\n' "rekey did not fail closed through Vault helper" >&2
	exit 1
fi

printf '%s\n' "vault sync helper tests passed"
