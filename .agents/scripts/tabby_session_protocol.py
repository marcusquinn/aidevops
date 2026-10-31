# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Frame command stdout without trusting SSH/login-shell startup output."""

import secrets
import shlex

from tabby_session_config import SessionError


def framed_command(script):
    marker = "AIDEVOPS_RESPONSE_" + secrets.token_hex(24)
    begin, end = "\n" + marker + ":BEGIN\n", "\n" + marker + ":END\n"
    # Subshell contains script exits; the wrapper preserves their status and
    # completes framing even for an empty inventory. Never rerun a command.
    wrapped = "printf '%s' " + shlex.quote(begin) + "\n(\n" + script + "\n)\n"
    wrapped += "aidevops_rc=$?\nprintf '%s' " + shlex.quote(end) + '\nexit "$aidevops_rc"\n'
    return begin, end, wrapped


def extract_response(output, begin, end):
    if output.count(begin) != 1 or output.count(end) != 1:
        raise SessionError("SSH response boundaries missing/ambiguous; command completion unverified (private output withheld)")
    _outside, _begin, remaining = output.partition(begin)
    payload, found, _outside = remaining.partition(end)
    if not found:
        raise SessionError("SSH response boundaries out of order (private output withheld)")
    return payload
