#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Refresh offline Google-ranked Reddit opportunities without provider writes."""
from __future__ import annotations
import argparse
import json
from prospecting_seo import SeoError, load_input, refresh

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("refresh",))
    parser.add_argument("--input", required=True)
    parser.add_argument("--dry-run", action="store_true", required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(refresh(load_input(args.input)), sort_keys=True))
    except SeoError as error:
        parser.error(str(error))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
