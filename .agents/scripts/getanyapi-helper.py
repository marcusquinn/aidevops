#!/usr/bin/env python3
"""Safe AnyAPI REST client with cost gates and capability-graduation evidence."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import uuid
from decimal import Decimal
from typing import Any, NamedTuple

from getanyapi_client import RequestOptions, api_request, query_string, read_input
from getanyapi_evidence import (
    AnyAPIError,
    append_evidence,
    build_study,
    decimal_value,
    read_evidence,
    safe_native_path,
)

NATIVE_STATUSES = ("direct", "partial", "missing", "unknown")


def require_api_key() -> str:
    key = os.environ.get("ANYAPI_API_KEY", "").strip()
    if not key:
        raise AnyAPIError(
            "ANYAPI_API_KEY is unavailable. Store it with "
            "`aidevops secret set ANYAPI_API_KEY`, then run this command through "
            "`aidevops secret ANYAPI_API_KEY -- ...`."
        )
    return key


def emit_json(value: Any) -> None:
    json.dump(value, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def price_ceiling(detail: dict[str, Any]) -> Decimal:
    pricing = detail.get("pricing")
    if not isinstance(pricing, dict) or "failoverMaxUsd" not in pricing:
        raise AnyAPIError("Selected SKU did not publish a failover price ceiling")
    return decimal_value(pricing["failoverMaxUsd"], "failoverMaxUsd")


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
    _, body, _ = api_request(
        "GET",
        f"/v1/apis/{urllib.parse.quote(sku, safe='.')}",
        RequestOptions(key=key),
    )
    if not isinstance(body, dict):
        raise AnyAPIError("AnyAPI detail response was not an object")
    return body


def command_get(args: argparse.Namespace) -> None:
    emit_json(get_detail(args.sku, require_api_key()))


def command_balance(_: argparse.Namespace) -> None:
    _, body, _ = api_request(
        "GET", "/v1/balance", RequestOptions(key=require_api_key())
    )
    emit_json(body)


def wallet_balance(key: str) -> Decimal:
    _, body, _ = api_request("GET", "/v1/balance", RequestOptions(key=key))
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


class UsageContext(NamedTuple):
    """Stable metadata shared by request evidence events."""

    sku: str
    category: str
    ceiling: Decimal
    native_status: str
    native_path: str


def response_event(
    status: int,
    body: Any,
    headers: dict[str, str],
    context: UsageContext,
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
        "sku": context.sku,
        "category": context.category,
        "outcome": "pending" if pending else "success",
        "request_id": request_id,
        "http_status": status,
        "quoted_max_usd": str(context.ceiling),
        "observed_cost_usd": str(observed_cost),
        "charged_cost_usd": "0" if replayed else str(observed_cost),
        "items": items,
        "replayed": replayed,
        "native_status": context.native_status,
        "native_path": context.native_path,
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
            RequestOptions(
                key=key,
                payload=payload,
                timeout=args.timeout,
                headers={"Idempotency-Key": str(uuid.uuid4())},
            ),
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
            status,
            body,
            headers,
            UsageContext(
                sku=args.sku,
                category=str(detail.get("category") or ""),
                ceiling=ceiling,
                native_status=args.native_status,
                native_path=native_path,
            ),
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
        RequestOptions(key=key),
    )
    context = prior_request_context(args.request_id)
    request_status = body.get("status") if isinstance(body, dict) else None
    if request_status == "succeeded" and isinstance(body.get("result"), dict):
        result = body["result"]
        event = response_event(
            200,
            result,
            {**headers, "x-anyapi-request-id": args.request_id},
            UsageContext(
                sku=str(body.get("sku") or context["sku"]),
                category=context["category"],
                ceiling=Decimal("0"),
                native_status=context["native_status"],
                native_path=context["native_path"],
            ),
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
