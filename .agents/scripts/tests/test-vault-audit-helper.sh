#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
VAULT_AUDIT_HELPER="$REPO_ROOT/.agents/scripts/vault-audit-helper.sh"
VAULT_HELPER="$REPO_ROOT/.agents/scripts/vault-helper.sh"

tmp_root="$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-vault-audit-test)"
trap 'rm -rf "$tmp_root"' EXIT

vault_dir="$tmp_root/vault-audit"
peer_dir="$tmp_root/peer-audit"
replica_dir="$tmp_root/replica"
mkdir -p "$vault_dir" "$peer_dir" "$replica_dir"

"$VAULT_AUDIT_HELPER" init --vault-dir "$vault_dir" >/dev/null
first_head="$("$VAULT_AUDIT_HELPER" append --vault-dir "$vault_dir" --actor worker --action vault.lock --target-collection audit --result attempt --session-id test-session --reason "lock requested")"
second_head="$("$VAULT_AUDIT_HELPER" append --vault-dir "$vault_dir" --actor worker --action vault.lock --target-collection audit --result success --session-id test-session --reason "lock completed")"

if [[ ! "$first_head" =~ ^[0-9a-f]{64}$ || ! "$second_head" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "audit heads are not stable hex hashes" >&2
	exit 1
fi

verify_output="$("$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir")"
case "$verify_output" in
	*"sequence=2"*"head=$second_head"*) ;;
	*)
		printf '%s\n' "verify output did not report expected head" >&2
		exit 1
		;;
esac

missing_log="$tmp_root/missing.jsonl"
python3 - "$vault_dir/audit-events.jsonl" "$missing_log" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
lines = source.read_text(encoding="utf-8").splitlines()
target.write_text(lines[1] + "\n", encoding="utf-8")
PY

if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --log "$missing_log" >/dev/null 2>"$tmp_root/missing.err"; then
	printf '%s\n' "missing sequence unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_SEQUENCE_GAP\|VAULT_AUDIT_CHAIN_BROKEN" "$tmp_root/missing.err"; then
	printf '%s\n' "missing sequence did not use a stable error code" >&2
	exit 1
fi

corrupted_sequence_log="$tmp_root/corrupted-sequence.jsonl"
python3 - "$vault_dir/audit-events.jsonl" "$corrupted_sequence_log" <<'PY'
from pathlib import Path
import json
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
records = [json.loads(line) for line in source.read_text(encoding="utf-8").splitlines()]
records[0]["sequence"] = "not-an-integer"
target.write_text("\n".join(json.dumps(record, sort_keys=True) for record in records) + "\n", encoding="utf-8")
PY

if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --log "$corrupted_sequence_log" >/dev/null 2>"$tmp_root/corrupted-sequence.err"; then
	printf '%s\n' "corrupted sequence unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_CORRUPTED" "$tmp_root/corrupted-sequence.err"; then
	printf '%s\n' "corrupted sequence did not use a stable corruption error code" >&2
	exit 1
fi

tampered_log="$tmp_root/tampered.jsonl"
python3 - "$vault_dir/audit-events.jsonl" "$tampered_log" <<'PY'
from pathlib import Path
import json
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
records = [json.loads(line) for line in source.read_text(encoding="utf-8").splitlines()]
records[0]["encrypted_event"]["payload"] = records[0]["encrypted_event"]["payload"][::-1]
target.write_text("\n".join(json.dumps(record, sort_keys=True) for record in records) + "\n", encoding="utf-8")
PY

if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --log "$tampered_log" >/dev/null 2>"$tmp_root/tampered.err"; then
	printf '%s\n' "tampered event unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_EVENT_TAMPERED" "$tmp_root/tampered.err"; then
	printf '%s\n' "tampered event did not use a stable error code" >&2
	exit 1
fi

"$VAULT_AUDIT_HELPER" init --vault-dir "$peer_dir" >/dev/null
malicious_head="$($VAULT_AUDIT_HELPER append --vault-dir "$peer_dir" --actor worker --action vault.lock --target-collection audit --result success --session-id test-session --reason "untrusted peer event")"
if [[ ! "$malicious_head" =~ ^[0-9a-f]{64}$ ]]; then
	printf '%s\n' "malicious peer head is not a stable hex hash" >&2
	exit 1
fi
if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --log "$peer_dir/audit-events.jsonl" >/dev/null 2>"$tmp_root/untrusted-record.err"; then
	printf '%s\n' "untrusted audit record unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_UNTRUSTED_DEVICE\|VAULT_AUDIT_UNTRUSTED_KEY" "$tmp_root/untrusted-record.err"; then
	printf '%s\n' "untrusted audit record did not use a stable error code" >&2
	exit 1
fi

receipt_file="$tmp_root/receipt.json"
"$VAULT_AUDIT_HELPER" receipt --vault-dir "$peer_dir" --head "$second_head" --sequence 2 --observer-device peer-one --output "$receipt_file" >/dev/null
trusted_peers="$tmp_root/trusted-peers.json"
python3 - "$peer_dir/audit-device.json" "$trusted_peers" <<'PY'
from pathlib import Path
import json
import sys

device = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
Path(sys.argv[2]).write_text(json.dumps({"trusted_observers": {"peer-one": device["audit_signing_public_key"]}}, sort_keys=True) + "\n", encoding="utf-8")
PY

if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --receipt "$receipt_file" >/dev/null 2>"$tmp_root/untrusted-receipt.err"; then
	printf '%s\n' "untrusted receipt unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_TRUSTED_PEER_REQUIRED" "$tmp_root/untrusted-receipt.err"; then
	printf '%s\n' "untrusted receipt did not require a trusted peer key" >&2
	exit 1
fi
"$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --receipt "$receipt_file" --trusted-peer-keys "$trusted_peers" >/dev/null

bad_receipt="$tmp_root/bad-receipt.json"
python3 - "$receipt_file" "$bad_receipt" <<'PY'
from pathlib import Path
import json
import sys

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
data["receipt"]["observed_head"] = "0" * 64
Path(sys.argv[2]).write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")
PY
if "$VAULT_AUDIT_HELPER" verify --vault-dir "$vault_dir" --receipt "$bad_receipt" --trusted-peer-keys "$trusted_peers" >/dev/null 2>"$tmp_root/bad-receipt.err"; then
	printf '%s\n' "mismatched receipt unexpectedly verified" >&2
	exit 1
fi
if ! grep -q "VAULT_AUDIT_RECEIPT_MISMATCH" "$tmp_root/bad-receipt.err"; then
	printf '%s\n' "mismatched receipt did not use a stable error code" >&2
	exit 1
fi

anchor_file="$tmp_root/public-anchor.json"
"$VAULT_AUDIT_HELPER" anchor --vault-dir "$vault_dir" --head "$second_head" --sequence 2 --output "$anchor_file" >/dev/null
if grep -E "actor|action|target_collection|reason|encrypted_event|payload|session" "$anchor_file" >/dev/null; then
	printf '%s\n' "public anchor leaked event metadata" >&2
	exit 1
fi
if ! grep -q "$second_head" "$anchor_file"; then
	printf '%s\n' "public anchor does not include the checkpoint head" >&2
	exit 1
fi

"$VAULT_AUDIT_HELPER" replicate --vault-dir "$vault_dir" --output-dir "$replica_dir" >/dev/null
if [[ ! -s "$replica_dir/audit-events.jsonl" ]]; then
	printf '%s\n' "replication did not copy encrypted audit records" >&2
	exit 1
fi

export AIDEVOPS_VAULT_AUDIT_DIR="$tmp_root/wrapped-audit"
"$VAULT_HELPER" audit init >/dev/null
"$VAULT_HELPER" audit append --actor worker --action vault.status --target-collection vault --result success --reason "wrapper command" >/dev/null
"$VAULT_HELPER" audit verify >/dev/null

printf '%s\n' "vault audit helper tests passed"
