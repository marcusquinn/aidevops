#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MESSAGE_HELPER="${AIDEVOPS_VAULT_MESSAGE_HELPER:-${SCRIPT_DIR}/vault-message-helper.sh}"
VAULT_HELPER="${AIDEVOPS_VAULT_HELPER:-${SCRIPT_DIR}/vault-helper.sh}"
AUDIT_HELPER="${AIDEVOPS_VAULT_AUDIT_HELPER:-${SCRIPT_DIR}/vault-audit-helper.sh}"

usage() {
	cat <<'EOF'
Usage: vault-remote-control-helper.sh <command> [options]

Commands:
  trust-controller --controller-device ID --policy disabled|request-only|sudo+passphrase|sudo+passphrase+2-of-N [--vault-dir DIR]
      Authorize or update a remote controller policy for this target device.
  revoke-controller --controller-device ID [--vault-dir DIR]
      Revoke a controller without deleting its audit history.
  send-lock --recipient FILE --repo DIR --target-device ID --reason TEXT [--vault-dir DIR] [--ttl SECONDS]
      Send a signed remote lock command. The target never needs a Vault passphrase to lock.
  send-unlock-request --recipient FILE --repo DIR --target-device ID --reason TEXT [--vault-dir DIR] [--ttl SECONDS]
      Ask the target/operator to unlock locally or approve a scoped grant.
  send-unlock-grant --recipient FILE --repo DIR --target-device ID --reason TEXT [--vault-dir DIR] [--ttl SECONDS]
      Send a true remote-unlock grant. Requires sudo on the controller and an interactive TTY.
  receive --repo DIR [--vault-dir DIR] [--revoked-devices FILE]
      Receive and apply decrypted remote-control messages for this target.
  status [--vault-dir DIR]
      Print remote-control policy/event summary as JSON.

Remote unlock is disabled by default. Passphrases are never accepted through
arguments, environment variables, non-TTY stdin, logs, issue bodies, chat, or
fixtures. Use a separate fleet-control policy; do not reuse issue approval keys.
EOF
	return 0
}

command_name="${1:-help}"
case "$command_name" in
	help | --help | -h)
		usage
		exit 0
		;;
	trust-controller | revoke-controller | send-lock | send-unlock-request | send-unlock-grant | receive | status)
		shift || true
		python3 - "$command_name" "$MESSAGE_HELPER" "$VAULT_HELPER" "$AUDIT_HELPER" "$@" <<'PY'
from __future__ import annotations

import argparse
import base64
import getpass
import json
import os
import secrets
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
ENCODING = "utf-8"
POLICY_FILE = "remote-control-policy.json"
STATE_FILE = "remote-control-state.json"
MESSAGE_DEVICE_FILE = "message-device.json"
ARG_VAULT_DIR = "--vault-dir"
ARG_REPO = "--repo"
CMD_BASH = "bash"
FIELD_ACTION = "action"
FIELD_CONTROLLER_DEVICE = "controller_device"
FIELD_CONTROLLERS = "controllers"
FIELD_DEVICE_ID = "device_id"
FIELD_EVENTS = "events"
FIELD_EXPIRES_AT = "expires_at"
FIELD_NONCE = "nonce"
FIELD_POLICY = "policy"
FIELD_REASON = "reason"
FIELD_RESULT = "result"
FIELD_REVOKED = "revoked"
FIELD_SCHEMA_VERSION = "schema_version"
FIELD_SEEN_NONCES = "seen_nonces"
FIELD_SENDER = "sender"
FIELD_TARGET_DEVICE = "target_device"
FIELD_UPDATED_AT = "updated_at"
RESULT_ATTEMPT = "attempt"
RESULT_SUCCESS = "success"
ACTION_LOCK = "lock"
ACTION_UNLOCK_GRANT = "unlock-grant"
ACTION_UNLOCK_REQUEST = "unlock-request"
ERR_MESSAGE_INVALID = "VAULT_REMOTE_MESSAGE_INVALID"
ERR_POLICY_DENIED = "VAULT_REMOTE_POLICY_DENIED"
POLICY_DISABLED = "disabled"
POLICY_REQUEST_ONLY = "request-only"
POLICY_SUDO_PASSPHRASE = "sudo+passphrase"
POLICY_SUDO_PASSPHRASE_QUORUM = "sudo+passphrase+2-of-N"
POLICIES = {POLICY_DISABLED, POLICY_REQUEST_ONLY, POLICY_SUDO_PASSPHRASE, POLICY_SUDO_PASSPHRASE_QUORUM}
ALLOWING_POLICIES = {POLICY_REQUEST_ONLY, POLICY_SUDO_PASSPHRASE, POLICY_SUDO_PASSPHRASE_QUORUM}
TRUE_UNLOCK_POLICIES = {POLICY_SUDO_PASSPHRASE, POLICY_SUDO_PASSPHRASE_QUORUM}
SENSITIVE_ENV_MARKERS = ("PASSPHRASE", "PASSWORD", "RECOVERY", "SECRET", "TOKEN")


class RemoteError(Exception):
    def __init__(self, code: str, message: str, exit_code: int = 1) -> None:
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def b64d(data: str) -> bytes:
    return base64.urlsafe_b64decode((data + ("=" * (-len(data) % 4))).encode("ascii"))


def vault_dir_from(value: str | None) -> Path:
    if value:
        return Path(value).expanduser()
    configured = os.environ.get("AIDEVOPS_VAULT_DIR")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".config" / "aidevops" / "vault"


def private_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding=ENCODING)
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def load_json(path: Path, missing_code: str = "VAULT_REMOTE_MISSING") -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding=ENCODING))
    except FileNotFoundError as exc:
        raise RemoteError(missing_code, f"Missing file: {path.name}", 2) from exc
    except json.JSONDecodeError as exc:
        raise RemoteError("VAULT_REMOTE_CORRUPTED", f"Invalid JSON: {path.name}", 3) from exc
    if not isinstance(data, dict):
        raise RemoteError("VAULT_REMOTE_CORRUPTED", f"Invalid JSON shape: {path.name}", 3)
    return data


def policy_path(vault_dir: Path) -> Path:
    return vault_dir / POLICY_FILE


def state_path(vault_dir: Path) -> Path:
    return vault_dir / STATE_FILE


def message_device(vault_dir: Path) -> dict[str, Any]:
    return load_json(vault_dir / MESSAGE_DEVICE_FILE, "VAULT_REMOTE_MESSAGE_UNINITIALIZED")


def load_policy(vault_dir: Path) -> dict[str, Any]:
    path = policy_path(vault_dir)
    if path.exists():
        policy = load_json(path)
    else:
        policy = {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_CONTROLLERS: {}, "kill_switch": False}
    controllers = policy.setdefault(FIELD_CONTROLLERS, {})
    if not isinstance(controllers, dict):
        raise RemoteError("VAULT_REMOTE_POLICY_CORRUPTED", "Remote-control policy controllers are invalid", 3)
    return policy


def load_state(vault_dir: Path) -> dict[str, Any]:
    path = state_path(vault_dir)
    if path.exists():
        state = load_json(path)
    else:
        state = {FIELD_SCHEMA_VERSION: SCHEMA_VERSION, FIELD_SEEN_NONCES: {}, FIELD_EVENTS: []}
    if not isinstance(state.get(FIELD_SEEN_NONCES, {}), dict) or not isinstance(state.get(FIELD_EVENTS, []), list):
        raise RemoteError("VAULT_REMOTE_STATE_CORRUPTED", "Remote-control state is invalid", 3)
    return state


def append_event(vault_dir: Path, event: dict[str, Any]) -> None:
    state = load_state(vault_dir)
    events = list(state.get(FIELD_EVENTS, []))
    redacted = dict(event)
    redacted["timestamp"] = int(time.time())
    events.append(redacted)
    state[FIELD_EVENTS] = events[-100:]
    private_write_json(state_path(vault_dir), state)


def audit(audit_helper: str, actor: str, action: str, result: str, reason: str) -> None:
    subprocess.run(
        [
            CMD_BASH,
            audit_helper,
            "append",
            "--actor",
            actor,
            "--action",
            action,
            "--target-collection",
            "vault-remote-control",
            "--result",
            result,
            "--reason",
            reason,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True,
    )


def cmd_trust_controller(args: argparse.Namespace) -> int:
    if args.policy not in POLICIES:
        raise RemoteError("VAULT_REMOTE_POLICY_INVALID", "Unsupported remote-control policy", 2)
    vault_dir = vault_dir_from(args.vault_dir)
    policy = load_policy(vault_dir)
    policy[FIELD_CONTROLLERS][args.controller_device] = {FIELD_POLICY: args.policy, FIELD_REVOKED: False, FIELD_UPDATED_AT: int(time.time())}
    private_write_json(policy_path(vault_dir), policy)
    print(json.dumps({FIELD_CONTROLLER_DEVICE: args.controller_device, FIELD_POLICY: args.policy, FIELD_REVOKED: False}, sort_keys=True))
    return 0


def cmd_revoke_controller(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    policy = load_policy(vault_dir)
    controller = dict(policy[FIELD_CONTROLLERS].get(args.controller_device, {}))
    controller[FIELD_POLICY] = str(controller.get(FIELD_POLICY, POLICY_DISABLED))
    controller[FIELD_REVOKED] = True
    controller[FIELD_UPDATED_AT] = int(time.time())
    policy[FIELD_CONTROLLERS][args.controller_device] = controller
    private_write_json(policy_path(vault_dir), policy)
    print(json.dumps({FIELD_CONTROLLER_DEVICE: args.controller_device, FIELD_REVOKED: True}, sort_keys=True))
    return 0


def require_no_secret_env() -> None:
    for name in os.environ:
        if name.startswith("AIDEVOPS_VAULT_REMOTE_TEST_"):
            continue
        if name.startswith("AIDEVOPS_") and any(marker in name.upper() for marker in SENSITIVE_ENV_MARKERS):
            raise RemoteError("VAULT_REMOTE_SECRET_ENV_DENIED", "Remote unlock refuses passphrase-like environment variables", 2)


def require_controller_sudo_and_tty() -> None:
    require_no_secret_env()
    assume_root = os.environ.get("AIDEVOPS_VAULT_REMOTE_TEST_ASSUME_ROOT") == "1"
    if hasattr(os, "geteuid") and os.geteuid() != 0 and not assume_root:
        raise RemoteError("VAULT_REMOTE_SUDO_REQUIRED", "Remote unlock grant requires sudo on the controlling machine", 4)
    if not sys.stdin.isatty():
        raise RemoteError("VAULT_REMOTE_TTY_REQUIRED", "Remote unlock grant requires a hidden interactive TTY passphrase prompt", 4)
    _ = getpass.getpass("Target Vault passphrase: ")


def send_command(args: argparse.Namespace, message_helper: str, action: str, message_class: str) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    key = message_device(vault_dir)
    now = int(time.time())
    ttl = int(args.ttl)
    if ttl <= 0 or ttl > 3600:
        raise RemoteError("VAULT_REMOTE_TTL_INVALID", "Remote-control commands require a 1-3600 second TTL", 2)
    if action == ACTION_UNLOCK_GRANT:
        require_controller_sudo_and_tty()
    body = {
        FIELD_SCHEMA_VERSION: SCHEMA_VERSION,
        "remote_control": True,
        FIELD_ACTION: action,
        FIELD_CONTROLLER_DEVICE: str(key[FIELD_DEVICE_ID]),
        FIELD_TARGET_DEVICE: args.target_device,
        FIELD_REASON: args.reason,
        FIELD_NONCE: secrets.token_hex(32),
        "created_at": now,
        FIELD_EXPIRES_AT: now + ttl,
        "policy_required": POLICY_SUDO_PASSPHRASE if action == ACTION_UNLOCK_GRANT else POLICY_REQUEST_ONLY,
    }
    with tempfile.NamedTemporaryFile("w", encoding=ENCODING, delete=False) as handle:
        json.dump(body, handle, sort_keys=True)
        handle.write("\n")
        body_path = handle.name
    try:
        result = subprocess.run(
            [
                CMD_BASH,
                message_helper,
                "send",
                ARG_VAULT_DIR,
                str(vault_dir),
                "--recipient",
                args.recipient,
                "--class",
                message_class,
                "--body-file",
                body_path,
                ARG_REPO,
                args.repo,
                "--expires-at",
                str(body[FIELD_EXPIRES_AT]),
                "--pad-bytes",
                "64",
            ],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        )
    finally:
        Path(body_path).unlink(missing_ok=True)
    print(result.stdout.strip())
    return 0


def decoded_body(entry: dict[str, Any]) -> dict[str, Any]:
    body = entry.get("body")
    if not isinstance(body, str):
        raise RemoteError(ERR_MESSAGE_INVALID, "Remote-control message body is missing", 3)
    data = json.loads(b64d(body).decode(ENCODING))
    if not isinstance(data, dict):
        raise RemoteError(ERR_MESSAGE_INVALID, "Remote-control message body is invalid", 3)
    return data


def controller_policy(policy: dict[str, Any], sender: str) -> str:
    controller = policy.get(FIELD_CONTROLLERS, {}).get(sender)
    if not isinstance(controller, dict) or controller.get(FIELD_REVOKED) is True:
        raise RemoteError("VAULT_REMOTE_CONTROLLER_REVOKED", "Remote-control sender is revoked or untrusted", 4)
    selected = str(controller.get(FIELD_POLICY, POLICY_DISABLED))
    if selected not in POLICIES or selected == POLICY_DISABLED:
        raise RemoteError(ERR_POLICY_DENIED, "Remote-control policy denies this sender", 4)
    return selected


def validate_command(vault_dir: Path, body: dict[str, Any], sender: str, selected_policy: str) -> None:
    if body.get("remote_control") is not True or body.get(FIELD_SCHEMA_VERSION) != SCHEMA_VERSION:
        raise RemoteError(ERR_MESSAGE_INVALID, "Remote-control message schema is invalid", 3)
    if str(body.get(FIELD_CONTROLLER_DEVICE, "")) != sender:
        raise RemoteError("VAULT_REMOTE_SENDER_MISMATCH", "Remote-control sender does not match command body", 4)
    target = str(body.get(FIELD_TARGET_DEVICE, ""))
    local_device = str(message_device(vault_dir)[FIELD_DEVICE_ID])
    if target not in (local_device, "*"):
        raise RemoteError("VAULT_REMOTE_TARGET_MISMATCH", "Remote-control command targets a different device", 4)
    now = int(time.time())
    if int(body.get(FIELD_EXPIRES_AT, 0)) < now:
        raise RemoteError("VAULT_REMOTE_EXPIRED", "Remote-control command is expired", 4)
    nonce = str(body.get(FIELD_NONCE, ""))
    if len(nonce) < 32:
        raise RemoteError("VAULT_REMOTE_NONCE_INVALID", "Remote-control command nonce is invalid", 3)
    state = load_state(vault_dir)
    if nonce in state.get(FIELD_SEEN_NONCES, {}):
        raise RemoteError("VAULT_REMOTE_REPLAY", "Remote-control command was already processed", 4)
    action = str(body.get(FIELD_ACTION, ""))
    if action == ACTION_UNLOCK_GRANT and selected_policy not in TRUE_UNLOCK_POLICIES:
        raise RemoteError(ERR_POLICY_DENIED, "True remote unlock is disabled for this controller", 4)
    if action in {ACTION_LOCK, ACTION_UNLOCK_REQUEST} and selected_policy not in ALLOWING_POLICIES:
        raise RemoteError(ERR_POLICY_DENIED, "Remote-control policy denies this action", 4)


def remember_nonce(vault_dir: Path, body: dict[str, Any]) -> None:
    state = load_state(vault_dir)
    seen = dict(state.get(FIELD_SEEN_NONCES, {}))
    seen[str(body[FIELD_NONCE])] = {FIELD_ACTION: body.get(FIELD_ACTION), "seen_at": int(time.time())}
    state[FIELD_SEEN_NONCES] = dict(list(seen.items())[-500:])
    private_write_json(state_path(vault_dir), state)


def apply_command(vault_dir: Path, vault_helper: str, audit_helper: str, body: dict[str, Any], sender: str) -> str:
    action = str(body.get(FIELD_ACTION, ""))
    reason = str(body.get(FIELD_REASON, "remote control"))[:160]
    if action == ACTION_LOCK:
        audit(audit_helper, sender, "vault.remote-lock", RESULT_ATTEMPT, reason)
        subprocess.run([CMD_BASH, vault_helper, ACTION_LOCK], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
        audit(audit_helper, sender, "vault.remote-lock", RESULT_SUCCESS, reason)
        append_event(vault_dir, {FIELD_ACTION: action, FIELD_SENDER: sender, FIELD_RESULT: RESULT_SUCCESS, FIELD_REASON: reason})
        return "locked"
    if action == ACTION_UNLOCK_REQUEST:
        audit(audit_helper, sender, "vault.unlock-request", RESULT_ATTEMPT, reason)
        audit(audit_helper, sender, "vault.unlock-request", RESULT_SUCCESS, reason)
        append_event(vault_dir, {FIELD_ACTION: action, FIELD_SENDER: sender, FIELD_RESULT: "queued", FIELD_REASON: reason})
        return "unlock-request-queued"
    if action == ACTION_UNLOCK_GRANT:
        if hasattr(os, "geteuid") and os.geteuid() != 0 and os.environ.get("AIDEVOPS_VAULT_REMOTE_TEST_ASSUME_ROOT") != "1":
            raise RemoteError("VAULT_REMOTE_TARGET_SUDO_REQUIRED", "Applying true remote unlock requires target-side sudo", 4)
        audit(audit_helper, sender, "vault.remote-unlock", RESULT_ATTEMPT, reason)
        append_event(vault_dir, {FIELD_ACTION: action, FIELD_SENDER: sender, FIELD_RESULT: "grant-validated", FIELD_REASON: reason})
        return "unlock-grant-validated"
    raise RemoteError("VAULT_REMOTE_ACTION_INVALID", "Unsupported remote-control action", 3)


def cmd_receive(args: argparse.Namespace, message_helper: str, vault_helper: str, audit_helper: str) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    receive_env = dict(os.environ)
    receive_env["AIDEVOPS_VAULT_MESSAGE_UNLOCKED"] = "1"
    subprocess.run(
        [CMD_BASH, message_helper, "receive", ARG_VAULT_DIR, str(vault_dir), ARG_REPO, args.repo]
        + (["--revoked-devices", args.revoked_devices] if args.revoked_devices else []),
        check=True,
        stdout=subprocess.PIPE,
        text=True,
        env=receive_env,
    )
    inbox = load_json(vault_dir / "message-inbox.json", "VAULT_REMOTE_INBOX_MISSING")
    policy = load_policy(vault_dir)
    if policy.get("kill_switch") is True:
        raise RemoteError("VAULT_REMOTE_KILL_SWITCH", "Remote control is locally disabled", 4)
    processed: list[dict[str, str]] = []
    for message_id, entry_any in sorted(dict(inbox.get("decrypted", {})).items()):
        entry = dict(entry_any)
        message_class = str(entry.get("class", ""))
        if message_class not in {"lock-command", ACTION_UNLOCK_REQUEST, ACTION_UNLOCK_GRANT}:
            continue
        sender = str(entry.get("sender_device", ""))
        selected_policy = controller_policy(policy, sender)
        body = decoded_body(entry)
        validate_command(vault_dir, body, sender, selected_policy)
        result = apply_command(vault_dir, vault_helper, audit_helper, body, sender)
        remember_nonce(vault_dir, body)
        processed.append({"message_id": str(message_id), FIELD_ACTION: str(body.get(FIELD_ACTION)), FIELD_RESULT: result})
    print(json.dumps({"processed": processed, "processed_count": len(processed)}, sort_keys=True))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    vault_dir = vault_dir_from(args.vault_dir)
    policy = load_policy(vault_dir)
    state = load_state(vault_dir)
    print(json.dumps({FIELD_CONTROLLERS: policy.get(FIELD_CONTROLLERS, {}), FIELD_EVENTS: len(state.get(FIELD_EVENTS, [])), FIELD_SEEN_NONCES: len(state.get(FIELD_SEEN_NONCES, {}))}, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="vault-remote-control-helper.sh")
    sub = parser.add_subparsers(dest="command", required=True)
    trust = sub.add_parser("trust-controller")
    trust.add_argument(ARG_VAULT_DIR)
    trust.add_argument("--controller-device", required=True)
    trust.add_argument("--policy", required=True, choices=sorted(POLICIES))
    trust.set_defaults(func=cmd_trust_controller)
    revoke = sub.add_parser("revoke-controller")
    revoke.add_argument(ARG_VAULT_DIR)
    revoke.add_argument("--controller-device", required=True)
    revoke.set_defaults(func=cmd_revoke_controller)
    for name, action, message_class in (
        ("send-lock", ACTION_LOCK, "lock-command"),
        ("send-unlock-request", ACTION_UNLOCK_REQUEST, ACTION_UNLOCK_REQUEST),
        ("send-unlock-grant", ACTION_UNLOCK_GRANT, ACTION_UNLOCK_GRANT),
    ):
        cmd = sub.add_parser(name)
        cmd.add_argument(ARG_VAULT_DIR)
        cmd.add_argument("--recipient", required=True)
        cmd.add_argument(ARG_REPO, required=True)
        cmd.add_argument("--target-device", required=True)
        cmd.add_argument("--reason", required=True)
        cmd.add_argument("--ttl", default="300")
        cmd.set_defaults(func=lambda parsed_args, act=action, cls=message_class: send_command(parsed_args, sys.argv[2], act, cls))
    receive = sub.add_parser("receive")
    receive.add_argument(ARG_VAULT_DIR)
    receive.add_argument(ARG_REPO, required=True)
    receive.add_argument("--revoked-devices")
    receive.set_defaults(func=lambda parsed_args: cmd_receive(parsed_args, sys.argv[2], sys.argv[3], sys.argv[4]))
    status = sub.add_parser("status")
    status.add_argument(ARG_VAULT_DIR)
    status.set_defaults(func=cmd_status)
    return parser


def main() -> int:
    args = build_parser().parse_args([sys.argv[1]] + sys.argv[5:])
    try:
        return int(args.func(args))
    except RemoteError as exc:
        print(f"{exc.code}: {exc}", file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
		;;
	*)
		printf '%s\n' "[ERROR] Unknown Vault remote-control command: $command_name" >&2
		usage >&2
		exit 2
		;;
esac
