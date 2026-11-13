#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline same-login foreign-device hint for REST quota reports.

Reads saved DISPATCH_CLAIM comment text (never fetched here: reporting must not
spend the quota being measured) and prints one token:

  same_login_foreign_device  a claim for the self login names another device
  none                       claims were readable and show only the local device
  unknown                    no evidence file, self login or local device id

Usage: gh_quota_foreign_device.py CLAIMS_FILE SELF_LOGIN [DEVICE_ID_FILE]
"""

import os
import re
import sys

_ID = r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
_RUNNER = re.compile(r"(?:^|\s)runner=(" + _ID + r")(?=\s|$)")
_DEVICE = re.compile(r"(?:^|\s)device=(" + _ID + r")(?=\s|$)")


def local_device(path):
    override = os.environ.get("AIDEVOPS_DEVICE_ID", "").strip()
    if override:
        return override
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def classify(text, self_login, device):
    """Return the hint token for DISPATCH_CLAIM lines in text."""
    if not (text and self_login and device):
        return "unknown"
    seen = False
    for line in text.splitlines():
        if "DISPATCH_CLAIM" not in line:
            continue
        runner, claimed = _RUNNER.search(line), _DEVICE.search(line)
        if not runner or not claimed or runner.group(1).lower() != self_login.lower():
            continue
        seen = True
        if claimed.group(1) != device:
            return "same_login_foreign_device"
    return "none" if seen else "unknown"


def hint(claims_file, self_login, device_file=""):
    """Return the hint token; unreadable or absent evidence is `unknown`."""
    if not claims_file or not self_login:
        return "unknown"
    device = local_device(device_file or os.path.expanduser("~/.aidevops/state/device-id"))
    try:
        with open(claims_file, encoding="utf-8", errors="replace") as handle:
            text = handle.read(4 * 1024 * 1024)
    except OSError:
        return "unknown"
    return classify(text, self_login, device)


def main(argv):
    print(hint(*(argv[1:4] + [""] * (3 - len(argv[1:4])))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
