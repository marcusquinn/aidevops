#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Offline same-login foreign-device hint for REST quota reports.

Reads saved DISPATCH_CLAIM comment text (never fetched here: reporting must not
spend the quota being measured) and prints one token:

  same_login_foreign_device  a claim for the self login names another device
  none                       claims were readable and show only the local device
  unknown                    no evidence file, self login or local device id

Without a foreign device in that file, positive evidence already in the local
pulse log also yields the hint (GH#37888, see gh_quota_pulse_evidence.py).

Usage: gh_quota_foreign_device.py CLAIMS_FILE SELF_LOGIN [DEVICE_ID_FILE]
Environment: AIDEVOPS_QUOTA_PULSE_LOG, AIDEVOPS_QUOTA_FOREIGN_DEVICE_LOOKBACK_S.
"""

import os
import re
import sys

from gh_quota_pulse_evidence import FOREIGN, pulse_log_hint

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
    except (OSError, UnicodeError):
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
            return FOREIGN
    return "none" if seen else "unknown"


_EVIDENCE_LIMIT_BYTES = 4 * 1024 * 1024


def _claims_hint(claims_file, self_login, device):
    """Return the hint for the saved claims file; unreadable/oversized is `unknown`."""
    if not claims_file or not self_login:
        return "unknown"
    try:
        with open(claims_file, "rb") as handle:
            raw = handle.read(_EVIDENCE_LIMIT_BYTES + 1)
    except OSError:
        return "unknown"
    # Do not classify incomplete evidence or a device value split at the limit;
    # the limit is in bytes, so multi-byte UTF-8 cannot slip past it.
    if len(raw) > _EVIDENCE_LIMIT_BYTES:
        return "unknown"
    return classify(raw.decode("utf-8", errors="replace"), self_login, device)


def hint(claims_file, self_login, device_file=""):
    """Return the hint token; positive evidence from either source wins over `none`."""
    # Same precedence as dispatch-claim-helper.sh, which writes the claim device.
    device_path = (device_file or os.environ.get("AIDEVOPS_DEVICE_ID_FILE", "").strip()
                   or os.path.expanduser("~/.aidevops/state/device-id"))
    device = local_device(device_path)
    claimed = _claims_hint(claims_file, self_login, device)
    if claimed == FOREIGN:
        return claimed
    return FOREIGN if pulse_log_hint(self_login, device) == FOREIGN else claimed


def main(argv):
    print(hint(*(argv[1:4] + [""] * (3 - len(argv[1:4])))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
