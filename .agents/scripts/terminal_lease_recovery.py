#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local checkpoint terminal-post outbox; GitHub authorization stays in the closer.

Native lifecycle identities prove only that the recording worker ended. No
registry writes, published-event edits or lease credentials belong in this log.

The worker records "pending" right after its ready transition (GH#36646), with
its own process identity, so a killed worker is drained like a failed exit.
A successful terminal post records "resolved"; a failed one reuses the row.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from uuid import NAMESPACE_URL, uuid5

from terminal_lease_evidence import PREFIX, KEYS, append, device_id, evidence_path, key, locked, rows

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "worker-lifecycle"))
from worker_lifecycle.process import ObservationUnavailable, ProcessIdentity
from worker_lifecycle.runtime import adapter_for

PERMANENT_DENIALS = frozenset((
    "claim_unmatched", "identity_mismatch", "not_checkpoint_claim", "later_coordination",
    "already_terminal", "already_released", "not_ready", "attempt_unknown", "expiry_unknown",
))
SKIP = object()  # settle(): leave the pending row for a later cycle


def record(kind, repo, issue, session, pid):
    # An ordinary worker (or a non-worker child with cleared context) is a no-op.
    if not session.startswith("pr-checkpoint-continuation-") or session != os.environ.get("AIDEVOPS_PR_CHECKPOINT_SESSION"):
        return
    claim = os.environ.get("AIDEVOPS_PR_CHECKPOINT_CLAIM_ID", "")
    attempt = os.environ.get("AIDEVOPS_ATTEMPT_ID", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or not issue.isdecimal() or not claim.isdecimal() or not attempt:
        raise ValueError("incomplete-checkpoint-identity")
    now = int(time.time())
    device = device_id()
    row = dict(zip(KEYS, (repo, int(issue), attempt, session, int(claim), device)))
    row.update(record_type=PREFIX + kind, ts=now)
    if kind == "pending":
        # Conservative upper bound: the ready lease was posted before this row.
        # The closer re-reads actual expiry/ordering, never trusting this as authority.
        ttl = max(7200, int(os.environ.get("DISPATCH_READY_LEASE_TTL", "7200")),
                  int(os.environ.get("AIDEVOPS_DISPATCH_READY_LEASE_TTL", "7200")))
        row["expires_at"] = now + ttl
        try:
            adapter = adapter_for(str(uuid5(NAMESPACE_URL, device)))
            row["process_identity"] = adapter.capture(int(pid)).to_dict()
        except (ValueError, OSError, ObservationUnavailable):
            # Preserve the failed post even when local observation is unavailable.
            # Missing proof can never authorize the subsequent GitHub close.
            row["process_identity"] = None
    append(evidence_path(), row)


def executor_live(session):
    executable = shutil.which("ps", path=os.defpath)
    if not executable or not Path(executable).is_absolute():
        return True  # Missing process visibility must never authorize a close.
    output = subprocess.run([executable, "-eo", "args="], capture_output=True, text=True, check=True).stdout  # nosec B603 — absolute system ps, fixed arguments
    for line in output.splitlines():
        args = line.split()
        if any(arg == "--session-key" and args[index + 1] == session
               for index, arg in enumerate(args[:-1])):
            return True
    return False


def worker_ended(row):
    try:
        identity = ProcessIdentity.from_dict(row.get("process_identity"))
        if identity.uid != os.getuid():
            return False
        return adapter_for(identity.installation_id).observe(identity).status == "ended"
    except (ValueError, OSError, ObservationUnavailable):
        return False


def issue_state(row):
    """Return the GitHub issue state ("open"/"closed"), or None when GitHub cannot answer."""
    try:
        result = subprocess.run([str(Path(shutil.which("gh")).resolve()), "api",  # nosec B603 — resolved gh, fixed arguments, positional data only
                                 f"repos/{row['repo']}/issues/{row['issue_number']}", "--jq", ".state"],
                                capture_output=True, text=True, timeout=60, check=True)
    except (TypeError, OSError, subprocess.SubprocessError):
        return None  # Missing gh, transport errors and pacing all defer the batch.
    return result.stdout.strip()


def local_resolution(row, kind, reason=None):
    resolution = {name: row[name] for name in KEYS}
    resolution.update(ts=int(time.time()), record_type=PREFIX + kind)
    if reason:
        resolution["reason"] = reason
    return resolution


def close_pending(row):
    """Return a token-free resolution, or None to defer the remaining batch."""
    helper = Path(__file__).resolve().with_name("dispatch-claim-helper.sh")
    try:
        result = subprocess.run([str(helper), "close-expired-pr-checkpoint-lease",  # nosec B603 — repository-owned absolute helper, positional data only
                                 str(row["issue_number"]), row["repo"],
                                 str(row["claim_id"]), row["session"]],
                                capture_output=True, text=True, timeout=90)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode == 0:
        return local_resolution(row, "resolved")
    # No raw helper/transport output enters the evidence log. Unknown failures
    # (including pacing and rate limits) defer the batch without a retry.
    match = re.fullmatch(r"PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=([a-z_]+)\s*", result.stderr)
    if not match or match[1] not in PERMANENT_DENIALS:
        return None
    return local_resolution(row, "blocked", match[1])


def settle(row):
    """Return a resolution, SKIP to keep the row pending, or None to defer the batch."""
    expiry = row.get("expires_at")
    if not isinstance(expiry, int) or int(time.time()) <= expiry + 120 or executor_live(row["session"]):
        return SKIP
    # Without a valid native identity the exit can never be proven: block once,
    # locally, instead of re-scanning the row every cycle.
    try:
        ProcessIdentity.from_dict(row.get("process_identity"))
    except ValueError:
        return local_resolution(row, "blocked", "identity_unavailable")
    if not worker_ended(row):
        return SKIP
    # Closed issues are resolved locally; the pulse never writes to them.
    state = issue_state(row)
    if state != "open":
        return local_resolution(row, "resolved", "issue_closed") if state == "closed" else None
    return close_pending(row)


def local_pending(history, device):
    done = {key(row) for row in history if row["record_type"] in
            (PREFIX + "resolved", PREFIX + "blocked")}
    return {key(row): row for row in history if row["record_type"] == PREFIX + "pending"
            and row.get("device") == device and key(row) not in done
            and str(row.get("session", "")).startswith("pr-checkpoint-continuation-")}


def drain():
    path = evidence_path()
    counts = {"candidates": 0, "closed": 0, "blocked": 0}
    # Idle hosts do not need a device file, a process scan, or any GitHub call.
    if not path.exists() or not rows(path):
        return counts
    device = device_id()
    # Serialize drainers separately; individual appends share the objective lock.
    with locked(Path(str(path) + ".terminal-drain")):
        pending = local_pending(rows(path), device)
        counts["candidates"] = len(pending)
        processed = 0
        for row in pending.values():
            if processed == 3:
                break
            resolution = settle(row)
            if resolution is SKIP:
                continue
            if resolution is None:
                break
            processed += 1
            append(path, resolution)
            counts["closed" if resolution["record_type"] == PREFIX + "resolved" else "blocked"] += 1
    return counts


def main():
    try:
        if sys.argv[1:] == ["drain"]:
            counts = drain()
            print(" ".join(f"{name}={count}" for name, count in counts.items()))
        elif len(sys.argv) == 6 and sys.argv[1] in ("pending", "resolved"):
            record(*sys.argv[1:])
        else:
            return 2
        return 0
    except (OSError, ValueError, TimeoutError, ObservationUnavailable, subprocess.SubprocessError):
        print("Terminal lease recovery deferred: local evidence or transport unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
