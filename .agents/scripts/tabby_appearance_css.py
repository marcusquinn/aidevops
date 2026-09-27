#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Managed Tabby ``appearance.css`` block for tabby-profile-sync.py.

Tabby 1.0.x (xterm.js 5.4) tints the terminal viewport scrollbar track, and
xterm always reserves a scrollbar column. Full-screen TUIs such as OpenCode
therefore show a dark strip on the right edge once a tab has scrollback. The
managed block hides the scrollbar track so the reserved column blends with the
terminal background. User CSS outside the marked block is preserved verbatim.

Opt out with ``AIDEVOPS_TABBY_HIDE_SCROLLBAR=false`` (removes the block).
"""

from __future__ import annotations

import os
import re

import yaml

MANAGED_START = "/* aidevops:managed-start terminal-scrollbar (replaced by aidevops setup) */"
MANAGED_END = "/* aidevops:managed-end terminal-scrollbar */"
MANAGED_CSS = "\n".join(
    (
        MANAGED_START,
        ".xterm-viewport::-webkit-scrollbar {",
        "  width: 0 !important;",
        "  height: 0 !important;",
        "  background: transparent !important;",
        "}",
        MANAGED_END,
    )
)
_MANAGED_RE = re.compile(
    re.escape(MANAGED_START) + r".*?" + re.escape(MANAGED_END) + r"\n?", re.DOTALL
)
_TOP_LEVEL_RE = re.compile(r"^[^\s#][^:]*:")
_CSS_KEY_RE = re.compile(r"^  css:(.*)$")


def managed_css_enabled(env: dict | None = None) -> bool:
    """Return whether the managed scrollbar CSS should be present."""
    value = (env if env is not None else os.environ).get("AIDEVOPS_TABBY_HIDE_SCROLLBAR", "")
    return value.strip().lower() not in {"0", "false", "no", "off"}


def desired_css(current: str, enabled: bool) -> str:
    """Return ``current`` with the managed block removed and optionally re-appended."""
    user_css = _MANAGED_RE.sub("", current or "").rstrip()
    if not enabled:
        return f"{user_css}\n" if user_css else ""
    return f"{user_css}\n{MANAGED_CSS}\n" if user_css else f"{MANAGED_CSS}\n"


def _section_bounds(lines: list[str], key: str) -> tuple[int, int] | None:
    start = next((i for i, line in enumerate(lines) if line.startswith(f"{key}:")), None)
    if start is None:
        return None
    inline = lines[start][len(key) + 1 :].strip()
    if inline == "{}":
        lines[start] = f"{key}:"
    elif inline:
        raise ValueError(f"Unsupported inline Tabby '{key}' mapping")
    end = next(
        (i for i in range(start + 1, len(lines)) if _TOP_LEVEL_RE.match(lines[i])),
        len(lines),
    )
    return start, end


def _css_entry_bounds(lines: list[str], start: int, end: int) -> tuple[int, int] | None:
    key_line = next((i for i in range(start + 1, end) if _CSS_KEY_RE.match(lines[i])), None)
    if key_line is None:
        return None
    stop = key_line + 1
    while stop < end and (not lines[stop].strip() or lines[stop].startswith("    ")):
        stop += 1
    while stop > key_line + 1 and not lines[stop - 1].strip():
        stop -= 1
    return key_line, stop


def _css_block(css: str) -> list[str]:
    if not css:
        return ["  css: ''"]
    body = [f"    {line}" if line else "" for line in css.rstrip("\n").split("\n")]
    return ["  css: |", *body]


def _without_css(document: dict) -> dict:
    appearance = dict(document.get("appearance") or {})
    appearance.pop("css", None)
    return {**document, "appearance": appearance}


def ensure_managed_appearance_css(config_text: str, env: dict | None = None) -> tuple[str, bool]:
    """Apply the managed CSS block; return ``(config_text, changed)``.

    The edit is textual so unrelated YAML stays byte-for-byte identical, then
    verified semantically: only ``appearance.css`` may differ.
    """
    original = yaml.safe_load(config_text) or {}
    appearance = original.get("appearance") if isinstance(original, dict) else None
    current = appearance.get("css") if isinstance(appearance, dict) else None
    wanted = desired_css(current if isinstance(current, str) else "", managed_css_enabled(env))
    if wanted == (current or "") or (not wanted and current is None):
        return config_text, False

    lines = config_text.split("\n")
    section = _section_bounds(lines, "appearance")
    if section is None:
        suffix = "" if config_text.endswith("\n") else "\n"
        updated = f"{config_text}{suffix}" + "\n".join(["appearance:", *_css_block(wanted)]) + "\n"
    else:
        entry = _css_entry_bounds(lines, *section)
        start, stop = entry if entry else (section[0] + 1, section[0] + 1)
        lines[start:stop] = _css_block(wanted)
        updated = "\n".join(lines)

    result = yaml.safe_load(updated)
    if result.get("appearance", {}).get("css", "") != wanted or _without_css(result) != _without_css(
        original
    ):
        raise ValueError("Managed Tabby CSS edit changed unrelated configuration")
    return updated, True
