#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Data operations for the context/keywords search-targets standard.

Normally called through `keywords-helper.sh` (`aidevops keywords ...`), which
resolves local config into AIDEVOPS_KEYWORDS_* environment variables.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import keywords_brief as brief  # noqa: E402
import keywords_cluster as cluster  # noqa: E402
import keywords_detect as detect  # noqa: E402
import keywords_hub as hub  # noqa: E402
import keywords_migrate as migrate  # noqa: E402
import keywords_registry as reg  # noqa: E402
import keywords_routine as routine  # noqa: E402
import keywords_store as store  # noqa: E402
import keywords_strategy as strategy  # noqa: E402
import keywords_track as track  # noqa: E402
import keywords_validate as validate  # noqa: E402


def _emit(value: object, as_json: bool = True) -> None:
    print(json.dumps(value, indent=2, sort_keys=True) if as_json else value)


def cmd_detect(args) -> int:
    print(",".join(detect.surfaces(Path(args.root), args.interface == "true", args.platform)))
    return 0


def cmd_init_tables(args) -> int:
    created = []
    for table in reg.TABLES:
        path = reg.table_path(Path(args.root), table)
        if not path.exists():
            reg.save_table(path, table, [])
            created.append(str(path))
    _emit({"created": created})
    return 0


def cmd_validate(args) -> int:
    result = validate.validate(Path(args.root))
    if args.json:
        _emit(result)
    else:
        for line in result["errors"]:
            print(f"ERROR {line}")
        for line in result["warnings"]:
            print(f"WARN  {line}")
        print(f"{'OK' if result['ok'] else 'FAIL'} {json.dumps(result['counts'], sort_keys=True)}")
    return 0 if result["ok"] else 1


def _mutate(args, operation) -> int:
    root = Path(args.root)
    registry = reg.load_registry(root)
    result = operation(registry)
    if getattr(args, "apply", True):
        reg.save_registry(root, registry)
    _emit(result)
    return 0


def cmd_migrate(args) -> int:
    return _mutate(args, lambda registry: migrate.migrate(Path(args.root), registry))


def cmd_add(args) -> int:
    values = reg.parse_assignments(args.fields)
    return _mutate(args, lambda registry: reg.add_row(registry, args.table, values))


def cmd_set(args) -> int:
    values = reg.parse_assignments(args.fields)
    return _mutate(args, lambda registry: reg.set_fields(registry, args.table, args.id, values))


def cmd_list(args) -> int:
    rows = reg.load_registry(Path(args.root))[args.table]
    text_field = reg.TABLES[args.table]["text"]
    for row in rows:
        if not args.status or row.get("status") == args.status:
            print(f"{row['id']}\t{row.get(text_field, '')}\t{row.get('status', '')}\t{row.get('priority', '')}")
    return 0


def cmd_score(args) -> int:
    return _mutate(args, lambda registry: {"changes": brief.score(registry)})


def cmd_brief(args) -> int:
    registry = reg.load_registry(Path(args.root))
    selector = {"target": args.target, "url": args.url, "cluster": args.cluster, "asset": args.asset}
    print(brief.brief(Path(args.root), registry, selector), end="")
    return 0


def cmd_expand(args) -> int:
    root = Path(args.root)
    minimum = strategy.threshold(strategy.load(root), "drilldown_min_priority")

    def operation(registry):
        candidates = cluster.expand(registry, args.head, minimum, args.force)
        stored = [reg.add_row(registry, "targets", row)["id"] for row in candidates] if args.apply else []
        return {"candidates": [row["phrase"] for row in candidates], "stored": stored}

    return _mutate(args, operation)


def cmd_cluster(args) -> int:
    serps = json.loads(Path(args.serps).read_text(encoding="utf-8"))
    if isinstance(serps, list):
        serps = {item["keyword"]: item.get("urls", []) for item in serps}
    groups = cluster.overlap_groups(serps, args.threshold)
    return _mutate(args, lambda registry: {"groups": groups, "applied": cluster.apply_groups(registry, groups)})


def cmd_property(args) -> int:
    prop = hub.property_id(Path(args.root))
    _emit({"property": prop, "store": str(hub.property_dir(prop)), "hub": str(hub.hub_dir() or "")})
    return 0


def cmd_sync(args) -> int:
    _emit(hub.sync(Path(args.root), write_local=not args.no_local_write))
    return 0


def cmd_rollup(args) -> int:
    root = Path(args.root)
    prop = hub.property_id(root)
    return _mutate(args, lambda registry: {"property": prop, "changed": store.rollup(prop, registry)})


def cmd_index(_args) -> int:
    _emit(store.build_index())
    return 0


def cmd_budget(args) -> int:
    root = Path(args.root)
    prop, front = hub.property_id(root), strategy.load(root)
    spent, rows = store.month_spend(prop)
    ok, message = store.check_budget(prop, front, args.estimate)
    _emit({"property": prop, "spent_usd": round(spent, 4), "limit_usd": store.budget_limit(front),
           "entries": len(rows), "check": message})
    return 0 if ok else 3


def _track_export(args, ctx: dict) -> tuple[list[dict], dict]:
    matched, unmatched = track.from_export(ctx["registry"], Path(args.file))
    return matched, {"unmatched_queries": len(unmatched)}


def _track_github(args, ctx: dict) -> tuple[list[dict], dict]:
    slug = args.slug or detect.github_slug(ctx["root"])
    return track.github(ctx["registry"], slug, ctx["surfaces"], args.limit), {}


def _track_npm(args, ctx: dict) -> tuple[list[dict], dict]:
    package = args.package or detect.npm_package(ctx["root"])
    return track.npm(ctx["registry"], package, ctx["surfaces"], args.limit), {}


def _track_dataforseo(args, ctx: dict) -> tuple[list[dict], dict]:
    domain = args.domain or (ctx["domains"] or [""])[0]
    rows, message = track.dataforseo(ctx["registry"], ctx["prop"], ctx["front"], domain, args.estimate)
    return rows, {"budget": message}


def _track_ai(args, ctx: dict) -> tuple[list[dict], dict]:
    registry = ctx["registry"]
    brands = args.brand or [row["name"] for row in registry["entities"] if row.get("role") == "self"]
    captures = json.loads(Path(args.file).read_text(encoding="utf-8"))
    return track.ai_captures(registry, captures, brands, ctx["domains"]), {}


TRACKERS = {"export": _track_export, "github": _track_github, "npm": _track_npm,
            "dataforseo": _track_dataforseo, "ai": _track_ai}


def cmd_track(args) -> int:
    if args.source in ("export", "ai") and not args.file:
        raise ValueError(f"--file is required for --source {args.source}")
    root = Path(args.root)
    front = strategy.load(root)
    prop = hub.property_id(root)
    ctx = {"root": root, "prop": prop, "front": front, "registry": reg.load_registry(root),
           "surfaces": strategy.as_list(front.get("surfaces")), "domains": strategy.as_list(front.get("domains"))}
    hub.pull()
    rows, extra = TRACKERS[args.source](args, ctx)
    shard = store.write_observations(prop, rows, args.source)
    published = hub.publish(f"keywords: track {prop} {args.source}")
    _emit({"property": prop, "observations": len(rows), "shard": str(shard or ""), "published": published, **extra})
    return 0


def cmd_report(args) -> int:
    root = Path(args.root)
    registry = reg.load_registry(root)
    prop = hub.property_id(root)
    store.rollup(prop, registry)
    _emit(store.summary(prop, registry, strategy.load(root)))
    return 0


def cmd_routine(args) -> int:
    _emit(routine.run(args.paid, args.estimate))
    return 0


def cmd_slug(args) -> int:
    print(reg.slugify(" ".join(args.text)))
    return 0


def _root(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", default=".", help="repository root (default: .)")


def _add_parsers(commands) -> None:
    simple = {"init-tables": cmd_init_tables, "property": cmd_property, "rollup": cmd_rollup, "report": cmd_report}
    for name, handler in simple.items():
        sub = commands.add_parser(name)
        _root(sub)
        sub.set_defaults(func=handler, apply=True)
    sub = commands.add_parser("detect")
    _root(sub)
    sub.add_argument("--interface", choices=["true", "false"], default="false")
    sub.add_argument("--platform", default="")
    sub.set_defaults(func=cmd_detect)
    sub = commands.add_parser("validate")
    _root(sub)
    sub.add_argument("--json", action="store_true")
    sub.set_defaults(func=cmd_validate)
    for name, handler in (("migrate", cmd_migrate), ("score", cmd_score)):
        sub = commands.add_parser(name)
        _root(sub)
        sub.add_argument("--apply", action="store_true", help="write changes (default: dry run)")
        sub.set_defaults(func=handler)
    for name, handler in (("add", cmd_add), ("set", cmd_set)):
        sub = commands.add_parser(name)
        _root(sub)
        sub.add_argument("table", choices=list(reg.TABLES))
        if name == "set":
            sub.add_argument("id")
        sub.add_argument("fields", nargs="+", help="field=value")
        sub.set_defaults(func=handler, apply=True)


def _add_query_parsers(commands) -> None:
    sub = commands.add_parser("list")
    _root(sub)
    sub.add_argument("table", choices=list(reg.TABLES))
    sub.add_argument("--status", default="")
    sub.set_defaults(func=cmd_list)
    sub = commands.add_parser("brief")
    _root(sub)
    for flag in ("--target", "--url", "--cluster"):
        sub.add_argument(flag, default="")
    sub.add_argument("--asset", default="", choices=["", *brief.ASSET_GUIDANCE])
    sub.set_defaults(func=cmd_brief)
    sub = commands.add_parser("expand")
    _root(sub)
    sub.add_argument("head")
    sub.add_argument("--apply", action="store_true")
    sub.add_argument("--force", action="store_true", help="ignore the drill-down priority threshold")
    sub.set_defaults(func=cmd_expand)
    sub = commands.add_parser("cluster")
    _root(sub)
    sub.add_argument("--serps", required=True, help='JSON {"keyword": [urls]} or [{"keyword", "urls"}]')
    sub.add_argument("--threshold", type=int, default=3)
    sub.add_argument("--apply", action="store_true")
    sub.set_defaults(func=cmd_cluster)
    sub = commands.add_parser("slug")
    sub.add_argument("text", nargs="+")
    sub.set_defaults(func=cmd_slug)


def _add_data_parsers(commands) -> None:
    sub = commands.add_parser("sync")
    _root(sub)
    sub.add_argument("--no-local-write", action="store_true")
    sub.set_defaults(func=cmd_sync)
    sub = commands.add_parser("index")
    sub.set_defaults(func=cmd_index)
    sub = commands.add_parser("budget")
    _root(sub)
    sub.add_argument("--estimate", type=float, default=0.0)
    sub.set_defaults(func=cmd_budget)
    sub = commands.add_parser("track")
    _root(sub)
    sub.add_argument("--source", required=True, choices=["export", "github", "npm", "dataforseo", "ai"])
    sub.add_argument("--file", default="")
    sub.add_argument("--domain", default="")
    sub.add_argument("--slug", default="")
    sub.add_argument("--package", default="")
    sub.add_argument("--brand", action="append", default=[])
    sub.add_argument("--limit", type=int, default=20)
    sub.add_argument("--estimate", type=float, default=0.05)
    sub.set_defaults(func=cmd_track)
    sub = commands.add_parser("routine")
    sub.add_argument("--paid", action="store_true")
    sub.add_argument("--estimate", type=float, default=0.05)
    sub.set_defaults(func=cmd_routine)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    _add_parsers(commands)
    _add_query_parsers(commands)
    _add_data_parsers(commands)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.func(args)
    except (KeyError, ValueError, RuntimeError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
