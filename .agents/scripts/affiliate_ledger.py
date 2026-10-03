#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private affiliate observations; canonical evidence owns all derived state."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path
from urllib.parse import urlsplit

from affiliate_records import OPAQUE, PURPOSES, validate_fields
from affiliate_storage import (
    AffiliateError, atomic, date, directory_fd, integer, observations, private_stat, public_url, read_private,
)

from knowledge_corpus_catalog import _authorized_rows, _open_authorized_catalog
from knowledge_corpus_context import (
    CatalogError, safe_location, validate_directory,
)
from knowledge_source_contract import (
    SourceContractError, canonical_evidence_id, canonical_json, projection_id,
    reject_credentials,
)

CONNECTOR = "affiliate-ledger"
KINDS = {
    "programme": {"merchant", "network", "signup_url", "dashboard_url", "requirements", "later_stages"},
    "account": {"state", "confirmation", "deadline_at"},
    "link": {"url", "purpose", "link_state", "http_status", "landing", "tracking",
             "restrictions"},
    "profile": {"profile_ref", "country", "approved", "data_scope"},
    "authorization": {"profile_id", "profile_sha256", "destination", "agreement_sha256", "data_scope",
                      "expires_at", "action"},
    "checkpoint": {"authorization_id", "outcome", "idempotency_id"},
}
COMMON = {"version", "kind", "id", "programme", "region", "stage", "observed_at",
          "source_url"}


def validate(record: dict) -> dict:
    """Closed field vocabulary prevents arbitrary form values/raw secrets entering evidence."""
    reject_credentials(record)
    if not isinstance(record, dict):
        raise AffiliateError("affiliate record must be an object")
    if not integer(record.get("version")) or record["version"] != 1:
        raise AffiliateError("unsupported affiliate record version")
    kind = record.get("kind")
    if kind not in KINDS or set(record) - COMMON - KINDS[kind]:
        raise AffiliateError("unknown affiliate fields")
    required = COMMON | KINDS[kind]
    required -= {"link": {"http_status", "landing", "tracking", "restrictions"},
                 "programme": {"dashboard_url"}, "account": {"deadline_at"}}.get(kind, set())
    if not required <= set(record):
        raise AffiliateError("missing affiliate fields")
    for field in ("id", "programme"):
        if not isinstance(record[field], str) or not OPAQUE.fullmatch(record[field]):
            raise AffiliateError("invalid opaque identity")
    if record["region"] not in {"unknown", "UK", "US", "global"}:
        raise AffiliateError("unsupported programme region")
    if record["stage"] not in {"network", "merchant"}:
        raise AffiliateError("network and merchant stages must be explicit")
    date(record["observed_at"])
    public_url(record["source_url"])
    if urlsplit(record["source_url"]).query:
        raise AffiliateError("source provenance must not contain query parameters")
    validate_fields(record)
    return record


class Ledger:
    """Resolve only personal:default through the authenticated catalog grant graph."""

    def __init__(self, base: Path, *, write: bool = False):
        self.base = base
        resolved, self.owner, connection = _open_authorized_catalog(base)
        try:
            rows = _authorized_rows(connection, self.owner,
                                    "knowledge.write" if write else "knowledge.read", "personal:default")
            if len(rows) != 1:
                raise AffiliateError("personal corpus authorization denied")
            self.corpus = str(rows[0]["corpus_id"])
            self.root = safe_location(resolved, str(rows[0]["location_ref"]))
        finally:
            connection.close()
        validate_directory(self.root, "personal corpus", repair=False)
        self.write = write
        self.raw = self.root / "sources" / "affiliate" / "raw"
        self.index = self.root / "index" / "affiliate.json"
        for path in (self.root / "sources", self.raw.parent, self.raw, self.index.parent):
            if not path.exists() and not path.is_symlink() and write:
                path.mkdir(mode=0o700)
            if path.exists() or path.is_symlink():
                validate_directory(path, "affiliate directory", repair=False)

    def _check_access(self) -> None:
        resolved, owner, connection = _open_authorized_catalog(self.base)
        try:
            rows = _authorized_rows(connection, owner,
                                    "knowledge.write" if self.write else "knowledge.read", "personal:default")
            if (owner != self.owner or len(rows) != 1 or rows[0]["corpus_id"] != self.corpus
                    or safe_location(resolved, str(rows[0]["location_ref"])) != self.root):
                raise AffiliateError("personal authorization changed")
        finally:
            connection.close()
        for path in (self.root, self.root / "sources", self.raw.parent, self.raw, self.index.parent):
            if path.exists() or path.is_symlink():
                validate_directory(path, "affiliate directory", repair=False)

    @contextlib.contextmanager
    def locked(self):
        """Exclusive lock covers replay, state validation, raw commit and projection."""
        if not self.write:
            raise AffiliateError("read-only ledger")
        self._check_access()
        with directory_fd(self.raw.parent) as directory:
            fd = os.open("ledger.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW,
                         0o600, dir_fd=directory)
            try:
                private_stat(os.fstat(fd))
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise AffiliateError("affiliate writer is busy; no action executed") from error
                self._check_projection_version()
                yield
            finally:
                os.close(fd)

    def replay(self) -> list[dict]:
        """Read immutable digest-bound observations; never trust a stale projection."""
        self._check_access()
        if not self.raw.exists():
            return []
        events = []
        with directory_fd(self.raw) as directory:
            for digest, envelope in observations(directory, self.corpus):
                validate(envelope["record"])
                eid = canonical_evidence_id(self.corpus, CONNECTOR, digest)
                events.append({**envelope, "evidence_id": eid,
                               "projection_id": projection_id(eid, CONNECTOR, envelope["record"]["id"]),
                               "authority": "projection", "canonical_plane": "_knowledge"})
        events.sort(key=lambda event: event["sequence"])
        if [e["sequence"] for e in events] != list(range(1, len(events) + 1)):
            raise AffiliateError("evidence sequence is incomplete")
        from affiliate_signup import validate_transition
        for index, event in enumerate(events):
            validate_transition(events[:index], event["record"], current=False)
        return events

    def append(self, record: dict) -> dict:
        """Idempotent ingestion with canonical raw commit preceding rebuildable projection."""
        validate(record)
        with self.locked():
            events = self.replay()
            for event in events:
                if event["record"] == record:
                    self._projection(events)
                    return event
            from affiliate_signup import validate_transition
            validate_transition(events, record)
            envelope = {"version": 1, "corpus_id": self.corpus,
                        "sequence": len(events) + 1, "record": record}
            payload = canonical_json(envelope).encode()
            if len(payload) > 65536:
                raise AffiliateError("affiliate observation exceeds bounded size")
            digest = hashlib.sha256(payload).hexdigest()
            atomic(self.raw / (digest + ".json"), payload)
            self._projection(self.replay())
            return self.replay()[-1]

    def _check_projection_version(self) -> None:
        with directory_fd(self.index.parent) as directory:
            try:
                projection = json.loads(read_private(self.index.name, directory, maximum=8388608))
            except FileNotFoundError:
                return
        if (not isinstance(projection, dict) or not integer(projection.get("version"))
                or projection["version"] != 1 or projection.get("corpus_id") != self.corpus):
            raise AffiliateError("unsupported or cross-corpus affiliate projection")

    def _projection(self, events: list[dict]) -> None:
        atomic(self.index, canonical_json({"version": 1, "corpus_id": self.corpus,
                                          "events": events}).encode())

    def rebuild(self) -> int:
        with self.locked():
            events = self.replay()
            self._projection(events)
            return len(events)


def latest(events: list[dict], kind: str | None = None) -> list[dict]:
    """Return latest entity observations, keeping membership and link state separate."""
    rows = {}
    for event in events:
        record = event["record"]
        if kind is None or record["kind"] == kind:
            rows[(record["kind"], record["id"])] = event
    return list(rows.values())


def catalog() -> list[dict]:
    return json.loads((Path(__file__).parent.parent / "templates" / "affiliate-programs.json").read_text())["programmes"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["list", "requirements", "lookup", "import", "rebuild", "prepare", "checkpoint"])
    parser.add_argument("--programme")
    parser.add_argument("--purpose", choices=sorted(PURPOSES))
    parser.add_argument("--file", type=Path)
    parser.add_argument("--authorization")
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "requirements":
            result = [p for p in catalog() if not args.programme or p["id"] == args.programme]
        elif args.command == "prepare":
            from affiliate_signup import prepare
            result = prepare(args.programme, live=args.live)
        else:
            from affiliate_signup import private_command
            result = private_command(args)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (AffiliateError, CatalogError, SourceContractError, OSError, sqlite3.Error,
            ValueError, TypeError, KeyError) as error:
        # Catalog/JSON errors can contain private paths or submitted values.
        del error
        print("ERROR: affiliate operation refused; check private scope, schema and evidence", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
