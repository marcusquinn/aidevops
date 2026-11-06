# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local host inventory CRUD and explicitly managed SSH aliases."""

import argparse
import json
import os
from pathlib import Path

from tabby_host_files import apply, snapshot
from tabby_host_ssh import conflicts, load, quote, render, validate
from tabby_session_config import SessionError, endpoint, identifier, validate_host


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("operation", choices=("add", "update", "remove", "list", "show"))
    result.add_argument("id", nargs="?")
    result.add_argument("--config", default=os.environ.get(
        "AIDEVOPS_TABBY_HOSTS", str(Path.home() / ".config/aidevops/tabby-hosts.json")))
    result.add_argument("--dry-run", action="store_true")
    result.add_argument("--allow-temporary-config", action="store_true",
                        help="explicitly allow writes to a temporary inventory (testing only)")
    result.add_argument("--ssh", action="store_true", help="remove: also delete the managed SSH alias")
    result.add_argument("--ssh-host", help="add: existing alias (defaults to host ID)")
    result.add_argument("--hostname", help="create/update an aidevops-owned SSH alias")
    result.add_argument("--user")
    result.add_argument("--port", type=int)
    result.add_argument("--identity-file")
    result.add_argument("--session-prefix")
    result.add_argument("--title-prefix")
    result.add_argument("--connect-interval", type=int)
    result.add_argument("--restore-order", type=int)
    enabled = result.add_mutually_exclusive_group()
    enabled.add_argument("--enabled", dest="enabled", action="store_true", default=None)
    enabled.add_argument("--disabled", dest="enabled", action="store_false")
    return result


def inventory(raw):
    if raw is None:
        return {"version": 1, "hosts": []}
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeError):
        raise SessionError("Cannot parse host inventory") from None
    if not isinstance(data, dict) or set(data) != {"version", "hosts"} or type(data["version"]) is not int or data["version"] != 1 or not isinstance(data["hosts"], list):
        raise SessionError("Expected version 1 host inventory")
    seen = set()
    for index, source in enumerate(data["hosts"]):
        host = validate_host(source, index)
        if host["id"] in seen:
            raise SessionError("Duplicate host ID")
        seen.add(host["id"])
    return data


def check_args(args):
    if args.operation != "list":
        identifier(args.id, "host ID")
    elif args.id is not None:
        raise SessionError("list does not accept a host ID")
    ssh_options = {key: getattr(args, key) for key in ("hostname", "user", "port", "identity_file")
                   if getattr(args, key) is not None}
    fields = {key: value for key, value in {
        "sessionPrefix": args.session_prefix, "titlePrefix": args.title_prefix,
        "connectIntervalSeconds": args.connect_interval, "restoreOrder": args.restore_order,
        "enabled": args.enabled}.items() if value is not None}
    if args.operation not in ("add", "update") and (ssh_options or fields or args.ssh_host is not None):
        raise SessionError("Connection/session options require add or update")
    if args.ssh and args.operation != "remove":
        raise SessionError("--ssh is only valid with remove")
    if args.ssh_host is not None and args.operation != "add":
        raise SessionError("--ssh-host is only valid with add; remove/add to change an alias mapping")
    return ssh_options, fields


def temporary(path):
    roots = [Path("/tmp"), Path("/var/tmp"), Path("/private/tmp")]
    if os.environ.get("TMPDIR"):
        roots.append(Path(os.environ["TMPDIR"]).absolute())
    return any(root == path or root in path.parents for root in roots)


def main(argv=None):
    args = parser().parse_args(argv)
    ssh_options, fields = check_args(args)
    config = Path(os.path.abspath(Path(args.config).expanduser()))
    ssh_config = Path.home() / ".ssh/config"
    managed = Path.home() / ".ssh/aidevops.conf"
    if config in (ssh_config, managed):
        raise SessionError("Inventory and SSH paths must be different")
    print("Inventory: " + str(config))
    old = snapshot(config)
    data = inventory(old)
    selected = next((h for h in data["hosts"] if h["id"] == args.id), None)
    if args.operation in ("list", "show"):
        if args.operation == "show" and selected is None:
            raise SessionError("Unknown host ID")
        for host in ([selected] if args.operation == "show" else data["hosts"]):
            if args.operation == "show":
                print(json.dumps(host, indent=2))
            else:
                print("{}\t{}\t{}\t{}".format(host["id"], host["sshHost"],
                      host.get("sessionPrefix", "oc-"), "enabled" if host.get("enabled", True) else "disabled"))
        return 0
    if temporary(config) and not args.allow_temporary_config:
        raise SessionError("Refusing temporary inventory; unset AIDEVOPS_TABBY_HOSTS or select --config; testing requires --allow-temporary-config")
    if args.operation == "add" and selected is not None:
        raise SessionError("Host already exists; use update")
    if args.operation != "add" and selected is None:
        raise SessionError("Unknown host ID")
    host = dict(selected) if selected else {"id": args.id, "sshHost": args.ssh_host or args.id,
                                           "sessionPrefix": "oc-", "titlePrefix": args.id,
                                           "connectIntervalSeconds": 5}
    host.update(fields)
    validate_host(host, 0)
    alias = host["sshHost"]
    changes = []
    if ssh_options or args.ssh:
        if any(c in str(managed) for c in "\x00\r\n%$"):
            raise SessionError("SSH managed path cannot contain control characters or expansion tokens")
        raw_ssh = snapshot(ssh_config)
        raw_managed = snapshot(managed)
        aliases = load(raw_managed)
        if alias not in aliases and any(a.lower() == alias.lower() for a in aliases):
            raise SessionError("Managed SSH alias exists with different casing; use its exact name")
        if conflicts(ssh_config, alias, managed):
            raise SessionError("Alias matches user-owned SSH configuration; refusing SSH changes")
        if args.ssh:
            if alias not in aliases:
                raise SessionError("SSH alias is not aidevops-managed; remove without --ssh to keep it")
            if any(h["id"] != args.id and h["sshHost"].lower() == alias.lower() for h in data["hosts"]):
                raise SessionError("SSH alias is referenced by another inventory entry")
            del aliases[alias]
        else:
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
        changes.append((managed, raw_managed, render(aliases)))
        # A leading Include avoids first-value-wins shadowing by later defaults.
        # Reset Host scope so original top-level settings remain global.
        include = ("Include " + quote(str(managed)) + "\nHost *\n").encode()
        if not args.ssh and not (raw_ssh or b"").startswith(include):
            changes.append((ssh_config, raw_ssh, include + (raw_ssh or b"")))
    elif args.operation == "add":
        endpoint(validate_host(host, 0))  # Local ssh -G only; no remote probe.
    if args.operation == "remove":
        data["hosts"].remove(selected)
    elif selected:
        data["hosts"][data["hosts"].index(selected)] = host
    else:
        data["hosts"].append(host)
    content = (json.dumps(data, indent=2) + "\n").encode()
    inventory(content)
    changes.append((config, old, content))
    print(("Would " if args.dry_run else "Will ") + args.operation + " host " + args.id + " (SSH alias: " + alias + ")")
    apply(changes, args.dry_run)
    if args.operation == "update" and ssh_options:
        print("Endpoint changed: existing tabs stay attached to their original endpoint; run list/restore afresh")
    print("No SSH connection requested; sessions, tabs, keys and attachment leases are unchanged")
    return 0
