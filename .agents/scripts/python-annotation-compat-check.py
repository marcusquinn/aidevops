#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reject PEP 604 union annotations that Python 3.9 evaluates at runtime.

Python 3.9 (macOS ``/usr/bin/python3``) is the framework floor. ``X | None`` in
a function signature, or at module or class level, raises ``TypeError`` at import
time unless the module has ``from __future__ import annotations`` (GH#34098).
Local variable annotations in function bodies are never evaluated, so they are
ignored. Static AST analysis: runs on any Python 3.9+ and never imports targets.

Usage: python-annotation-compat-check.py FILE.py [FILE.py ...]
Exit: 0 clean, 1 violations found.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

FIX_HINT = "add 'from __future__ import annotations' after the module docstring"


def _has_postponed_annotations(tree: ast.Module) -> bool:
    for node in tree.body:
        if isinstance(node, ast.ImportFrom) and node.module == "__future__":
            if any(alias.name == "annotations" for alias in node.names):
                return True
    return False


def _uses_union_operator(annotation: ast.expr | None) -> bool:
    if annotation is None:
        return False
    return any(isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr)
               for node in ast.walk(annotation))


class _RuntimeAnnotationFinder(ast.NodeVisitor):
    """Collect line numbers of union annotations evaluated at runtime."""

    def __init__(self) -> None:
        self.lines: list[int] = []
        self._function_depth = 0

    def _record(self, annotation: ast.expr | None) -> None:
        if _uses_union_operator(annotation):
            self.lines.append(annotation.lineno)

    def _visit_function(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        # Signature annotations are evaluated when the def statement executes.
        arguments = node.args
        for argument in arguments.posonlyargs + arguments.args + arguments.kwonlyargs:
            self._record(argument.annotation)
        for argument in (arguments.vararg, arguments.kwarg):
            if argument is not None:
                self._record(argument.annotation)
        self._record(node.returns)
        self._function_depth += 1
        for statement in node.body:
            self.visit(statement)
        self._function_depth -= 1

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self._visit_function(node)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        self._visit_function(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        # A class body executes (and evaluates its annotations) even when the
        # class is defined inside a function.
        saved_depth = self._function_depth
        self._function_depth = 0
        for statement in node.body:
            self.visit(statement)
        self._function_depth = saved_depth

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if self._function_depth == 0:
            self._record(node.annotation)


def check_file(path: Path) -> list[str]:
    """Return violation messages for one file; unparsable files are skipped."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, SyntaxError, UnicodeDecodeError, ValueError) as exc:
        print(f"{path}: skipped ({type(exc).__name__})", file=sys.stderr)
        return []
    if _has_postponed_annotations(tree):
        return []
    finder = _RuntimeAnnotationFinder()
    finder.visit(tree)
    return [f"{path}:{line}: PEP 604 union annotation fails on Python 3.9; {FIX_HINT}"
            for line in sorted(set(finder.lines))]


def main(argv: list[str]) -> int:
    violations: list[str] = []
    for name in argv:
        if name.endswith(".py"):
            violations.extend(check_file(Path(name)))
    for message in violations:
        print(message)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
