# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Pure validation for private Tabby host inventory, without SSH operations."""

import re
from pathlib import Path


class SessionError(Exception):
    """An intentionally sanitized operational failure."""


def identifier(value, label, pattern=r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}"):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise SessionError("Invalid " + label)
    return value


def validate_host_flags(host):
    for field in ("enabled", "identitiesOnly"):
        if field in host and type(host[field]) is not bool:
            raise SessionError(field + " must be boolean")


def validate_host(source, index):
    allowed = {"id", "sshHost", "titlePrefix", "sessionPrefix", "restoreOrder", "enabled",
               "connectIntervalSeconds", "port", "user", "identityFile", "identitiesOnly", "endpointId"}
    if not isinstance(source, dict) or set(source) - allowed:
        raise SessionError("Unknown host fields; arbitrary SSH options/hooks are not supported")
    host = dict(source)
    for field in ("id", "sshHost"):
        identifier(host.get(field), field)
    for field, default in (("titlePrefix", host["id"]), ("sessionPrefix", "oc-")):
        host[field] = identifier(host.get(field, default), field)
    identifier(host["sessionPrefix"], "sessionPrefix", r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}")
    host.setdefault("enabled", True)
    validate_host_flags(host)
    for field, default, low, high in (("restoreOrder", index, 0, 1000000),
                                     ("connectIntervalSeconds", 5, 0, 60),
                                     ("port", None, 1, 65535)):
        value = host.get(field, default)
        if value is not None and (type(value) is not int or not low <= value <= high):
            raise SessionError("Invalid " + field)
        host[field] = value
    if "user" in host:
        identifier(host["user"], "user", r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}")
    if "identityFile" in host:
        value = host["identityFile"]
        if not isinstance(value, str) or not value or any(c in value for c in "\x00\n\r"):
            raise SessionError("Invalid identityFile")
        identity = Path(value).expanduser()
        if not identity.is_absolute():
            raise SessionError("identityFile must be absolute or home-relative, not working-directory-relative")
        host["identityFile"] = str(identity)
    if "endpointId" in host:
        identifier(host["endpointId"], "endpointId")
    host["index"] = index
    return host
