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
    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    requests = data.get("requests", [])
    if not isinstance(requests, list):
        requests = []

    for i, req in enumerate(requests):
        print(f"  Request {i+1}:")
        print(f"    Path: {req.get('path', 'unknown')}")
        headers = req.get("headers", {})
        print(f"    User-Agent: {headers.get('user-agent', 'unknown')}")
        billing = req.get("billing_header")
        if isinstance(billing, str) and billing:
            print(f"    Billing: {billing[:80]}...")
        body = req.get("body")
        if isinstance(body, dict):
            print(f"    Model: {body.get('model', 'unknown')}")
            print(f"    Body keys: {body.get('body_keys', [])}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: cch-traffic-summary.py <capture.json>", file=sys.stderr)
        sys.exit(2)
    print_summary(sys.argv[1])
