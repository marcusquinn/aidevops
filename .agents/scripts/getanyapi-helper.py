#!/usr/bin/env python3
"""Safe AnyAPI REST client with cost gates and capability-graduation evidence."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

API_BASE = "https://api.getanyapi.com"
LEDGER_SCHEMA_VERSION = 1
NATIVE_STATUSES = ("direct", "partial", "missing", "unknown")


class AnyAPIError(RuntimeError):
    """Customer-safe AnyAPI request failure."""

    def __init__(self, message: str, status: int = 0, body: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def ledger_path() -> Path:
    root = Path(
        os.environ.get(
            "AIDEVOPS_WORKSPACE_DIR",
            str(Path.home() / ".aidevops" / ".agent-workspace"),
        )
    )
    return root / "observability" / "getanyapi-usage.jsonl"


def require_api_key() -> str:
    key = os.environ.get("ANYAPI_API_KEY", "").strip()
    if not key:
        raise AnyAPIError(
            "ANYAPI_API_KEY is unavailable. Store it with "
            "`aidevops secret set ANYAPI_API_KEY`, then run this command through "
            "`aidevops secret ANYAPI_API_KEY -- ...`."
        )
    return key


def parse_json_bytes(raw: bytes) -> Any:
    if not raw:
        return {}
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AnyAPIError("AnyAPI returned a non-JSON response") from exc


def api_request(
    method: str,
    path: str,
    *,
    key: str | None = None,
    payload: Any = None,
    timeout: int = 120,
    headers: dict[str, str] | None = None,
) -> tuple[int, Any, dict[str, str]]:
    request_headers = {"Accept": "application/json", **(headers or {})}
    if key:
        request_headers["Authorization"] = f"Bearer {key}"
    data = None
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        f"{API_BASE}{path}", data=data, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return (
                response.status,
                parse_json_bytes(response.read()),
                {key.lower(): value for key, value in response.headers.items()},
            )
    except urllib.error.HTTPError as exc:
        body = parse_json_bytes(exc.read())
        raise AnyAPIError(
            f"AnyAPI returned HTTP {exc.code}; response body suppressed",
            exc.code,
            body,
        )
    except urllib.error.URLError as exc:
        raise AnyAPIError(f"AnyAPI request failed: {exc.reason}") from exc


def emit_json(value: Any) -> None:
    json.dump(value, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def append_evidence(event: dict[str, Any]) -> None:
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.parent.chmod(0o700)
    except OSError:
        pass
    bounded = {
        "schema_version": LEDGER_SCHEMA_VERSION,
        "recorded_at": utc_now(),
        "sku": str(event.get("sku") or "")[:160],
        "category": str(event.get("category") or "")[:80],
        "outcome": str(event.get("outcome") or "unknown")[:40],
        "request_id": str(event.get("request_id") or "")[:160],
        "http_status": int(event.get("http_status") or 0),
        "error_code": str(event.get("error_code") or "")[:120],
        "quoted_max_usd": str(event.get("quoted_max_usd") or "0")[:40],
        "observed_cost_usd": str(event.get("observed_cost_usd") or "0")[:40],
        "charged_cost_usd": str(event.get("charged_cost_usd") or "0")[:40],
        "items": int(event.get("items") or 0),
        "replayed": bool(event.get("replayed") or False),
        "native_status": str(event.get("native_status") or "unknown")[:40],
        "native_path": safe_native_path(str(event.get("native_path") or "")),
    }
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, (json.dumps(bounded, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(descriptor)
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def safe_native_path(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    if value.startswith(("/", "~")) or ".." in Path(value).parts:
        raise AnyAPIError("native path must be a repository-relative agent or helper path")
    return value[:240]


def decimal_value(value: Any, field: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise AnyAPIError(f"AnyAPI returned an invalid {field}") from exc
    if result < 0:
        raise AnyAPIError(f"AnyAPI returned a negative {field}")
    return result


def price_ceiling(detail: dict[str, Any]) -> Decimal:
    pricing = detail.get("pricing")
    if not isinstance(pricing, dict) or "failoverMaxUsd" not in pricing:
        raise AnyAPIError("Selected SKU did not publish a failover price ceiling")
    return decimal_value(pricing["failoverMaxUsd"], "failoverMaxUsd")


def read_input(path_value: str) -> Any:
    if path_value == "-":
        raw = sys.stdin.read()
    else:
        path = Path(path_value).expanduser()
        if not path.is_file() or path.is_symlink():
            raise AnyAPIError("input file must be a regular, non-symlink file")
        if os.name == "posix" and path.stat().st_mode & 0o077:
            raise AnyAPIError("input file must be owner-only (chmod 600)")
        raw = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AnyAPIError(f"input is not valid JSON: {exc.msg}") from exc
    if not isinstance(payload, dict):
        raise AnyAPIError("input JSON must be an object")
    return payload


def query_string(values: dict[str, Any]) -> str:
    filtered = {key: value for key, value in values.items() if value not in (None, "")}
    return urllib.parse.urlencode(filtered)


def command_catalog(args: argparse.Namespace) -> None:
    query = query_string({"category": args.category})
    _, body, _ = api_request("GET", f"/catalog{f'?{query}' if query else ''}")
    emit_json(body)


def command_search(args: argparse.Namespace) -> None:
    if not any((args.query, args.category, args.platform)):
        raise AnyAPIError("search requires --query, --category, or --platform")
    query = query_string(
        {
            "q": args.query,
            "category": args.category,
            "platform": args.platform,
            "limit": args.limit,
        }
    )
    _, body, _ = api_request("GET", f"/catalog/search?{query}")
    emit_json(body)


def get_detail(sku: str, key: str) -> dict[str, Any]:
    _, body, _ = api_request("GET", f"/v1/apis/{urllib.parse.quote(sku, safe='.')}", key=key)
    if not isinstance(body, dict):
        raise AnyAPIError("AnyAPI detail response was not an object")
    return body


def command_get(args: argparse.Namespace) -> None:
    emit_json(get_detail(args.sku, require_api_key()))


def command_balance(_: argparse.Namespace) -> None:
    _, body, _ = api_request("GET", "/v1/balance", key=require_api_key())
    emit_json(body)


def wallet_balance(key: str) -> Decimal:
    _, body, _ = api_request("GET", "/v1/balance", key=key)
    if not isinstance(body, dict) or "usd" not in body:
        raise AnyAPIError("AnyAPI balance response did not contain usd")
    return decimal_value(body["usd"], "wallet balance")


def error_code(body: Any) -> str:
    if not isinstance(body, dict):
        return ""
    return str(body.get("code") or "")


def payment_cost(body: Any) -> Decimal:
    if not isinstance(body, dict):
        return Decimal("0")
    payment = body.get("payment")
    if not isinstance(payment, dict) or payment.get("settlementState") != "charged_undelivered":
        return Decimal("0")
    return decimal_value(payment.get("costUsd", 0), "payment costUsd")


def response_event(
    *,
    sku: str,
    category: str,
    status: int,
    body: Any,
    headers: dict[str, str],
    ceiling: Decimal,
    native_status: str,
    native_path: str,
) -> dict[str, Any]:
    request_id = headers.get("x-anyapi-request-id", "")
    if isinstance(body, dict):
        request_id = str(body.get("requestId") or request_id)
    pending = status == 202
    replayed = headers.get("idempotency-replayed", "").lower() == "true"
    if isinstance(body, dict):
        replayed = replayed or bool(body.get("replayed"))
    observed_cost = Decimal("0")
    items = 0
    if isinstance(body, dict) and not pending:
        observed_cost = decimal_value(body.get("costUsd", 0), "costUsd")
        items = int(body.get("items") or 0)
    return {
        "sku": sku,
        "category": category,
        "outcome": "pending" if pending else "success",
        "request_id": request_id,
        "http_status": status,
        "quoted_max_usd": str(ceiling),
        "observed_cost_usd": str(observed_cost),
        "charged_cost_usd": "0" if replayed else str(observed_cost),
        "items": items,
        "replayed": replayed,
        "native_status": native_status,
        "native_path": native_path,
    }


def command_run(args: argparse.Namespace) -> None:
    key = require_api_key()
    native_path = safe_native_path(args.native_path)
    detail = get_detail(args.sku, key)
    ceiling = price_ceiling(detail)
    approved = decimal_value(args.approved_max_usd, "approved maximum")
    if ceiling > approved:
        raise AnyAPIError(
            f"Live failover ceiling ${ceiling} exceeds approved maximum ${approved}; "
            "obtain a new cost decision before running."
        )
    balance = wallet_balance(key)
    if balance < ceiling:
        raise AnyAPIError(
            f"Wallet balance ${balance} is below the live failover ceiling ${ceiling}; "
            "stop rather than attempting an underfunded paid call."
        )
    payload = read_input(args.input_file)
    query = query_string(
        {
            "fields": args.fields,
            "max_items": args.max_items,
            "summary": "true" if args.summary else None,
        }
    )
    run_path = f"/v1/run/{urllib.parse.quote(args.sku, safe='.')}{f'?{query}' if query else ''}"
    try:
        status, body, headers = api_request(
            "POST",
            run_path,
            key=key,
            payload=payload,
            timeout=args.timeout,
            headers={"Idempotency-Key": str(uuid.uuid4())},
        )
    except AnyAPIError as exc:
        charged = payment_cost(exc.body)
        append_evidence(
            {
                "sku": args.sku,
                "category": detail.get("category", ""),
                "outcome": "error",
                "http_status": exc.status,
                "error_code": error_code(exc.body),
                "quoted_max_usd": str(ceiling),
                "observed_cost_usd": str(charged),
                "charged_cost_usd": str(charged),
                "native_status": args.native_status,
                "native_path": native_path,
            }
        )
        raise
    append_evidence(
        response_event(
            sku=args.sku,
            category=str(detail.get("category") or ""),
            status=status,
            body=body,
            headers=headers,
            ceiling=ceiling,
            native_status=args.native_status,
            native_path=native_path,
        )
    )
    emit_json(body)


def prior_request_context(request_id: str) -> dict[str, str]:
    context = {"sku": "", "category": "", "native_status": "unknown", "native_path": ""}
    for event in read_evidence():
        if str(event.get("request_id") or "") == request_id:
            for key in context:
                context[key] = str(event.get(key) or context[key])
    return context


def command_request(args: argparse.Namespace) -> None:
    key = require_api_key()
    status, body, headers = api_request(
        "GET",
        f"/v1/requests/{urllib.parse.quote(args.request_id, safe='_-')}",
        key=key,
    )
    context = prior_request_context(args.request_id)
    request_status = body.get("status") if isinstance(body, dict) else None
    if request_status == "succeeded" and isinstance(body.get("result"), dict):
        result = body["result"]
        event = response_event(
            sku=str(body.get("sku") or context["sku"]),
            category=context["category"],
            status=200,
            body=result,
            headers={**headers, "x-anyapi-request-id": args.request_id},
            ceiling=Decimal("0"),
            native_status=context["native_status"],
            native_path=context["native_path"],
        )
        append_evidence(event)
    elif request_status in {"failed", "expired"}:
        charged = payment_cost(body)
        append_evidence(
            {
                **context,
                "outcome": str(request_status),
                "request_id": args.request_id,
                "http_status": status,
                "error_code": error_code(body),
                "observed_cost_usd": str(charged),
                "charged_cost_usd": str(charged),
            }
        )
    emit_json(body)


def read_evidence() -> list[dict[str, Any]]:
    path = ledger_path()
    if not path.exists():
        return []
    events: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and value.get("schema_version") == LEDGER_SCHEMA_VERSION:
            events.append(value)
    return events


def build_study(events: list[dict[str, Any]], sku_filter: str = "") -> dict[str, Any]:
    filtered = [event for event in events if not sku_filter or event.get("sku") == sku_filter]
    latest_by_request: dict[str, dict[str, Any]] = {}
    unkeyed: list[dict[str, Any]] = []
    for event in filtered:
        request_id = str(event.get("request_id") or "")
        if request_id:
            latest_by_request[request_id] = event
        else:
            unkeyed.append(event)
    terminal = list(latest_by_request.values()) + unkeyed
    grouped: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "successful_uses": 0,
            "charged_usd": Decimal("0"),
            "items": 0,
            "attempts": 0,
            "native_statuses": set(),
            "native_paths": set(),
        }
    )
    for event in terminal:
        sku = str(event.get("sku") or "unknown")
        row = grouped[sku]
        row["attempts"] += 1
        row["native_statuses"].add(str(event.get("native_status") or "unknown"))
        if event.get("native_path"):
            row["native_paths"].add(str(event["native_path"]))
        row["charged_usd"] += decimal_value(
            event.get("charged_cost_usd", 0), "ledger cost"
        )
        if event.get("outcome") == "success":
            row["successful_uses"] += 1
            row["items"] += int(event.get("items") or 0)
    candidates = []
    for sku, row in grouped.items():
        candidates.append(
            {
                "sku": sku,
                "attempts": row["attempts"],
                "successful_uses": row["successful_uses"],
                "charged_usd": str(row["charged_usd"]),
                "items": row["items"],
                "native_statuses": sorted(row["native_statuses"]),
                "native_paths": sorted(row["native_paths"]),
                "next_decision": "assess native aidevops graduation with volume, terms, quality, and maintenance evidence",
            }
        )
    candidates.sort(
        key=lambda row: (Decimal(row["charged_usd"]), row["successful_uses"], row["items"]),
        reverse=True,
    )
    total_charged = sum((Decimal(row["charged_usd"]) for row in candidates), Decimal("0"))
    return {
        "evidence_events": len(filtered),
        "terminal_uses": len(terminal),
        "successful_uses": sum(row["successful_uses"] for row in candidates),
        "charged_usd": str(total_charged),
        "candidates": candidates,
        "interpretation": "ranked evidence only; no automatic build threshold",
    }


def command_study(args: argparse.Namespace) -> None:
    emit_json(build_study(read_evidence(), args.sku or ""))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    catalog = subparsers.add_parser("catalog", help="Browse the free API catalog")
    catalog.add_argument("--category")
    catalog.set_defaults(func=command_catalog)

    search = subparsers.add_parser("search", help="Search the free API catalog")
    search.add_argument("--query")
    search.add_argument("--category")
    search.add_argument("--platform")
    search.add_argument("--limit", type=int)
    search.set_defaults(func=command_search)

    get = subparsers.add_parser("get", help="Fetch one SKU's schema and pricing")
    get.add_argument("--sku", required=True)
    get.set_defaults(func=command_get)

    balance = subparsers.add_parser("balance", help="Read wallet balance")
    balance.set_defaults(func=command_balance)

    run = subparsers.add_parser("run", help="Execute a cost-gated paid API call")
    run.add_argument("--sku", required=True)
    run.add_argument("--input-file", required=True, help="JSON object file, or - for stdin")
    run.add_argument("--approved-max-usd", required=True)
    run.add_argument("--native-status", required=True, choices=NATIVE_STATUSES)
    run.add_argument("--native-path", default="")
    run.add_argument("--fields")
    run.add_argument("--max-items", type=int)
    run.add_argument("--summary", action="store_true")
    run.add_argument("--timeout", type=int, default=120)
    run.set_defaults(func=command_run)

    request = subparsers.add_parser("request", help="Resume a durable request")
    request.add_argument("--request-id", required=True)
    request.set_defaults(func=command_request)

    study = subparsers.add_parser("study", help="Summarize native-capability graduation evidence")
    study.add_argument("--sku")
    study.set_defaults(func=command_study)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if getattr(args, "limit", None) is not None and args.limit < 1:
        parser.error("--limit must be at least 1")
    if getattr(args, "max_items", None) is not None and args.max_items < 1:
        parser.error("--max-items must be at least 1")
    if getattr(args, "timeout", 1) < 1:
        parser.error("--timeout must be at least 1")
    try:
        args.func(args)
    except AnyAPIError as exc:
        print(f"getanyapi: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
