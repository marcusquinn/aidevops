"""Linux screen-time source orchestration and trusted command execution."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

from screen_time_linux_logind import collect_linux_events, linux_payload
from screen_time_linux_wtmp import wtmp_payload


def run_trusted_command(executable_name, arguments):
    executable = shutil.which(executable_name)
    if not executable or not os.path.isabs(executable):
        return None, "executable-not-found"
    try:
        # The executable is resolved to an absolute path and callers supply a
        # fixed argv shape; no command text reaches a shell.
        result = subprocess.run(  # nosec B603
            [executable, *arguments], check=False, capture_output=True, text=True, timeout=30
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, type(exc).__name__
    if result.returncode != 0:
        return None, f"exit-{result.returncode}"
    return result.stdout.splitlines(), None


def fixture_lines(variable):
    fixture = os.environ.get(variable)
    if not fixture:
        return None, None
    try:
        return Path(fixture).read_text(encoding="utf-8").splitlines(), None
    except OSError as exc:
        return [], f"fixture-read-failed:{type(exc).__name__}"


def journal_lines():
    lines, error = fixture_lines("AIDEVOPS_LOGIND_FIXTURE")
    if lines is not None or error:
        return lines or [], error
    lines, error = run_trusted_command(
        "journalctl",
        ["--since", "366 days ago", "-u", "systemd-logind.service", "--no-pager", "-o", "short-iso"],
    )
    return lines or [], f"journal-read-failed:{error}" if error else None


def read_wtmp_lines(user, journal_reason):
    lines, error = fixture_lines("AIDEVOPS_LAST_FIXTURE")
    if lines is not None or error:
        return lines, error
    lines, error = run_trusted_command("last", ["-F", "-s", "-365days", user])
    return lines, f"{journal_reason};wtmp-read-failed:{error}" if error else None


def wtmp_collection(now, user, journal_reason):
    lines, error = read_wtmp_lines(user, journal_reason)
    return wtmp_payload(lines or [], error, now, journal_reason)


def linux_collection(now, user):
    lines, error = journal_lines()
    if error:
        return wtmp_collection(now, user, error)
    intervals, observations = collect_linux_events(lines, now, user)
    if not observations:
        return wtmp_collection(now, user, "journal-readable-no-user-observations")
    return linux_payload(intervals, observations, now)
