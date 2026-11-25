#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Shared, install-free project Node selection. Source from validator/worker entry points.
[[ -n "${_PROJECT_NODE_RUNTIME_LOADED:-}" ]] && return 0
_PROJECT_NODE_RUNTIME_LOADED=1

# Prints "hard <expression>" and "pref <version>" lines. engines.node is hard.
# A numeric version-file pin requires its major and prefers its exact value, so
# patch drift between maintainer machines does not block workers (GH#32897).
# Aliases such as lts/* or node need a network lookup and are ignored.
_project_node_requirement() {
	local dir="$1" file="" value="" engines=""
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
		[[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || continue
		printf 'hard %s\npref %s\n' "${value%%.*}" "$value"
	done
	if [[ -f "$dir/package.json" ]]; then
		engines=$(jq -r '.engines.node // empty' "$dir/package.json") || return 1
		[[ -n "$engines" ]] && printf 'hard %s\n' "$engines"
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

# Callers prepend the selected bin to the whole worker PATH, so a Node found in
# a shared multi-tool directory (Homebrew, /usr/local/bin or Nix profiles) must not
# reorder git, gh, python or jq (GH#39156). Print a private directory that
# links only the Node toolchain from that directory instead.
_project_node_private_bin() {
	local node_path="$1" version="$2" source_dir="${1%/*}" key="" link_dir="" tool=""
	key=$(printf '%s' "$node_path" | cksum | awk '{print $1}') || return 1
	link_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/project-node/${version#v}-${key}/bin"
	mkdir -p "$link_dir" || return 1
	for tool in node npm npx corepack; do
		[[ -e "$source_dir/$tool" ]] || continue
		[[ -L "$link_dir/$tool" && "$(readlink "$link_dir/$tool")" == "$source_dir/$tool" ]] && continue
		ln -sfn "$source_dir/$tool" "$link_dir/$tool" || return 1
	done
	[[ -x "$link_dir/node" ]] || return 1
	printf '%s\n' "$link_dir"
	return 0
}

# Prints selected bin path. Caller exports PATH in its own process/subshell.
_project_node_bin() {
	local root="$1" scope="${2:-.}" requirements="" preferred="" found="" line="" candidate="" version="" bin="" current=""
	local pass="" wanted="" shared_dirs=" "
	local -a candidates=()
	for candidate in "$root" "$root/$scope"; do
		found=$(_project_node_requirement "$candidate") || return 1
		while IFS= read -r line; do
			case "$line" in
			"pref "*) preferred="${preferred}${preferred:+$'\n'}${line#pref }" ;;
			"hard "*) requirements="${requirements}${requirements:+$'\n'}${line#hard }" ;;
			esac
		done <<<"$found"
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
	# Homebrew prefixes: macOS arm64/x86_64 and Linux; overridable for hermetic tests.
	# Versioned and unversioned kegs are node-only directories. <prefix>/bin also
	# covers the nodejs.org installer (/usr/local/bin) but is shared (GH#39156).
	local brew_prefix=""
	for brew_prefix in ${AIDEVOPS_NODE_BREW_PREFIXES:-/opt/homebrew /usr/local ${HOMEBREW_PREFIX:-/home/linuxbrew/.linuxbrew}}; do
		candidates+=("$brew_prefix"/opt/node@*/bin/node "$brew_prefix"/opt/node/bin/node "$brew_prefix"/bin/node)
		shared_dirs="${shared_dirs}${brew_prefix}/bin "
	done
	# Nix user, XDG, per-user and system profiles are shared multi-tool prefixes.
	# Override the profile list for hermetic tests, as with Homebrew prefixes.
	local nix_profile=""
	for nix_profile in ${AIDEVOPS_NODE_NIX_PROFILES:-$HOME/.nix-profile ${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/profile /nix/var/nix/profiles/per-user/${USER:-}/profile /run/current-system/sw}; do
		candidates+=("$nix_profile/bin/node")
		shared_dirs="${shared_dirs}${nix_profile}/bin "
	done
	candidates+=("${N_PREFIX:-/usr/local}"/n/versions/node/*/bin/node "$HOME"/n/versions/node/*/bin/node)
	[[ -n "$nullglob_before" ]] || shopt -u nullglob
	# Pass 1 honours exact version-file pins; pass 2 accepts any hard-compatible runtime.
	for pass in preferred hard; do
		wanted="$requirements"
		if [[ "$pass" == preferred ]]; then
			[[ -n "$preferred" ]] || continue
			wanted="${requirements}"$'\n'"${preferred}"
		fi
		for candidate in "${candidates[@]}"; do
			[[ -x "$candidate" ]] || continue
			version=$("$candidate" --version 2>/dev/null) || continue
			_project_node_satisfies "$version" "$wanted" || continue
			bin="${candidate%/*}"
			# Never return a shared multi-tool bin; skip it if linking fails.
			if [[ "$candidate" != "$current" && "$shared_dirs" == *" ${bin} "* ]]; then
				bin=$(_project_node_private_bin "$candidate" "$version") || continue
			fi
			if [[ "$pass" == hard && -n "$preferred" ]]; then
				printf 'WARNING: project pins node %s; using installed %s, which satisfies "%s". Install the pinned version to match exactly.\n' \
					"${preferred//$'\n'/ and }" "$version" "${requirements//$'\n'/ and }" >&2
			fi
			# Preserve package-manager shims when the active runtime already matches.
			[[ "$candidate" == "$current" ]] && return 0
			printf '%s\n' "$bin"
			return 0
		done
	done
	version=$(node --version 2>/dev/null || printf unknown)
	printf 'ENVIRONMENT FAILURE: node %s does not satisfy engines "%s" (root/scope requirements; a numeric version-file pin requires its major). Install a matching Node or select it with fnm, nvm, volta, mise, Homebrew node or node@<major>, Nix, the nodejs.org installer, or n; then rerun.\n' "$version" "${requirements//$'\n'/ and }" >&2
	return 1
}
