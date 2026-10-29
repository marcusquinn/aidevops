#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#35331: recovery of expired never-ready approval-bound checkpoint claims."""

import copy
import importlib.util
import json
import pathlib
import shutil
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import sys
import unittest

TESTS = pathlib.Path(__file__).resolve().parent
SCRIPTS = TESTS.parent
BASH = shutil.which("bash")
if not BASH or not pathlib.Path(BASH).is_absolute():
    raise RuntimeError("An absolute path to the installed Bash runtime is required")
sys.path.insert(0, str(SCRIPTS))
from checkpoint_github_fixture import comment
from pr_checkpoint_events import fields


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


revision = load("revision", SCRIPTS / "pr-checkpoint-revision.py")
base = load("revision_tests", TESTS / "test-pr-checkpoint-revision.py")
LT = "lease_" + "token"  # fixture field name, assembled to keep values opaque


def claim_only_fixture():
    """An approval-bound claim expired before ready and was closed."""
    data = base.fixture()
    data["comments"] = data["comments"] + [
        comment(4, f"DISPATCH_CLAIM nonce=expired {LT}=expired runner=worker "
                   "checkpoint_approval=3 session=checkpoint-42 phase=prelaunch expires_at=1", "worker"),
        comment(5, "CLAIM_RELEASED reason=claim_only_no_worker runner=worker claim_id=4 nonce=expired",
                "worker")]
    return data


def approved(data):
    line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
    return {**data, "comments": data["comments"] + [comment(20, line, "maintainer", "OWNER")]}


def diagnostic_fixture():
    data = claim_only_fixture()
    data["comments"].insert(-1, comment(4.5,
        "CLAIM_RELEASED reason=worker_ownership_lost runner=worker exit=1 session_count=0", "worker"))
    return data


def edit(data, index, old, new):
    data["comments"][index]["body"] = data["comments"][index]["body"].replace(old, new)


class ClaimOnlyRecoveryTests(unittest.TestCase):
    def test_unbound_diagnostic_needs_exact_abort_and_explicit_acknowledgement(self):
        data = diagnostic_fixture()
        with self.assertRaises(ValueError):
            revision.validate(data)
        result = revision.validate(approved(data))
        self.assertEqual(result["released_successors"][0]["unbound_release_ids"], [4.5])
        for case in ("remove_abort", "remove_acknowledgement", "alter_acknowledgement"):
            changed = copy.deepcopy(data)
            if case == "remove_abort":
                changed["comments"].pop()
            else:
                changed = approved(changed)
                approval = json.loads(changed["comments"][-1]["body"][len(revision.PREFIX):])
                episode = approval["released_successors"][0]
                if case == "remove_acknowledgement":
                    del episode["unbound_release_ids"]
                else:
                    episode["unbound_release_ids"] = [99]
                changed["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(changed) if case != "remove_abort" else approved(changed)

    def test_unbound_diagnostic_does_not_relax_identity_or_live_events(self):
        identity_fields = ["nonce=x", f"{LT}=x", "session=x", "attempt_id=attempt:x", "claim_id=4",
                           "nonce x", "SESSION=x", "runner=worker", "trailing_fragment"]
        mutations = {
            "foreign_actor": lambda d: d["comments"][-2]["user"].update(login="other"),
            "edited": lambda d: d["comments"][-2].update(updated_at="2026-09-05T12:01:00Z"),
            "wrong_reason": lambda d: edit(d, -2, "worker_ownership_lost", "blocked"),
            "wrong_runner": lambda d: edit(d, -2, "runner=worker", "runner=other"),
            "nonzero_sessions": lambda d: edit(d, -2, "session_count=0", "session_count=1"),
            "duplicate_claim_id": lambda d: d["comments"][-2].update(id=4),
            "diagnostic_after_abort_id": lambda d: d["comments"][-2].update(id=6),
            "ready_before": lambda d: d["comments"].insert(-2, comment(4.25,
                f"DISPATCH_LEASE phase=ready {LT}=expired session=checkpoint-42 attempt_id=attempt:x", "worker")),
            "ready_after": lambda d: d["comments"].insert(-1, comment(4.75,
                f"DISPATCH_LEASE phase=ready {LT}=expired session=checkpoint-42 attempt_id=attempt:x", "worker")),
            "post_abort": lambda d: d["comments"].append(comment(6,
                "CLAIM_RELEASED reason=worker_ownership_lost runner=worker exit=1 session_count=0", "worker")),
        }
        for field in identity_fields:
            data = diagnostic_fixture()
            data["comments"][-2]["body"] += " " + field
            with self.subTest(field=field), self.assertRaises(ValueError):
                approved(data)
        for case, mutate in mutations.items():
            data = diagnostic_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                approved(data)

    def test_expired_claim_blocks_until_fresh_bound_approval(self):
        data = claim_only_fixture()
        with self.assertRaises(ValueError):  # the consumed approval is not revived
            revision.validate(data)
        result = revision.validate(approved(data))
        self.assertEqual(result["approval_id"], 20)
        self.assertEqual(result["released_successors"], [
            {"runner": "worker", "claim_id": 4, "release_id": 5, "outcome": "claim_only_no_worker"}])
        renewed = claim_only_fixture()
        renewed["comments"].insert(-1, comment(4.5, f"DISPATCH_LEASE phase=prelaunch {LT}=expired "
                                                    "session=checkpoint-42 expires_at=2 attempt_id=attempt:x",
                                               "worker"))
        history = revision.validate(approved(renewed))["released_successors"]
        self.assertEqual(history[0]["attempt"], "attempt:x")

    def test_claim_only_closure_rejects_non_exact_or_late_evidence(self):
        lease = f"{LT}=expired session=checkpoint-42"
        renew = "DISPATCH_LEASE phase=prelaunch " + lease
        mutations = {
            "unreleased": lambda d: d["comments"].pop(),
            "wrong_claim_id": lambda d: edit(d, -1, "claim_id=4", "claim_id=9"),
            "wrong_nonce": lambda d: edit(d, -1, "nonce=expired", "nonce=other"),
            "wrong_runner": lambda d: edit(d, -1, "runner=worker", "runner=other"),
            "other_actor": lambda d: d["comments"][-1]["user"].update(login="stranger"),
            "edited": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "reached_ready": lambda d: d["comments"].insert(-1, comment(
                4.5, f"DISPATCH_LEASE phase=ready {lease} attempt_id=attempt:late", "worker")),
            "launched": lambda d: d["comments"].insert(-1, comment(
                4.5, f"Dispatching worker\n{lease}", "worker")),
            "released_before_claim_expiry": lambda d: edit(d, -2, "expires_at=1", "expires_at=9999999999"),
            "unknown_claim_expiry": lambda d: edit(d, -2, " expires_at=1", ""),
            "released_during_live_renewal": lambda d: d["comments"].insert(-1, comment(
                4.5, f"{renew} expires_at=9999999999 attempt_id=attempt:late", "worker")),
            "unknown_renewal_expiry": lambda d: d["comments"].insert(-1, comment(
                4.5, f"{renew} attempt_id=attempt:late", "worker")),
            "late_renewal": lambda d: d["comments"].append(comment(
                6, f"{renew} attempt_id=attempt:late", "worker")),
            "replayed_claim": lambda d: d["comments"].append(comment(
                6, f"DISPATCH_CLAIM nonce=expired {lease} runner=worker phase=prelaunch", "worker")),
        }
        for case, mutate in mutations.items():
            data = claim_only_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                approved(data)

    def test_bound_closure_keeps_live_claim_fencing(self):
        data = approved(claim_only_fixture())
        approval = json.loads(data["comments"][-1]["body"][len(revision.PREFIX):])
        approval["released_successors"][0]["release_id"] = 99
        altered = copy.deepcopy(data)
        altered["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
        with self.assertRaises(ValueError):
            revision.validate(altered)
        for value, accepted in (("expired", False), ("fresh", True)):
            claimed = copy.deepcopy(data)
            claimed.update(lease=value, session="checkpoint-42", assignee="worker", claiming=True)
            claimed["comments"].append(comment(21, f"DISPATCH_CLAIM nonce={value} {LT}={value} "
                "runner=worker checkpoint_approval=20 session=checkpoint-42 expires_at=1788620400", "worker"))
            with self.subTest(value=value):
                if accepted:
                    self.assertEqual(revision.validate(claimed)["approval_id"], 20)
                else:
                    with self.assertRaises(ValueError):
                        revision.validate(claimed)


def blocked_before_ready_fixture():
    """GH#35683: attempt A released blocked, then claim B released blocked before ready."""
    data = base.fixture()
    ready, release = data["comments"][:2]
    original = fields(ready["body"])[LT]
    data["comments"] = [ready, release,
        comment(2.5, f"DISPATCH_LEASE phase=terminal {LT}={original} session=issue-123 "
                     "expires_at=0 attempt_id=attempt:original", "worker"),
        comment(4, f"DISPATCH_CLAIM nonce=claimb {LT}=claimb runner=worker session=issue-124 "
                   "phase=prelaunch expires_at=1", "worker"),
        comment(5, "<!-- ops:start -->\nCLAIM_RELEASED reason=blocked runner=worker "
                   "ts=2026-09-05T12:00:00Z\n\nTerminal blocker: reason=permission_required "
                   "owner=permission-maintainer task=123 attempt=abcdef0123456789.\n<!-- ops:end -->",
                "worker")]
    return data


class BlockedBeforeReadyTests(unittest.TestCase):
    EPISODE = {"runner": "worker", "claim_id": 4, "release_id": 5, "outcome": "blocked_before_ready"}

    def test_checkpoint_release_acknowledges_never_ready_blocked_claim(self):
        data = blocked_before_ready_fixture()
        with self.assertRaises(ValueError):  # release B never closes attempt A
            revision.template({**data, "release_id": 5, "attempt": "attempt:original"})
        line = revision.template({**data, "release_id": 2, "attempt": "attempt:original"})
        self.assertEqual(json.loads(line[len(revision.PREFIX):])["released_successors"], [self.EPISODE])
        result = revision.validate(approved(data))
        self.assertEqual((result["approval_id"], result["released_successors"]), (20, [self.EPISODE]))
        bound = blocked_before_ready_fixture()
        edit(bound, -1, "runner=worker ", "runner=worker nonce=claimb claim_id=4 ")
        self.assertEqual(revision.validate(approved(bound))["released_successors"], [self.EPISODE])

    def test_approval_must_acknowledge_the_episode_exactly(self):
        for case in ("omit", "alter_outcome", "alter_release"):
            changed = approved(blocked_before_ready_fixture())
            approval = json.loads(changed["comments"][-1]["body"][len(revision.PREFIX):])
            if case == "omit":
                del approval["released_successors"]
            elif case == "alter_outcome":
                approval["released_successors"][0]["outcome"] = "claim_only_no_worker"
            else:
                approval["released_successors"][0]["release_id"] = 99
            changed["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
            with self.subTest(case=case), self.assertRaises(ValueError):
                revision.validate(changed)

    def test_blocked_closure_fails_closed(self):
        lease = f"{LT}=claimb session=issue-124"
        mutations = {
            "reached_ready": lambda d: d["comments"].insert(-1, comment(
                4.5, f"DISPATCH_LEASE phase=ready {lease} expires_at=1 attempt_id=attempt:b", "worker")),
            "launched": lambda d: d["comments"].insert(-1, comment(
                4.5, f"Dispatching worker\n{lease}", "worker")),
            "unknown_claim_expiry": lambda d: edit(d, -2, " expires_at=1", ""),
            "released_before_claim_expiry": lambda d: edit(d, -2, "expires_at=1", "expires_at=9999999999"),
            "released_during_live_renewal": lambda d: d["comments"].insert(-1, comment(
                4.5, f"DISPATCH_LEASE phase=prelaunch {lease} expires_at=9999999999 attempt_id=attempt:b",
                "worker")),
            "edited": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "other_actor": lambda d: d["comments"][-1]["user"].update(login="stranger"),
            "wrong_runner": lambda d: edit(d, -1, "runner=worker", "runner=other"),
            "wrong_nonce": lambda d: edit(d, -1, "runner=worker ", "runner=worker nonce=other "),
            "wrong_claim_id": lambda d: edit(d, -1, "runner=worker ", "runner=worker claim_id=9 "),
            "wrong_session": lambda d: edit(d, -1, "runner=worker ", "runner=worker session=other "),
            "unbound_attempt": lambda d: edit(d, -1, "runner=worker ", "runner=worker attempt_id=attempt:x "),
            "other_open_claim": lambda d: d["comments"].insert(-1, comment(
                4.5, f"DISPATCH_CLAIM nonce=other {LT}=other runner=worker session=s phase=prelaunch "
                     "expires_at=1", "worker")),
            "release_before_claim": lambda d: d["comments"][-1].update(id=3),
            "second_release": lambda d: d["comments"].append(comment(
                6, "CLAIM_RELEASED reason=blocked runner=worker ts=2026-09-05T12:00:00Z", "worker")),
            "late_lease": lambda d: d["comments"].append(comment(
                6, f"DISPATCH_LEASE phase=terminal {lease} expires_at=0", "worker")),
        }
        for case, mutate in mutations.items():
            data = blocked_before_ready_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                approved(data)


def successor_claim_fixture(*events):
    """Attempt A fully closed, then claim B on device devb followed by events."""
    data = blocked_before_ready_fixture()
    data["comments"] = data["comments"][:3] + [
        comment(4, f"DISPATCH_CLAIM nonce=claimb {LT}=claimb runner=worker device=devb "
                   "session=issue-124 phase=prelaunch expires_at=1", "worker"),
        comment(4.3, f"DISPATCH_LEASE phase=prelaunch {LT}=claimb device=devb session=issue-124 "
                     "expires_at=2 attempt_id=attempt:a", "worker"),
        *events]
    return data


def stale_reset_fixture():
    """GH#36005: claim B is released by its owner's stale recovery before ready."""
    return successor_claim_fixture(comment(
        5, "CLAIM_RELEASED reason=stale_assignment_reset runner=worker ts=2026-09-05T12:00:00Z "
           "device=devb stale_threshold_s=600", "worker"))


def rebind_fixture():
    """GH#36005: claim B's worker publishes ready under a fresh attempt ID."""
    lease = f"{LT}=claimb device=devb session=issue-124"
    return successor_claim_fixture(
        comment(4.6, f"DISPATCH_LEASE phase=ready {lease} expires_at=3 attempt_id=attempt:b", "worker"),
        comment(5, "CLAIM_RELEASED reason=blocked runner=worker ts=2026-09-05T12:00:00Z", "worker"),
        comment(6, f"DISPATCH_LEASE phase=terminal {lease} expires_at=0 attempt_id=attempt:b", "worker"))


class StaleResetAndRebindTests(unittest.TestCase):
    STALE = {"runner": "worker", "claim_id": 4, "release_id": 5,
             "outcome": "stale_reset_before_ready", "attempt": "attempt:a"}
    REBOUND = {"runner": "worker", "attempt": "attempt:b", "claim_id": 4,
               "ready_id": 4.6, "release_id": 5, "terminal_id": 6}

    def test_owner_stale_reset_closes_never_ready_claim(self):
        result = revision.validate(approved(stale_reset_fixture()))
        self.assertEqual(result["released_successors"], [self.STALE])
        changed = approved(stale_reset_fixture())
        approval = json.loads(changed["comments"][-1]["body"][len(revision.PREFIX):])
        approval["released_successors"][0]["outcome"] = "blocked_before_ready"
        changed["comments"][-1]["body"] = revision.PREFIX + json.dumps(approval)
        with self.assertRaises(ValueError):
            revision.validate(changed)

    def test_stale_reset_closure_fails_closed(self):
        lease = f"{LT}=claimb device=devb session=issue-124"
        mutations = {
            "wrong_device": lambda d: edit(d, -1, "device=devb", "device=other"),
            "missing_device": lambda d: edit(d, -1, " device=devb", ""),
            "claim_without_device": lambda d: edit(d, -3, " device=devb", ""),
            "live_renewal": lambda d: edit(d, -2, "expires_at=2", "expires_at=9999999999"),
            "reached_ready": lambda d: d["comments"].insert(-1, comment(
                4.6, f"DISPATCH_LEASE phase=ready {lease} expires_at=3 attempt_id=attempt:a", "worker")),
            "launched": lambda d: d["comments"].insert(-1, comment(
                4.6, f"Dispatching worker\n{lease} attempt_id=attempt:a", "worker")),
            "wrong_runner": lambda d: edit(d, -1, "runner=worker", "runner=other"),
            "other_actor": lambda d: d["comments"][-1]["user"].update(login="stranger"),
            "edited": lambda d: d["comments"][-1].update(updated_at="2026-09-05T12:01:00Z"),
            "unbound_attempt": lambda d: edit(d, -1, "device=devb", "device=devb attempt_id=attempt:x"),
        }
        for case, mutate in mutations.items():
            data = stale_reset_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                approved(data)

    def test_first_ready_lease_may_rebind_attempt_once(self):
        result = revision.validate(approved(rebind_fixture()))
        self.assertEqual(result["released_successors"], [self.REBOUND])

    def test_attempt_rebind_fails_closed(self):
        lease = f"{LT}=claimb device=devb session=issue-124"
        mutations = {
            "ready_other_device": lambda d: edit(d, -3, "device=devb", "device=other"),
            "ready_without_device": lambda d: edit(d, -3, " device=devb", ""),
            "claim_without_device": lambda d: edit(d, -5, " device=devb", ""),
            "after_launch": lambda d: d["comments"].insert(-3, comment(
                4.5, f"Dispatching worker\n{lease} attempt_id=attempt:a", "worker")),
            "second_rebind": lambda d: d["comments"].insert(-2, comment(
                4.8, f"DISPATCH_LEASE phase=ready {lease} expires_at=3 attempt_id=attempt:c", "worker")),
            "terminal_names_prelaunch_attempt": lambda d: edit(d, -1, "attempt:b", "attempt:a"),
            "release_names_prelaunch_attempt": lambda d: edit(
                d, -2, "runner=worker ", "runner=worker attempt_id=attempt:a "),
            "prelaunch_rebind": lambda d: edit(d, -3, "phase=ready", "phase=prelaunch"),
            "unprefixed_ready": lambda d: edit(d, -3, "attempt_id=attempt:b", "attempt_id=b"),
        }
        for case, mutate in mutations.items():
            data = rebind_fixture()
            mutate(data)
            with self.subTest(case=case), self.assertRaises(ValueError):
                approved(data)


def abort_pages(*extra, claim_author="worker", approval="checkpoint_approval=3 ", expiry=" expires_at=100"):
    claim = comment(4, f"DISPATCH_CLAIM nonce=tok runner=worker {LT}=tok device=dev "
                       f"{approval}session=s1 phase=prelaunch{expiry}", claim_author)
    return [[claim, *extra]]


def abort_decision(data, now=200, runner="worker", device="dev"):
    command = 'source "$1/dispatch-claim-checkpoint.sh"; _dch_abort_claim_id "$2" "$3" tok s1 "$4" "$5"'
    # Fixed Bash source; JSON and identities are positional data only.
    return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), json.dumps(data),  # nosec B603
                           runner, device, str(now)],
                          capture_output=True, text=True, check=False).stdout.strip()


class AbortPredicateTests(unittest.TestCase):
    def test_abort_requires_owned_expired_never_ready_claim(self):
        self.assertEqual(abort_decision(abort_pages()), "4")
        lease = f"{LT}=tok session=s1"
        renew = "DISPATCH_LEASE phase=prelaunch " + lease

        def event(body, author="worker"):
            return abort_pages(comment(5, body, author))

        cases = {
            "lease_live": (abort_pages(), {"now": 50}),
            "renewed_live": (event(f"{renew} expires_at=300"), {}),
            "runner": (abort_pages(), {"runner": "other"}),
            "device": (abort_pages(), {"device": "other"}),
            "author": (abort_pages(claim_author="other"), {}),
            "generic_claim": (abort_pages(approval=""), {}),
            "missing_expiry": (abort_pages(expiry=""), {}),
            "zero_expiry": (abort_pages(expiry=" expires_at=0"), {}),
            "malformed_expiry": (abort_pages(expiry=" expires_at=-5"), {}),
            "malformed_renewal": (event(f"{renew} expires_at=soon"), {}),
            "renewal_without_expiry": (event(renew), {}),
            "ready": (event(f"DISPATCH_LEASE phase=ready {lease}"), {}),
            "launched": (event(f"Dispatching worker\n{lease}"), {}),
            "released": (event("CLAIM_RELEASED reason=blocked runner=worker nonce=tok"), {}),
            "foreign_event": (event(renew, "other"), {}),
        }
        for case, (data, kwargs) in cases.items():
            with self.subTest(case=case):
                self.assertTrue(abort_decision(data, **kwargs).startswith("deny:"))


if __name__ == "__main__":
    unittest.main()
