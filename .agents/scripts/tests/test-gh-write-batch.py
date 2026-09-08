#!/usr/bin/env python3
"""Hermetic regression tests for bounded managed GitHub write batches."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "gh-write-batch.py"
SPEC = importlib.util.spec_from_file_location("gh_write_batch", SCRIPT)
assert SPEC and SPEC.loader
BATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BATCH)


class BatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="gh-write-batch-test.")
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.signature = self.private_file(
            "signature-helper.sh",
            "#!/usr/bin/env bash\nprintf '%s\\n' '<!-- aidevops:sig -->' 'canonical footer'\n",
        )
        os.chmod(self.signature, 0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def private_file(self, name: str, content: str) -> Path:
        path = self.root / name
        path.write_text(content, encoding="utf-8")
        os.chmod(path, 0o600)
        return path

    def prepare(self, operations: list[dict], recovery_of: dict | None = None) -> dict:
        manifest = {
            "schema": BATCH.SCHEMA,
            "repository": "test/repo",
            "operations": operations,
        }
        if recovery_of is not None:
            manifest["recovery_of"] = recovery_of
        manifest_path = self.private_file("manifest.json", json.dumps(manifest))
        prepared_path = self.root / "prepared.json"
        args = argparse.Namespace(
            manifest=str(manifest_path),
            temp_root=str(self.root),
            signature_helper=str(self.signature),
            output=str(prepared_path),
        )
        self.assertEqual(BATCH.prepare(args), 0)
        return json.loads(prepared_path.read_text(encoding="utf-8"))

    @staticmethod
    def preflight(prepared: dict, permission: str = "WRITE", marker: str | None = None) -> dict:
        repository: dict = {"viewerPermission": permission}
        labels = sorted({label for op in prepared["operations"] for label in op.get("labels", [])})
        for index, label in enumerate(labels):
            repository[f"l{index}"] = {"id": f"L{index}", "name": label}
        for index, operation in enumerate(prepared["operations"]):
            target = {
                "__typename": operation["target_type"],
                "id": f"T{index}",
                "number": operation["number"],
                "title": "old title",
                "body": "old body",
                "labels": {"nodes": [], "pageInfo": {"hasNextPage": False}},
            }
            if prepared.get("recovery_of") and operation["kind"].endswith("_comment"):
                target["comments"] = {
                    "nodes": [{"body": marker}] if marker else [],
                    "pageInfo": {"hasPreviousPage": False},
                }
            repository[f"t{index}"] = target
        return {"data": {"repository": repository}}

    def execute(self, prepared: dict, calls: list[tuple]) -> tuple[int, dict]:
        prepared_path = self.private_file("execute.json", json.dumps(prepared))
        receipt_path = self.root / "receipt.json"
        args = argparse.Namespace(prepared=str(prepared_path), receipt=str(receipt_path))
        with (
            mock.patch.object(BATCH, "graphql_call", side_effect=calls),
            redirect_stdout(StringIO()),
            redirect_stderr(StringIO()),
        ):
            result = BATCH.execute(args)
        return result, json.loads(receipt_path.read_text(encoding="utf-8"))

    def test_prepare_signs_comments_and_rejects_unsafe_shapes(self) -> None:
        body = self.private_file("body.md", "Substantive comment\n")
        prepared = self.prepare(
            [{"id": "comment", "kind": "issue_comment", "number": 7, "body_file": str(body)}]
        )
        copied = Path(prepared["operations"][0]["body_file"]).read_text(encoding="utf-8")
        self.assertEqual(copied.count("<!-- aidevops:sig -->"), 1)
        self.assertIn(f"<!-- aidevops:batch:{prepared['manifest_sha256']}:comment -->", copied)

        outside = Path(tempfile.gettempdir()) / "gh-write-batch-unsafe.md"
        outside.write_text("unsafe", encoding="utf-8")
        os.chmod(outside, 0o600)
        self.addCleanup(outside.unlink, missing_ok=True)
        with self.assertRaisesRegex(BATCH.BatchError, "under AIDEVOPS_TEMP_DIR"):
            self.prepare(
                [{"id": "unsafe", "kind": "pr_comment", "number": 8, "body_file": str(outside)}]
            )
        with self.assertRaisesRegex(BATCH.BatchError, "unsupported fields"):
            self.prepare([{"id": "mixed", "kind": "issue_add_labels", "number": 1, "labels": ["bug"], "repository": "other/repo"}])
        with self.assertRaisesRegex(BATCH.BatchError, "1-10 operations"):
            self.prepare(
                [{"id": f"op{index}", "kind": "issue_add_labels", "number": index + 1, "labels": ["bug"]} for index in range(11)]
            )
        with self.assertRaisesRegex(BATCH.BatchError, "protected label"):
            self.prepare([{"id": "origin", "kind": "pr_add_labels", "number": 2, "labels": ["origin:interactive"]}])

    def test_all_success_and_label_alias_order(self) -> None:
        prepared = self.prepare(
            [
                {"id": "labels", "kind": "pr_add_labels", "number": 3, "labels": ["zeta", "alpha"]},
                {"id": "edit", "kind": "issue_edit", "number": 4, "title": "Updated title"},
            ]
        )
        preflight = self.preflight(prepared)
        _, preflight_variables = BATCH.preflight_query(prepared)
        self.assertEqual(preflight_variables["label0"], "alpha")
        self.assertEqual(preflight_variables["label1"], "zeta")
        mutation = {"data": {"o0": {"clientMutationId": "labels"}, "o1": {"clientMutationId": "edit", "issue": {"id": "T1", "number": 4}}}}
        result, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (0, json.dumps(mutation), "", False)],
        )
        self.assertEqual(result, 0)
        self.assertEqual(receipt["overall"], "succeeded")
        self.assertEqual({op["status"] for op in receipt["operations"]}, {"succeeded"})

    def test_partial_error_timeout_and_authority_fail_closed(self) -> None:
        body = self.private_file("body.md", "Comment\n")
        prepared = self.prepare(
            [
                {"id": "one", "kind": "issue_comment", "number": 1, "body_file": str(body)},
                {"id": "two", "kind": "pr_comment", "number": 2, "body_file": str(body)},
            ]
        )
        preflight = self.preflight(prepared)
        partial = {
            "data": {
                "o0": {
                    "clientMutationId": "one",
                    "commentEdge": {"node": {"id": "C1"}},
                }
            }
        }
        result, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (1, json.dumps(partial), "error", False)],
        )
        self.assertEqual(result, 1)
        self.assertEqual([op["status"] for op in receipt["operations"]], ["succeeded", "unknown"])

        scoped_error = {"data": {"o0": None, "o1": None}, "errors": [{"path": ["o0"], "message": "failed"}]}
        _, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (1, json.dumps(scoped_error), "", False)],
        )
        self.assertEqual([op["status"] for op in receipt["operations"]], ["failed", "unknown"])

        global_error = {"data": None, "errors": [{"message": "service unavailable"}]}
        _, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (1, json.dumps(global_error), "", False)],
        )
        self.assertEqual({op["status"] for op in receipt["operations"]}, {"unknown"})

        _, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (124, "", "timeout", True)],
        )
        self.assertEqual({op["status"] for op in receipt["operations"]}, {"unknown"})

        _, receipt = self.execute(
            prepared,
            [(0, json.dumps(preflight), "", False), (75, "", "retry_at=123", False)],
        )
        self.assertEqual({op["status"] for op in receipt["operations"]}, {"deferred"})

        result, receipt = self.execute(
            prepared,
            [(0, json.dumps(self.preflight(prepared, permission="READ")), "", False)],
        )
        self.assertEqual(result, 1)
        self.assertEqual({op["status"] for op in receipt["operations"]}, {"rejected"})

        label_prepared = self.prepare(
            [{"id": "label", "kind": "issue_add_labels", "number": 3, "labels": ["missing"]}]
        )
        unknown_label = self.preflight(label_prepared)
        unknown_label["data"]["repository"]["l0"] = None
        result, receipt = self.execute(
            label_prepared,
            [(0, json.dumps(unknown_label), "", False)],
        )
        self.assertEqual(result, 1)
        self.assertEqual(receipt["operations"][0]["status"], "rejected")

    def test_recovery_uses_original_marker_and_prevents_duplicate_comment(self) -> None:
        body = self.private_file("recovery-body.md", "Recover me\n")
        original = self.prepare(
            [{"id": "recover", "kind": "issue_comment", "number": 9, "body_file": str(body)}]
        )
        receipt = BATCH.base_receipt(original)
        receipt_path = self.root / "original-receipt.json"
        BATCH.write_private_json(receipt_path, receipt)
        recovered = self.prepare(
            [{"id": "recover", "kind": "issue_comment", "number": 9, "body_file": str(body)}],
            {"manifest_sha256": original["manifest_sha256"], "receipt_file": str(receipt_path)},
        )
        marker = f"<!-- aidevops:batch:{original['manifest_sha256']}:recover -->"
        self.assertIn(marker, Path(recovered["operations"][0]["body_file"]).read_text(encoding="utf-8"))
        result, recovered_receipt = self.execute(
            recovered,
            [(0, json.dumps(self.preflight(recovered, marker=marker)), "", False)],
        )
        self.assertEqual(result, 0)
        self.assertEqual(recovered_receipt["operations"][0]["status"], "already_succeeded")

        changed = self.private_file("changed.md", "Different payload\n")
        with self.assertRaisesRegex(BATCH.BatchError, "payload does not match"):
            self.prepare(
                [{"id": "recover", "kind": "issue_comment", "number": 9, "body_file": str(changed)}],
                {"manifest_sha256": original["manifest_sha256"], "receipt_file": str(receipt_path)},
            )

        pr_body = self.private_file("pr-body.md", "Stable PR content\n")
        original_edit = self.prepare(
            [{"id": "edit", "kind": "pr_edit", "number": 10, "body_file": str(pr_body)}]
        )
        edit_receipt = BATCH.base_receipt(original_edit)
        edit_receipt_path = self.root / "edit-receipt.json"
        BATCH.write_private_json(edit_receipt_path, edit_receipt)
        original_published_body = Path(original_edit["operations"][0]["body_file"]).read_text(
            encoding="utf-8"
        )
        self.signature.write_text(
            "#!/usr/bin/env bash\nprintf '%s\\n' '<!-- aidevops:sig -->' 'new canonical footer'\n",
            encoding="utf-8",
        )
        recovered_edit = self.prepare(
            [{"id": "edit", "kind": "pr_edit", "number": 10, "body_file": str(pr_body)}],
            {
                "manifest_sha256": original_edit["manifest_sha256"],
                "receipt_file": str(edit_receipt_path),
            },
        )
        edit_preflight = self.preflight(recovered_edit)
        edit_preflight["data"]["repository"]["t0"]["body"] = original_published_body
        result, recovered_edit_receipt = self.execute(
            recovered_edit,
            [(0, json.dumps(edit_preflight), "", False)],
        )
        self.assertEqual(result, 0)
        self.assertEqual(recovered_edit_receipt["operations"][0]["status"], "already_succeeded")


if __name__ == "__main__":
    unittest.main()
