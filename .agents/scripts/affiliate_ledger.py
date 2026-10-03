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
import re
import sqlite3
import stat
import sys
import uuid
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

from knowledge_corpus_catalog import _authorized_rows, _open_authorized_catalog
from knowledge_corpus_context import (
    CatalogError, safe_location, validate_directory, validate_private_file,
)
from knowledge_corpus_helpers import _default_base
from knowledge_source_contract import (
    SourceContractError, canonical_evidence_id, canonical_json, projection_id,
    reject_credentials,
)

CONNECTOR = "affiliate-ledger"
STATES = {"discovered", "preparation-ready", "awaiting-human", "submitted",
          "pending-review", "approved", "rejected", "closed"}
PURPOSES = {"home", "product", "pricing", "store", "bundle", "bot"}
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
OPAQUE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{2,95}$")
SECRET_QUERY = re.compile(r"token|secret|password|cookie|auth|session|key|code|tax|iban", re.I)


class AffiliateError(ValueError):
    """Sanitized safety failure; never include input values in diagnostics."""


def date(value: str) -> datetime:
    """Require explicit timezone evidence timestamps."""
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            raise ValueError
        return result
    except (ValueError, AttributeError) as error:
        raise AffiliateError("invalid evidence date") from error


def public_url(value: str) -> str:
    """Preserve tracking bytes while rejecting credential-shaped URLs."""
    if not isinstance(value, str) or len(value) > 2048 or any(c.isspace() for c in value):
        raise AffiliateError("invalid public URL")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.fragment or parsed.port not in (None, 443)):
        raise AffiliateError("invalid public URL")
    if any(SECRET_QUERY.search(key) for key, _ in parse_qsl(parsed.query)):
        raise AffiliateError("credential-shaped URL is forbidden")
    return value


def validate(record: dict) -> dict:
    """Closed field vocabulary prevents arbitrary form values/raw secrets entering evidence."""
    reject_credentials(record)
    if not isinstance(record, dict) or type(record.get("version")) is not int or record["version"] != 1:
        raise AffiliateError("unsupported affiliate record version")
    kind = record.get("kind")
    if kind not in KINDS or set(record) - COMMON - KINDS[kind]:
        raise AffiliateError("unknown affiliate fields")
    required = COMMON | KINDS[kind]
    if kind == "link":
        required -= {"http_status", "landing", "tracking", "restrictions"}
    elif kind == "programme":
        required -= {"dashboard_url"}
    elif kind == "account":
        required -= {"deadline_at"}
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
    if kind == "programme":
        for field in ("merchant", "network"):
            if not isinstance(record[field], str) or not OPAQUE.fullmatch(record[field]):
                raise AffiliateError("programme requires stable merchant/network identities")
        public_url(record["signup_url"])
        if "dashboard_url" in record:
            public_url(record["dashboard_url"])
        if record["later_stages"] not in {"unknown", "observed"}:
            raise AffiliateError("later programme stages must retain uncertainty")
        if (not isinstance(record["requirements"], list) or not record["requirements"]
                or any(item not in {"country", "business-identity", "tax-residency",
                                    "audience-evidence", "promotional-properties", "email-verification",
                                    "captcha", "agreement", "payout-handoff", "unknown"}
                       for item in record["requirements"])):
            raise AffiliateError("unsupported requirement vocabulary")
    elif kind == "account":
        if "deadline_at" in record:
            date(record["deadline_at"])
        proof = record["confirmation"]
        if record["state"] not in STATES or proof not in {
            "none", "submission-receipt", "review-notice", "approval-notice",
            "rejection-notice", "closure-notice",
        }:
            raise AffiliateError("invalid account observation")
        expected = {"submitted": "submission-receipt", "pending-review": "review-notice",
                    "approved": "approval-notice", "rejected": "rejection-notice",
                    "closed": "closure-notice"}
        if record["state"] in expected and proof != expected[record["state"]]:
            raise AffiliateError("account state requires explicit confirmation evidence")
    elif kind == "link":
        public_url(record["url"])
        if record["purpose"] not in PURPOSES or record["link_state"] not in {
            "observed", "verified", "degraded", "unknown",
        }:
            raise AffiliateError("invalid link observation")
        status = record.get("http_status")
        if status is not None and (type(status) is not int or not 100 <= status <= 599):
            raise AffiliateError("invalid HTTP observation")
        if record.get("landing") not in {None, "matched", "wrong-product", "closed", "unknown"}:
            raise AffiliateError("invalid landing observation")
        if record.get("tracking") not in {None, "preserved", "lost", "unknown"}:
            raise AffiliateError("invalid tracking observation")
        restrictions = record.get("restrictions", ["unknown"])
        if (not isinstance(restrictions, list) or any(item not in {
                "unknown", "disclosure-required", "no-paid-search", "no-email", "no-social",
                "no-coupon", "approved-properties-only",
        } for item in restrictions)):
            raise AffiliateError("unsupported placement restrictions; retain unknown")
        if status in {403, 405, 429} and record["link_state"] not in {"unknown", "observed"}:
            raise AffiliateError("access-limited links remain unverified")
        if record["link_state"] == "verified" and not (
            status is not None and 200 <= status < 300
            and record.get("landing") == "matched" and record.get("tracking") == "preserved"
        ):
            raise AffiliateError("verification requires matched landing and intact tracking")
        if record["link_state"] == "degraded" and not (
            record.get("landing") in {"wrong-product", "closed"} or record.get("tracking") == "lost"
        ):
            raise AffiliateError("degradation requires destination evidence")
    elif kind == "profile":
        if not re.fullmatch(r"protected:[A-Za-z0-9_-]{3,96}", str(record["profile_ref"])):
            raise AffiliateError("profile must reference separately protected material")
        if not isinstance(record["country"], str) or not re.fullmatch(r"[A-Z]{2}|unknown", record["country"]):
            raise AffiliateError("country must be evidenced, never inferred")
        if type(record["approved"]) is not bool:
            raise AffiliateError("profile approval must be explicit")
    elif kind == "authorization":
        public_url(record["destination"])
        if urlsplit(record["destination"]).query:
            raise AffiliateError("signup destination must not contain query parameters")
        date(record["expires_at"])
        if (record["action"] != "submit"
                or not re.fullmatch(r"[0-9a-f]{64}", record["agreement_sha256"])
                or not re.fullmatch(r"[0-9a-f]{64}", record["profile_sha256"])):
            raise AffiliateError("authorization must bind submission and agreement version")
    elif kind == "checkpoint":
        if record["outcome"] not in {"awaiting-reconciliation", "confirmed-submitted", "confirmed-not-submitted"}:
            raise AffiliateError("invalid reconciliation outcome")
        if not re.fullmatch(r"[0-9a-f]{64}", record["idempotency_id"]):
            raise AffiliateError("invalid idempotency identity")
    for field in ("profile_id", "authorization_id"):
        if field in record and not OPAQUE.fullmatch(str(record[field])):
            raise AffiliateError("invalid reference")
    if "data_scope" in record and (not isinstance(record["data_scope"], list)
            or not record["data_scope"] or any(item not in {
                "identity-reference", "country", "promotional-properties", "audience-evidence",
            } for item in record["data_scope"])):
        raise AffiliateError("unsupported personal data scope")
    return record


def private_stat(info: os.stat_result, *, directory: bool = False) -> None:
    """Check the opened inode, not a pathname that can be substituted."""
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)):
        raise AffiliateError("insecure affiliate inode")


@contextlib.contextmanager
def directory_fd(path: Path):
    """Anchor operations through non-symlink directory descriptors at every component."""
    descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.absolute().parts[1:]:
            if part in {".", ".."}:
                raise AffiliateError("non-canonical affiliate path")
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        private_stat(os.fstat(descriptor), directory=True)
        yield descriptor
    finally:
        os.close(descriptor)


def read_private(name: str, directory: int, *, maximum: int = 65536) -> bytes:
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    with os.fdopen(descriptor, "rb") as handle:
        private_stat(os.fstat(handle.fileno()))
        payload = handle.read(maximum + 1)
    if len(payload) > maximum:
        raise AffiliateError("affiliate observation exceeds bounded size")
    return payload


def atomic(path: Path, payload: bytes) -> None:
    """Replace descriptor-anchored private files, fsync data and directory."""
    with directory_fd(path.parent) as directory:
        try:
            info = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None:
            private_stat(info)
        name = ".affiliate-" + uuid.uuid4().hex
        descriptor = os.open(name, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(name, path.name, src_dir_fd=directory, dst_dir_fd=directory)
            os.fsync(directory)
        finally:
            try:
                os.unlink(name, dir_fd=directory)
            except FileNotFoundError:
                pass


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
                fcntl.flock(fd, fcntl.LOCK_EX)
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
            for name in sorted(os.listdir(directory)):
                # Interrupted private drafts never contribute authority.
                if name.startswith(".affiliate-"):
                    try:
                        private_stat(os.stat(name, dir_fd=directory, follow_symlinks=False))
                    except FileNotFoundError:
                        pass
                    continue
                payload = read_private(name, directory)
                digest = hashlib.sha256(payload).hexdigest()
                if name != digest + ".json":
                    raise AffiliateError("evidence integrity mismatch")
                envelope = json.loads(payload)
                if (set(envelope) != {"version", "corpus_id", "sequence", "record"}
                        or type(envelope["version"]) is not int or envelope["version"] != 1
                        or envelope["corpus_id"] != self.corpus
                        or type(envelope["sequence"]) is not int):
                    raise AffiliateError("unsupported or cross-corpus evidence")
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
                    return event
            from affiliate_signup import validate_transition
            validate_transition(events, record)
            envelope = {"version": 1, "corpus_id": self.corpus,
                        "sequence": len(events) + 1, "record": record}
            payload = canonical_json(envelope).encode()
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
        if (projection.get("version") != 1 or projection.get("corpus_id") != self.corpus):
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
            ledger = Ledger(_default_base(), write=args.command in {"import", "rebuild", "checkpoint"})
            if args.command == "import":
                if args.file is None:
                    raise AffiliateError("private import file required")
                validate_private_file(args.file, "import input", repair=False)
                with directory_fd(args.file.parent) as directory:
                    result = ledger.append(json.loads(read_private(args.file.name, directory)))
            elif args.command == "rebuild":
                result = {"rebuilt": ledger.rebuild()}
            elif args.command == "checkpoint":
                from affiliate_signup import checkpoint
                result = checkpoint(ledger, args.authorization)
            else:
                events = latest(ledger.replay(), "link" if args.command == "lookup" else None)
                result = [e for e in events if not args.programme or e["record"]["programme"] == args.programme]
                if args.command == "lookup":
                    result = [e for e in result if e["record"]["link_state"] == "verified"
                              and args.purpose == e["record"]["purpose"]]
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
