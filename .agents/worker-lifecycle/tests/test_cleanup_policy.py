"""Decision-table simulations, not evidence of a working archive executor."""

from dataclasses import replace
import unittest

from worker_lifecycle.cleanup_policy import CleanupEvidence, decide_cleanup


class CleanupPolicyContract(unittest.TestCase):
    def setUp(self):
        self.complete = CleanupEvidence(
            generation_verified=True,
            admission_closed=True,
            ownership_complete=True,
            writers_quiescent=True,
            run_states=("ended",),
            inventory_complete=True,
            preservation="required",
        )

    def test_missing_registration_is_not_permission(self):
        result = decide_cleanup(CleanupEvidence())
        self.assertEqual((result.action, result.reason), ("hold", "generation-unverified"))

    def test_each_missing_proof_holds_even_with_preserved_results(self):
        for field in (
            "generation_verified", "admission_closed", "ownership_complete",
            "writers_quiescent", "inventory_complete",
        ):
            with self.subTest(field=field):
                evidence = replace(self.complete, preservation="verified", **{field: False})
                self.assertEqual(decide_cleanup(evidence).action, "hold")

    def test_empty_live_or_unknown_owners_hold(self):
        for states in ((), ("alive",), ("unknown",), ("ended", "alive"), ("ended", "unknown")):
            with self.subTest(states=states):
                result = decide_cleanup(replace(self.complete, run_states=states))
                self.assertEqual(result.reason, "runs-not-confirmed-ended")
                self.assertEqual(result.action, "hold")

    def test_all_owners_must_end(self):
        result = decide_cleanup(replace(self.complete, run_states=("ended", "ended")))
        self.assertEqual(result.action, "archive-candidate")

    def test_unpublished_results_require_archive(self):
        # No push or PR is needed to deserve preservation. The collector must
        # classify staged, unstaged, untracked and unique committed results.
        result = decide_cleanup(self.complete)
        self.assertEqual(result.action, "archive-candidate")
        self.assertFalse(result.cleanup_authorized)

    def test_preserved_results_only_produce_a_candidate(self):
        result = decide_cleanup(replace(self.complete, preservation="verified"))
        self.assertEqual(result.action, "remove-candidate")
        self.assertFalse(result.cleanup_authorized)

    def test_failed_inventory_cannot_be_archived_then_removed(self):
        result = decide_cleanup(replace(self.complete, inventory_complete=False))
        self.assertEqual(result.reason, "inventory-incomplete")

    def test_uncertain_preservation_holds(self):
        result = decide_cleanup(replace(self.complete, preservation="unknown"))
        self.assertEqual(result.action, "hold")

    def test_repeatable_and_never_authorizes_cleanup(self):
        for preservation in ("required", "verified", "unknown"):
            evidence = replace(self.complete, preservation=preservation)
            first = decide_cleanup(evidence)
            self.assertEqual(first, decide_cleanup(evidence))
            self.assertFalse(first.cleanup_authorized)


if __name__ == "__main__":
    unittest.main()
