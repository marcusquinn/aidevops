#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capture OpenCode's terminal render without changing the live session DB."""

import argparse
from contextlib import closing, suppress
import errno
import fcntl
import math
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import sqlite3
import struct
import sys
import tempfile
import termios
import time


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("seconds must be finite and positive")
    return seconds


def terminal_size(value):
    size = int(value)
    if not 1 <= size <= 65535:
        raise argparse.ArgumentTypeError("terminal size must be between 1 and 65535")
    return size


def exec_renderer(args, env):
    try:
        os.chdir(args.cwd)
        fcntl.ioctl(0, termios.TIOCSWINSZ,
                    struct.pack("HHHH", args.rows, args.cols, 0, 0))
        # Same argv-only process contract as runtime-launcher.py; the binary
        # is resolved before fork and the session is an argument, never shell code.
        os.execve(args.binary, [args.binary, "--session", args.session], env)  # nosec B606
    except OSError as error:
        os.write(2, f"tui-capture: {error}\n".encode())
        os._exit(127)


def read_render(fd, seconds):
    chunks = []
    query_tail = b""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        ready, _, _ = select.select([fd], [], [], min(0.25, remaining))
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError as error:
            if error.errno == errno.EIO:  # Linux PTYs signal child exit with EIO.
                break
            raise
        if not data:
            break
        chunks.append(data)
        queries = query_tail + data
        for query in re.finditer(rb"\x1b\[(\??)6n", queries):
            os.write(fd, b"\x1b[" + query.group(1) + b"1;1R")
        query_tail = re.sub(rb"\x1b\[\??6n", b"", queries)[-4:]
    return b"".join(chunks)


def stop_renderer(pid, reaped):
    # pty.fork owns a child session: signal its group, including plugins.
    with suppress(ProcessLookupError):
        os.killpg(pid, signal.SIGTERM)
    time.sleep(1)
    with suppress(ProcessLookupError):
        os.killpg(pid, signal.SIGKILL)
    if not reaped:
        os.waitpid(pid, 0)


def capture(args, data_dir):
    env = dict(os.environ)
    env.update(TERM="xterm-256color", XDG_DATA_HOME=str(data_dir),
               AIDEVOPS_OPENCODE_ISOLATED_DB="1")
    if args.tui_config:
        env["OPENCODE_TUI_CONFIG"] = str(Path(args.tui_config).resolve(strict=True))
    args.binary = shutil.which(args.binary)
    if not args.binary:
        raise ValueError("renderer binary not found")
    args.binary = str(Path(args.binary).resolve(strict=True))
    pid, fd = pty.fork()
    if pid == 0:
        exec_renderer(args, env)
    waited = 0
    try:
        raw = read_render(fd, args.seconds)
        waited, status = os.waitpid(pid, os.WNOHANG)
        return raw, status if waited else None
    finally:
        try:
            stop_renderer(pid, waited)
        finally:
            os.close(fd)


def plain_text(raw):
    text = raw.decode("utf-8", "replace")
    text = re.sub(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", "", text)
    text = re.sub(r"\x1b[PX^_].*?\x1b\\", "", text, flags=re.DOTALL)
    # Keep styled words together, but separate cursor-positioned screen runs.
    text = re.sub(r"\x1b\[[0-?]*[ -/]*m", "", text)
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "\n", text)
    text = re.sub(r"\x1b[ -/]*[@-~]", "", text)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    text = text.replace("\r", "\n")
    return re.sub(r"\n[ \t]*\n+", "\n", text).strip() + "\n"


def validate_output(args, source):
    output = Path(args.out).resolve()
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "opencode"
    protected = [source, Path(str(source) + "-wal"), Path(str(source) + "-shm"),
                 config / "tui.json", config / "opencode.json",
                 config / "opencode.jsonc", Path.home() / ".config/opencode/tui.json",
                 Path.home() / ".config/opencode/opencode.json"]
    if args.tui_config:
        protected.append(Path(args.tui_config))
    if env_config := os.environ.get("OPENCODE_CONFIG"):
        protected.extend([Path(env_config), Path(args.cwd) / env_config])
    for path in protected:
        if output == path.resolve():
            raise ValueError("output must not overwrite a session DB or configuration")
        with suppress(FileNotFoundError):
            if output.samefile(path):
                raise ValueError("output must not overwrite a session DB or configuration")
    return output


def check_render(text, expected, status):
    if not text.strip():
        raise ValueError("no screen text captured")
    missing = [item for item in expected if item not in text]
    if missing:
        raise ValueError("missing expected text: " + ", ".join(repr(item) for item in missing))
    if status is None:
        return
    exit_code = os.waitstatus_to_exitcode(status)
    if exit_code != 0:
        raise ValueError(f"renderer exited with status {exit_code}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cwd", default=os.getcwd())
    parser.add_argument("--data-dir", required=True, help="Source launcher XDG data directory")
    parser.add_argument("--tui-config", help="Temporary TUI config overlay (never edited)")
    parser.add_argument("--seconds", type=positive_seconds, default=20)
    parser.add_argument("--cols", type=terminal_size, default=200)
    parser.add_argument("--rows", type=terminal_size, default=50)
    parser.add_argument("--binary", default="opencode", help="V2/opencode2 is best effort")
    parser.add_argument("--expect", action="append", default=[], help="Required text (repeatable)")
    args = parser.parse_args()
    try:
        args.cwd = str(Path(args.cwd).resolve(strict=True))
        if not args.tui_config:
            inherited_tui = os.environ.get("OPENCODE_TUI_CONFIG")
            if inherited_tui:
                args.tui_config = str(Path(args.cwd) / inherited_tui)
        source = Path(args.data_dir).resolve() / "opencode" / "opencode.db"
        output = validate_output(args, source)
        if not source.is_file():
            raise ValueError("session database not found; specify the launcher --cwd or --data-dir")
        temp_root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", str(Path.home() / ".aidevops/.agent-workspace/tmp")))
        temp_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="tui-capture-", dir=temp_root) as temporary:
            data_dir = Path(temporary)
            database = data_dir / "opencode" / "opencode.db"
            database.parent.mkdir()
            # SQLite backup includes committed WAL data; never open the source
            # writable and never let the renderer migrate or update the live DB.
            with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as original:
                with closing(sqlite3.connect(database)) as snapshot:
                    original.backup(snapshot)
                    if not snapshot.execute("SELECT 1 FROM session WHERE id = ?", (args.session,)).fetchone():
                        raise ValueError("Session not found; check --session and launcher --cwd/--data-dir")
            raw, status = capture(args, data_dir)
        text = plain_text(raw)
        output.write_text(text, encoding="utf-8")
        check_render(text, args.expect, status)
        return 0
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"tui-capture: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
