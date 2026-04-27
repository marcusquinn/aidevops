#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
knowledge_index_helpers.py — Corpus tree aggregation and query helpers.

Used by knowledge-index-helper.sh for:
  - Building a meta-tree from per-source tree.json files
  - Querying the corpus tree by natural-language intent (keyword scoring)

CLI usage (called from knowledge-index-helper.sh):
  knowledge_index_helpers.py aggregate <sources_dir> <output_tree_json>
  knowledge_index_helpers.py query <corpus_tree_json> <intent> [max_results]
"""

import json
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


@dataclass
class _WalkContext:
    """Bundled search context for _walk_tree to reduce parameter count."""

    terms: List[str]
    results: List[Dict[str, Any]] = field(default_factory=list)
    max_depth: int = 5


def _score_text(text: str, terms: List[str]) -> int:
    """Count keyword matches in text (case-insensitive)."""
    text_lower = text.lower()
    score = 0
    for term in terms:
        score += text_lower.count(term.lower())
    return score


def _score_node(node: Dict[str, Any], terms: List[str]) -> int:
    """Score a single tree node: title matches weight 3×, summary 1×."""
    title_score = _score_text(node.get('title', ''), terms) * 3
    summary_score = _score_text(node.get('summary', ''), terms)
    return title_score + summary_score


def _walk_tree(
    node: Dict[str, Any],
    source_id: str,
    ctx: _WalkContext,
    depth: int = 0,
) -> None:
    """Recursively walk tree nodes, collecting keyword-scored matches."""
    if depth > ctx.max_depth:
        return
    score = _score_node(node, ctx.terms)
    if score > 0:
        ctx.results.append({
            'source_id': source_id,
            'score': score,
            'anchor': node.get('title', ''),
            'excerpt': node.get('summary', ''),
            'page': node.get('page'),
            'level': node.get('level', depth + 1),
        })
    for child in node.get('children', []):
        _walk_tree(child, source_id, ctx, depth + 1)


def _extract_top_levels(tree_node: Dict[str, Any], max_depth: int = 2) -> Dict[str, Any]:
    """Return tree_node with children truncated at max_depth levels."""
    node = {k: v for k, v in tree_node.items() if k != 'children'}
    if max_depth > 0:
        node['children'] = [
            _extract_top_levels(child, max_depth - 1)
            for child in tree_node.get('children', [])
        ]
    else:
        node['children'] = []
    return node


def _read_source_kind(meta_path: str) -> str:
    """Read kind field from meta.json, defaulting to 'document'."""
    if not os.path.isfile(meta_path):
        return 'document'
    try:
        with open(meta_path, 'r', encoding='utf-8') as f:
            meta = json.load(f)
        return str(meta.get('kind', 'document') or 'document')
    except (json.JSONDecodeError, OSError):
        return 'document'


# ---------------------------------------------------------------------------
# Public: aggregate_corpus_tree
# ---------------------------------------------------------------------------


def aggregate_corpus_tree(sources_dir: str) -> Dict[str, Any]:
    """
    Build a meta-tree from per-source tree.json files.

    Groups sources by kind (from meta.json). Root = 'corpus', children =
    kind-groups, each kind-group's children = individual source trees
    (top 2 levels only — keeps the corpus tree navigable).
    """
    kind_groups: Dict[str, List[Dict[str, Any]]] = {}

    if not os.path.isdir(sources_dir):
        return _empty_corpus_tree()

    source_ids = sorted(
        d for d in os.listdir(sources_dir)
        if os.path.isdir(os.path.join(sources_dir, d))
    )

    for source_id in source_ids:
        source_dir = os.path.join(sources_dir, source_id)
        tree_path = os.path.join(source_dir, 'tree.json')
        meta_path = os.path.join(source_dir, 'meta.json')

        if not os.path.isfile(tree_path):
            continue

        kind = _read_source_kind(meta_path)

        try:
            with open(tree_path, 'r', encoding='utf-8') as f:
                source_tree = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue

        top_tree = _extract_top_levels(source_tree.get('tree', {}), max_depth=2)
        source_node: Dict[str, Any] = {
            'source_id': source_id,
            'title': top_tree.get('title', source_id),
            'summary': top_tree.get('summary', ''),
            'level': 2,
            'children': top_tree.get('children', []),
        }

        if kind not in kind_groups:
            kind_groups[kind] = []
        kind_groups[kind].append(source_node)

    groups = []
    for kind in sorted(kind_groups.keys()):
        groups.append({
            'title': kind.capitalize() + 's',
            'level': 1,
            'summary': f'{len(kind_groups[kind])} source(s)',
            'children': kind_groups[kind],
        })

    total = sum(len(v) for v in kind_groups.values())
    return {
        'title': 'corpus',
        'level': 0,
        'summary': f'{total} source(s) across {len(kind_groups)} kind(s)',
        'children': groups,
    }


def _empty_corpus_tree() -> Dict[str, Any]:
    """Return a minimal empty corpus tree."""
    return {
        'title': 'corpus',
        'level': 0,
        'summary': '0 sources',
        'children': [],
    }


# ---------------------------------------------------------------------------
# Public: query_corpus_tree
# ---------------------------------------------------------------------------


def query_corpus_tree(
    corpus_tree: Dict[str, Any],
    intent: str,
    max_results: int = 10,
) -> List[Dict[str, Any]]:
    """
    Walk the corpus tree and return keyword-scored matches for intent.

    Splits intent into terms (≥3 chars), scores each node in the tree by
    title/summary keyword frequency, returns top max_results matches sorted
    by score descending, then level ascending (shallower matches first).

    Return format: [{source_id, score, anchor, excerpt, page, level}, ...]
    """
    terms = [t.strip() for t in re.split(r'[\s,]+', intent) if len(t.strip()) >= 3]
    if not terms:
        return []

    ctx = _WalkContext(terms=terms)

    for kind_group in corpus_tree.get('children', []):
        for source_node in kind_group.get('children', []):
            source_id = source_node.get('source_id', '')
            _walk_tree(source_node, source_id, ctx)

    ctx.results.sort(key=lambda x: (-x['score'], x.get('level', 0)))
    return ctx.results[:max_results]


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def _cmd_aggregate(sources_dir: str, output_path: str) -> int:
    """Build and write corpus tree JSON."""
    tree = aggregate_corpus_tree(sources_dir)
    result = {
        'version': '1.0',
        'generator': 'aidevops/knowledge-index-helper',
        'tree': tree,
    }
    try:
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
            f.write('\n')
    except OSError as exc:
        print(f'ERROR: cannot write {output_path}: {exc}', file=sys.stderr)
        return 1
    return 0


def _cmd_query(corpus_path: str, intent: str, max_results: int = 10) -> int:
    """Query corpus tree and print JSON matches to stdout."""
    try:
        with open(corpus_path, 'r', encoding='utf-8') as f:
            corpus = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        print(f'ERROR: cannot read {corpus_path}: {exc}', file=sys.stderr)
        return 1

    tree = corpus.get('tree', corpus)
    matches = query_corpus_tree(tree, intent, max_results)
    output = {'matches': matches}
    print(json.dumps(output, indent=2, ensure_ascii=False))
    return 0


def _run_aggregate() -> int:
    """Parse aggregate CLI args, validate, and dispatch."""
    if len(sys.argv) < 4:
        print('aggregate requires: <sources_dir> <output_json>', file=sys.stderr)
        return 1
    return _cmd_aggregate(sys.argv[2], sys.argv[3])


def _run_query() -> int:
    """Parse query CLI args, validate, and dispatch."""
    if len(sys.argv) < 4:
        print('query requires: <corpus_json> <intent>', file=sys.stderr)
        return 1
    max_r = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4].isdigit() else 10
    return _cmd_query(sys.argv[2], sys.argv[3], max_r)


_USAGE = (
    'Usage: knowledge_index_helpers.py aggregate <sources_dir> <output_json>\n'
    '       knowledge_index_helpers.py query <corpus_json> <intent> [max_results]'
)

_COMMAND_HANDLERS: Dict[str, Callable[[], int]] = {
    'aggregate': _run_aggregate,
    'query': _run_query,
}


def main() -> int:
    """CLI dispatcher."""
    if len(sys.argv) < 2:
        print(_USAGE, file=sys.stderr)
        return 1
    command = sys.argv[1]
    handler = _COMMAND_HANDLERS.get(command)
    if handler is None:
        print(f'Unknown command: {command}', file=sys.stderr)
        return 1
    return handler()


if __name__ == '__main__':
    sys.exit(main())
