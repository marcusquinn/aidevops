#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""GH#36593: represent a trusted release that has no open episode to close."""

import re

UNATTRIBUTED = "unattributed_release"


def unattributed_release(comment, line, f):
    """Record a release that has no open episode to close.

    #aidevops:trust-boundary — the caller already requires a trusted, unedited
    comment. The entry opens and closes nothing, and it is not evidence of a
    claim, lease, completion or absence of side effects. It is reported in
    released_successors, so approval-template emits it only when a maintainer
    names its exact comment ID, and dispatch-approved accepts only an approval
    that lists it exactly. Releases inside an open episode keep their existing
    closers and rejections.
    """
    reason = f.get("reason", "")
    if not line.startswith("CLAIM_RELEASED ") or re.fullmatch(r"[a-z_]{1,64}", reason) is None:
        return None
    return {"runner": comment["user"]["login"], "release_id": comment["id"],
            "outcome": UNATTRIBUTED, "reason": reason, "provenance": "unrecovered"}
