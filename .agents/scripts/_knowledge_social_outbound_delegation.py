#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Hash-bound delegated authorization and transactional budget reservations."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from typing import Callable
from typing import Any

from _knowledge_social_outbound import _new_id, _verified_operation
from _knowledge_social_store_migration import initialize_public_engagement_migration
from _public_engagement_policy import Grant, PolicyError, digest, parse_grant
from knowledge_social_store import SocialStoreError, validate_opaque


@dataclass(frozen=True)
class AuthorizationRequest:
    """Fresh evidence and scope for one immutable delegated operation."""

    project_id: str
    corpus_id: str
    community: str
    rules_observed_at: int
    source_observed_at: int
    current_time: int


def _grant_row(database: sqlite3.Connection, grant_id: str) -> tuple[sqlite3.Row, Grant]:
    initialize_public_engagement_migration(database)
    row = database.execute(
        "SELECT * FROM public_engagement_grants WHERE grant_id=?", (grant_id,)
    ).fetchone()
    if row is None:
        raise SocialStoreError("delegated grant is unavailable")
    try:
        grant = parse_grant(json.loads(row["policy_json"]))
    except (json.JSONDecodeError, PolicyError) as error:
        raise SocialStoreError("delegated grant is invalid") from error
    if grant.policy_hash != row["policy_hash"] or grant.revision != row["revision"]:
        raise SocialStoreError("delegated grant integrity check failed")
    return row, grant


def _store_owner_grant_uncommitted(
    database: sqlite3.Connection,
    document: dict[str, Any],
    *,
    authenticated_owner_id: str,
    current_time: int,
) -> dict[str, Any]:
    """Create or replace a grant only for the matching authenticated owner."""
    try:
        grant = parse_grant(document)
    except PolicyError as error:
        raise SocialStoreError(str(error)) from error
    owner_id = validate_opaque(authenticated_owner_id, "owner_id")
    if grant.owner_id != owner_id:
        raise SocialStoreError("grant owner does not match the authenticated owner")
    initialize_public_engagement_migration(database)
    existing = database.execute(
        "SELECT revision,owner_id FROM public_engagement_grants WHERE grant_id=?",
        (grant.grant_id,),
    ).fetchone()
    if existing and (existing["owner_id"] != owner_id or grant.revision <= existing["revision"]):
        raise SocialStoreError("grant revision must advance under the same owner")
    database.execute(
        """INSERT INTO public_engagement_grants(
             grant_id,revision,owner_id,project_id,corpus_id,connection_id,account_id,
             policy_hash,policy_json,state,created_at,updated_at,revoked_at)
           VALUES(?,?,?,?,?,?,?,?,?,'active',?,?,NULL)
           ON CONFLICT(grant_id) DO UPDATE SET
             revision=excluded.revision,policy_hash=excluded.policy_hash,
             policy_json=excluded.policy_json,state='active',updated_at=excluded.updated_at,
             revoked_at=NULL""",
        (grant.grant_id, grant.revision, owner_id, grant.project_id, grant.corpus_id,
         grant.connection_id, grant.account_id, grant.policy_hash,
         json.dumps(document, sort_keys=True, separators=(",", ":")), current_time, current_time),
    )
    return {"grant_id": grant.grant_id, "revision": grant.revision, "state": "active", "policy_hash": grant.policy_hash}


def store_owner_grant(
    database: sqlite3.Connection,
    document: dict[str, Any],
    *,
    authenticated_owner_id: str,
    current_time: int,
) -> dict[str, Any]:
    database.execute("BEGIN IMMEDIATE")
    try:
        result = _store_owner_grant_uncommitted(
            database,
            document,
            authenticated_owner_id=authenticated_owner_id,
            current_time=current_time,
        )
        database.execute("COMMIT")
        return result
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def revoke_owner_grant(database: sqlite3.Connection, grant_id: str, owner_id: str, current_time: int) -> dict[str, Any]:
    initialize_public_engagement_migration(database)
    changed = database.execute(
        "UPDATE public_engagement_grants SET state='revoked',revoked_at=?,updated_at=? "
        "WHERE grant_id=? AND owner_id=? AND state='active'",
        (current_time, current_time, validate_opaque(grant_id, "grant_id"), validate_opaque(owner_id, "owner_id")),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("active owner grant is unavailable")
    return {"grant_id": grant_id, "state": "revoked"}


def _authorize_operation_uncommitted(
    database: sqlite3.Connection,
    operation_id: str,
    grant_id: str,
    request: AuthorizationRequest,
) -> dict[str, Any]:
    """Bind one immutable Reddit text intent to one exact grant revision."""
    row = _verified_operation(database, operation_id)
    grant_row, grant = _grant_row(database, grant_id)
    community = validate_opaque(request.community, "community")
    values = (row["provider"], row["action"], row["connection_id"], row["remote_account_id"])
    expected = ("reddit", row["action"], grant.connection_id, grant.account_id)
    if values != expected or row["action"] not in grant.actions or community not in grant.communities:
        raise SocialStoreError("operation is outside delegated grant scope")
    if request.project_id != grant.project_id or request.corpus_id != grant.corpus_id:
        raise SocialStoreError("operation project or corpus is outside delegated grant scope")
    if row["created_by"] != grant.owner_id:
        raise SocialStoreError("operation owner does not match delegated grant owner")
    if row["state"] != "draft" or not grant.enabled or grant_row["state"] != "active":
        raise SocialStoreError("delegated authorization is disabled")
    if not grant.not_before <= request.current_time < grant.expires_at:
        raise SocialStoreError("delegated grant is not currently valid")
    if request.rules_observed_at > request.current_time or request.current_time - request.rules_observed_at > grant.rules_max_age_seconds:
        raise SocialStoreError("community rules evidence is stale")
    source_age = request.current_time - request.source_observed_at
    if source_age < 0 or source_age > grant.rules_max_age_seconds:
        raise SocialStoreError("source evidence is stale")
    if grant.disclosure not in (row["payload"] or ""):
        raise SocialStoreError("required delegated-engagement disclosure is missing")
    target_digest = digest({"target": row["target_remote_id"], "community": community})
    schedule_digest = digest({"scheduled_at": row["scheduled_at"]})
    authorization_id = _new_id("aut")
    database.execute(
        """INSERT INTO public_engagement_authorizations(
             authorization_id,operation_id,grant_id,grant_revision,grant_hash,intent_sha256,
             target_digest,schedule_digest,project_id,corpus_id,community,rules_observed_at,
             source_observed_at,authorized_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (authorization_id, operation_id, grant.grant_id, grant.revision, grant.policy_hash,
         row["intent_sha256"], target_digest, schedule_digest, grant.project_id, grant.corpus_id,
          community, request.rules_observed_at, request.source_observed_at, request.current_time),
    )
    database.execute("UPDATE outbound_operations SET state='approved',updated_at=? WHERE operation_id=? AND state='draft'", (request.current_time, operation_id))
    return {"operation_id": operation_id, "authorization_kind": "delegated_policy", "authorization_id": authorization_id, "grant_id": grant.grant_id, "grant_revision": grant.revision}


def authorize_operation(
    database: sqlite3.Connection,
    operation_id: str,
    grant_id: str,
    **scope: Any,
) -> dict[str, Any]:
    """Atomically bind policy authority and advance the immutable draft."""
    database.execute("BEGIN IMMEDIATE")
    try:
        request = AuthorizationRequest(**scope)
        result = _authorize_operation_uncommitted(
            database, operation_id, grant_id, request
        )
        database.execute("COMMIT")
        return result
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def delegated_authorization(database: sqlite3.Connection, operation_id: str, current_time: int) -> tuple[sqlite3.Row, Grant] | None:
    initialize_public_engagement_migration(database)
    operation = _verified_operation(database, operation_id)
    exact_approval = database.execute(
        """SELECT 1 FROM outbound_approvals
             WHERE operation_id=? AND principal_id=? AND intent_sha256=?
               AND revoked_at IS NULL AND expires_at>?
             LIMIT 1""",
        (operation_id, operation["created_by"], operation["intent_sha256"], current_time),
    ).fetchone()
    if exact_approval is not None:
        return None
    auth = database.execute(
        "SELECT * FROM public_engagement_authorizations WHERE operation_id=? ORDER BY authorized_at DESC LIMIT 1",
        (operation_id,),
    ).fetchone()
    if auth is None:
        return None
    grant_row, grant = _grant_row(database, str(auth["grant_id"]))
    suppressed = database.execute(
        "SELECT 1 FROM public_engagement_suppressions WHERE active=1 AND (account_id=? OR community=? OR thread_id=?) LIMIT 1",
        (grant.account_id, auth["community"], operation["target_remote_id"] or ""),
    ).fetchone()
    valid = all((
        grant_row["state"] == "active",
        grant.enabled,
        grant.revision == auth["grant_revision"],
        grant.policy_hash == auth["grant_hash"],
        operation["intent_sha256"] == auth["intent_sha256"],
        grant.not_before <= current_time < grant.expires_at,
        current_time - auth["rules_observed_at"] <= grant.rules_max_age_seconds,
        current_time - auth["source_observed_at"] <= grant.rules_max_age_seconds,
        suppressed is None,
    ))
    if not valid:
        raise SocialStoreError("delegated authorization is stale, revoked, expired, or suppressed")
    return auth, grant


def reserve_delegated_capacity(database: sqlite3.Connection, operation_id: str, attempt_id: str, current_time: int) -> None:
    delegated = delegated_authorization(database, operation_id, current_time)
    if delegated is None:
        return
    auth, grant = delegated
    operation = _verified_operation(database, operation_id)
    window_start = current_time - grant.window_seconds
    account_count = database.execute(
        "SELECT count(*) FROM public_engagement_reservations WHERE account_id=? AND reserved_at>=? AND state IN ('reserved','started','unknown','sent')",
        (grant.account_id, window_start),
    ).fetchone()[0]
    community_count = database.execute(
        "SELECT count(*) FROM public_engagement_reservations WHERE account_id=? AND community=? AND reserved_at>=? AND state IN ('reserved','started','unknown','sent')",
        (grant.account_id, auth["community"], window_start),
    ).fetchone()[0]
    thread_id = operation["target_remote_id"] or ""
    thread_rows = database.execute(
        "SELECT reserved_at FROM public_engagement_reservations WHERE account_id=? AND thread_id=? AND state IN ('reserved','started','unknown','sent') ORDER BY reserved_at DESC",
        (grant.account_id, thread_id),
    ).fetchall() if thread_id else []
    if account_count >= grant.account_cap or community_count >= grant.community_cap:
        raise SocialStoreError("delegated engagement cap is exhausted")
    if thread_rows and (len(thread_rows) >= grant.thread_turn_cap or current_time - thread_rows[0]["reserved_at"] < grant.thread_cooldown_seconds):
        raise SocialStoreError("delegated thread turn or cooldown limit is exhausted")
    database.execute(
        "INSERT INTO public_engagement_reservations(reservation_id,operation_id,attempt_id,grant_id,account_id,community,thread_id,reserved_at,state) VALUES(?,?,?,?,?,?,?,?,?)",
        (_new_id("res"), operation_id, attempt_id, grant.grant_id, grant.account_id, auth["community"], thread_id or None, current_time, "reserved"),
    )


def mark_delegated_started(database: sqlite3.Connection, operation_id: str, attempt_id: str, current_time: int) -> None:
    if delegated_authorization(database, operation_id, current_time) is None:
        return
    changed = database.execute("UPDATE public_engagement_reservations SET state='started' WHERE operation_id=? AND attempt_id=? AND state='reserved'", (operation_id, attempt_id)).rowcount
    if changed != 1:
        raise SocialStoreError("delegated reservation is unavailable")


def mark_delegated_started_if_authorized(
    database: sqlite3.Connection,
    delegated: tuple[sqlite3.Row, Grant] | None,
    operation_id: str,
    attempt_id: str,
    current_time: int,
) -> None:
    """Mark a reservation only when provider start uses delegated authority."""
    if delegated is not None:
        mark_delegated_started(database, operation_id, attempt_id, current_time)


def run_immediate_transaction(
    database: sqlite3.Connection, operation: Callable[[], None]
) -> None:
    """Run a provider-boundary mutation in one immediate transaction."""
    database.execute("BEGIN IMMEDIATE")
    try:
        operation()
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def finish_delegated_reservation(database: sqlite3.Connection, operation_id: str, attempt_id: str, state: str, provider_started: bool) -> None:
    final = "sent" if state == "succeeded" else "unknown" if provider_started or state == "unknown" else "released"
    database.execute("UPDATE public_engagement_reservations SET state=? WHERE operation_id=? AND attempt_id=? AND state IN ('reserved','started')", (final, operation_id, attempt_id))
