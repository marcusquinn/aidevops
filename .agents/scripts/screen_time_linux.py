"""Linux screen time from sampled human input evidence.

Login sessions, unlocked sessions and open lids are not screen time: always-on
hosts, SSH/tmux sessions and desktops that never lock report ~24h/day. Each
sample instead reads only input timestamps (never keystrokes, titles or
content):

- terminal sessions (SSH, console, attached tmux/screen clients): the access
  time of /dev/<tty>, which the kernel advances only when the tty delivers input;
- graphical sessions: desktop idle time over the session bus (GNOME Mutter
  IdleMonitor, org.freedesktop.ScreenSaver on KDE and others) or xprintidle,
  else the logind IdleHint when the desktop maintains it.

Locked sessions never count. screen_time_linux_activity turns samples into
active intervals that end an idle cut-off after the last input.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from screen_time_interval_common import safe_float
from screen_time_linux_activity import activity_collection, record_sample

GRAPHICAL_TYPES = ("x11", "wayland", "mir")
TTY_NAME = re.compile(r"(?:pts/[0-9]+|tty[A-Za-z]*[0-9]+)")
SESSION_ID = re.compile(r"[A-Za-z0-9_.-]+")
SESSION_PROPERTIES = ("Type", "Class", "State", "TTY", "LockedHint", "IdleHint", "IdleSinceHint")
# (evidence kind, executable, argv, milliseconds per reported unit)
DESKTOP_IDLE_QUERIES = (
    ("gnome-idle-monitor", "busctl", ["--user", "call", "org.gnome.Mutter.IdleMonitor",
                                      "/org/gnome/Mutter/IdleMonitor/Core", "org.gnome.Mutter.IdleMonitor",
                                      "GetIdletime"], 1),
    ("screensaver-idle", "busctl", ["--user", "call", "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver",
                                    "org.freedesktop.ScreenSaver", "GetSessionIdleTime"], 1000),
    ("xprintidle", "xprintidle", [], 1),
)


def run_trusted_command(executable_name, arguments, timeout=30, env=None):
    executable = shutil.which(executable_name)
    if not executable or not os.path.isabs(executable):
        return None, "executable-not-found"
    try:
        # The executable is resolved to an absolute path and callers supply a
        # fixed argv shape; no command text reaches a shell.
        result = subprocess.run(  # nosec B603
            [executable, *arguments], check=False, capture_output=True, text=True, timeout=timeout, env=env
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, type(exc).__name__
    if result.returncode != 0:
        return None, f"exit-{result.returncode}"
    return result.stdout.splitlines(), None


def session_bus_env():
    """Cron lacks XDG_RUNTIME_DIR; busctl --user needs it to find the bus."""
    env = dict(os.environ)
    runtime = env.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    if Path(runtime).is_dir():
        env["XDG_RUNTIME_DIR"] = runtime
    return env


def first_number(lines):
    tokens = lines[0].split() if lines else []
    return safe_float(tokens[-1]) if tokens else None


class SystemProbe:
    """Read live logind, tty, utmp and desktop idle state."""

    def __init__(self, user):
        self.user = user
        self.env = session_bus_env()

    def sessions(self):
        lines, error = run_trusted_command("loginctl", ["show-user", self.user, "-p", "Sessions", "--value"], 10)
        ids = " ".join(lines or []).split() if not error else []
        return [self.session(item) for item in ids if SESSION_ID.fullmatch(item)]

    def session(self, session_id):
        arguments = ["show-session", session_id]
        for name in SESSION_PROPERTIES:
            arguments += ["-p", name]
        lines, _ = run_trusted_command("loginctl", arguments, 10)
        return dict(line.partition("=")[::2] for line in lines or [] if "=" in line)

    def tty_atime(self, tty):
        try:
            return os.stat(f"/dev/{tty}").st_atime
        except OSError:
            return None

    def desktop_idle(self):
        for kind, executable, arguments, unit_ms in DESKTOP_IDLE_QUERIES:
            if executable == "xprintidle" and not self.env.get("DISPLAY"):
                continue
            lines, error = run_trusted_command(executable, arguments, 5, self.env)
            value = None if error else first_number(lines)
            if value is not None and value >= 0:
                return value * unit_ms / 1000, kind
        return None, None

    def who_ttys(self):
        lines, _ = run_trusted_command("who", [], 10)
        rows = [line.split() for line in lines or []]
        return [row[1] for row in rows if len(row) >= 2 and row[0] == self.user]


class FixtureProbe:
    """Deterministic probe for tests (AIDEVOPS_SCREEN_ACTIVITY_FIXTURE)."""

    def __init__(self, payload):
        self.payload = payload if isinstance(payload, dict) else {}

    def sessions(self):
        return [item for item in self.payload.get("sessions", []) if isinstance(item, dict)]

    def tty_atime(self, tty):
        atimes = self.payload.get("tty_atime")
        return safe_float(atimes.get(tty)) if isinstance(atimes, dict) else None

    def desktop_idle(self):
        value = safe_float(self.payload.get("desktop_idle_seconds"))
        return (value, "fixture-desktop-idle") if value is not None else (None, None)

    def who_ttys(self):
        return [str(item) for item in self.payload.get("who", [])]


def tty_evidence(tty, probe):
    if not TTY_NAME.fullmatch(tty or ""):
        return None, None
    atime = probe.tty_atime(tty)
    return (atime, "tty-atime") if atime is not None else (None, "tty-unreadable")


def graphical_evidence(props, now, desktop):
    idle, kind = desktop
    if idle is not None:
        return now - idle, kind
    if (safe_float(props.get("IdleSinceHint")) or 0) <= 0:
        # The desktop never maintained logind's idle hint: unobservable, not active.
        return None, "graphical-idle-unavailable"
    return (now, "logind-idle-hint") if props.get("IdleHint") == "no" else (None, "logind-idle-hint")


def session_evidence(props, now, probe, desktop):
    if not str(props.get("Class", "user")).startswith("user") or props.get("State") == "closing":
        return None, None
    if props.get("LockedHint") == "yes":
        return None, "locked"
    if props.get("Type") in GRAPHICAL_TYPES:
        return graphical_evidence(props, now, desktop)
    return tty_evidence(props.get("TTY", ""), probe)


def combined_evidence(results, now):
    inputs = [min(now, value) for value, _ in results if value is not None]
    kinds = sorted({kind for _, kind in results if kind})
    return {"last_input": max(inputs, default=None), "kinds": kinds}


def gather_evidence(now, probe):
    sessions = probe.sessions()
    graphical = any(item.get("Type") in GRAPHICAL_TYPES for item in sessions)
    desktop = probe.desktop_idle() if graphical else (None, None)
    results = [session_evidence(item, now, probe, desktop) for item in sessions]
    # utmp also covers hosts without logind and sessions logind lists without a TTY.
    session_ttys = {item.get("TTY") for item in sessions}
    results += [tty_evidence(tty, probe) for tty in sorted(set(probe.who_ttys()) - session_ttys)]
    return combined_evidence(results, now)


def probe_for(user):
    fixture = os.environ.get("AIDEVOPS_SCREEN_ACTIVITY_FIXTURE")
    if not fixture:
        return SystemProbe(user)
    try:
        return FixtureProbe(json.loads(Path(fixture).read_text(encoding="utf-8")))
    except (OSError, ValueError):
        return FixtureProbe({})


def linux_sample(now, user, directory):
    return record_sample(directory, now, gather_evidence(now, probe_for(user)))


def linux_collection(now, directory):
    return activity_collection(directory, now)
