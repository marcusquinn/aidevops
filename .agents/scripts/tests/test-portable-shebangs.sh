#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Fail when a tracked file starts with an absolute bash/zsh/python/node
# interpreter (e.g. #!/bin/bash). Use #!/usr/bin/env <tool> so PATH decides,
# which works on macOS, FHS Linux and systems without /bin/bash.
# POSIX #!/bin/sh stays allowed. Heredoc fixtures are not line 1, so tests may
# still embed such shebangs as data.

set -euo pipefail

repo_root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)

# Root sudo targets keep an absolute interpreter by design: an env lookup
# would follow the caller's PATH under sudo.
allowed_absolute=(
	".agents/scripts/worktree-cwd-inspect.py"
)

is_allowed() {
	local file="$1"
	local allowed=""
	for allowed in "${allowed_absolute[@]}"; do
		[[ "$file" == "$allowed" ]] && return 0
	done
	return 1
}

violations=0
while IFS= read -r -d '' file; do
	[[ -f "${repo_root}/${file}" && ! -L "${repo_root}/${file}" ]] || continue
	first=""
	IFS= read -r first <"${repo_root}/${file}" || true
	[[ "$first" == '#!'* ]] || continue
	case "$first" in
	'#!/usr/bin/env '* | '#!/bin/sh' | '#!/bin/sh '*) continue ;;
	'#!/'*bin/bash* | '#!/'*bin/zsh* | '#!/'*bin/python* | '#!/'*bin/node*) ;;
	*) continue ;;
	esac
	is_allowed "$file" && continue
	printf 'FAIL: %s: %s (use #!/usr/bin/env ...)\n' "$file" "$first" >&2
	violations=$((violations + 1))
done < <(git -C "$repo_root" ls-files -z)

if [[ "$violations" -gt 0 ]]; then
	printf '%s file(s) use an absolute interpreter shebang\n' "$violations" >&2
	exit 1
fi
printf 'PASS: all tracked shebangs resolve interpreters through PATH\n'
exit 0
