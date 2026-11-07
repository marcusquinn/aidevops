# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local host inventory CRUD and explicitly managed SSH aliases."""

import json
import os
from pathlib import Path

from tabby_host_files import apply, snapshot
from tabby_host_inventory import check_args, inventory, parser, temporary
from tabby_host_ssh import load, quote, render, validate
from tabby_host_ssh_scan import conflicts
from tabby_session_config import SessionError, endpoint, validate_host


SYSTEM_SSH_CONFIG = Path("/etc/ssh/ssh_config")


def display(args, data, selected):
    if args.operation == "show" and selected is None:
        raise SessionError("Unknown host ID")
    for host in ([selected] if args.operation == "show" else data["hosts"]):
        if args.operation == "show":
            print(json.dumps(host, indent=2))
        else:
            print("{}\t{}\t{}\t{}".format(host["id"], host["sshHost"],
                  host.get("sessionPrefix", "oc-"), "enabled" if host.get("enabled", True) else "disabled"))


def selected_host(args, selected, fields):
    if args.operation == "add" and selected is not None:
        raise SessionError("Host already exists; use update")
    if args.operation != "add" and selected is None:
        raise SessionError("Unknown host ID")
    host = dict(selected) if selected else {"id": args.id, "sshHost": args.ssh_host or args.id,
                                           "sessionPrefix": "oc-", "titlePrefix": args.id,
                                           "connectIntervalSeconds": 5}
    host.update(fields)
    validate_host(host, 0)
    return host


def delete_alias(args, host, aliases, data):
    alias = host["sshHost"]
    if alias not in aliases:
        raise SessionError("SSH alias is not aidevops-managed; remove without --ssh to keep it")
    if any(h["id"] != args.id and h["sshHost"].lower() == alias.lower() for h in data["hosts"]):
        raise SessionError("SSH alias is referenced by another inventory entry")
    del aliases[alias]


def update_alias(args, host, aliases, ssh_options):
    alias = host["sshHost"]
    if args.operation == "add" and alias in aliases:
        raise SessionError("SSH alias already managed; register without SSH options or use update")
    if args.operation == "update" and alias not in aliases:
        raise SessionError("SSH alias is user-owned; only inventory settings can be updated")
    options = dict(aliases.get(alias, {}))
    options.update(ssh_options)
    validate(options)
    if args.identity_file is not None and not Path(options["identity_file"]).is_file():
        raise SessionError("Identity file is unavailable")
    if any(k in host for k in ("port", "user", "identityFile")):
        raise SessionError("Inventory has legacy SSH overrides; migrate them manually before managing this alias")
    aliases[alias] = options


def ssh_changes(args, host, data, ssh_options):
    ssh_config = Path.home() / ".ssh/config"
    managed = Path.home() / ".ssh/aidevops.conf"
    if any(c in str(managed) for c in "\x00\r\n%$"):
        raise SessionError("SSH managed path cannot contain control characters or expansion tokens")
    raw_ssh = snapshot(ssh_config)
    raw_managed = snapshot(managed)
    aliases = load(raw_managed)
    alias = host["sshHost"]
    if alias not in aliases and any(a.lower() == alias.lower() for a in aliases):
        raise SessionError("Managed SSH alias exists with different casing; use its exact name")
    if conflicts(ssh_config, alias, managed):
        raise SessionError("Alias matches user-owned SSH configuration; refusing SSH changes")
    if conflicts(SYSTEM_SSH_CONFIG, alias, managed, include_base=SYSTEM_SSH_CONFIG.parent):
        raise SessionError("Alias matches system SSH configuration; refusing SSH changes")
    if args.ssh:
        delete_alias(args, host, aliases, data)
    else:
        update_alias(args, host, aliases, ssh_options)
    changes = [(managed, raw_managed, render(aliases))]
    # Lead with the Include, then reset Host scope to preserve global defaults.
    include = ("Include " + quote(str(managed)) + "\nHost *\n").encode()
    if not args.ssh and not (raw_ssh or b"").startswith(include):
        changes.append((ssh_config, raw_ssh, include + (raw_ssh or b"")))
    return changes


def edit_inventory(args, data, selected, host):
    if args.operation == "remove":
        data["hosts"].remove(selected)
    elif selected:
        data["hosts"][data["hosts"].index(selected)] = host
    else:
        data["hosts"].append(host)
    content = (json.dumps(data, indent=2) + "\n").encode()
    inventory(content)
    return content


def main(argv=None):
    args = parser().parse_args(argv)
    ssh_options, fields = check_args(args)
    config = Path(os.path.abspath(Path(args.config).expanduser()))
    if config in (Path.home() / ".ssh/config", Path.home() / ".ssh/aidevops.conf"):
        raise SessionError("Inventory and SSH paths must be different")
    print("Inventory: " + str(config))
    old = snapshot(config)
    data = inventory(old)
    selected = next((h for h in data["hosts"] if h["id"] == args.id), None)
    if args.operation in ("list", "show"):
        display(args, data, selected)
        return 0
    if temporary(config) and not args.allow_temporary_config:
        raise SessionError("Refusing temporary inventory; unset AIDEVOPS_TABBY_HOSTS or select --config; testing requires --allow-temporary-config")
    host = selected_host(args, selected, fields)
    changes = []
    if ssh_options or args.ssh:
        changes = ssh_changes(args, host, data, ssh_options)
    elif args.operation == "add":
        endpoint(validate_host(host, 0))  # Local ssh -G only; no remote probe.
    content = edit_inventory(args, data, selected, host)
    changes.append((config, old, content))
    print(("Would " if args.dry_run else "Will ") + args.operation + " host " + args.id + " (SSH alias: " + host["sshHost"] + ")")
    apply(changes, args.dry_run)
    if args.operation == "update" and ssh_options:
        print("Endpoint changed: existing tabs stay attached to their original endpoint; run list/restore afresh")
    print("No SSH connection requested; sessions, tabs, keys and attachment leases are unchanged")
    return 0
