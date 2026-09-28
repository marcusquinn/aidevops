#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared, install-free project Node selection. Source from validator/worker entry points.
[[ -n "${_PROJECT_NODE_RUNTIME_LOADED:-}" ]] && return 0
_PROJECT_NODE_RUNTIME_LOADED=1

_project_node_requirement() {
	local dir="$1" file="" value=""
	for file in .nvmrc .node-version .tool-versions; do
		[[ -f "$dir/$file" ]] || continue
		if [[ "$file" == .tool-versions ]]; then
			value=$(python3 -c 'import sys; print(next((p[1] for l in open(sys.argv[1]) if (p := l.split()) and p[0] == "nodejs" and len(p) > 1), ""))' "$dir/$file") || return 1
		else
			IFS= read -r value <"$dir/$file" || [[ -n "$value" ]]
		fi
		value="${value%%#*}"
		value="${value#v}"
		value="${value%$'\r'}"
		value="${value//[[:space:]]/}"
		[[ -n "$value" ]] || continue
		printf '%s\n' "$value"
		return 0
	done
	if [[ -f "$dir/package.json" ]]; then
		jq -r '.engines.node // empty' "$dir/package.json" || return 1
	fi
	return 0
}

_project_node_satisfies() {
	local version="$1" requirements="$2"
	python3 -c '
import re, sys
def parts(s):
    s = s.strip().lstrip("v")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", s): raise ValueError(s)
    p = tuple(map(int, s.split(".")))
    return p + (0,) * (3-len(p)), len(p)
def matches(version, expression):
    for alternative in expression.split("||"):
        ok = True
        for token in re.findall(r"(?:>=|<=|>|<|=|\^|~)?\s*v?\d+(?:\.\d+){0,2}", alternative):
            match = re.fullmatch(r"(>=|<=|>|<|=|\^|~)?\s*(v?\d+(?:\.\d+){0,2})", token.strip())
            if not match: raise ValueError(token)
            op, raw = match.groups()
            target, precision = parts(raw)
            if op == "^":
                index = next((i for i, x in enumerate(target) if x), 2)
                upper = list(target); upper[index] += 1; upper[index+1:] = [0] * (2-index)
                good = target <= version < tuple(upper)
            elif op == "~":
                index = 0 if precision == 1 else 1
                upper = list(target); upper[index] += 1; upper[index+1:] = [0] * (2-index)
                good = target <= version < tuple(upper)
            else:
                good = {">=": version >= target, "<=": version <= target,
                        ">": version > target, "<": version < target,
                        "=": version == target, None: version[:precision] == target[:precision]}[op]
            ok = ok and good
        if not re.sub(r"(?:>=|<=|>|<|=|\^|~)?\s*v?\d+(?:\.\d+){0,2}|\s|\*", "", alternative) and ok:
            return True
    return False
try:
    version, _ = parts(sys.argv[1])
    sys.exit(0 if all(matches(version, line) for line in sys.argv[2].splitlines() if line) else 1)
except ValueError:
    sys.exit(1)
' "$version" "$requirements"
	return $?
}

# Prints selected bin path. Caller exports PATH in its own process/subshell.
_project_node_bin() {
	local root="$1" scope="${2:-.}" requirements="" line="" candidate="" version="" bin="" current=""
	local -a candidates=()
	for candidate in "$root" "$root/$scope"; do
		line=$(_project_node_requirement "$candidate") || return 1
		[[ -n "$line" ]] && requirements="${requirements}${requirements:+$'\n'}${line}"
	done
	[[ -n "$requirements" ]] || return 2
	current=$(command -v node 2>/dev/null || true)
	[[ -n "$current" ]] && candidates+=("$current")
	# Include standard manager caches and explicit installation prefixes, not downloads.
	local nullglob_before=""
	shopt -q nullglob && nullglob_before=1
	shopt -s nullglob
	candidates+=("${FNM_DIR:-$HOME/.local/share/fnm}"/node-versions/*/installation/bin/node)
	candidates+=("${NVM_DIR:-$HOME/.nvm}"/versions/node/*/bin/node)
	candidates+=("$HOME"/.volta/tools/image/node/*/bin/node)
	candidates+=("${MISE_DATA_DIR:-$HOME/.local/share/mise}"/installs/node/*/bin/node)
	candidates+=(/opt/homebrew/opt/node@*/bin/node /usr/local/opt/node@*/bin/node)
	candidates+=("${N_PREFIX:-/usr/local}"/n/versions/node/*/bin/node "$HOME"/n/versions/node/*/bin/node)
	[[ -n "$nullglob_before" ]] || shopt -u nullglob
	for candidate in "${candidates[@]}"; do
		[[ -x "$candidate" ]] || continue
		version=$("$candidate" --version 2>/dev/null) || continue
		if _project_node_satisfies "$version" "$requirements"; then
			# Preserve package-manager shims when the active runtime already matches.
			[[ "$candidate" == "$current" ]] && return 0
			bin="${candidate%/*}"
			printf '%s\n' "$bin"
			return 0
		fi
	done
	version=$(node --version 2>/dev/null || printf unknown)
	printf 'ENVIRONMENT FAILURE: node %s does not satisfy engines "%s" (root/scope requirements). Install a matching Node or select it with fnm, nvm, volta, mise, Homebrew node@<major>, or n; then rerun.\n' "$version" "${requirements//$'\n'/ and }" >&2
	return 1
}
