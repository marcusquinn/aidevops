# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Tabby command-array transport and local launch planning, not profile sync."""

import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from tabby_session_config import SessionError
from tabby_session_legacy import legacy_state
from tabby_session_state import lease, state_directory, state_key


@dataclass
class LaunchContext:
    args: object
    binary: str
    host: dict
    endpoint_id: str
    clients: set
    sessions: list


def report(host, session, status, detail=""):
    print("{}\t{}\t{}{}".format(host["id"], session["name"], status, "\t" + detail if detail else ""), flush=True)


def launch_argv(context, session, key, token):
    # Tabby 1.0.236 array option; no shell fragments, even for paths with spaces.
    script = str(Path(__file__).with_name("tabby_sessions.py").absolute())
    command = [sys.executable, script, "_attach", context.host["id"],
               "--config", context.args.config, "--state-dir", context.args.state_dir,
               "--key", key, "--token", token,
               "--identity", ":".join(session[k] for k in ("sid", "created", "server"))]
    return [context.binary, "run"] + ["--command=" + arg for arg in command]


def request(context, session, legacy):
    status = legacy_state(legacy, session, context.sessions)
    if status:
        report(context.host, session, "skipped", status)
        return "skipped"
    key = state_key(context.endpoint_id, session)
    directory = state_directory(context.args.state_dir)
    try:
        with lease(directory, key) as handle:
            status = handle.observe(context.clients, session["sid"])
            if status != "missing":
                report(context.host, session, "skipped", status)
                return status
            token = handle.reserve()
    finally:
        os.close(directory)
    try:
        # Fixed executable and array transport; every field remains one argv.
        result = subprocess.run(  # nosec B603 - validated Tabby path, no shell
            launch_argv(context, session, key, token), capture_output=True, timeout=20, check=False)
        if result.returncode:
            raise SessionError("Tabby launch failed; remote session retained")
    except (OSError, subprocess.TimeoutExpired, SessionError):
        # Keep the bounded nonce even on failure: Tabby may have received it.
        report(context.host, session, "failed", "launch uncertain; remote work retained; retry restore after 120s")
        return "failed"
    report(context.host, session, "requested", "pending Run/authentication; not proof of attachment")
    return "requested"


def observe(state, key, clients, sid):
    try:
        directory = state_directory(state, create=False)
    except FileNotFoundError:
        return "missing"
    try:
        with lease(directory, key, create=False) as handle:
            return handle.observe(clients, sid)
    except FileNotFoundError:
        return "missing"
    finally:
        os.close(directory)


def tabby_executable():
    override = os.environ.get("AIDEVOPS_TABBY_BIN")
    candidates = [override] if override else [shutil.which("tabby"),
        "/Applications/Tabby.app/Contents/MacOS/Tabby",
        str(Path.home() / "Applications/Tabby.app/Contents/MacOS/Tabby")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).absolute())
    raise SessionError("Tabby executable unavailable")


def check_tabby(binary):
    try:
        # Locally discovered executable; fixed, non-mutating CLI probes.
        version = subprocess.run(  # nosec B603 - validated executable, fixed argv
            [binary, "--version"], capture_output=True, text=True, timeout=15, check=False)
        help_text = subprocess.run(  # nosec B603 - validated executable, fixed argv
            [binary, "run", "--help"], capture_output=True, text=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise SessionError("Tabby CLI probe failed") from None
    if "1.0.235" in version.stdout or "stripAnsi" in version.stderr + help_text.stderr:
        raise SessionError("Broken Tabby CLI (stripAnsi); upgrade Tabby, do not patch its archive")
    if version.returncode or help_text.returncode or "--command" not in help_text.stdout:
        raise SessionError("Unsupported Tabby CLI: run --command array is required")
    match = re.search(r"\b\d+\.\d+\.\d+\b", version.stdout)
    return match.group() if match else "version unknown"
