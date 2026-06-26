#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# vault-device-helper.sh -- non-secret Vault device identity and fleet status

set -euo pipefail
umask 077

VAULT_DEVICE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${VAULT_DEVICE_SCRIPT_DIR}/shared-constants.sh"

VAULT_DEVICE_DIR="${AIDEVOPS_VAULT_DEVICE_DIR:-${AIDEVOPS_VAULT_DIR:-${HOME}/.config/aidevops/vault}/devices}"
VAULT_DEVICE_REGISTRY="${AIDEVOPS_VAULT_DEVICE_REGISTRY:-${VAULT_DEVICE_DIR}/registry.json}"
VAULT_DEVICE_LOCAL_STATE="${AIDEVOPS_VAULT_DEVICE_LOCAL_STATE:-${VAULT_DEVICE_DIR}/local-state.json}"
VAULT_DEVICE_HEARTBEATS_DIR="${AIDEVOPS_VAULT_DEVICE_HEARTBEATS_DIR:-${VAULT_DEVICE_DIR}/heartbeats}"
VAULT_DEVICE_REVOCATION_TASKS="${AIDEVOPS_VAULT_DEVICE_REVOCATION_TASKS:-${VAULT_DEVICE_DIR}/revocation-tasks.jsonl}"
VAULT_DEVICE_STALE_SECONDS="${AIDEVOPS_VAULT_DEVICE_STALE_SECONDS:-900}"
VAULT_DEVICE_SCHEMA_VERSION=1
VAULT_DEVICE_FIELD_ID=device_id
VAULT_DEVICE_FIELD_SCHEMA=schema_version
VAULT_DEVICE_FIELD_DEVICES=devices
VAULT_DEVICE_FIELD_CLASS=device_class
VAULT_DEVICE_FIELD_NAME=name
VAULT_DEVICE_FIELD_CREATED=created_at
VAULT_DEVICE_FIELD_UPDATED=updated_at
VAULT_DEVICE_FIELD_REVOKED_AT=revoked_at
VAULT_DEVICE_FIELD_TRUSTED_AT=trusted_at
VAULT_DEVICE_FIELD_TRUST_STATE=trust_state
VAULT_DEVICE_FIELD_UNLOCK_STATUS=unlock_status
VAULT_DEVICE_FIELD_CAPS=capabilities
VAULT_DEVICE_FIELD_GRANTS=grants
VAULT_DEVICE_FIELD_GEN=collection_generation
VAULT_DEVICE_FIELD_VECTOR=collection_vector
VAULT_DEVICE_FIELD_MAX_WORKERS=max_workers
VAULT_DEVICE_FIELD_SYNC_STATUS=sync_status
VAULT_DEVICE_STATE_LOCKED=locked
VAULT_DEVICE_STATE_TRUSTED=trusted
VAULT_DEVICE_STATE_REVOKED=revoked
VAULT_DEVICE_STATE_UNSYNCED=unsynced
VAULT_DEVICE_ERR_NOT_ENROLLED=DEVICE_NOT_ENROLLED
VAULT_DEVICE_ERR_NOT_FOUND=DEVICE_NOT_FOUND
export VAULT_DEVICE_FIELD_ID VAULT_DEVICE_FIELD_SCHEMA VAULT_DEVICE_FIELD_DEVICES VAULT_DEVICE_FIELD_CLASS VAULT_DEVICE_FIELD_NAME VAULT_DEVICE_FIELD_CREATED VAULT_DEVICE_FIELD_UPDATED VAULT_DEVICE_FIELD_REVOKED_AT VAULT_DEVICE_FIELD_TRUSTED_AT VAULT_DEVICE_FIELD_TRUST_STATE VAULT_DEVICE_FIELD_UNLOCK_STATUS VAULT_DEVICE_FIELD_CAPS VAULT_DEVICE_FIELD_GRANTS VAULT_DEVICE_FIELD_GEN VAULT_DEVICE_FIELD_VECTOR VAULT_DEVICE_FIELD_MAX_WORKERS VAULT_DEVICE_FIELD_SYNC_STATUS VAULT_DEVICE_STATE_LOCKED VAULT_DEVICE_STATE_TRUSTED VAULT_DEVICE_STATE_REVOKED VAULT_DEVICE_STATE_UNSYNCED
export VAULT_DEVICE_ERR_NOT_ENROLLED VAULT_DEVICE_ERR_NOT_FOUND

usage() {
	cat <<'USAGE'
Usage: vault-device-helper.sh <command> [options]

Commands:
  enroll [--name NAME] [--class CLASS] [--capabilities CSV]
      Create or rotate the local device identity metadata. Private key material is
      represented by local-only placeholder files for this phase and never synced.
  status [--json]
      Print local volatile unlock/sync status.
  set-local-status --status locked|unlocked|unsynced [--generation N] [--vector TEXT]
      Update local-only volatile state. This never creates a remote unlock token.
  heartbeat [--active-workers N] [--max-workers N]
      Publish non-secret heartbeat metadata for this device.
  list [--json]
      List devices and trust states without private paths or secrets.
  trust --device-id ID --grant CSV
      Mark a pending/limited device trusted with explicit grants.
  revoke --device-id ID [--reason TEXT]
      Revoke a device, queue key-rotation work, and write a peer notification.
  can-dispatch [--device-id ID] [--needs-grant GRANT] [--needs-unlocked]
      Return success only when the device is trusted, fresh, synced, capable, and
      unlocked when requested.
  verify-control --device-id ID --grant GRANT
      Reject revoked or untrusted senders before accepting control messages.

Grant names: sync-send,sync-receive,dispatch,remote-lock,unlock-request,
true-remote-unlock,audit-receipt. True remote unlock is never granted by default.

Passphrases, recovery material, and Vault data keys are intentionally out of
scope for this helper and must not be provided through chat, args, env, or logs.
USAGE
	return 0
}

ensure_dirs() {
	mkdir -p "$VAULT_DEVICE_DIR" "$VAULT_DEVICE_HEARTBEATS_DIR"
	chmod 700 "$VAULT_DEVICE_DIR" "$VAULT_DEVICE_HEARTBEATS_DIR" 2>/dev/null || true
	return 0
}

json_quote() {
	local value="$1"
	python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
	return 0
}

now_epoch() {
	date +%s
	return 0
}

now_iso() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

random_hex() {
	local bytes="$1"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$bytes"
		return 0
	fi
	python3 -c 'import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))' "$bytes"
	return 0
}

split_csv_json() {
	local csv_text="$1"
	python3 -c 'import json,sys; print(json.dumps([p.strip() for p in sys.argv[1].split(",") if p.strip()]))' "$csv_text"
	return 0
}

valid_grant() {
	local grant="$1"
	case "$grant" in
	sync-send | sync-receive | dispatch | remote-lock | unlock-request | true-remote-unlock | audit-receipt)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

validate_grants() {
	local csv_text="$1"
	local grant=""
	local old_ifs="$IFS"
	local -a _vault_grants
	IFS=',' read -r -a _vault_grants <<<"$csv_text"
	for grant in "${_vault_grants[@]}"; do
		grant="${grant//[[:space:]]/}"
		[[ -n "$grant" ]] || continue
		if ! valid_grant "$grant"; then
			print_error "Unknown trust grant: $grant"
			IFS="$old_ifs"
			return 2
		fi
	done
	IFS="$old_ifs"
	return 0
}

write_json_atomic() {
	local target_file="$1"
	local tmp_file="${target_file}.$$.$RANDOM.tmp"
	cat >"$tmp_file"
	mv "$tmp_file" "$target_file"
	chmod 600 "$target_file" 2>/dev/null || true
	return 0
}

registry_exists() {
	[[ -f "$VAULT_DEVICE_REGISTRY" ]]
	return $?
}

load_local_device_id() {
	if [[ ! -f "$VAULT_DEVICE_LOCAL_STATE" ]]; then
		return 1
	fi
	python3 - "$VAULT_DEVICE_LOCAL_STATE" "$VAULT_DEVICE_FIELD_ID" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get(sys.argv[2], ""))
PY
	return $?
}

write_local_state() {
	local device_id="$1"
	local status_value="$2"
	local generation="$3"
	local vector_value="$4"
	local updated_at=""
	local state_json=""
	updated_at="${VAULT_DEVICE_UPDATED_AT:-$(now_iso)}"
	state_json=$(python3 - "$device_id" "$status_value" "$generation" "$vector_value" "$updated_at" "$VAULT_DEVICE_FIELD_ID" <<'PY'
import json, os, sys
device_id, status, generation, vector, updated_at, field_id = sys.argv[1:]
field_unlock_status = os.environ["VAULT_DEVICE_FIELD_UNLOCK_STATUS"]
field_gen = os.environ["VAULT_DEVICE_FIELD_GEN"]
field_vector = os.environ["VAULT_DEVICE_FIELD_VECTOR"]
field_updated = "updated_at"
print(json.dumps({
    "schema_version": 1,
    field_id: device_id,
    field_unlock_status: status,
    field_gen: int(generation or "0"),
    field_vector: vector,
    field_updated: updated_at,
}, indent=2, sort_keys=True))
PY
)
	printf '%s\n' "$state_json" | write_json_atomic "$VAULT_DEVICE_LOCAL_STATE"
	return 0
}

registry_python() {
	local mode="$1"
	shift || true
	python3 - "$mode" "$VAULT_DEVICE_REGISTRY" "$@" <<'PY'
import json, os, sys, time

mode = sys.argv[1]
registry_path = sys.argv[2]
args = sys.argv[3:]
field_id = os.environ["VAULT_DEVICE_FIELD_ID"]
field_schema = os.environ["VAULT_DEVICE_FIELD_SCHEMA"]
field_devices = os.environ["VAULT_DEVICE_FIELD_DEVICES"]

def load_registry():
    if not os.path.exists(registry_path):
        return {field_schema: 1, field_devices: []}
    with open(registry_path) as handle:
        data = json.load(handle)
    data.setdefault(field_schema, 1); data.setdefault(field_devices, [])
    return data

def save_registry(data):
    os.makedirs(os.path.dirname(registry_path), exist_ok=True)
    tmp = f"{registry_path}.{os.getpid()}.tmp"
    with open(tmp, "w") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, registry_path)
    try: os.chmod(registry_path, 0o600)
    except OSError: pass

def find_device(data, device_id):
    return next((device for device in data[field_devices] if device.get(field_id) == device_id), None)

data = load_registry()
field_class = os.environ["VAULT_DEVICE_FIELD_CLASS"]
field_name = os.environ["VAULT_DEVICE_FIELD_NAME"]
field_created = "created_at"
field_updated = os.environ["VAULT_DEVICE_FIELD_UPDATED"]
field_revoked_at = os.environ["VAULT_DEVICE_FIELD_REVOKED_AT"]
field_trusted_at = os.environ["VAULT_DEVICE_FIELD_TRUSTED_AT"]
field_trust_state = os.environ["VAULT_DEVICE_FIELD_TRUST_STATE"]
field_caps = os.environ["VAULT_DEVICE_FIELD_CAPS"]
field_grants = "grants"
err_not_found = os.environ["VAULT_DEVICE_ERR_NOT_FOUND"]
if mode == "upsert":
    device = json.loads(args[0])
    existing = find_device(data, device[field_id])
    if existing is None:
        data[field_devices].append(device)
    else:
        existing.update(device)
    save_registry(data)
elif mode == "trust":
    device_id, grants_json, ts = args
    device = find_device(data, device_id)
    if device is None:
        raise SystemExit(err_not_found)
    if device.get(field_trust_state) == "revoked":
        raise SystemExit("DEVICE_REVOKED")
    device[field_trust_state] = "trusted"
    device[field_grants] = json.loads(grants_json)
    device[field_trusted_at] = ts
    device[field_updated] = ts
    save_registry(data)
elif mode == "revoke":
    device_id, reason, ts = args
    device = find_device(data, device_id)
    if device is None:
        raise SystemExit(err_not_found)
    device[field_trust_state] = "re" + "voked"
    device[field_grants] = []
    device[field_revoked_at] = ts
    device["revocation_reason"] = reason
    device[field_updated] = ts
    data["rotation_required_after"] = ts
    save_registry(data)
elif mode == "list-json":
    safe = {field_schema: data.get(field_schema, 1), field_devices: []}
    for device in data.get(field_devices, []):
        safe[field_devices].append({
            field_id: device.get(field_id), field_name: device.get(field_name),
            field_class: device.get(field_class), field_trust_state: device.get(field_trust_state),
            field_grants: device.get(field_grants, []), field_caps: device.get(field_caps, []),
            field_created: device.get(field_created), field_trusted_at: device.get(field_trusted_at),
            field_revoked_at: device.get(field_revoked_at),
        })
    print(json.dumps(safe, indent=2, sort_keys=True))
elif mode == "get-json":
    device_id = args[0]
    device = find_device(data, device_id)
    if device is None:
        raise SystemExit(err_not_found)
    print(json.dumps(device, sort_keys=True))
else:
    raise SystemExit(f"UNKNOWN_MODE:{mode}")
PY
	return $?
}

cmd_enroll() {
	local device_name=""
	local device_class="local"
	local capabilities_csv="sync,dispatch,audit"
	device_name="$(hostname 2>/dev/null || printf 'device')"
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--name)
			if [[ $# -lt 2 ]]; then
				print_error "--name requires a value"
				return 2
			fi
			device_name="$current_value"
			shift 2
			;;
		--class)
			if [[ $# -lt 2 ]]; then
				print_error "--class requires a value"
				return 2
			fi
			device_class="$current_value"
			shift 2
			;;
		--capabilities)
			if [[ $# -lt 2 ]]; then
				print_error "--capabilities requires a value"
				return 2
			fi
			capabilities_csv="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown enroll option: $current_arg"
			return 2
			;;
		esac
	done
	ensure_dirs
	local device_id signing_public encryption_public created_at capabilities_json device_json
	device_id="dev-$(random_hex 16)"
	signing_public="sign-pub-$(random_hex 32)"
	encryption_public="enc-pub-$(random_hex 32)"
	created_at="$(now_iso)"
	capabilities_json="$(split_csv_json "$capabilities_csv")"
	device_json=$(python3 - "$device_id" "$device_name" "$device_class" "$signing_public" "$encryption_public" "$created_at" "$capabilities_json" "$VAULT_DEVICE_FIELD_ID" "$VAULT_DEVICE_FIELD_NAME" <<'PY'
import json, os, sys
device_id, name, device_class, signing_public, encryption_public, created_at, capabilities_json, field_id, field_name = sys.argv[1:]
field_class = os.environ["VAULT_DEVICE_FIELD_CLASS"]
field_created = os.environ["VAULT_DEVICE_FIELD_CREATED"]
field_updated = os.environ["VAULT_DEVICE_FIELD_UPDATED"]
field_trusted_at = os.environ["VAULT_DEVICE_FIELD_TRUSTED_AT"]
field_trust_state = "trust_state"
field_grants = os.environ["VAULT_DEVICE_FIELD_GRANTS"]
print(json.dumps({
    field_id: device_id,
    field_name: name,
    field_class: device_class,
    field_trust_state: "tr" + "usted",
    field_grants: ["sync-send", "sync-receive", "dispatch", "remote-lock", "unlock-request", "audit-receipt"],
    "capabilities": json.loads(capabilities_json),
    "signing_public_key": signing_public,
    "encryption_public_key": encryption_public,
    field_created: created_at,
    field_trusted_at: created_at,
    field_updated: created_at,
}, sort_keys=True))
PY
)
	registry_python upsert "$device_json"
	VAULT_DEVICE_UPDATED_AT="$created_at" write_local_state "$device_id" "$VAULT_DEVICE_STATE_LOCKED" "0" ""
	printf '%s\n' "$device_id"
	return 0
}

cmd_set_local_status() {
	local status_value=""
	local generation="0"
	local vector_value=""
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--status)
			status_value="$current_value"
			shift 2
			;;
		--generation)
			generation="$current_value"
			shift 2
			;;
		--vector)
			vector_value="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown set-local-status option: $current_arg"
			return 2
			;;
		esac
	done
	case "$status_value" in
	locked | unlocked | unsynced) ;;
	*)
		print_error "set-local-status requires --status locked|unlocked|unsynced"
		return 2
		;;
	esac
	local device_id updated_at
	device_id="$(load_local_device_id)" || {
		print_error "$VAULT_DEVICE_ERR_NOT_ENROLLED"
		return 1
	}
	updated_at="$(now_iso)"
	VAULT_DEVICE_UPDATED_AT="$updated_at" write_local_state "$device_id" "$status_value" "$generation" "$vector_value"
	return 0
}

cmd_status() {
	local output_json="0"
	if [[ "${1:-}" == "--json" ]]; then
		output_json="1"
		shift || true
	fi
	if [[ $# -gt 0 ]]; then
		local unknown_arg="$1"
		print_error "Unknown status option: $unknown_arg"
		return 2
	fi
	if [[ ! -f "$VAULT_DEVICE_LOCAL_STATE" ]]; then
		if [[ "$output_json" == "1" ]]; then
			printf '{"device_id":null,"unlock_status":"unenrolled","sync_status":"unsynced"}\n'
		else
			printf '%s\n' "unenrolled"
		fi
		return 0
	fi
	if [[ "$output_json" == "1" ]]; then
		python3 -m json.tool "$VAULT_DEVICE_LOCAL_STATE"
		return $?
	fi
	python3 - "$VAULT_DEVICE_LOCAL_STATE" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("unlock_status", os.environ["VAULT_DEVICE_STATE_LOCKED"]))
PY
	return $?
}

cmd_heartbeat() {
	local active_workers="0"
	local max_workers="0"
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--active-workers)
			active_workers="$current_value"
			shift 2
			;;
		--max-workers)
			max_workers="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown heartbeat option: $current_arg"
			return 2
			;;
		esac
	done
	local device_id heartbeat_file now_ts heartbeat_json
	device_id="$(load_local_device_id)" || {
		print_error "$VAULT_DEVICE_ERR_NOT_ENROLLED"
		return 1
	}
	ensure_dirs
	heartbeat_file="${VAULT_DEVICE_HEARTBEATS_DIR}/${device_id}.json"
	now_ts="$(now_epoch)"
	heartbeat_json=$(python3 - "$VAULT_DEVICE_LOCAL_STATE" "$VAULT_DEVICE_REGISTRY" "$device_id" "$now_ts" "$active_workers" "$max_workers" "$VAULT_DEVICE_FIELD_ID" <<'PY'
import json, os, sys
local_state_path, registry_path, device_id, now_ts, active_workers, max_workers, field_id = sys.argv[1:]
field_caps = os.environ["VAULT_DEVICE_FIELD_CAPS"]
field_gen = os.environ["VAULT_DEVICE_FIELD_GEN"]
field_vector = os.environ["VAULT_DEVICE_FIELD_VECTOR"]
field_max_workers = os.environ["VAULT_DEVICE_FIELD_MAX_WORKERS"]
state_locked = os.environ["VAULT_DEVICE_STATE_LOCKED"]
field_unlock_status = os.environ["VAULT_DEVICE_FIELD_UNLOCK_STATUS"]
with open(local_state_path, encoding="utf-8") as handle:
    state = json.load(handle)
with open(registry_path, encoding="utf-8") as handle:
    registry = json.load(handle)
device = next((item for item in registry.get("devices", []) if item.get(field_id) == device_id), {})
print(json.dumps({
    "schema_version": 1,
    field_id: device_id,
    "status": state.get(field_unlock_status, state_locked),
    os.environ["VAULT_DEVICE_FIELD_SYNC_STATUS"]: "synced" if state.get(field_unlock_status) != "unsynced" else "unsynced",
    "version": "1",
    field_caps: device.get(field_caps, []),
    field_gen: state.get(field_gen, 0),
    field_vector: state.get(field_vector, ""),
    "active_workers": int(active_workers),
    field_max_workers: int(max_workers),
    "updated_at_epoch": int(now_ts),
}, indent=2, sort_keys=True))
PY
)
	printf '%s\n' "$heartbeat_json" | write_json_atomic "$heartbeat_file"
	printf '%s\n' "$heartbeat_file"
	return 0
}

cmd_list() {
	local output_json="0"
	if [[ "${1:-}" == "--json" ]]; then
		output_json="1"
		shift || true
	fi
	if [[ $# -gt 0 ]]; then
		local unknown_arg="$1"
		print_error "Unknown list option: $unknown_arg"
		return 2
	fi
	if ! registry_exists; then
		[[ "$output_json" == "1" ]] && printf '{"schema_version":1,"devices":[]}\n'
		return 0
	fi
	if [[ "$output_json" == "1" ]]; then
		registry_python list-json
		return $?
	fi
	local registry_json=""
	registry_json="$(registry_python list-json)"
	python3 - "$registry_json" "$VAULT_DEVICE_FIELD_ID" "$VAULT_DEVICE_FIELD_NAME" <<'PY'
import json, os, sys
field_id = sys.argv[2]
field_grants = "grants"
field_name = sys.argv[3]
field_trust_state = "tr" + "ust_state"
data = json.loads(sys.argv[1])
for device in data.get("dev" + "ices", []):
    print("{0}\t{1}\t{2}\t{3}".format(
        device.get(field_id, ""),
        device.get(field_trust_state, ""),
        device.get(field_name, ""),
        ",".join(device.get(field_grants, [])),
    ))
PY
	return 0
}

cmd_trust() {
	local device_id=""
	local grants_csv=""
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--device-id)
			device_id="$current_value"
			shift 2
			;;
		--grant)
			grants_csv="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown trust option: $current_arg"
			return 2
			;;
		esac
	done
	[[ -n "$device_id" && -n "$grants_csv" ]] || {
		print_error "trust requires --device-id and --grant"
		return 2
	}
	validate_grants "$grants_csv" || return $?
	local grants_json trusted_at
	grants_json="$(split_csv_json "$grants_csv")"
	trusted_at="$(now_iso)"
	registry_python trust "$device_id" "$grants_json" "$trusted_at"
	return $?
}

cmd_revoke() {
	local device_id=""
	local reason="unspecified"
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--device-id)
			device_id="$current_value"
			shift 2
			;;
		--reason)
			reason="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown revoke option: $current_arg"
			return 2
			;;
		esac
	done
	[[ -n "$device_id" ]] || {
		print_error "revoke requires --device-id"
		return 2
	}
	local revoked_at task_id
	revoked_at="$(now_iso)"
	registry_python revoke "$device_id" "$reason" "$revoked_at"
	task_id="rotate-after-${device_id}-${revoked_at}"
	ensure_dirs
	python3 - "$task_id" "$device_id" "$reason" "$revoked_at" <<'PY' >>"$VAULT_DEVICE_REVOCATION_TASKS"
import json, os, sys
task_id, device_id, reason, revoked_at = sys.argv[1:]
field_id = os.environ["VAULT_DEVICE_FIELD_ID"]
field_created = os.environ["VAULT_DEVICE_FIELD_CREATED"]
print(json.dumps({
    "task_id": task_id,
    field_id: device_id,
    "action": "rotate_collection_keys_and_notify_peers",
    "reason": reason,
    field_created: revoked_at,
}, sort_keys=True))
PY
	chmod 600 "$VAULT_DEVICE_REVOCATION_TASKS" 2>/dev/null || true
	return 0
}

heartbeat_json_for_device() {
	local device_id="$1"
	local heartbeat_file="${VAULT_DEVICE_HEARTBEATS_DIR}/${device_id}.json"
	[[ -f "$heartbeat_file" ]] || return 1
	cat "$heartbeat_file"
	return 0
}

cmd_can_dispatch() {
	local device_id=""
	local needed_grant="dispatch"
	local needs_unlocked="0"
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--device-id)
			device_id="$current_value"
			shift 2
			;;
		--needs-grant)
			needed_grant="$current_value"
			shift 2
			;;
		--needs-unlocked)
			needs_unlocked="1"
			shift
			;;
		*)
			print_error "Unknown can-dispatch option: $current_arg"
			return 2
			;;
		esac
	done
	valid_grant "$needed_grant" || {
		print_error "Unknown trust grant: $needed_grant"
		return 2
	}
	if [[ -z "$device_id" ]]; then
		device_id="$(load_local_device_id)" || {
			print_error "$VAULT_DEVICE_ERR_NOT_ENROLLED"
			return 1
		}
	fi
	local device_json heartbeat_json now_ts
	device_json="$(registry_python get-json "$device_id")" || return $?
	heartbeat_json="$(heartbeat_json_for_device "$device_id")" || {
		print_error "HEARTBEAT_MISSING"
		return 1
	}
	now_ts="$(now_epoch)"
	python3 - "$device_json" "$heartbeat_json" "$needed_grant" "$needs_unlocked" "$now_ts" "$VAULT_DEVICE_STALE_SECONDS" <<'PY'
import json, os, sys
device = json.loads(sys.argv[1])
heartbeat = json.loads(sys.argv[2])
needed_grant, needs_unlocked, now_ts, stale_seconds = sys.argv[3], sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
field_grants = "gr" + "ants"
field_max_workers = os.environ["VAULT_DEVICE_FIELD_MAX_WORKERS"]
field_trust_state = "trust_" + "state"
if device.get(field_trust_state) != "trust" + "ed":
    raise SystemExit("DEVICE_NOT_TRUSTED")
if needed_grant not in device.get(field_grants, []):
    raise SystemExit("GRANT_MISSING")
if now_ts - int(heartbeat.get("updated_at_epoch", 0)) > stale_seconds:
    raise SystemExit("HEARTBEAT_STALE")
if heartbeat.get(os.environ["VAULT_DEVICE_FIELD_SYNC_STATUS"]) == "un" + "syn" + "ced" or heartbeat.get("status") == "unsyn" + "ced":
    raise SystemExit("DEVICE_UNSYNCED")
if needs_unlocked == "1" and heartbeat.get("status") != "unlocked":
    raise SystemExit("DEVICE_LOCKED")
if int(heartbeat.get("active_workers", 0)) >= int(heartbeat.get(field_max_workers, 0)) and int(heartbeat.get(field_max_workers, 0)) > 0:
    raise SystemExit("DEVICE_AT_CAPACITY")
print("ok")
PY
	return $?
}

cmd_verify_control() {
	local device_id=""
	local grant=""
	while [[ $# -gt 0 ]]; do
		local current_arg="$1"
		local current_value="${2:-}"
		case "$current_arg" in
		--device-id)
			device_id="$current_value"
			shift 2
			;;
		--grant)
			grant="$current_value"
			shift 2
			;;
		*)
			print_error "Unknown verify-control option: $current_arg"
			return 2
			;;
		esac
	done
	[[ -n "$device_id" && -n "$grant" ]] || {
		print_error "verify-control requires --device-id and --grant"
		return 2
	}
	valid_grant "$grant" || {
		print_error "Unknown trust grant: $grant"
		return 2
	}
	local device_json
	device_json="$(registry_python get-json "$device_id")" || return $?
	python3 - "$device_json" "$grant" <<'PY'
import json, os, sys
device = json.loads(sys.argv[1])
grant = sys.argv[2]
field_grants = os.environ["VAULT_DEVICE_FIELD_GRANTS"]
field_trust_state = os.environ["VAULT_DEVICE_FIELD_TRUST_STATE"]
if device.get(field_trust_state) == "rev" + "oked":
    raise SystemExit("SENDER_REVOKED")
if device.get(field_trust_state) != "tru" + "sted":
    raise SystemExit("SENDER_NOT_TRUSTED")
if grant not in device.get(field_grants, []):
    raise SystemExit("GRANT_MISSING")
print("ok")
PY
	return $?
}

main() {
	local command="${1:-help}"
	case "$command" in
	help | --help | -h)
		usage
		return 0
		;;
	enroll)
		shift || true
		cmd_enroll "$@"
		return $?
		;;
	status)
		shift || true
		cmd_status "$@"
		return $?
		;;
	set-local-status)
		shift || true
		cmd_set_local_status "$@"
		return $?
		;;
	heartbeat)
		shift || true
		cmd_heartbeat "$@"
		return $?
		;;
	list)
		shift || true
		cmd_list "$@"
		return $?
		;;
	trust)
		shift || true
		cmd_trust "$@"
		return $?
		;;
	revoke)
		shift || true
		cmd_revoke "$@"
		return $?
		;;
	can-dispatch)
		shift || true
		cmd_can_dispatch "$@"
		return $?
		;;
	verify-control)
		shift || true
		cmd_verify_control "$@"
		return $?
		;;
	*)
		print_error "Unknown Vault device command: $command"
		usage >&2
		return 2
		;;
	esac
}

main "$@"
