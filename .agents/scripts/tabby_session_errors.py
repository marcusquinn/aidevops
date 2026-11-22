# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Sanitized SSH error categories; never expose private transport diagnostics."""

from tabby_session_config import SessionError


class TransientSSHError(SessionError):
    """A transport failure that permits retrying read-only inventory, not creation."""


SSH_FAILURES = (
    (("too many authentication failures",), SessionError,
     "SSH rejected too many identities; select the correct key and enable identitiesOnly"),
    (("permission denied", "authentication failed"), SessionError,
     "SSH authentication failed; prepare agent/MFA privately"),
    (("host key verification failed", "remote host identification has changed"), SessionError,
     "SSH host key verification failed; verify the host key privately"),
    (("connection reset", "connection closed", "connection timed out", "operation timed out",
      "session open refused by peer", "administratively prohibited", "exceeded maxstartups",
      "too many unauthenticated connections"), TransientSSHError,
     "SSH connection/channel unavailable; check server connection limits or multiplexing if persistent"),
)


def probe_error(returncode, stderr):
    """Classify privately; never include server/user/key paths or raw SSH logs."""
    error_type = SessionError
    message = "SSH/tmux probe failed (exit {}); prepare agent/MFA or SSH multiplexing privately".format(returncode)
    if returncode == 255:
        diagnostic = stderr.lower()
        for patterns, category, hint in SSH_FAILURES:
            if any(text in diagnostic for text in patterns):
                error_type, message = category, hint
                break
    elif returncode == 71:
        message = "Remote tmux inventory command failed (SSH reached the host)"
    return error_type(message)
