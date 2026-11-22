# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""PTY reads and terminal interaction for opencode-tui-capture.py."""

import codecs
import errno
import os
import re
import select
import time


INTERACTIVE_QUERIES = (
    (b"\x1b[c", b"\x1b[?1;2c"),
    (b"\x1b[?u", b"\x1b[?0u"),
    (b"\x1b[14t", b"\x1b[4;800;1200t"),
)


def answer_terminal_queries(fd, queries):
    for query, response in INTERACTIVE_QUERIES:
        for _ in range(queries.count(query)):
            os.write(fd, response)
        queries = queries.replace(query, b"")
    for query in re.finditer(rb"\x1bP\+q([0-9a-fA-F;]*)\x1b\\", queries):
        os.write(fd, b"\x1bP0+r\x1b\\")
    return queries


def incomplete_query(data):
    """Return a trailing partial escape sequence to prepend to the next read."""
    start = data.rfind(b"\x1b")
    if start < 0 or len(data) - start > 256:
        return b""
    tail = data[start:]
    if re.fullmatch(rb"\x1b(?:\[[0-?]*[ -/]*|P[^\x1b]*\x1b?)?", tail):
        return tail
    return b""


def read_render(fd, seconds, interactive=False):
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
        if interactive:
            queries = answer_terminal_queries(fd, queries)
        query_tail = incomplete_query(re.sub(rb"\x1b\[\??6n", b"", queries))
    return b"".join(chunks)


def click_position(initial, text):
    target = initial.rfind(text.encode("utf-8"))
    positions = []
    if target >= 0:
        positions = list(re.finditer(rb"\x1b\[(\d+);(\d+)H", initial[:target]))
    if not positions:
        raise ValueError(f"click target not rendered with a cursor position: {text!r}")
    last = positions[-1]
    row, col = map(int, last.groups())
    run = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", initial[last.end():target])
    col += len(run.decode("utf-8", "replace")) + min(3, len(text) - 1)
    return row, col


def decode_keys(keys):
    pattern = r"\\(?:u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|x[0-9a-fA-F]{2}|[0-7]{1,3}|.)"
    return re.sub(pattern, lambda match: codecs.decode(match.group(), "unicode_escape"), keys)


def capture_render(fd, args):
    if args.click_text is None:
        return read_render(fd, args.seconds)
    initial = read_render(fd, args.seconds * 0.6, interactive=True)
    row, col = click_position(initial, args.click_text)
    os.write(fd, f"\x1b[<35;{col};{row}M".encode())
    time.sleep(0.2)
    os.write(fd, f"\x1b[<0;{col};{row}M".encode())
    time.sleep(0.05)
    os.write(fd, f"\x1b[<0;{col};{row}m".encode())
    raw = read_render(fd, args.seconds * 0.4, interactive=True)
    if args.keys is not None:
        os.write(fd, decode_keys(args.keys).encode("utf-8"))
        raw += read_render(fd, args.seconds * 0.4, interactive=True)
    return raw
