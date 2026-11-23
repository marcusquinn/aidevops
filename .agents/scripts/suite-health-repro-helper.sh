#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# suite-health-repro-helper.sh - reproduce Shell Suite Main Health rows locally
# and classify each red suite by where it fails (GH#40105).
#
# Usage:
#   suite-health-repro-helper.sh host      [OPTIONS] [SUITE...]
#   suite-health-repro-helper.sh fakehome  [OPTIONS] [SUITE...]
#   suite-health-repro-helper.sh linux     [OPTIONS] [SUITE...]
#   suite-health-repro-helper.sh all       [OPTIONS] [SUITE...]   (host+fakehome+linux, then classify)
#   suite-health-repro-helper.sh classify  FILE.tsv [FILE.tsv...]
#   suite-health-repro-helper.sh check-steps
#
# Modes:
#   host      run each suite on this host with the current HOME.
#   fakehome  run each suite with a disposable HOME that only links
#             ~/.aidevops/agents to the checkout, sets a git identity and unsets
#             GH_TOKEN/GITHUB_TOKEN/XDG_*. The maintainer HOME is never reused.
#   linux     run in an ubuntu container: copy the checkout without .git, git init,
#             create an unprivileged `runner` user (HOME 750), then replay the
#             staging steps extracted from the workflow file (not reimplemented).
#
# Options:
#   --results FILE   suite-results.tsv from the workflow artifact (suite is column 1)
#   --class NAME     rows to select from --results by column 4 (default: regression; "all" = every row)
#   --jobs N         concurrent suites (default 4)
#   --timeout SEC    per-suite timeout (default 180; a suite's own
#                    `# aidevops:suite-timeout=` may raise it, capped at 900)
#   --repo DIR       checkout to test (default: this script's git toplevel)
#   --image IMG      container image for linux mode (default ubuntu:24.04)
#   --workflow FILE  workflow replayed by linux mode
#   --keep           keep temp dir and per-suite logs (path printed on stderr)
#
# Output (stdout): TSV `suite  mode  rc  first_failing_line`. `all` and `classify`
# print `suite  host  fakehome  linux  classification` instead. Progress goes to
# stderr as `AIDEVOPS_PROGRESS:` lines.
# Exit: 0 ok, 1 usage/runtime unavailable, 2 workflow drift (step names missing).
#
# Drift risk: linux mode extracts `env:` and `run:` of the named workflow steps
# in STAGING_STEPS. If a step is renamed the replay would silently skip it, so
# `check-steps` (run automatically before linux mode) fails when a name is missing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
WORKFLOW_REL=".github/workflows/shell-suite-main-health.yml"
STAGING_STEPS="Install suite toolchain|Install pinned shfmt|Stage checked-out framework|Stage managed Vault crypto runtime"
TIMEOUT_CAP=900

JOBS=4
SUITE_TIMEOUT=180
CLASS="regression"
RESULTS=""
REPO=""
IMAGE="ubuntu:24.04"
WORKFLOW=""
KEEP=0
SUITES=()

die() {
	local msg="$1"
	printf 'suite-health-repro-helper: %s\n' "$msg" >&2
	exit 1
}

progress() {
	local msg="$1"
	printf 'AIDEVOPS_PROGRESS: %s\n' "$msg" >&2
	return 0
}

# Print an executable timeout command name, or nothing.
timeout_cmd() {
	if command -v timeout >/dev/null 2>&1; then
		printf 'timeout'
	elif command -v gtimeout >/dev/null 2>&1; then
		printf 'gtimeout'
	fi
	return 0
}

temp_base() {
	local base="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$base" || return 1
	printf '%s' "$base"
	return 0
}

# make_temp dir|file PREFIX: create a temp path under the framework temp base.
make_temp() {
	local kind="$1"
	local prefix="$2"
	local base
	base="$(temp_base)" || return 1
	if [[ "$kind" == "dir" ]]; then
		mktemp -d "${base}/${prefix}.XXXXXX"
	else
		mktemp "${base}/${prefix}.XXXXXX"
	fi
	return $?
}

# Effective timeout: the suite's declared budget may only raise the default.
effective_timeout() {
	local file="$1"
	local declared
	declared="$(head -n 20 "$file" 2>/dev/null | sed -n 's/^#[[:space:]]*aidevops:suite-timeout=\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -n 1)"
	if [[ -n "$declared" ]]; then
		[[ "$declared" -gt "$TIMEOUT_CAP" ]] && declared="$TIMEOUT_CAP"
		if [[ "$declared" -gt "$SUITE_TIMEOUT" ]]; then
			printf '%s' "$declared"
			return 0
		fi
	fi
	printf '%s' "$SUITE_TIMEOUT"
	return 0
}

# First failing line of a suite log: first FAIL/error-ish line, else last non-empty line.
first_failing_line() {
	local log="$1"
	local line
	line="$(LC_ALL=C grep -a -m 1 -E 'FAIL|✗|not ok|[Ee]rror|[Ss]yntax|command not found|No such file|Permission denied' "$log" 2>/dev/null)"
	if [[ -z "$line" ]]; then
		line="$(LC_ALL=C grep -a -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -n 1)"
	fi
	printf '%s' "$line" | tr '\t\r' '  ' | cut -c1-300
	return 0
}

# Internal: run one suite. Env: SHR_REPO SHR_OUT SHR_TIMEOUT SHR_TIMEOUT_CMD SHR_LABEL
run_one() {
	local mode="$1"
	local suite="$2"
	local name="${suite//\//__}"
	local log="${SHR_OUT}/logs/${name}.log"
	local file="${SHR_REPO}/${suite}"
	local tmo rc=0 fh=""
	if [[ ! -f "$file" ]]; then
		printf '%s\t%s\t%s\t%s\n' "$suite" "${SHR_LABEL:-$mode}" "-" "suite file not found" >"${SHR_OUT}/rows/${name}.tsv"
		return 0
	fi
	tmo="$(effective_timeout "$file")"
	cd "$SHR_REPO" || return 1
	local -a pre=()
	if [[ -n "${SHR_TIMEOUT_CMD:-}" ]]; then
		pre=("$SHR_TIMEOUT_CMD" -k 10 "$tmo")
	fi
	if [[ "$mode" == "fakehome" ]]; then
		fh="$(mktemp -d "${SHR_OUT}/home.XXXXXX")" || return 1
		if [[ "$fh" == "$HOME" ]]; then
			return 1
		fi
		mkdir -p "$fh/.aidevops" "$fh/tmp"
		ln -s "${SHR_REPO}/.agents" "$fh/.aidevops/agents"
		printf '[user]\n\tname = aidevops-repro\n\temail = repro@aidevops.invalid\n' >"$fh/.gitconfig"
		env -u GH_TOKEN -u GITHUB_TOKEN -u XDG_CONFIG_HOME -u XDG_DATA_HOME \
			-u XDG_STATE_HOME -u XDG_CACHE_HOME -u XDG_RUNTIME_DIR -u AIDEVOPS_TEMP_DIR \
			HOME="$fh" TMPDIR="$fh/tmp" GIT_CONFIG_GLOBAL="$fh/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
			${pre[@]+"${pre[@]}"} bash "$suite" </dev/null >"$log" 2>&1 || rc=$?
		rm -rf "$fh"
	else
		${pre[@]+"${pre[@]}"} bash "$suite" </dev/null >"$log" 2>&1 || rc=$?
	fi
	local line=""
	[[ "$rc" -ne 0 ]] && line="$(first_failing_line "$log")"
	printf '%s\t%s\t%s\t%s\n' "$suite" "${SHR_LABEL:-$mode}" "$rc" "$line" >"${SHR_OUT}/rows/${name}.tsv"
	progress "suite-health-repro ${SHR_LABEL:-$mode} ${suite} rc=${rc}"
	return 0
}

# Run all suites in $1 (list file) in MODE with bounded concurrency; rows to stdout.
run_mode() {
	local mode="$1"
	local list="$2"
	local out tcmd xpid suite name
	out="$(make_temp dir "suite-health-repro")" || return 1
	mkdir -p "$out/logs" "$out/rows"
	tcmd="$(timeout_cmd)"
	[[ -z "$tcmd" ]] && printf 'suite-health-repro-helper: no timeout/gtimeout found; suites run unbounded\n' >&2
	progress "suite-health-repro ${mode} starting $(wc -l <"$list" | tr -d ' ') suites, jobs=${JOBS}"
	export SHR_REPO="$REPO" SHR_OUT="$out" SHR_TIMEOUT_CMD="$tcmd" SHR_LABEL="${LABEL_OVERRIDE:-$mode}"
	export SUITE_TIMEOUT TIMEOUT_CAP
	xargs -P "$JOBS" -I '{}' bash "$SELF" _run-one "$mode" '{}' <"$list" >&2 &
	xpid=$!
	trap 'pkill -TERM -P "$xpid" 2>/dev/null; kill "$xpid" 2>/dev/null; exit 130' INT TERM
	wait "$xpid"
	trap - INT TERM
	while IFS= read -r suite; do
		name="${suite//\//__}"
		if [[ -f "$out/rows/${name}.tsv" ]]; then
			cat "$out/rows/${name}.tsv"
		else
			printf '%s\t%s\t%s\t%s\n' "$suite" "${SHR_LABEL:-$mode}" "-" "no result recorded"
		fi
	done <"$list"
	if [[ "$KEEP" -eq 1 ]]; then
		printf 'suite-health-repro-helper: kept %s\n' "$out" >&2
	else
		rm -rf "$out"
	fi
	return 0
}

# Verify every replayed workflow step name is present.
check_steps() {
	local wf="$1"
	local missing=0 step
	[[ -f "$wf" ]] || die "workflow not found: $wf"
	local IFS='|'
	for step in $STAGING_STEPS; do
		if ! grep -qF -- "- name: ${step}" "$wf"; then
			printf 'suite-health-repro-helper: workflow step missing: %s\n' "$step" >&2
			missing=1
		fi
	done
	[[ "$missing" -eq 0 ]] && return 0
	return 2
}

# Print the env exports and dedented run body of one workflow step.
extract_step() {
	local wf="$1"
	local step="$2"
	awk -v want="- name: ${step}" '
		function indent(s,   m) { match(s, /^ */); return RLENGTH }
		{
			if (!in_step) {
				t = $0; sub(/^ +/, "", t)
				if (t == want) { in_step = 1; step_ind = indent($0) }
				next
			}
			if ($0 ~ /^ *- name:/ && indent($0) <= step_ind) { exit }
			if (in_run) {
				if ($0 ~ /^ *$/) { print ""; next }
				if (indent($0) >= run_ind) { print substr($0, run_ind + 1); next }
				in_run = 0
			}
			t = $0; sub(/^ +/, "", t)
			if (t == "env:") { in_env = 1; next }
			if (t ~ /^run: *\|/) { in_env = 0; in_run = 1; run_ind = -1; getline nxt; run_ind = indent(nxt); print substr(nxt, run_ind + 1); next }
			if (in_env && t ~ /^[A-Za-z_][A-Za-z0-9_]*: /) {
				k = t; sub(/:.*/, "", k)
				v = t; sub(/^[^:]*: */, "", v); gsub(/^'\''|'\''$/, "", v)
				printf "export %s=\x27%s\x27\n", k, v
			}
		}' "$wf"
	return 0
}

run_linux() {
	local list="$1"
	local wf="${WORKFLOW:-${REPO}/${WORKFLOW_REL}}"
	local stage out step n=0 label_rows
	command -v docker >/dev/null 2>&1 || die "docker not found; linux mode needs a container runtime"
	docker info >/dev/null 2>&1 || die "docker daemon unavailable"
	check_steps "$wf" || exit 2
	stage="$(make_temp dir "suite-health-linux")" || return 1
	mkdir -p "$stage/src" "$stage/out"
	# Copy the checkout without .git (a linked-worktree .git file breaks in a container).
	(cd "$REPO" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -xf - -C "$stage/src" || die "copy failed"
	cp "$SELF" "$stage/helper.sh"
	cp "$list" "$stage/suites.txt"
	: >"$stage/steps.sh"
	local IFS_SAVE="$IFS"
	IFS='|'
	for step in $STAGING_STEPS; do
		n=$((n + 1))
		{
			printf '# step: %s\nset -eo pipefail\n' "$step"
			extract_step "$wf" "$step"
		} >"$stage/step-${n}.sh"
		printf 'echo "== replaying step: %s"\nbash /home/runner/step-%s.sh || exit 1\n' "$step" "$n" >>"$stage/steps.sh"
	done
	IFS="$IFS_SAVE"
	cat >"$stage/inner.sh" <<'INNER'
#!/usr/bin/env bash
# Runs as the unprivileged runner user inside the container.
set -u
export HOME=/home/runner RUNNER_TEMP=/home/runner/_temp GITHUB_WORKSPACE=/home/runner/work
export GITHUB_ENV=/home/runner/_temp/github_env GITHUB_PATH=/home/runner/_temp/github_path GITHUB_REF=refs/heads/main
mkdir -p "$RUNNER_TEMP"; : >"$GITHUB_ENV"; : >"$GITHUB_PATH"
cd "$GITHUB_WORKSPACE" || exit 1
git init -q . && git add -A >/dev/null 2>&1 && git -c user.name=r -c user.email=r@r.invalid commit -q -m snapshot
bash /home/runner/steps.sh >&2 || { echo "staging failed" >&2; exit 3; }
while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done <"$GITHUB_ENV"
while IFS= read -r p; do [ -n "$p" ] && PATH="$p:$PATH"; done <"$GITHUB_PATH"
export PATH
exec bash /home/runner/helper.sh _inner-host --repo "$GITHUB_WORKSPACE" --jobs "$SHR_JOBS" --timeout "$SHR_TIMEOUT" /home/runner/suites.txt
INNER
	cat >"$stage/outer.sh" <<'OUTER'
#!/usr/bin/env bash
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq sudo git jq curl ca-certificates nodejs npm python3 python3-venv python3-pip >/dev/null
useradd -m -d /home/runner -s /bin/bash runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner
chmod 750 /home/runner
cp -a /stage/src /home/runner/work
cp /stage/inner.sh /stage/steps.sh /stage/helper.sh /stage/suites.txt /stage/step-*.sh /home/runner/
chown -R runner:runner /home/runner
chmod 777 /out
exec runuser -u runner -- env SHR_JOBS="$SHR_JOBS" SHR_TIMEOUT="$SHR_TIMEOUT" bash /home/runner/inner.sh
OUTER
	progress "suite-health-repro linux staging container ${IMAGE}"
	docker run --rm --init --pids-limit 4096 -e SHR_JOBS="$JOBS" -e SHR_TIMEOUT="$SUITE_TIMEOUT" \
		-v "$stage:/stage:ro" -v "$stage/out:/out" "$IMAGE" bash /stage/outer.sh >"$stage/out/rows.raw" 2>"$stage/out/stderr.log"
	local rc=$?
	label_rows="$stage/out/rows.raw"
	if [[ "$rc" -ne 0 ]] && ! grep -q "$(printf '\t')linux$(printf '\t')" "$label_rows" 2>/dev/null; then
		tail -n 5 "$stage/out/stderr.log" >&2
		printf 'suite-health-repro-helper: container run failed (rc=%s)\n' "$rc" >&2
		[[ "$KEEP" -eq 1 ]] || rm -rf "$stage"
		return 1
	fi
	cat "$label_rows"
	if [[ "$KEEP" -eq 1 ]]; then
		printf 'suite-health-repro-helper: kept %s\n' "$stage" >&2
	else
		rm -rf "$stage"
	fi
	return 0
}

# classification code for host/fakehome/linux results (P pass, F fail, - not run)
classify_code() {
	local code="$1"
	case "$code" in
	PPP | PP- | P-P | P--) printf 'not-reproduced' ;;
	FP?) printf 'maintainer-home-state' ;;
	PPF | P-F) printf 'linux-specific' ;;
	PF?) printf 'needs-host-state-not-in-fakehome' ;;
	FFP) printf 'host-platform-specific' ;;
	FFF) printf 'reproducible-drift' ;;
	FF-) printf 'red-on-host-and-fakehome' ;;
	F--) printf 'host-only-red' ;;
	*) printf 'unclassified' ;;
	esac
	return 0
}

# classify FILE...: files hold TSV rows `suite mode rc line` for modes host/fakehome/linux.
classify_files() {
	local suite h f l classification
	printf 'suite\thost\tfakehome\tlinux\tclassification\n'
	cat "$@" | awk -F'\t' -v modes='host fakehome linux' '
		BEGIN { nm = split(modes, mn, " ") }
		{
			split($0, f, "\t")
			for (j = 1; j <= nm; j++) {
				if (f[2] != mn[j]) continue
				if (!(f[1] in seen)) { seen[f[1]] = 1; order[++n] = f[1] }
				res[f[1], j] = (f[3] == "0") ? "P" : "F"
			}
		}
		END {
			for (i = 1; i <= n; i++) {
				line = order[i]
				for (j = 1; j <= nm; j++) line = line "\t" (((order[i], j) in res) ? res[order[i], j] : "-")
				print line
			}
		}' | while IFS="$(printf '\t')" read -r suite h f l; do
		classification="$(classify_code "${h}${f}${l}")"
		printf '%s\t%s\t%s\t%s\t%s\n' "$suite" "$h" "$f" "$l" "$classification"
	done
	return 0
}

build_list() {
	local list="$1"
	local s
	: >"$list"
	if [[ -n "$RESULTS" ]]; then
		[[ -f "$RESULTS" ]] || die "results file not found: $RESULTS"
		awk -F'\t' -v c="$CLASS" 'NR > 1 && $1 != "" && (c == "all" || $4 == c) { print $1 }' "$RESULTS" >>"$list"
	fi
	for s in ${SUITES[@]+"${SUITES[@]}"}; do
		printf '%s\n' "$s" >>"$list"
	done
	awk '!seen[$0]++' "$list" >"$list.u" && mv "$list.u" "$list"
	[[ -s "$list" ]] || die "no suites selected (give --results FILE or suite paths)"
	return 0
}

usage() {
	sed -n '4,40p' "$SELF" | sed 's/^# \{0,1\}//'
	return 0
}

main() {
	local sub="${1:-}"
	[[ -n "$sub" ]] || {
		usage
		return 1
	}
	shift
	local positional=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--results) RESULTS="${2:-}"; shift 2 ;;
		--class) CLASS="${2:-}"; shift 2 ;;
		--jobs) JOBS="${2:-}"; shift 2 ;;
		--timeout) SUITE_TIMEOUT="${2:-}"; shift 2 ;;
		--repo) REPO="${2:-}"; shift 2 ;;
		--image) IMAGE="${2:-}"; shift 2 ;;
		--workflow) WORKFLOW="${2:-}"; shift 2 ;;
		--keep) KEEP=1; shift ;;
		-h | --help) usage; return 0 ;;
		*) positional+=("$arg"); shift ;;
		esac
	done
	case "$JOBS" in '' | *[!0-9]* | 0) die "--jobs must be a positive integer" ;; esac
	case "$SUITE_TIMEOUT" in '' | *[!0-9]* | 0) die "--timeout must be a positive integer" ;; esac
	REPO="${REPO:-${SHR_REPO:-}}"; [[ -n "$REPO" ]] || REPO="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null)" || die "no repo"
	REPO="$(cd "$REPO" && pwd)" || die "bad repo"

	case "$sub" in
	_run-one)
		run_one "${positional[0]}" "${positional[1]}"
		return $?
		;;
	check-steps)
		check_steps "${WORKFLOW:-${REPO}/${WORKFLOW_REL}}"
		return $?
		;;
	extract-step)
		# Debug aid: print what linux mode would replay for one workflow step.
		[[ ${#positional[@]} -gt 0 ]] || die "extract-step needs a step name"
		extract_step "${WORKFLOW:-${REPO}/${WORKFLOW_REL}}" "${positional[0]}"
		return $?
		;;
	classify)
		[[ ${#positional[@]} -gt 0 ]] || die "classify needs at least one TSV file"
		classify_files "${positional[@]}"
		return $?
		;;
	host | fakehome | linux | all | _inner-host) ;;
	*) usage; return 1 ;;
	esac

	local list
	if [[ "$sub" == "_inner-host" ]]; then
		# Inside the container: positional[0] is the suite list; label rows `linux`.
		LABEL_OVERRIDE=linux
		printf 'suite\tmode\trc\tfirst_failing_line\n' >/dev/null
		run_mode host "${positional[0]}"
		return 0
	fi
	list="$(make_temp file "suite-health-list")" || return 1
	SUITES=(${positional[@]+"${positional[@]}"})
	build_list "$list"
	local rc=0 tmp
	case "$sub" in
	host | fakehome)
		printf 'suite\tmode\trc\tfirst_failing_line\n'
		run_mode "$sub" "$list"
		;;
	linux)
		printf 'suite\tmode\trc\tfirst_failing_line\n'
		run_linux "$list" || rc=$?
		;;
	all)
		tmp="$(make_temp file "suite-health-all")" || return 1
		run_mode host "$list" >"$tmp"
		run_mode fakehome "$list" >>"$tmp"
		run_linux "$list" >>"$tmp" || printf 'suite-health-repro-helper: linux column unavailable\n' >&2
		classify_files "$tmp"
		rm -f "$tmp"
		;;
	esac
	rm -f "$list"
	return "$rc"
}

main "$@"
