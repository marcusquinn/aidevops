# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Select and combine per-platform screen-time sources for the interval engine."""

from __future__ import annotations

from pathlib import Path

from screen_time_interval_common import WINDOWS, union_intervals
from screen_time_linux import linux_collection, linux_sample
from screen_time_macos import macos_collection
from screen_time_macos_input import macos_input_collection, macos_input_sample
from screen_time_macos_pmset import pmset_collection

STALE_HOURS = 72
SAMPLED_PLATFORMS = ("Linux", "Darwin")


def unsupported(os_type):
    return {"status": "unavailable", "source": "unsupported-platform", "reason": os_type, "intervals": []}


def merge_display_sources(knowledge, pmset, now):
    """Union a readable Knowledge source with pmset display assertions.

    Both observe display-on time, but neither is complete alone: the backlit
    stream can stop for days while pmset keeps only about a week (GH#37492).
    """
    if knowledge.get("status") == "unavailable":
        return pmset
    if pmset.get("status") == "unavailable":
        return knowledge
    latest = max(knowledge["latest_epoch"], pmset["latest_epoch"])
    freshness = max(0.0, (now - latest) / 3600)
    return dict(
        knowledge,
        source=f"{knowledge['source']}+{pmset['source']}",
        intervals=union_intervals(knowledge["intervals"] + pmset["intervals"], now - WINDOWS["year"], now),
        observations=knowledge.get("observations", 0) + pmset.get("observations", 0),
        latest_epoch=latest,
        earliest_epoch=min(knowledge["earliest_epoch"], pmset["earliest_epoch"]),
        observation_epochs=knowledge.get("observation_epochs", []) + pmset.get("observation_epochs", []),
        coverage_start_epoch=min(knowledge["coverage_start_epoch"], pmset["coverage_start_epoch"]),
        coverage_end_epoch=max(knowledge["coverage_end_epoch"], pmset["coverage_end_epoch"]),
        freshness_hours=round(freshness, 1),
        status="stale" if freshness > STALE_HOURS else "ok",
    )


def display_collection(os_type, db, now, directory):
    """macOS display-on time (Knowledge DB with pmset); Linux sampled input activity."""
    if os_type == "Darwin":
        return merge_display_sources(macos_collection(Path(db), now), pmset_collection(now), now)
    if os_type == "Linux":
        return linux_collection(now, directory)
    return unsupported(os_type)


def input_collection(os_type, now, directory):
    """Human input activity under the shared idle cut-off rule on every platform."""
    if os_type == "Darwin":
        return macos_input_collection(now, directory)
    if os_type == "Linux":
        return linux_collection(now, directory)
    return unsupported(os_type)


def record_input_sample(os_type, now, user, directory):
    """Record one input-activity sample: macOS HID idle; Linux tty and desktop idle."""
    if os_type == "Darwin":
        return macos_input_sample(now, directory)
    return linux_sample(now, user, directory)


def with_evidence(payload, collection):
    """Expose the latest sample's evidence kinds (e.g. desktop vs terminal input)."""
    if "evidence" in collection:
        payload["evidence"] = collection["evidence"]
    return payload
