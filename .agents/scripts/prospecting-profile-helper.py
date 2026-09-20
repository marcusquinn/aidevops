#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Create or save a bounded, evidence-backed prospecting discovery plan."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from prospecting_profile import ProfileError, generate_profile, store_payload
from prospecting_store import ProspectingStoreError, connect, migrate, update_project_version


def load(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise ProfileError("input must be a regular JSON file")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ProfileError("input must be a JSON object")
    return value


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    profile = commands.add_parser("profile", help="create a profile from supplied snapshots")
    profile.add_argument("--input", required=True, type=Path)
    profile.add_argument("--dry-run", action="store_true", help="validate and render without persistence")
    profile.add_argument("--store", type=Path, help="private prospecting store for an explicit save")
    profile.add_argument("--project", help="project to update when saving")
    profile.add_argument("--expected-profile-version", type=int, help="required current profile version")
    profile.add_argument("--expected-discovery-version", type=int, help="required current discovery version")
    return root


def main() -> int:
    try:
        arguments = parser().parse_args()
        result = generate_profile(load(arguments.input))
        saving = arguments.store is not None
        if saving and arguments.dry_run:
            raise ProfileError("--dry-run cannot save a profile")
        if saving and (not arguments.project or arguments.expected_profile_version is None or arguments.expected_discovery_version is None):
            raise ProfileError("saving requires --project and both expected versions")
        if saving:
            database = connect(arguments.store)
            try:
                migrate(database)
                profile, discovery = store_payload(result)
                result["saved"] = {
                    "profile_version": update_project_version(database, arguments.project, "profile", arguments.expected_profile_version, profile),
                    "discovery_version": update_project_version(database, arguments.project, "discovery", arguments.expected_discovery_version, discovery),
                }
            finally:
                database.close()
        result["dry_run"] = arguments.dry_run
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except (OSError, json.JSONDecodeError, ProfileError, ProspectingStoreError) as error:
        print(f"prospecting profile: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
