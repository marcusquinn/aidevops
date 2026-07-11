#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck disable=SC2016
grep -q 'DEPLOYED_CLI="${REAL_HOME:+$REAL_HOME/.aidevops/agents/aidevops.sh}"' "$REPO_DIR/bin/aidevops"
# shellcheck disable=SC2016
grep -q '"$convergence_helper" converge "$cli_source" "$orchestrator_source" "$deployed_cli" "$deployed_version"' \
	"$REPO_DIR/.agents/scripts/setup/modules/config.sh"
grep -q 'git clone --depth 1 --branch main' \
	"$REPO_DIR/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"

mkdir -p "$TEST_HOME/.aidevops/agents/scripts" "$TEST_HOME/Git/aidevops" "$TEST_HOME/bin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "deployed:%%s\\n" "$1"\n' >"$TEST_HOME/.aidevops/agents/aidevops.sh"
printf '#!/usr/bin/env bash\nprintf "canonical\\n"\n' >"$TEST_HOME/Git/aidevops/aidevops.sh"
result=$(HOME="$TEST_HOME" bash "$REPO_DIR/bin/aidevops" version-check)
[[ "$result" == "deployed:version-check" ]] || {
	printf 'FAIL: launcher selected %s\n' "$result" >&2
	exit 1
}

# Exercise the real orchestrator and real module tree in setup's deployed
# layout. A deliberately stale canonical VERSION must not leak into output.
cp "$REPO_DIR/aidevops.sh" "$TEST_HOME/.aidevops/agents/aidevops.sh"
cp -R "$REPO_DIR/.agents/scripts/." "$TEST_HOME/.aidevops/agents/scripts/"
printf '9.8.7\n' >"$TEST_HOME/.aidevops/agents/VERSION"
printf '1.2.3\n' >"$TEST_HOME/Git/aidevops/VERSION"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TEST_HOME/bin/curl"
chmod +x "$TEST_HOME/bin/curl"
result=$(cd "$TEST_HOME" && HOME="$TEST_HOME" PATH="$TEST_HOME/bin:/usr/bin:/bin" bash "$REPO_DIR/bin/aidevops" --version)
[[ "$result" == "aidevops 9.8.7" ]] || {
	printf 'FAIL: real deployed CLI selected %s\n' "$result" >&2
	exit 1
}

MOCK_BIN="$TEST_HOME/mock-bin"
REAL_USER_HOME="$TEST_HOME/real-user"
mkdir -p "$MOCK_BIN" "$REAL_USER_HOME/.aidevops/agents"
printf '#!/usr/bin/env bash\nprintf "0\\n"\n' >"$MOCK_BIN/id"
printf '#!/usr/bin/env bash\nprintf "worker:x:501:20::%s:/bin/bash\\n"\n' "$REAL_USER_HOME" >"$MOCK_BIN/getent"
chmod +x "$MOCK_BIN/id" "$MOCK_BIN/getent"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "sudo-deployed:%%s\\n" "$1"\n' >"$REAL_USER_HOME/.aidevops/agents/aidevops.sh"
result=$(PATH="$MOCK_BIN:$PATH" HOME="/root" SUDO_USER="worker" bash "$REPO_DIR/bin/aidevops" version-check)
[[ "$result" == "sudo-deployed:version-check" ]] || {
	printf 'FAIL: sudo launcher selected %s\n' "$result" >&2
	exit 1
}

grep -q 'After this, step 1 will always match and the deployed copy runs directly.' "$REPO_DIR/bin/aidevops"

printf 'PASS: CLI launcher, orchestrator, and clean update checkout remain coherent\n'
