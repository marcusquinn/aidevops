#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Find the Tabby OpenCode profile that owns a project directory.

`opencode-session-restart-helper.sh tabby-open` reopens a stopped session with
`Tabby profile <name>` so the new tab keeps the profile's name and colours.
Tabby's CLI selects the first profile with that exact name, so this prints
`<name>\t<cwd>` only when exactly one aidevops OpenCode profile matches the
directory and no other profile shares its name.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import yaml

OPENCODE_LAUNCH = "aidevops opencode"


def default_config() -> Path:
    override = os.environ.get("AIDEVOPS_TABBY_CONFIG")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/tabby/config.yaml"
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "tabby/config.yaml"


def _normal(path: str) -> str:
    return os.path.realpath(os.path.expanduser(path)).rstrip("/") if path else ""


def is_opencode_profile(profile: dict) -> bool:
    options = profile.get("options") or {}
    launch = " ".join(str(part) for part in (options.get("args") or []))
    launch = f"{options.get('command') or ''} {launch}"
    return profile.get("type") == "local" and OPENCODE_LAUNCH in launch


def _cwd(profile: dict) -> str:
    return _normal(str((profile.get("options") or {}).get("cwd") or ""))


def profile_for(profiles: list[dict], directory: str) -> tuple[str, str] | None:
    """Return (name, cwd) for the profile owning directory, else None.

    Exact cwd matches win. A session started in a parent folder (an
    organisation folder above a repository) falls back to its single child
    profile, or to the child whose basename equals the parent's.
    """
    want = _normal(directory)
    candidates = [p for p in profiles if isinstance(p, dict) and is_opencode_profile(p)]
    matches = [p for p in candidates if _cwd(p) == want]
    if not matches:
        matches = [p for p in candidates if _cwd(p).startswith(want + "/")]
        if len(matches) > 1:
            base = os.path.basename(want)
            matches = [p for p in matches if os.path.basename(_cwd(p)) == base]
    if len(matches) != 1:
        return None
    name = str(matches[0].get("name") or "")
    same_name = [p for p in profiles if isinstance(p, dict) and str(p.get("name") or "") == name]
    if not name or len(same_name) != 1 or "\t" in name or "\n" in name:
        return None
    return name, _cwd(matches[0])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    lookup = sub.add_parser("profile-for", help="print the unique profile name for a directory")
    lookup.add_argument("--dir", required=True)
    lookup.add_argument("--config", default=None)
    args = parser.parse_args(argv)

    config = Path(args.config) if args.config else default_config()
    try:
        data = yaml.safe_load(config.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        print(f"cannot read Tabby config {config}: {exc}", file=sys.stderr)
        return 1
    found = profile_for(data.get("profiles") or [], args.dir)
    if found is None:
        print(f"no unique aidevops OpenCode Tabby profile for {args.dir}", file=sys.stderr)
        return 2
    print(f"{found[0]}\t{found[1]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
