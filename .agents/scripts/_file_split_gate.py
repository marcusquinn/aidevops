# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""File-identity gate and stale-pointer checks for file-split-verify.py."""

import re

from _file_split_git import file_lines, grep_head

PIN_GREP = r'caller_function"?[[:space:]]*=='
SCRIPT_REF_RE = re.compile(r"framework_script\(|caller_script")
SCRIPT_LITERAL_RE = re.compile(r"([A-Za-z0-9_.+-]+\.(?:sh|bash|zsh|jq|py))\b")
SCRIPT_VARIABLE_RE = re.compile(
    r'framework_script\(\s*\$|caller_script"?\s*==\s*"?\$'
)
PIN_WINDOW_BEFORE = 3
PIN_WINDOW_AFTER = 4


def basename_re(name):
    """Match a file basename not embedded in a longer file name."""
    return re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(name) + r"(?![A-Za-z0-9_-])")


def _base(path):
    return path.rsplit("/", 1)[-1]


def pin_is_gate_for(lines, line_no, old_base):
    """Decide whether a caller_function pin at line_no of lines binds old_base."""
    start = max(0, line_no - 1 - PIN_WINDOW_BEFORE)
    window = lines[start:line_no + PIN_WINDOW_AFTER]
    literals, variable = set(), False
    for text in window:
        if text.lstrip().startswith("#") or not SCRIPT_REF_RE.search(text):
            continue
        variable = variable or bool(SCRIPT_VARIABLE_RE.search(text))
        literals.update(SCRIPT_LITERAL_RE.findall(text))
    # No script reference near the pin: fail closed.
    return old_base in literals or variable or not literals


def _code_pins(head):
    """Return caller_function pins outside docs and comments."""
    hits = grep_head(head, ["-E", "-e", PIN_GREP])
    return [
        hit for hit in hits
        if not hit[0].endswith(".md") and not hit[2].lstrip().startswith("#")
    ]


def _pin_regex(name):
    quoted = re.escape(name)
    return re.compile(
        r'caller_function"?\s*==\s*(?:"' + quoted + r'"|\'' + quoted + r"\'|"
        + quoted + r"(?![A-Za-z0-9_.:-]))"
    )


def _gate_checker(head, old_base, cache):
    """Return a (path, line_no) predicate: does the pin there bind old_base."""
    return lambda path, line_no: pin_is_gate_for(
        file_lines(head, path, cache), line_no, old_base
    )


def _pin_sites(pins, name, is_gate):
    """Return (path, line_no, text) pins of `name` where is_gate(path, line_no)."""
    pin_re = _pin_regex(name)
    return [
        (path, line_no, content.strip())
        for path, line_no, content in pins
        if pin_re.search(content) and is_gate(path, line_no)
    ]


def _script_ref_sites(head, sites, old_base, cache):
    """Return script-reference lines naming old_base just after each pin."""
    old_re = basename_re(old_base)
    found = []
    for path, line_no, _content in sites:
        following = file_lines(head, path, cache)[line_no:line_no + PIN_WINDOW_AFTER]
        found.extend(
            (path, line_no + offset, text.strip())
            for offset, text in enumerate(following, 1)
            if SCRIPT_REF_RE.search(text) and old_re.search(text)
        )
    return found


def gate_findings(head, moves):
    """Return {(fn, old, new): [(path, line_no, content)]} for gated moves."""
    if not moves:
        return {}
    pins = _code_pins(head)
    cache, findings = {}, {}
    for move in moves:
        name, old_base = move[0], _base(move[1])
        sites = _pin_sites(pins, name, _gate_checker(head, old_base, cache))
        if sites:
            sites += _script_ref_sites(head, sites, old_base, cache)
            findings[move] = sorted(set(sites))
    return findings


def _pointer_warnings(head, name, old_base, new_path):
    """Return ({(path, line_no): warning}, pointer_files) for `A::fn` pointers."""
    pointer_re = re.compile(
        r"(?<![A-Za-z0-9_.-])" + re.escape(f"{old_base}::{name}") + r"(?![A-Za-z0-9_])"
    )
    warnings, files = {}, set()
    for path, line_no, content in grep_head(head, ["-F", "-e", f"{old_base}::{name}"]):
        if pointer_re.search(content):
            files.add(path)
            warnings[(path, line_no)] = (content.strip(), name, new_path)
    return warnings, files


def _edit_warnings(edit_lines, move, skip):
    """Return warnings for `EDIT:` lines naming old_base beside fn or a pointer file.

    move is (name, old_base, new_path); skip is (pointer_files, seen).
    """
    name, old_base, new_path = move
    pointer_files, seen = skip
    old_re = basename_re(old_base)
    name_re = re.compile(r"\b" + re.escape(name) + r"\b")
    return {
        (path, line_no): (content.strip(), name, new_path)
        for path, line_no, content in edit_lines
        if old_re.search(content)
        and (path, line_no) not in seen
        and (path in pointer_files or name_re.search(content))
    }


def stale_pointers(head, moves):
    """Return sorted (path, line_no, content, fn, new_path) WARN entries."""
    warnings = {}
    edit_lines = grep_head(head, ["-F", "-e", "EDIT:"]) if moves else []
    for name, old_path, new_path in moves:
        old_base = _base(old_path)
        found, pointer_files = _pointer_warnings(head, name, old_base, new_path)
        warnings.update(found)
        warnings.update(
            _edit_warnings(
                edit_lines, (name, old_base, new_path), (pointer_files, warnings)
            )
        )
    return sorted((path, line_no, *rest) for (path, line_no), rest in warnings.items())
