# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Host-command arguments and validated local inventory schema."""

import argparse
import json
import os
from pathlib import Path

from tabby_session_config import SessionError, identifier, validate_host


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
    identities = result.add_mutually_exclusive_group()
    identities.add_argument("--identities-only", dest="identities_only", action="store_true", default=None,
                            help="offer only configured SSH identities, not unrelated agent keys")
    identities.add_argument("--no-identities-only", dest="identities_only", action="store_false")
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
    if not isinstance(data, dict):
        raise SessionError("Expected version 1 host inventory")
    if "version" not in data or "hosts" not in data:
        raise SessionError("Expected version 1 host inventory")
    if type(data["version"]) is not int or data["version"] != 1:
        raise SessionError("Expected version 1 host inventory")
    if not isinstance(data["hosts"], list):
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
        "enabled": args.enabled, "identitiesOnly": args.identities_only}.items() if value is not None}
    if args.identity_file is not None and args.identities_only is None:
        fields["identitiesOnly"] = True
    if args.operation not in ("add", "update") and (ssh_options or fields or args.ssh_host is not None):
        raise SessionError("Connection/session options require add or update")
    if args.ssh and args.operation != "remove":
        raise SessionError("--ssh is only valid with remove")
    if args.ssh_host is not None and args.operation != "add":
        raise SessionError("--ssh-host is only valid with add; remove/add to change an alias mapping")
    return ssh_options, fields


def temporary(path):
    roots = [Path("/tmp"), Path("/var/tmp"), Path("/private/tmp")]  # nosec B108 - refusing these paths, not creating temp files
    if os.environ.get("TMPDIR"):
        roots.append(Path(os.environ["TMPDIR"]).absolute())
    return any(root == path or root in path.parents for root in roots)
