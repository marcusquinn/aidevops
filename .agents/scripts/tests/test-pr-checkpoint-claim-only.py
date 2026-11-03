#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GH#35331: recovery of expired never-ready approval-bound checkpoint claims."""

import copy
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess  # nosec B404 — executes fixed offline fixture programs only
import sys
import tempfile
import unittest
from unittest import mock

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


def assert_rejection(test, data, comment_id, reason="transition_rejected"):
    with test.assertRaises(ValueError) as caught:
        approved(data)
    message = str(caught.exception)
    test.assertIn("intervening coordination is not fully released; no approval generated", message)
    test.assertIn(f"comment={comment_id} ", message)
    test.assertIn(f"reason={reason}", message)
    test.assertEqual(message.count("rejected comment="), 1)
    for record in data["comments"]:
        values = fields(record["body"])
        for key in (LT, "nonce", "session"):
            if values.get(key):
                test.assertNotIn(values[key], message)


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
            reason = {"edited": "edited", "reached_ready": "open_at_end"}.get(case, "transition_rejected")
            with self.subTest(case=case):
                assert_rejection(self, data, 5, reason)

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
            # Legacy raw IDs normalize to their prefixed form (GH#35316), so the
            # remaining malformed case is an empty attempt.
            "empty_ready_attempt": lambda d: edit(d, -3, "attempt_id=attempt:b", "attempt_id=attempt:"),
        }
        for case, mutate in mutations.items():
            data = rebind_fixture()
            mutate(data)
            rejected = {"second_rebind": 4.8, "terminal_names_prelaunch_attempt": 6,
                        "release_names_prelaunch_attempt": 5}.get(case, 4.6)
            with self.subTest(case=case):
                assert_rejection(self, data, rejected)


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


EXPIRED_READY_LEASE = f"{LT}=claimb device=devb session=issue-124"
EXPIRED_READY_RELEASE = ("CLAIM_RELEASED reason=expired_ready_lease_reconciled runner=worker "
                         "ts=2026-09-05T12:00:00Z claim_id=4 attempt_id=attempt:a device=devb session=issue-124")


def expired_ready_fixture(*events):
    """GH#36544: claim B reached ready, then its ready lease expired unreleased."""
    return successor_claim_fixture(
        comment(4.6, f"DISPATCH_LEASE phase=ready {EXPIRED_READY_LEASE} expires_at=3 attempt_id=a", "worker"),
        *events)


def expired_ready_closed_fixture():
    return expired_ready_fixture(
        comment(5, EXPIRED_READY_RELEASE, "worker"),
        comment(6, f"DISPATCH_LEASE phase=terminal {EXPIRED_READY_LEASE} expires_at=0 attempt_id=attempt:a",
                "worker"))


class ExpiredReadyLeaseHistoryTests(unittest.TestCase):
    EPISODE = {"runner": "worker", "attempt": "attempt:a", "claim_id": 4,
               "ready_id": 4.6, "release_id": 5, "terminal_id": 6}

    def test_unreleased_ready_lease_stays_open_at_end(self):
        assert_rejection(self, expired_ready_fixture(), 4.6, "open_at_end")

    def test_owner_closure_is_an_ordinary_released_successor(self):
        result = revision.validate(approved(expired_ready_closed_fixture()))
        self.assertEqual(result["released_successors"], [self.EPISODE])

    def test_release_without_terminal_lease_stays_open(self):
        data = expired_ready_fixture(comment(5, EXPIRED_READY_RELEASE, "worker"))
        assert_rejection(self, data, 5, "open_at_end")


def ready_pages(*extra, claim_author="worker", approval="checkpoint_approval=3 ", ready_expiry=" expires_at=150"):
    lease = f"{LT}=tok device=dev session=s1"
    return [[
        comment(4, f"DISPATCH_CLAIM nonce=tok runner=worker {LT}=tok device=dev "
                   f"{approval}session=s1 phase=prelaunch expires_at=100", claim_author),
        comment(5, f"DISPATCH_LEASE phase=prelaunch {lease} expires_at=110 attempt_id=raw-1"),
        comment(6, f"DISPATCH_LEASE phase=ready {lease}{ready_expiry} attempt_id=raw-1"),
        *extra]]


RECOVERY = ("CLAIM_RELEASED reason=expired_ready_lease_reconciled runner=worker claim_id=4 "
            "attempt_id=attempt:raw-1 device=dev session=s1")


def ready_decision(data, now=200, runner="worker", device="dev", claim_id=4):
    command = ('source "$1/dispatch-claim-checkpoint.sh"; '
               '_dch_expired_ready_claim "$2" "$3" "$6" s1 "$4" "$5"')
    # Fixed Bash source; JSON and identities are positional data only.
    return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), json.dumps(data),  # nosec B603
                           runner, device, str(now), str(claim_id)],
                          capture_output=True, text=True, check=False).stdout.strip()


def live_executor(session, processes):
    command = 'source "$1/dispatch-claim-checkpoint.sh"; _dch_session_has_live_executor "$2" "$3"'
    return subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), session, processes],  # nosec B603
                          capture_output=True, text=True, check=False).returncode == 0


class ExpiredReadyPredicateTests(unittest.TestCase):
    def test_owned_expired_ready_claim_is_selected(self):
        self.assertEqual(ready_decision(ready_pages()), "4\ttok\tattempt:raw-1\topen")
        self.assertEqual(ready_decision(ready_pages(comment(7, RECOVERY))),
                         "4\ttok\tattempt:raw-1\treleased")

    def test_expired_ready_closure_fails_closed(self):
        lease = f"{LT}=tok device=dev session=s1"
        cases = {
            "lease_live": (ready_pages(), {"now": 120}),
            "unknown_ready_expiry": (ready_pages(ready_expiry=""), {}),
            "runner": (ready_pages(), {"runner": "other"}),
            "device": (ready_pages(), {"device": "other"}),
            "claim_id": (ready_pages(), {"claim_id": 5}),
            "author": (ready_pages(claim_author="other"), {}),
            "generic_claim": (ready_pages(approval=""), {}),
            "never_ready": ([ready_pages()[0][:2]], {}),
            "released": (ready_pages(comment(7, "CLAIM_RELEASED reason=clean runner=worker")), {}),
            "released_with_token": (ready_pages(comment(7, f"CLAIM_RELEASED reason=clean {lease}")), {}),
            "terminal": (ready_pages(comment(7, f"DISPATCH_LEASE phase=terminal {lease} expires_at=0")), {}),
            "foreign_event": (ready_pages(comment(7, f"DISPATCH_LEASE phase=ready {lease}", "other")), {}),
            "wrong_session": (ready_pages(comment(7, f"DISPATCH_LEASE phase=ready {LT}=tok device=dev "
                                                      "session=s2 expires_at=150")), {}),
            "later_claim": (ready_pages(comment(7, f"DISPATCH_CLAIM nonce=n2 {LT}=n2 runner=worker "
                                                   "session=s9 phase=prelaunch expires_at=1")), {}),
            "edited_recovery": (ready_pages({**comment(7, RECOVERY), "updated_at": "2026-09-06T00:00:00Z"}), {}),
            "edited_claim": ([[{**ready_pages()[0][0], "updated_at": "2026-09-06T00:00:00Z"},
                                *ready_pages()[0][1:]]], {}),
            "foreign_recovery": (ready_pages(comment(7, RECOVERY, "other")), {}),
            "duplicate_recovery": (ready_pages(comment(7, RECOVERY), comment(8, RECOVERY)), {}),
            "recovery_wrong_attempt": (ready_pages(comment(7, RECOVERY.replace("raw-1", "raw-2"))), {}),
        }
        for case, (data, kwargs) in cases.items():
            with self.subTest(case=case):
                self.assertTrue(ready_decision(data, **kwargs).startswith("deny:"))

    def test_live_executor_probe_matches_exact_session(self):
        self.assertTrue(live_executor("s1", "bash run --session-key s1 --dir x\n"))
        self.assertFalse(live_executor("s1", "bash run --session-key s12 --dir x\n"))
        self.assertFalse(live_executor("s1", ""))


class TerminalLeaseOutboxTests(unittest.TestCase):
    def setUp(self):
        self.recovery = load("terminal_lease_recovery", SCRIPTS / "terminal_lease_recovery.py")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = pathlib.Path(self.temp.name) / "evidence.jsonl"
        self.session = "pr-checkpoint-continuation-owner-repo-42"
        self.env = mock.patch.dict(os.environ, {
            "AIDEVOPS_OBJECTIVE_EVIDENCE_FILE": str(self.path),
            "AIDEVOPS_PR_CHECKPOINT_SESSION": self.session,
            "AIDEVOPS_PR_CHECKPOINT_CLAIM_ID": "4",
            "AIDEVOPS_ATTEMPT_ID": "raw-1",
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        device = mock.patch.object(self.recovery, "device_id", return_value="dev")
        device.start()
        self.addCleanup(device.stop)

    def pending(self, **changes):
        row = dict(repo="owner/repo", issue_number=124, attempt_id="raw-1", claim_id=4,
                   device="dev", session=self.session, ts=1, expires_at=100,
                   record_type="terminal_lease_pending")
        row.update(changes)
        self.recovery.append(self.path, row)
        return row

    def drain(self, result=None, live=False, ended=True):
        with mock.patch.object(self.recovery, "executor_live", return_value=live), \
             mock.patch.object(self.recovery, "worker_ended", return_value=ended), \
             mock.patch.object(self.recovery.subprocess, "run", return_value=result) as run:
            counts = self.recovery.drain()
        return counts, run

    def test_empty_log_never_calls_github_or_process_scan(self):
        with mock.patch.object(self.recovery.subprocess, "run") as run:
            self.assertEqual(self.recovery.drain()["candidates"], 0)
            run.assert_not_called()

    def test_pending_closes_once_with_exact_guarded_command(self):
        self.pending()
        counts, run = self.drain(subprocess.CompletedProcess([], 0, "closed", ""))
        self.assertEqual(counts, {"candidates": 1, "closed": 1, "blocked": 0})
        self.assertEqual(run.call_args.args[0], [str(SCRIPTS / "dispatch-claim-helper.sh"),
                         "close-expired-pr-checkpoint-lease", "124", "owner/repo", "4", self.session])
        counts, run = self.drain()
        self.assertEqual(counts["candidates"], 0)
        run.assert_not_called()

    def test_live_unexpired_foreign_unknown_and_ordinary_records_stay_local(self):
        for change, kwargs in [({}, {"live": True}), ({}, {"ended": False}),
                               ({"expires_at": 9999999999}, {}), ({"device": "foreign"}, {}),
                               ({"session": "issue-124"}, {})]:
            with self.subTest(change=change, kwargs=kwargs):
                self.path.unlink(missing_ok=True)
                self.pending(**change)
                counts, run = self.drain(**kwargs)
                self.assertEqual(counts["closed"], 0)
                run.assert_not_called()

    def test_deny_is_allowlisted_blocked_and_never_retried(self):
        self.pending()
        counts, _ = self.drain(subprocess.CompletedProcess([], 1, "",
                              "PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=identity_mismatch\n"))
        self.assertEqual(counts["blocked"], 1)
        self.assertEqual(self.recovery.rows(self.path)[-1]["reason"], "identity_mismatch")
        _, run = self.drain()
        run.assert_not_called()

    def test_transport_failure_stops_batch_without_blocking_or_retrying(self):
        for issue in range(1, 5):
            self.pending(issue_number=issue)
        counts, run = self.drain(subprocess.CompletedProcess([], 75, "", "gh-transport pacing"))
        self.assertEqual(run.call_count, 1)
        self.assertEqual(counts, {"candidates": 4, "closed": 0, "blocked": 0})
        self.assertEqual(len(self.recovery.rows(self.path)), 4)

    def test_at_most_three_closures_per_cycle(self):
        for issue in range(1, 6):
            self.pending(issue_number=issue)
        counts, run = self.drain(subprocess.CompletedProcess([], 0, "", ""))
        self.assertEqual(run.call_count, 3)
        self.assertEqual(counts["closed"], 3)

    def test_partial_tail_is_preserved_without_swallowing_next_record(self):
        self.path.write_text('{"interrupted":')
        self.pending()
        self.assertEqual(len(self.recovery.rows(self.path)), 1)
        self.assertTrue(self.path.read_text().startswith('{"interrupted":\n'))

    def test_unknown_deny_stays_pending(self):
        self.pending()
        counts, _ = self.drain(subprocess.CompletedProcess([], 1, "",
                              "PR_CHECKPOINT_LEASE_CLOSE_DENIED reason=future_transient\n"))
        self.assertEqual(counts["blocked"], 0)
        self.assertEqual(len(self.recovery.rows(self.path)), 1)

    def test_expiry_grace_boundary(self):
        self.pending()
        with mock.patch.object(self.recovery.time, "time", return_value=220):
            _, run = self.drain()
            run.assert_not_called()
        with mock.patch.object(self.recovery.time, "time", return_value=221):
            counts, _ = self.drain(subprocess.CompletedProcess([], 0, "", ""))
            self.assertEqual(counts["closed"], 1)

    def test_unknown_native_identity_is_not_exit_proof(self):
        self.assertFalse(self.recovery.worker_ended({}))

    def test_capture_unavailable_preserves_pending_without_authority(self):
        with mock.patch.object(self.recovery, "adapter_for", side_effect=OSError):
            self.recovery.record("pending", "owner/repo", "124", self.session, "1")
        row = self.recovery.rows(self.path)[0]
        self.assertIsNone(row["process_identity"])
        self.assertFalse(self.recovery.worker_ended(row))

    def test_pulse_logs_one_idle_summary_without_external_state(self):
        logfile = pathlib.Path(self.temp.name) / "pulse.log"
        result = subprocess.run([BASH, "-c", 'source "$1/pulse-issue-reconcile-stale.sh"; '
                                 '_normalize_stale_close_pending_checkpoint_leases',
                                 "test", str(SCRIPTS)],
                                env={**os.environ, "LOGFILE": str(logfile)},
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(logfile.read_text(),
                         "[pulse-wrapper] Pending checkpoint leases: candidates=0 closed=0 blocked=0\n")

    def test_native_lifecycle_proof_and_token_free_idempotent_record(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
        try:
            self.recovery.record("pending", "owner/repo", "124", self.session, str(child.pid))
            self.recovery.record("pending", "owner/repo", "124", self.session, str(child.pid))
            records = self.recovery.rows(self.path)
            self.assertEqual(len(records), 1)
            row = records[0]
            self.assertGreaterEqual(row["expires_at"], row["ts"] + 7200)
            self.assertFalse(self.recovery.worker_ended(row))
            self.assertNotIn(LT, self.path.read_text())
        finally:
            child.terminate()
            child.wait()
        self.assertTrue(self.recovery.worker_ended(row))
        self.recovery.record("resolved", "owner/repo", "124", self.session, str(child.pid))
        counts, run = self.drain()
        self.assertEqual(counts["candidates"], 0)
        run.assert_not_called()

    def test_exit_helper_retries_once_and_records_one_pending(self):
        command = ('source "$1/terminal-lease-recovery.sh"; '
                   'sleep() { return 0; }; '
                   'fail_post() { printf "post\\n" >> "$2.calls"; return 1; }; '
                   'export AIDEVOPS_DISPATCH_LEASE_TOKEN=opaque-fixture; '
                   '_terminal_lease_emit_or_record 124 owner/repo "$2" fail_post || true')
        # Use a local device file for the child, not any host state.
        device = pathlib.Path(self.temp.name) / "device-id"
        device.write_text("dev\n")
        result = subprocess.run([BASH, "-c", command, "test", str(SCRIPTS), self.session],
                                cwd=self.temp.name, env={**os.environ, "AIDEVOPS_DEVICE_ID_FILE": str(device)},
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((pathlib.Path(self.temp.name) / "terminal.calls").read_text(), "post\npost\n")
        self.assertEqual(len(self.recovery.rows(self.path)), 1)
        self.assertNotIn("opaque-fixture", self.path.read_text())


if __name__ == "__main__":
    unittest.main()
