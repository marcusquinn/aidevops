#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Closed lease data contracts; no credential-store or process operations."""
import json
import os
import re
import select
import stat
import time

LIMIT = 65536
# Common hooks are denied, but callers must still select only reviewed names.
RESERVED_NAMES = frozenset({
    "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "ENV", "GNUPGHOME", "SHELLOPTS",
    "GCONV_PATH", "IFS", "PS4", "PROMPT_COMMAND", "GIT_SSH", "GIT_SSH_COMMAND",
    "GIT_ASKPASS", "SSH_ASKPASS", "GIT_EXTERNAL_DIFF", "GIT_EXEC_PATH",
    "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS"})
RESERVED_PREFIXES = r"(?:LD_|DYLD_|NODE_|PYTHON|BASH_|AIDEVOPS_|GIT_CONFIG|PERL5|RUBY)"


def require(condition, reason):
    """Enforce preconditions even with Python assertions disabled."""
    if not condition:
        raise ValueError(reason)


def validate_values(values):
    require(isinstance(values, dict), "values")
    require(1 <= len(values) <= 16, "values")
    for name, value in values.items():
        require(re.fullmatch(r"[A-Z][A-Z0-9_]{0,95}", name), "values")
        require(isinstance(value, str), "values")
        require(value, "values")
        require("\0" not in value, "values")
        require(name not in RESERVED_NAMES, "values")
        require(not re.match(RESERVED_PREFIXES, name), "values")
    require(len(json.dumps(values).encode()) <= LIMIT, "values")
    return values


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate-key")
        result[key] = value
    return result


def closed_json(data):
    return json.loads(data, object_pairs_hook=_unique_object)


def validate_contract(contract):
    require(isinstance(contract, dict) and set(contract) == {
        "version", "configurationNames", "results"}, "contract")
    require(type(contract["version"]) is int and contract["version"] == 1, "contract")
    names = contract["configurationNames"]
    require(isinstance(names, list) and len(names) <= 16, "contract")
    require(all(isinstance(name, str) for name in names) and len(set(names)) == len(names), "contract")
    for name in names:
        if name != "NODE_ENV":
            validate_values({name: "contract-placeholder"})
    results = contract["results"]
    require(isinstance(results, list) and 1 <= len(results) <= 64, "contract")
    for entry in results:
        require(isinstance(entry, dict) and set(entry) == {"exitCode", "value"}, "contract")
        require(type(entry["exitCode"]) is int and 0 <= entry["exitCode"] <= 255, "contract")
        value = entry["value"]
        require(isinstance(value, dict) and 1 <= len(value) <= 8, "contract")
        for key, literal in value.items():
            require(re.fullmatch(r"[a-z][A-Za-z0-9]{0,63}", key), "contract")
            require(type(literal) is bool or
                    (type(literal) is int and 0 <= literal <= 9007199254740991) or
                    (isinstance(literal, str) and
                     re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", literal)), "contract")
    return contract


def read_configuration(descriptor, names):
    """Bounded pipe/socket input, never argv, plaintext files or ambient lookup."""
    require(type(descriptor) is int and descriptor >= 3, "configuration")
    mode = os.fstat(descriptor).st_mode
    require(stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode), "configuration")
    data = bytearray()
    deadline = time.monotonic() + 5
    try:
        os.set_blocking(descriptor, False)
        while True:
            remaining = deadline - time.monotonic()
            require(remaining > 0 and select.select([descriptor], [], [], remaining)[0], "configuration")
            try:
                part = os.read(descriptor, min(4096, LIMIT + 1 - len(data)))
            except BlockingIOError:
                continue  # Readiness must not turn a raced pipe into an unbounded read.
            if not part:
                break
            data.extend(part)
            require(len(data) <= LIMIT, "configuration")
    finally:
        os.close(descriptor)
    values = closed_json(data)
    require(isinstance(values, dict) and set(values) == set(names), "configuration")
    for name, value in values.items():
        if name == "NODE_ENV":
            require(value in ("development", "test"), "configuration")
        else:
            validate_values({name: value})
    return values
