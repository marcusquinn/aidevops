#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Idempotent column upgrades for the private social corpus schema."""

from __future__ import annotations

import sqlite3


def ensure_public_engagement_tables(connection: sqlite3.Connection) -> None:
    """Create private additive delegated-authority state without exporting it."""
    statements = (
        """CREATE TABLE IF NOT EXISTS public_engagement_grants (
             grant_id TEXT PRIMARY KEY,revision INTEGER NOT NULL,owner_id TEXT NOT NULL,
             project_id TEXT NOT NULL,corpus_id TEXT NOT NULL,connection_id TEXT NOT NULL,
             account_id TEXT NOT NULL,policy_hash TEXT NOT NULL,policy_json TEXT NOT NULL,
             state TEXT NOT NULL CHECK(state IN ('active','paused','revoked')),
             created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,revoked_at INTEGER)""",
        """CREATE TABLE IF NOT EXISTS public_engagement_authorizations (
             authorization_id TEXT PRIMARY KEY,operation_id TEXT NOT NULL UNIQUE REFERENCES outbound_operations(operation_id),
             grant_id TEXT NOT NULL REFERENCES public_engagement_grants(grant_id),grant_revision INTEGER NOT NULL,
             grant_hash TEXT NOT NULL,intent_sha256 TEXT NOT NULL,target_digest TEXT NOT NULL,
             schedule_digest TEXT NOT NULL,project_id TEXT NOT NULL,corpus_id TEXT NOT NULL,
             community TEXT NOT NULL,rules_observed_at INTEGER NOT NULL,source_observed_at INTEGER NOT NULL,
             authorized_at INTEGER NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS public_engagement_reservations (
             reservation_id TEXT PRIMARY KEY,operation_id TEXT NOT NULL UNIQUE REFERENCES outbound_operations(operation_id),
             attempt_id TEXT NOT NULL UNIQUE,grant_id TEXT NOT NULL,account_id TEXT NOT NULL,
             community TEXT NOT NULL,thread_id TEXT,reserved_at INTEGER NOT NULL,
             state TEXT NOT NULL CHECK(state IN ('reserved','started','released','unknown','sent')))""",
        """CREATE TABLE IF NOT EXISTS public_engagement_suppressions (
             suppression_id TEXT PRIMARY KEY,account_id TEXT,community TEXT,thread_id TEXT,
             active INTEGER NOT NULL CHECK(active IN (0,1)),reason TEXT NOT NULL,created_at INTEGER NOT NULL,
             CHECK(account_id IS NOT NULL OR community IS NOT NULL OR thread_id IS NOT NULL))""",
        "CREATE INDEX IF NOT EXISTS idx_public_engagement_budget ON public_engagement_reservations(account_id,community,reserved_at,state)",
    )
    for statement in statements:
        connection.execute(statement)


def add_sync_run_v2_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(sync_runs)").fetchall()
    }
    if "stream" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN stream TEXT NOT NULL DEFAULT ''"
        )
    if "run_kind" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'sync'"
        )
    if "collector_id" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN collector_id TEXT")
    if "started_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN started_at INTEGER")
    if "completed_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN completed_at INTEGER")
    if "request_hash" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN request_hash TEXT")


def add_outbound_v4_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(outbound_operations)").fetchall()
    }
    additions = (
        (
            "destination_remote_id",
            "ALTER TABLE outbound_operations ADD COLUMN destination_remote_id TEXT",
        ),
        ("subject", "ALTER TABLE outbound_operations ADD COLUMN subject TEXT"),
        (
            "subject_sha256",
            "ALTER TABLE outbound_operations ADD COLUMN subject_sha256 TEXT",
        ),
        (
            "intent_version",
            "ALTER TABLE outbound_operations ADD COLUMN "
            "intent_version INTEGER NOT NULL DEFAULT 1",
        ),
    )
    for column, statement in additions:
        if column not in columns:
            connection.execute(statement)


def add_outbound_v7_columns(connection: sqlite3.Connection) -> None:
    """Add private, hash-bound video source selectors without rewriting intents."""
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(outbound_operations)").fetchall()
    }
    additions = (
        ("media_path", "ALTER TABLE outbound_operations ADD COLUMN media_path TEXT"),
        ("media_sha256", "ALTER TABLE outbound_operations ADD COLUMN media_sha256 TEXT"),
    )
    for column, statement in additions:
        if column not in columns:
            connection.execute(statement)


def add_source_v5_columns(connection: sqlite3.Connection) -> None:
    table = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fetch_batches'"
    ).fetchone()
    if table is None:
        return
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(fetch_batches)").fetchall()
    }
    if "evidence_id" not in columns:
        connection.execute(
            "ALTER TABLE fetch_batches ADD COLUMN evidence_id TEXT "
            "REFERENCES evidence_sources(evidence_id)"
        )
