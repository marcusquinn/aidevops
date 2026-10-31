#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Generation-bound boot-transition and same-boot census receipt policy."""

import os
import time

import worktree_lifetime_owner as owner

CENSUS_INTERVAL = 2


def quiescence(launch, worktree_identity=None, census_cache=None):
    """Require a boot transition or two complete, empty Linux path censuses."""
    from worktree_lifetime_reconcile import finished, identity, valid_boot
    owner.require(finished(launch), "recorded process is not reconciled as finished")
    before = owner.boot_id()
    owner.require(valid_boot(before), "boot identity unavailable")
    receipt = {"schema": "owner-observation-quiescence/v1", "identity": identity(launch),
               "process_completion": dict(launch["process_completion"]),
               "group": "previous-boot-ended", "observed_boot": before}
    if before == launch["boot_id"]:
        owner.require(isinstance(worktree_identity, dict) and
                      os.path.isabs(worktree_identity.get("path", "")) and
                      bool(worktree_identity.get("source_inode")),
                      "same-boot parent requires worktree generation identity")
        from worktree_process_snapshot import path_census
        # This cache belongs to one seal/authorization call, never the registry.
        key = (worktree_identity["path"], worktree_identity["source_inode"], os.getuid(), before)
        samples = census_cache.get(key) if census_cache is not None else None
        if samples is None:
            samples = []
            for index in range(2):
                if index:
                    time.sleep(CENSUS_INTERVAL)
                sample = path_census(worktree_identity["path"])
                owner.require(empty_census(sample, before), "same-boot process census active or unavailable")
                samples.append(sample)
            if census_cache is not None:
                census_cache[key] = samples
        owner.require(samples[1]["observed_at"] - samples[0]["observed_at"] >= CENSUS_INTERVAL,
                      "process census interval too short")
        owner.require(owner.recorded_process_status(launch)["status"] in
                      ("previous-boot", "pid-absent", "pid-reused"), "recorded parent no longer finished")
        receipt.update(group="same-boot-proc-census", worktree_identity=dict(worktree_identity),
                       samples=samples)
    owner.require(owner.boot_id() == before, "boot changed during observation")
    return dict(receipt, observed_at=time.time())


def empty_census(sample, boot):
    from worktree_lifetime_reconcile import valid_timestamp
    return isinstance(sample, dict) and all((
        sample.get("status") == "available", sample.get("boot_id") == boot,
        type(sample.get("uid")) is int and sample["uid"] == os.getuid(),
        type(sample.get("references")) is int and sample["references"] == 0,
        type(sample.get("uncertain")) is int and sample["uncertain"] == 0,
        valid_timestamp(sample.get("observed_at"))))


def validate_quiescence(launch, worktree_identity=None):
    from worktree_lifetime_reconcile import finished, identity, valid_boot, valid_timestamp
    invalid = "invalid observation completion receipt"
    owner.require(finished(launch), invalid)
    receipt = launch.get("observation_quiescence", {})
    owner.require(isinstance(receipt, dict), invalid)
    owner.require(all((receipt.get("schema") == "owner-observation-quiescence/v1",
                       receipt.get("identity") == identity(launch),
                       receipt.get("process_completion") == launch.get("process_completion"),
                       valid_boot(receipt.get("observed_boot")),
                       valid_timestamp(receipt.get("observed_at")))), invalid)
    if receipt.get("group") == "previous-boot-ended":
        owner.require(receipt["observed_boot"] != launch["boot_id"], invalid)
        return
    samples = receipt.get("samples")
    owner.require(all((receipt.get("group") == "same-boot-proc-census",
                       receipt["observed_boot"] == launch["boot_id"],
                       isinstance(worktree_identity, dict),
                       receipt.get("worktree_identity") == worktree_identity,
                       isinstance(samples, list) and len(samples) == 2)), invalid)
    owner.require(all(empty_census(sample, receipt["observed_boot"]) for sample in samples), invalid)
    owner.require(samples[1]["observed_at"] - samples[0]["observed_at"] >= CENSUS_INTERVAL and
                  samples[1]["observed_at"] <= receipt["observed_at"], invalid)
