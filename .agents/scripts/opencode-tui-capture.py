#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capture OpenCode's terminal render without changing the live session DB."""

import argparse
from contextlib import closing
import errno
import fcntl
import math
import os
from pathlib import Path
import pty
import re
import select
import signal
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


def capture(args, data_dir):
    env = dict(os.environ)
    env.update(TERM="xterm-256color", XDG_DATA_HOME=str(data_dir),
               AIDEVOPS_OPENCODE_ISOLATED_DB="1")
    if args.tui_config:
        env["OPENCODE_TUI_CONFIG"] = str(Path(args.tui_config).resolve(strict=True))
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.chdir(args.cwd)
            fcntl.ioctl(0, termios.TIOCSWINSZ,
                        struct.pack("HHHH", args.rows, args.cols, 0, 0))
            os.execvpe(args.binary, [args.binary, "--session", args.session], env)
        except OSError as error:
            os.write(2, f"tui-capture: {error}\n".encode())
            os._exit(127)
    chunks = []
    query_tail = b""
    status = None
    natural_status = None
    try:
        deadline = time.monotonic() + args.seconds
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
        waited, status = os.waitpid(pid, os.WNOHANG)
        if not waited:
            status = None
        natural_status = status
    finally:
        # pty.fork creates a child session: terminate its group, including any
        # servers/plugins it started, then reap the child even on exceptions.
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        grace = time.monotonic() + 1
        while status is None and time.monotonic() < grace:
            waited, child_status = os.waitpid(pid, os.WNOHANG)
            if waited:
                status = child_status
            else:
                time.sleep(0.05)
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if status is None:
            _, status = os.waitpid(pid, 0)
        os.close(fd)
    return b"".join(chunks), natural_status


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
        output = Path(args.out).resolve()
        config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "opencode"
        protected = [source, Path(str(source) + "-wal"), Path(str(source) + "-shm"),
                     config / "tui.json", config / "opencode.json",
                     config / "opencode.jsonc", Path.home() / ".config/opencode/tui.json",
                     Path.home() / ".config/opencode/opencode.json"]
        if args.tui_config:
            protected.append(Path(args.tui_config))
        if env_config := os.environ.get("OPENCODE_CONFIG"):
            protected.append(Path(env_config))
            protected.append(Path(args.cwd) / env_config)
        if any(output == path.resolve() or (output.exists() and path.exists()
                                           and output.samefile(path)) for path in protected):
            raise ValueError("output must not overwrite a session DB or configuration")
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
        if not raw or not text.strip():
            raise ValueError("no screen text captured")
        missing = [expected for expected in args.expect if expected not in text]
        if missing:
            raise ValueError("missing expected text: " + ", ".join(repr(item) for item in missing))
        if status is not None:
            if os.WIFSIGNALED(status):
                raise ValueError(f"renderer terminated by signal {os.WTERMSIG(status)}")
            if os.WIFEXITED(status) and os.WEXITSTATUS(status) != 0:
                raise ValueError(f"renderer exited with status {os.WEXITSTATUS(status)}")
        return 0
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"tui-capture: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
