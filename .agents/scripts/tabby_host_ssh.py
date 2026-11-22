# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Strictly owned OpenSSH alias file, separate from user-owned Host blocks."""

import ipaddress
import json
import re
from pathlib import Path

from tabby_session_config import SessionError, identifier

HEADER = "# aidevops-managed SSH aliases; edit with aidevops tabby sessions host\n"
FIELDS = {"hostname": "HostName", "user": "User", "port": "Port", "identity_file": "IdentityFile"}


def quote(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def validate(options):
    if not isinstance(options, dict) or set(options) - FIELDS.keys():
        raise SessionError("Invalid managed SSH fields")
    hostname = options.get("hostname")
    if not isinstance(hostname, str) or any(c in hostname for c in "%$"):
        raise SessionError("Invalid hostname; use a DNS name or IP address")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", hostname):
            raise SessionError("Invalid hostname; use a DNS name or IP address")
    if "user" in options:
        identifier(options["user"], "user", r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}")
    if "port" in options and (type(options["port"]) is not int or not 1 <= options["port"] <= 65535):
        raise SessionError("Invalid SSH port")
    if "identity_file" in options:
        value = options["identity_file"]
        if not isinstance(value, str) or not value or any(c in value for c in "\x00\r\n%$"):
            raise SessionError("Invalid identity file; SSH token/environment expansion is not supported")
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise SessionError("Identity file must be an absolute or home-relative path")
        options["identity_file"] = str(path)


def render(aliases):
    text = HEADER + "# data: " + json.dumps(aliases, sort_keys=True) + "\n"
    for alias, options in sorted(aliases.items()):
        identifier(alias, "SSH alias")
        validate(options)
        text += "\nHost " + alias + "\n"
        for key, directive in FIELDS.items():
            if key in options:
                text += "    " + directive + " " + quote(options[key]) + "\n"
    return text.encode()


def load(raw):
    if raw is None:
        return {}
    try:
        lines = raw.decode().splitlines()
        aliases = json.loads(lines[1].removeprefix("# data: "))
        if not isinstance(aliases, dict) or render(aliases) != raw:
            raise ValueError
        return aliases
    except (ValueError, IndexError, AttributeError, TypeError, SessionError):
        raise SessionError("Managed SSH file was edited externally; refusing to overwrite it") from None
