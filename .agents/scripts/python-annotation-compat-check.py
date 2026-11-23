#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reject annotation and typing constructs that break Python 3.9 at runtime.

Python 3.9 (macOS ``/usr/bin/python3``) is the framework floor. Two checks:

1. ``X | None`` in a function signature, or at module or class level, raises
   ``TypeError`` at import time unless the module has
   ``from __future__ import annotations`` (GH#34098). Local variable
   annotations in function bodies are never evaluated, so they are ignored.
2. Importing a ``typing`` name added after 3.9 (``TypeGuard``, ``ParamSpec``,
   ...) raises ``ImportError`` (GH#38706). Imports under
   ``if TYPE_CHECKING:`` or in a ``try`` that handles ``ImportError`` are safe.

Static AST analysis: runs on any Python 3.9+ and never imports targets.

Usage: python-annotation-compat-check.py FILE.py [FILE.py ...]
Exit: 0 clean, 1 violations found.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

FIX_HINT = "add 'from __future__ import annotations' after the module docstring"
TYPING_FIX_HINT = ("import it under 'if TYPE_CHECKING:' (annotations must be "
                   "postponed) or fall back on ImportError")

# Public typing names absent from Python 3.9's typing module.
PY310_TYPING_NAMES = frozenset({
    "Concatenate", "LiteralString", "Never", "NoDefault", "NotRequired",
    "ParamSpec", "ParamSpecArgs", "ParamSpecKwargs", "ReadOnly", "Required",
    "Self", "TypeAlias", "TypeAliasType", "TypeGuard", "TypeIs", "TypeVarTuple",
    "Unpack", "assert_never", "assert_type", "clear_overloads",
    "dataclass_transform", "evaluate_forward_ref", "get_overloads",
    "get_protocol_members", "is_protocol", "is_typeddict", "override",
    "reveal_type",
})
_IMPORT_ERRORS = frozenset({"ImportError", "ModuleNotFoundError", "Exception",
                            "BaseException"})


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


def _is_guard(test: ast.expr) -> bool:
    """True for `TYPE_CHECKING`, `typing.TYPE_CHECKING` or `sys.version_info >= ...`."""
    if isinstance(test, ast.Name):
        return test.id == "TYPE_CHECKING"
    if isinstance(test, ast.Attribute):
        return test.attr == "TYPE_CHECKING"
    if isinstance(test, ast.Compare) and len(test.ops) == 1:
        left = test.left
        return (isinstance(left, ast.Attribute) and left.attr == "version_info"
                and isinstance(test.ops[0], (ast.Gt, ast.GtE)))
    return False


def _handles_import_error(node: ast.Try) -> bool:
    """True when a handler is bare or names an ImportError-compatible type."""
    for handler in node.handlers:
        if handler.type is None:
            return True
        types = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
        if any(isinstance(item, ast.Name) and item.id in _IMPORT_ERRORS for item in types):
            return True
    return False


class _RuntimeTypingImportFinder(ast.NodeVisitor):
    """Collect `from typing import <3.10+ name>` statements executed at runtime."""

    def __init__(self) -> None:
        self.findings: list[tuple[int, str]] = []

    def _visit_all(self, statements: list[ast.stmt]) -> None:
        for statement in statements:
            self.visit(statement)

    def visit_If(self, node: ast.If) -> None:
        if not _is_guard(node.test):
            self._visit_all(node.body)
        self._visit_all(node.orelse)

    def visit_Try(self, node: ast.Try) -> None:
        if not _handles_import_error(node):
            self._visit_all(node.body)
        for handler in node.handlers:
            self._visit_all(handler.body)
        self._visit_all(node.orelse)
        self._visit_all(node.finalbody)

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        if node.module == "typing" and node.level == 0:
            self.findings.extend((node.lineno, alias.name) for alias in node.names
                                 if alias.name in PY310_TYPING_NAMES)


def check_file(path: Path) -> list[str]:
    """Return violation messages for one file; unparsable files are skipped."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except (OSError, SyntaxError, UnicodeDecodeError, ValueError) as exc:
        print(f"{path}: skipped ({type(exc).__name__})", file=sys.stderr)
        return []
    messages: list[str] = []
    if not _has_postponed_annotations(tree):
        finder = _RuntimeAnnotationFinder()
        finder.visit(tree)
        messages.extend(
            f"{path}:{line}: PEP 604 union annotation fails on Python 3.9; {FIX_HINT}"
            for line in sorted(set(finder.lines)))
    typing_finder = _RuntimeTypingImportFinder()
    typing_finder.visit(tree)
    messages.extend(
        f"{path}:{line}: typing.{name} does not exist on Python 3.9; {TYPING_FIX_HINT}"
        for line, name in sorted(set(typing_finder.findings)))
    return messages


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
