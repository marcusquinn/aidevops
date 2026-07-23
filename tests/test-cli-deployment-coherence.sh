#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# shellcheck disable=SC2016
grep -q 'DEPLOYED_CLI="$REAL_HOME/.aidevops/agents/aidevops.sh"' "$REPO_DIR/bin/aidevops"
# shellcheck disable=SC2016
grep -q '"$convergence_helper" converge "$cli_source" "$orchestrator_source" "$deployed_cli" "$deployed_version"' \
	"$REPO_DIR/.agents/scripts/setup/modules/config.sh"
# shellcheck disable=SC2016
grep -q 'git clone --depth 1 "${REPO_URL:-https://github.com/marcusquinn/aidevops.git}"' \
	"$REPO_DIR/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"

mkdir -p "$TEST_HOME/.aidevops/agents/scripts" \
	"$TEST_HOME/Git/aidevops/.agents/scripts/aidevops-cli" "$TEST_HOME/bin"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "deployed:%%s\\n" "$1"\n' >"$TEST_HOME/.aidevops/agents/aidevops.sh"
printf '#!/usr/bin/env bash\nprintf "canonical\\n"\n' >"$TEST_HOME/Git/aidevops/aidevops.sh"
result=$(HOME="$TEST_HOME" bash "$REPO_DIR/bin/aidevops" version-check)
[[ "$result" == "deployed:version-check" ]] || {
	printf 'FAIL: launcher selected %s\n' "$result" >&2
	exit 1
}
result=$(HOME="$TEST_HOME" AIDEVOPS_PREFER_LOCAL=1 bash "$REPO_DIR/bin/aidevops" version-check)
[[ "$result" == "canonical" ]] || {
	printf 'FAIL: local-development override selected %s\n' "$result" >&2
	exit 1
}

# Exercise the real orchestrator and real module tree in setup's deployed
# layout. A deliberately stale canonical VERSION must not leak into output.
cp "$REPO_DIR/aidevops.sh" "$TEST_HOME/.aidevops/agents/aidevops.sh"
cp -R "$REPO_DIR/.agents/scripts/." "$TEST_HOME/.aidevops/agents/scripts/"
printf '9.8.7\n' >"$TEST_HOME/.aidevops/agents/VERSION"
printf '1.2.3\n' >"$TEST_HOME/Git/aidevops/VERSION"
cat >"$TEST_HOME/Git/aidevops/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL: stale canonical CLI module was sourced\n' >&2
exit 42
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TEST_HOME/bin/curl"
chmod +x "$TEST_HOME/bin/curl"
result=$(cd "$TEST_HOME" && HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH" bash "$REPO_DIR/bin/aidevops" --version)
[[ "$result" == "aidevops 9.8.7" ]] || {
	printf 'FAIL: real deployed CLI selected %s\n' "$result" >&2
	exit 1
}
[[ "$(tr -d '\n' <"$TEST_HOME/Git/aidevops/VERSION")" == "1.2.3" ]] || {
	printf 'FAIL: canonical VERSION was mutated during deployed CLI execution\n' >&2
	exit 1
}

# Exercise the Homebrew package layout without relying on post_install to clone
# a canonical checkout. The formula places the launcher in libexec and exports
# a separate share/aidevops tree containing .agents and VERSION.
BREW_HOME="$TEST_HOME/brew-home"
BREW_LIBEXEC="$TEST_HOME/brew/libexec"
BREW_SHARE="$TEST_HOME/brew/share/aidevops"
mkdir -p "$BREW_HOME" "$BREW_LIBEXEC" "$BREW_SHARE"
cp "$REPO_DIR/aidevops.sh" "$BREW_LIBEXEC/aidevops.sh"
cp -R "$REPO_DIR/.agents" "$BREW_SHARE/.agents"
cp "$REPO_DIR/VERSION" "$BREW_SHARE/VERSION"
result=$(HOME="$BREW_HOME" AIDEVOPS_SHARE="$BREW_SHARE" bash "$BREW_LIBEXEC/aidevops.sh" --version)
[[ "$result" == "aidevops $(tr -d '\n' <"$REPO_DIR/VERSION")" ]] || {
	printf 'FAIL: Homebrew package root selected %s\n' "$result" >&2
	exit 1
}

# An incomplete package root must not become a source location merely because
# it carries one expected module. This keeps the package trust boundary fail
# closed before any partial snapshot can execute.
INVALID_SHARE="$TEST_HOME/brew/invalid-share"
mkdir -p "$INVALID_SHARE/.agents/scripts/aidevops-cli"
cat >"$INVALID_SHARE/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh" <<'EOF'
#!/usr/bin/env bash
printf 'FAIL: incomplete Homebrew package root was sourced\n' >&2
exit 42
EOF
invalid_share_output=""
invalid_share_rc=0
invalid_share_output=$(HOME="$BREW_HOME" AIDEVOPS_SHARE="$INVALID_SHARE" \
	bash "$BREW_LIBEXEC/aidevops.sh" --version 2>&1) || invalid_share_rc=$?
if [[ "$invalid_share_rc" -eq 0 || "$invalid_share_output" == *"incomplete Homebrew package root was sourced"* ]]; then
	printf 'FAIL: incomplete Homebrew package root was accepted: %s\n' "$invalid_share_output" >&2
	exit 1
fi

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

# A failed passwd lookup must preserve the HOME fallback under pipefail.
printf '#!/usr/bin/env bash\nexit 2\n' >"$MOCK_BIN/getent"
printf '#!/usr/bin/env bash\nexit 1\n' >"$MOCK_BIN/curl"
chmod +x "$MOCK_BIN/curl"
result=$(PATH="$MOCK_BIN:$PATH" HOME="$TEST_HOME" SUDO_USER="missing-worker" bash "$REPO_DIR/bin/aidevops" --version)
[[ "$result" == "aidevops 9.8.7" ]] || {
	printf 'FAIL: failed passwd lookup did not preserve HOME fallback: %s\n' "$result" >&2
	exit 1
}

# The launcher must remain nounset-safe when an environment omits HOME.
# shellcheck disable=SC2016
grep -q 'REAL_HOME="${HOME:-}"' "$REPO_DIR/bin/aidevops"
if unset_home_output=$(env -u HOME -u SUDO_USER bash "$REPO_DIR/bin/aidevops" --version 2>&1); then
	printf 'FAIL: launcher accepted an empty HOME\n' >&2
	exit 1
fi
[[ "$unset_home_output" == "Error: HOME is not set; unable to resolve aidevops installation paths." ]] || {
	printf 'FAIL: launcher returned an unexpected empty-HOME error: %s\n' "$unset_home_output" >&2
	exit 1
}

grep -q 'After this, step 1 will always match and the deployed copy runs directly.' "$REPO_DIR/bin/aidevops"

printf 'PASS: CLI launcher, orchestrator, and clean update checkout remain coherent\n'
