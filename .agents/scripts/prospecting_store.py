#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Private, project-isolated SQLite store for prospecting projections."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from prospecting_contract import DISPOSITIONS, ImportDocument, validate_project_payload

SCHEMA_VERSION = 1


class ProspectingStoreError(RuntimeError):
    """Raised when a prospecting operation cannot preserve store invariants."""


class StaleVersionError(ProspectingStoreError):
    """Raised when a compare-and-swap update uses a stale version."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def document_digest(value: dict[str, Any]) -> str:
    return "sha256:" + hashlib.sha256(_json(value).encode()).hexdigest()


def database_path(root: Path) -> Path:
    return root / "prospecting.db"


def connect(root: Path) -> sqlite3.Connection:
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if root.is_symlink():
        raise ProspectingStoreError("store root cannot be a symlink")
    os.chmod(root, 0o700)
    path = database_path(root)
    if path.is_symlink():
        raise ProspectingStoreError("database cannot be a symlink")
    database = sqlite3.connect(str(path), isolation_level=None, timeout=5.0)
    database.row_factory = sqlite3.Row
    database.execute("PRAGMA busy_timeout=5000")
    database.execute("PRAGMA foreign_keys=ON")
    database.execute("PRAGMA journal_mode=WAL")
    database.execute("PRAGMA synchronous=FULL")
    os.chmod(path, 0o600)
    return database


def _schema() -> tuple[str, ...]:
    return (
        """CREATE TABLE projects (
            project_id TEXT PRIMARY KEY, name TEXT NOT NULL,
            profile_version INTEGER NOT NULL CHECK(profile_version > 0),
            discovery_version INTEGER NOT NULL CHECK(discovery_version > 0),
            profile_json TEXT NOT NULL, discovery_json TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
        """CREATE TABLE project_versions (
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
            version_kind TEXT NOT NULL CHECK(version_kind IN ('profile','discovery')),
            version INTEGER NOT NULL CHECK(version > 0), payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL, PRIMARY KEY(project_id,version_kind,version))""",
        """CREATE TABLE evidence_objects (
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
            provider TEXT NOT NULL, object_id TEXT NOT NULL,
            object_type TEXT NOT NULL CHECK(object_type IN ('post','comment')),
            parent_object_id TEXT, evidence_id TEXT NOT NULL, corpus_id TEXT NOT NULL,
            observed_at TEXT NOT NULL, PRIMARY KEY(project_id,provider,object_id))""",
        """CREATE TABLE leads (
            project_id TEXT NOT NULL, lead_id TEXT NOT NULL, provider TEXT NOT NULL,
            object_id TEXT NOT NULL, score REAL NOT NULL CHECK(score BETWEEN 0 AND 100),
            matching_phrase TEXT NOT NULL, explanation TEXT NOT NULL,
            intent TEXT NOT NULL, stage TEXT NOT NULL, suitability TEXT NOT NULL,
            unknowns_json TEXT NOT NULL, rubric_version TEXT NOT NULL,
            model_version TEXT NOT NULL, evidence_version TEXT NOT NULL,
            scored_at TEXT NOT NULL, PRIMARY KEY(project_id,lead_id),
            FOREIGN KEY(project_id,provider,object_id)
                REFERENCES evidence_objects(project_id,provider,object_id) ON DELETE RESTRICT)""",
        """CREATE TABLE dispositions (
            project_id TEXT NOT NULL, lead_id TEXT NOT NULL, disposition TEXT NOT NULL,
            version INTEGER NOT NULL CHECK(version > 0), updated_at TEXT NOT NULL,
            PRIMARY KEY(project_id,lead_id),
            FOREIGN KEY(project_id,lead_id) REFERENCES leads(project_id,lead_id) ON DELETE CASCADE)""",
        """CREATE TABLE disposition_history (
            event_id INTEGER PRIMARY KEY AUTOINCREMENT, project_id TEXT NOT NULL,
            lead_id TEXT NOT NULL, disposition TEXT NOT NULL, version INTEGER NOT NULL,
            changed_at TEXT NOT NULL,
            FOREIGN KEY(project_id,lead_id) REFERENCES leads(project_id,lead_id) ON DELETE CASCADE)""",
        """CREATE TABLE import_receipts (
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
            digest TEXT NOT NULL, imported_at TEXT NOT NULL, object_count INTEGER NOT NULL,
            lead_count INTEGER NOT NULL, PRIMARY KEY(project_id,digest))""",
        """CREATE TABLE jobs (
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
            job_id TEXT NOT NULL, job_kind TEXT NOT NULL, status TEXT NOT NULL,
            input_ref TEXT, output_ref TEXT, started_at TEXT, finished_at TEXT,
            PRIMARY KEY(project_id,job_id))""",
        """CREATE TABLE usage_records (
            project_id TEXT NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
            usage_id TEXT NOT NULL, job_id TEXT, provider TEXT NOT NULL,
            unit TEXT NOT NULL, quantity TEXT NOT NULL, cost_amount TEXT,
            currency TEXT, recorded_at TEXT NOT NULL, PRIMARY KEY(project_id,usage_id),
            FOREIGN KEY(project_id,job_id) REFERENCES jobs(project_id,job_id) ON DELETE SET NULL)""",
        "CREATE INDEX lead_rank ON leads(project_id,score DESC,lead_id)",
        "CREATE INDEX disposition_events ON disposition_history(project_id,lead_id,version)",
    )


def migrate(database: sqlite3.Connection) -> None:
    current = int(database.execute("PRAGMA user_version").fetchone()[0])
    if current not in (0, SCHEMA_VERSION):
        raise ProspectingStoreError(f"unsupported prospecting schema version: {current}")
    if current == SCHEMA_VERSION:
        return
    database.execute("BEGIN IMMEDIATE")
    try:
        for statement in _schema():
            database.execute(statement)
        database.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
        database.execute("COMMIT")
    except Exception:
        database.execute("ROLLBACK")
        raise


@contextmanager
def transaction(database: sqlite3.Connection) -> Iterator[None]:
    database.execute("BEGIN IMMEDIATE")
    try:
        yield
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def _project(database: sqlite3.Connection, project_id: str) -> sqlite3.Row:
    row = database.execute("SELECT * FROM projects WHERE project_id=?", (project_id,)).fetchone()
    if row is None:
        raise ProspectingStoreError("project does not exist")
    return row


def initialize_project(database: sqlite3.Connection, document: ImportDocument) -> None:
    project = document.project
    now = _now()
    with transaction(database):
        existing = database.execute(
            "SELECT name,profile_version,discovery_version,profile_json,discovery_json "
            "FROM projects WHERE project_id=?", (project.project_id,)
        ).fetchone()
        profile_json = _json(project.profile)
        discovery_json = _json(project.discovery)
        if existing is not None:
            identity = (project.name, project.profile_version, project.discovery_version, profile_json, discovery_json)
            stored = (existing["name"], existing["profile_version"], existing["discovery_version"], existing["profile_json"], existing["discovery_json"])
            if identity != stored:
                raise StaleVersionError("project versions conflict with stored project")
            return
        database.execute(
            "INSERT INTO projects VALUES(?,?,?,?,?,?,?,?)",
            (project.project_id, project.name, project.profile_version, project.discovery_version,
             profile_json, discovery_json, now, now),
        )
        for kind, version, payload in (
            ("profile", project.profile_version, profile_json),
            ("discovery", project.discovery_version, discovery_json),
        ):
            database.execute(
                "INSERT INTO project_versions VALUES(?,?,?,?,?)",
                (project.project_id, kind, version, payload, now),
            )


def import_document(database: sqlite3.Connection | None, raw: dict[str, Any], *, dry_run: bool = False) -> dict[str, Any]:
    document = ImportDocument.from_mapping(raw)
    digest = document_digest(raw)
    project_id = document.project.project_id
    if dry_run:
        return {"project_id": project_id, "digest": digest, "objects": len(document.objects), "leads": len(document.leads), "dry_run": True}
    if database is None:
        raise ProspectingStoreError("database is required for a mutating import")
    initialize_project(database, document)
    now = _now()
    with transaction(database):
        receipt = database.execute(
            "SELECT object_count,lead_count FROM import_receipts WHERE project_id=? AND digest=?",
            (project_id, digest),
        ).fetchone()
        if receipt is not None:
            return {"project_id": project_id, "digest": digest, "objects": receipt["object_count"], "leads": receipt["lead_count"], "replayed": True}
        for item in document.objects:
            existing = database.execute(
                "SELECT object_type,parent_object_id,evidence_id,corpus_id,observed_at FROM evidence_objects "
                "WHERE project_id=? AND provider=? AND object_id=?",
                (project_id, item.provider, item.object_id),
            ).fetchone()
            values = (item.object_type, item.parent_object_id, item.evidence_id, item.corpus_id, item.observed_at)
            if existing is not None and tuple(existing) != values:
                raise ProspectingStoreError(f"conflicting evidence object: {item.provider}/{item.object_id}")
            database.execute(
                "INSERT OR IGNORE INTO evidence_objects VALUES(?,?,?,?,?,?,?,?)",
                (project_id, item.provider, item.object_id, *values),
            )
        for lead in document.leads:
            values = (lead.provider, lead.object_id, lead.score, lead.matching_phrase,
                      lead.explanation, lead.intent, lead.stage, lead.suitability,
                      _json(lead.unknowns), lead.rubric_version, lead.model_version,
                      lead.evidence_version)
            existing = database.execute(
                "SELECT provider,object_id,score,matching_phrase,explanation,intent,stage,suitability,"
                "unknowns_json,rubric_version,model_version,evidence_version FROM leads "
                "WHERE project_id=? AND lead_id=?", (project_id, lead.lead_id),
            ).fetchone()
            if existing is not None and tuple(existing) != values:
                raise ProspectingStoreError(f"conflicting lead: {lead.lead_id}")
            database.execute(
                "INSERT OR IGNORE INTO leads VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (project_id, lead.lead_id, *values, now),
            )
            database.execute(
                "INSERT OR IGNORE INTO dispositions VALUES(?,?,?,?,?)",
                (project_id, lead.lead_id, "new", 1, now),
            )
            database.execute(
                "INSERT INTO disposition_history(project_id,lead_id,disposition,version,changed_at) "
                "SELECT ?,?,?,?,? WHERE changes() > 0",
                (project_id, lead.lead_id, "new", 1, now),
            )
        database.execute(
            "INSERT INTO import_receipts VALUES(?,?,?,?,?)",
            (project_id, digest, now, len(document.objects), len(document.leads)),
        )
    return {"project_id": project_id, "digest": digest, "objects": len(document.objects), "leads": len(document.leads), "replayed": False}


def list_leads(database: sqlite3.Connection, project_id: str, *, disposition: str | None = None, limit: int = 100) -> list[dict[str, Any]]:
    _project(database, project_id)
    if not 1 <= limit <= 1000:
        raise ProspectingStoreError("limit must be between 1 and 1000")
    parameters: list[Any] = [project_id]
    predicate = ""
    if disposition is not None:
        if disposition not in DISPOSITIONS:
            raise ProspectingStoreError("unsupported disposition")
        predicate = " AND d.disposition=?"
        parameters.append(disposition)
    parameters.append(limit)
    rows = database.execute(
        "SELECT l.lead_id,l.provider,l.object_id,o.object_type,o.parent_object_id,o.evidence_id,"
        "o.corpus_id,l.score,l.matching_phrase,l.explanation,l.intent,l.stage,l.suitability,"
        "l.unknowns_json,l.rubric_version,l.model_version,l.evidence_version,"
        "d.disposition,d.version AS disposition_version FROM leads l "
        "JOIN evidence_objects o ON o.project_id=l.project_id AND o.provider=l.provider AND o.object_id=l.object_id "
        "JOIN dispositions d ON d.project_id=l.project_id AND d.lead_id=l.lead_id "
        "WHERE l.project_id=?" + predicate + " ORDER BY l.score DESC,l.lead_id LIMIT ?",
        parameters,
    ).fetchall()
    result = []
    for row in rows:
        item = dict(row)
        item["unknowns"] = json.loads(item.pop("unknowns_json"))
        result.append(item)
    return result


def set_disposition(database: sqlite3.Connection, project_id: str, lead_id: str, disposition: str, expected_version: int) -> int:
    if disposition not in DISPOSITIONS:
        raise ProspectingStoreError("unsupported disposition")
    if isinstance(expected_version, bool) or not isinstance(expected_version, int) or expected_version < 1:
        raise ProspectingStoreError("expected version must be a positive integer")
    now = _now()
    with transaction(database):
        cursor = database.execute(
            "UPDATE dispositions SET disposition=?,version=version+1,updated_at=? "
            "WHERE project_id=? AND lead_id=? AND version=?",
            (disposition, now, project_id, lead_id, expected_version),
        )
        if cursor.rowcount != 1:
            raise StaleVersionError("lead is missing or disposition version is stale")
        new_version = expected_version + 1
        database.execute(
            "INSERT INTO disposition_history(project_id,lead_id,disposition,version,changed_at) VALUES(?,?,?,?,?)",
            (project_id, lead_id, disposition, new_version, now),
        )
    return new_version


def rescore(database: sqlite3.Connection, project_id: str, lead_id: str, score: float, rubric_version: str, model_version: str) -> None:
    if not 0 <= score <= 100:
        raise ProspectingStoreError("score must be between 0 and 100")
    with transaction(database):
        cursor = database.execute(
            "UPDATE leads SET score=?,rubric_version=?,model_version=?,scored_at=? WHERE project_id=? AND lead_id=?",
            (score, rubric_version, model_version, _now(), project_id, lead_id),
        )
        if cursor.rowcount != 1:
            raise ProspectingStoreError("lead does not exist")


def update_project_version(database: sqlite3.Connection, project_id: str, kind: str, expected_version: int, payload: dict[str, Any]) -> int:
    if kind not in ("profile", "discovery"):
        raise ProspectingStoreError("version kind must be profile or discovery")
    if isinstance(expected_version, bool) or not isinstance(expected_version, int) or expected_version < 1:
        raise ProspectingStoreError("expected version must be a positive integer")
    validate_project_payload(kind, payload)
    field = f"{kind}_version"
    payload_field = f"{kind}_json"
    payload_json = _json(payload)
    now = _now()
    with transaction(database):
        cursor = database.execute(
            f"UPDATE projects SET {field}={field}+1,{payload_field}=?,updated_at=? WHERE project_id=? AND {field}=?",
            (payload_json, now, project_id, expected_version),
        )
        if cursor.rowcount != 1:
            raise StaleVersionError(f"{kind} version is stale")
        new_version = expected_version + 1
        database.execute(
            "INSERT INTO project_versions VALUES(?,?,?,?,?)",
            (project_id, kind, new_version, payload_json, now),
        )
    return new_version


def export_project(database: sqlite3.Connection, project_id: str) -> dict[str, Any]:
    project = _project(database, project_id)
    return {
        "schema": "aidevops.prospecting-export/v1",
        "project": {
            "project_id": project["project_id"], "name": project["name"],
            "profile_version": project["profile_version"], "discovery_version": project["discovery_version"],
            "profile": json.loads(project["profile_json"]), "discovery": json.loads(project["discovery_json"]),
        },
        "leads": list_leads(database, project_id, limit=1000),
    }


def delete_project(database: sqlite3.Connection, root: Path, project_id: str, expected_name: str) -> Path:
    project = _project(database, project_id)
    if project["name"] != expected_name:
        raise ProspectingStoreError("project name confirmation does not match")
    project_key = hashlib.sha256(project_id.encode()).hexdigest()[:16]
    backup = root / f"prospecting-before-delete-{project_key}.db"
    if backup.exists() or backup.is_symlink():
        raise ProspectingStoreError("delete backup already exists")
    temporary = backup.with_suffix(".tmp")
    for _attempt in range(3):
        if temporary.exists():
            temporary.unlink()
        observed_version = database.execute("PRAGMA data_version").fetchone()[0]
        destination = sqlite3.connect(str(temporary))
        try:
            database.backup(destination)
            if destination.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ProspectingStoreError("delete backup failed integrity check")
        finally:
            destination.close()
        database.execute("BEGIN IMMEDIATE")
        locked_version = database.execute("PRAGMA data_version").fetchone()[0]
        if locked_version != observed_version:
            database.execute("ROLLBACK")
            continue
        os.chmod(temporary, 0o600)
        temporary.replace(backup)
        current = _project(database, project_id)
        if current["name"] != expected_name:
            database.execute("ROLLBACK")
            raise ProspectingStoreError("project name changed before deletion")
        database.execute("DELETE FROM leads WHERE project_id=?", (project_id,))
        database.execute("DELETE FROM evidence_objects WHERE project_id=?", (project_id,))
        database.execute("DELETE FROM projects WHERE project_id=?", (project_id,))
        database.execute("COMMIT")
        return backup
    if temporary.exists():
        temporary.unlink()
    raise ProspectingStoreError("project changed while creating delete backup")
