#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck disable=SC2016
grep -q 'DEPLOYED_CLI="$HOME/.aidevops/agents/aidevops.sh"' "$REPO_DIR/bin/aidevops"
# shellcheck disable=SC2016
grep -q '_install_aidevops_cli_copy "$INSTALL_DIR/aidevops.sh" "$deployed_cli"' \
	"$REPO_DIR/.agents/scripts/setup/modules/config.sh"
grep -q 'git clone --depth 1 --branch main' \
	"$REPO_DIR/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"

mkdir -p "$TEST_HOME/.aidevops/agents" "$TEST_HOME/Git/aidevops"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "deployed:%%s\\n" "$1"\n' >"$TEST_HOME/.aidevops/agents/aidevops.sh"
printf '#!/usr/bin/env bash\nprintf "canonical\\n"\n' >"$TEST_HOME/Git/aidevops/aidevops.sh"
result=$(HOME="$TEST_HOME" bash "$REPO_DIR/bin/aidevops" version-check)
[[ "$result" == "deployed:version-check" ]] || {
	printf 'FAIL: launcher selected %s\n' "$result" >&2
	exit 1
}

printf 'PASS: CLI launcher, orchestrator, and clean update checkout remain coherent\n'
