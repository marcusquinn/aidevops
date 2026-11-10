# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""macOS human input evidence for the shared input-activity sampler.

``HIDIdleTime`` on IOHIDSystem is the nanoseconds since the last keyboard,
mouse or trackpad event. Reading it needs no privacy permission and reveals
no keystrokes, titles or content. Declared user-activity assertions
(``caffeinate -u``) do not reset it, so it measures human input rather than
display-on time. Input counts only while this user owns the unlocked console,
matching the Linux sampler's locked-session rule; screen_time_linux_activity
turns samples into active intervals that end an idle cut-off after the input.
"""

from __future__ import annotations

import json
import os
import plistlib
import re
from pathlib import Path
from xml.parsers.expat import ExpatError

from screen_time_interval_common import safe_float
from screen_time_linux import run_trusted_command
from screen_time_linux_activity import activity_collection, record_sample

COLLECTOR = "macos-input-activity"
HID_IDLE = re.compile(r'"HIDIdleTime" = ([0-9]+)')
NANOSECONDS_PER_SECOND = 1e9


def hid_idle_seconds():
    lines, error = run_trusted_command("ioreg", ["-c", "IOHIDSystem", "-r", "-k", "HIDIdleTime", "-d", "1"], 10)
    values = [int(value) for line in lines or [] for value in HID_IDLE.findall(line)] if not error else []
    # Several HID systems can report; the smallest idle is the latest input.
    return min(values) / NANOSECONDS_PER_SECOND if values else None


def console_root():
    lines, error = run_trusted_command("ioreg", ["-n", "Root", "-d", "1", "-a"], 10)
    if error:
        return {}
    try:
        payload = plistlib.loads("\n".join(lines).encode("utf-8"))
    except (ValueError, ExpatError):
        return {}
    if isinstance(payload, list):
        payload = next((item for item in payload if isinstance(item, dict)), {})
    return payload if isinstance(payload, dict) else {}


def console_state(root, uid):
    """Return (locked, on_console) from IORegistry Root; None when unknown."""
    locked = root.get("IOConsoleLocked")
    users = root.get("IOConsoleUsers")
    on_console = None
    if isinstance(users, list):
        on_console = any(
            isinstance(user, dict) and user.get("kCGSSessionUserIDKey") == uid and user.get("kCGSSessionOnConsoleKey") is True
            for user in users
        )
    return (locked if isinstance(locked, bool) else None), on_console


class SystemProbe:
    """Read live HID idle time and console ownership."""

    def __init__(self):
        self.uid = os.getuid()

    def idle_seconds(self):
        return hid_idle_seconds()

    def console(self):
        return console_state(console_root(), self.uid)


class FixtureProbe:
    """Deterministic probe for tests (AIDEVOPS_HID_IDLE_FIXTURE)."""

    def __init__(self, payload):
        self.payload = payload if isinstance(payload, dict) else {}

    def idle_seconds(self):
        return safe_float(self.payload.get("idle_seconds"))

    def console(self):
        locked, on_console = self.payload.get("locked"), self.payload.get("on_console")
        return (locked if isinstance(locked, bool) else None), (on_console if isinstance(on_console, bool) else None)


def gather_evidence(now, probe):
    locked, on_console = probe.console()
    if locked:
        return {"last_input": None, "kinds": ["locked"]}
    if on_console is False:
        # Fast user switching: the HID idle clock belongs to another user's session.
        return {"last_input": None, "kinds": ["not-console-user"]}
    idle = probe.idle_seconds()
    if idle is None or idle < 0:
        return {"last_input": None, "kinds": ["hid-idle-unavailable"]}
    kinds = ["hid-idle"] + ([] if locked is not None and on_console is not None else ["console-state-unknown"])
    return {"last_input": now - idle, "kinds": kinds}


def probe_for():
    fixture = os.environ.get("AIDEVOPS_HID_IDLE_FIXTURE")
    if not fixture:
        return SystemProbe()
    try:
        return FixtureProbe(json.loads(Path(fixture).read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return FixtureProbe({})


def macos_input_sample(now, directory):
    return record_sample(directory, now, gather_evidence(now, probe_for()), COLLECTOR)


def macos_input_collection(now, directory):
    return activity_collection(directory, now, COLLECTOR)
