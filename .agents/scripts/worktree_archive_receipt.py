#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Validate restoration receipts without granting source-removal authority."""

import hashlib
import json
from pathlib import Path


def verify_restoration_receipt(record, value, archive, proof):
    # Resolve lifecycle helpers at call time: restoration and retirement also
    # share them, and callers may already hold the registry write transaction.
    from worktree_lifetime_archive import helper, inode, require
    from worktree_archive_restore import RestorationProof
    from worktree_recovery_retirement_transaction import fingerprint
    manifest = archive / "manifest.json"
    receipt = value.get("canonical_restore", {})
    expected_source = {"identity": record["identity"], "generation": record["generation"],
                       "snapshot": value["snapshot"]}
    expected_receipt = {"schema": "canonical-restore/v1", "state": "cleaned",
                        "source": expected_source, "archive": str(archive),
                        "manifest_sha256": value["manifest_sha256"]}
    require(all(receipt.get(key) == expected for key, expected in expected_receipt.items()),
            "canonical restoration receipt unavailable; prepare required")
    captured = json.loads(manifest.read_text(encoding="utf-8"))
    common = Path(captured["source_git_common_dir"])
    require(inode(archive) == receipt["archive_inode"] and captured["base_sha"] == receipt["base"]
            and common == common.resolve(strict=True) and inode(common) == receipt["base_inode"],
            "archive or base identity changed since restoration")
    require(fingerprint(archive) == receipt["archive_digest"], "archive artifacts changed since restoration")
    if proof is None:
        # Native removal may hold the registry write transaction. Do not allocate
        # another registered worktree there: fully revalidate immutable inputs and
        # dependencies against the bound restoration receipt instead. No persistent
        # verified cache bypasses this fresh graph check across process boundaries.
        helper("verify", str(archive))
    else:
        require(isinstance(proof, RestorationProof) and proof.archive == archive
                and proof.archive_digest == receipt["archive_digest"], "wrong restoration proof")
        proof.check()
    require(hashlib.sha256(manifest.read_bytes()).hexdigest() == value["manifest_sha256"], "archive changed during verification")
    require(fingerprint(archive) == receipt["archive_digest"], "archive artifacts changed during verification")
