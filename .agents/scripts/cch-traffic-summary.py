#!/usr/bin/env python3
"""Print a human-readable summary of a CCH traffic capture file.

Used by cch-traffic-monitor.sh capture command.
Usage: cch-traffic-summary.py <capture.json>
"""
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import json
import sys


def print_summary(path):
    """Print summary of captured requests."""
    with open(path) as f:
        data = json.load(f)

    for i, req in enumerate(data["requests"]):
        print(f"  Request {i+1}:")
        print(f"    Path: {req['path']}")
        print(f"    User-Agent: {req['headers'].get('user-agent', 'unknown')}")
        if req.get("billing_header"):
            print(f"    Billing: {req['billing_header'][:80]}...")
        if req.get("body"):
            print(f"    Model: {req['body'].get('model', 'unknown')}")
            print(f"    Body keys: {req['body'].get('body_keys', [])}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: cch-traffic-summary.py <capture.json>", file=sys.stderr)
        sys.exit(2)
    print_summary(sys.argv[1])
