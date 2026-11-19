#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
#
# Runtime evidence for Linux procfs observer changes (worktree_process_proc.py,
# worktree_process_attestation.py, lease census) from any host with Docker.
# Runs process fixtures in a stock Linux container and prints a diffable report.
#
# Usage:
#   linux-procfs-runtime-check.sh [--head DIR] [--base DIR] [--image IMG] [--uid N] [--forged]
#   linux-procfs-runtime-check.sh --sudo-session [--head TREE] [--base TREE] [--image IMG] [--uid N]
# DIR is a scripts directory holding worktree_process_proc.py. Default head: this
# script's directory. With --base, prints base report, head report and a diff.
#
# --sudo-session reproduces a real sudo env reset for a non-root user who owns
# /run/user/<uid> and a live session-bus socket, then reports the user and session
# env that approval-triggered pulse kicks receive. TREE is a repository root
# (holding .agents/scripts/approval-helper.sh); default head: this checkout.
# Cases: permission kick (spawn fallback), issue-approval --merge-only kick, and
# permission kick with a systemctl recorder on PATH.
# Exit: 0 ok, 1 usage/runtime unavailable, 2 a container run failed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${PROCFS_CHECK_IMAGE:-debian:stable-slim}"
BOOTSTRAP='command -v python3 >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq python3 >/dev/null 2>&1; }; exec python3 /fixture.py /scripts "$@"'

# Container-side script for --sudo-session (runs as root; $1 = uid, tree at /tree).
# Recorder log is world-writable because the kicked process runs as the real user.
read -r -d '' SUDO_SESSION_SCRIPT <<'SUDO_SESSION_EOF' || true
uid="$1"
export DEBIAN_FRONTEND=noninteractive
need=""
for tool in sudo jq pgrep git python3; do
	command -v "$tool" >/dev/null 2>&1 || need="$need $tool"
done
if [ -n "$need" ]; then
	apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq sudo jq procps git python3 >/dev/null 2>&1 || {
		echo "container bootstrap failed: could not install sudo jq procps git python3" >&2
		exit 3
	}
fi
useradd -m -u "$uid" -s /bin/bash alice
printf 'alice ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/alice
chmod 440 /etc/sudoers.d/alice
mkdir -p "/run/user/${uid}"
chown alice "/run/user/${uid}"
chmod 700 "/run/user/${uid}"
python3 -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(600)' "/run/user/${uid}/bus" &
for _ in $(seq 1 50); do
	[ -S "/run/user/${uid}/bus" ] && break
	sleep 0.1
done
[ -S "/run/user/${uid}/bus" ] || { echo "session bus socket was not created" >&2; exit 3; }
chown alice "/run/user/${uid}/bus"
LOG=/var/tmp/kick-recorder.log
mkdir -p /opt/rec/bin "/home/alice/.aidevops/agents/scripts"
cat >/opt/rec/record.sh <<'REC'
#!/bin/sh
LOG=/var/tmp/kick-recorder.log
{
	printf '%s: user=%s args=[%s]\n' "$1" "$(id -un)" "$2"
	printf '%s:   XDG_RUNTIME_DIR=%s\n' "$1" "${XDG_RUNTIME_DIR-<unset>}"
	printf '%s:   DBUS_SESSION_BUS_ADDRESS=%s\n' "$1" "${DBUS_SESSION_BUS_ADDRESS-<unset>}"
} >>"$LOG"
REC
printf '#!/bin/sh\nexec /opt/rec/record.sh pulse "$*"\n' >/home/alice/.aidevops/agents/scripts/pulse-wrapper.sh
printf '#!/bin/sh\n/opt/rec/record.sh systemctl "$*"\nexit 0\n' >/opt/rec/bin/systemctl
chmod 755 /opt/rec/record.sh /opt/rec/bin/systemctl /home/alice/.aidevops/agents/scripts/pulse-wrapper.sh
chown -R alice "/home/alice/.aidevops"
run_case() {
	local name="$1" fn="$2" pfx="$3" waited
	: >"$LOG"
	chmod 666 "$LOG"
	printf 'export PATH="%s:$PATH"\nsource /tree/.agents/scripts/approval-helper.sh\n%s\n' "$pfx" "$fn" >/opt/rec/case.sh
	chmod 644 /opt/rec/case.sh
	printf '## case: %s\n' "$name"
	su alice -s /bin/bash -c 'sudo bash /opt/rec/case.sh' || printf '(case command exited non-zero)\n'
	waited=0
	while [ ! -s "$LOG" ] && [ "$waited" -lt 25 ]; do
		sleep 0.2
		waited=$((waited + 1))
	done
	sleep 0.5
	if [ -s "$LOG" ]; then cat "$LOG"; else printf '(no kick observed)\n'; fi
}
printf 'fixture: sudo user=alice uid=%s bus=/run/user/%s/bus\n' "$uid" "$uid"
run_case "permission kick, spawn fallback" "_kick_pulse_after_permission_approval" "/usr/bin"
run_case "issue approval --merge-only kick" "_kick_pulse_after_approval issue 1 owner/repo" "/usr/bin"
run_case "permission kick, systemctl recorder on PATH" "_kick_pulse_after_permission_approval" "/opt/rec/bin"
SUDO_SESSION_EOF

usage() {
	printf 'Usage: %s [--head DIR] [--base DIR] [--image IMG] [--uid N] [--forged] [--sudo-session]\n' "$(basename "$0")" >&2
	return 0
}

die() {
	local message="$1"
	printf 'linux-procfs-runtime-check: %s\n' "$message" >&2
	return 0
}

require_runtime() {
	command -v docker >/dev/null 2>&1 || {
		die "docker not found; a Linux container runtime is required"
		return 1
	}
	docker info >/dev/null 2>&1 || {
		die "docker daemon unavailable; start it to run Linux procfs fixtures"
		return 1
	}
	return 0
}

# run_report LABEL DIR UID FORGED -> prints the fixture report for one scripts dir.
run_report() {
	local label="$1" dir="$2" uid="$3" forged="$4"
	local extra=()
	[[ "$forged" == "1" ]] && extra+=(--forged)
	printf '# %s: %s\n' "$label" "$dir"
	local cid_dir cid_file cid
	cid_dir="$(mktemp -d)" || return 2
	cid_file="${cid_dir}/cid"
	docker run --rm --init --cidfile "$cid_file" --pids-limit 512 \
		--mount "type=bind,source=${dir},target=/scripts,readonly" \
		--mount "type=bind,source=${SCRIPT_DIR}/linux-procfs-runtime-fixture.py,target=/fixture.py,readonly" \
		"$IMAGE" sh -c "$BOOTSTRAP" sh "$uid" ${extra[@]+"${extra[@]}"} || {
		if [[ -s "$cid_file" ]]; then
			cid="$(<"$cid_file")"
			docker rm -f "$cid" >/dev/null 2>&1 || true
		fi
		rm -rf "$cid_dir"
		die "container run failed for ${label}"
		return 2
	}
	rm -rf "$cid_dir"
	return 0
}

# run_sudo_report LABEL TREE UID -> prints the sudo-session report for one repo tree.
run_sudo_report() {
	local label="$1" tree="$2" uid="$3"
	printf '# %s: %s\n' "$label" "$tree"
	local cid_dir cid_file cid
	cid_dir="$(mktemp -d)" || return 2
	cid_file="${cid_dir}/cid"
	docker run --rm --init --cidfile "$cid_file" --pids-limit 512 \
		--mount "type=bind,source=${tree},target=/tree,readonly" \
		"$IMAGE" bash -c "$SUDO_SESSION_SCRIPT" bash "$uid" || {
		if [[ -s "$cid_file" ]]; then
			cid="$(<"$cid_file")"
			docker rm -f "$cid" >/dev/null 2>&1 || true
		fi
		rm -rf "$cid_dir"
		die "container run failed for ${label}"
		return 2
	}
	rm -rf "$cid_dir"
	return 0
}

# main_sudo_session HEAD_TREE BASE_TREE UID -> sudo-session reports plus diff.
main_sudo_session() {
	local head_tree="$1" base_tree="$2" uid="$3"
	local dir
	for dir in "$head_tree" ${base_tree:+"$base_tree"}; do
		[[ -f "$dir/.agents/scripts/approval-helper.sh" ]] || {
			die "missing .agents/scripts/approval-helper.sh in ${dir} (--sudo-session needs repository roots)"
			return 1
		}
	done
	require_runtime || return 1
	head_tree="$(cd "$head_tree" && pwd)"
	local head_out base_out=""
	if [[ -n "$base_tree" ]]; then
		base_tree="$(cd "$base_tree" && pwd)"
		base_out="$(run_sudo_report base "$base_tree" "$uid")" || return 2
	fi
	head_out="$(run_sudo_report head "$head_tree" "$uid")" || return 2
	if [[ -n "$base_out" ]]; then
		printf '%s\n\n' "$base_out"
	fi
	printf '%s\n' "$head_out"
	if [[ -n "$base_out" ]]; then
		printf '\n# diff base -> head\n'
		diff <(printf '%s\n' "$base_out" | tail -n +2) <(printf '%s\n' "$head_out" | tail -n +2) || true
	fi
	return 0
}

main() {
	local head_dir="" base_dir="" uid=1000 forged=0 sudo_session=0
	local opt value
	while [[ $# -gt 0 ]]; do
		opt="${1:-}"
		value="${2:-}"
		case "$opt" in
		--head | --base | --image | --uid)
			[[ $# -ge 2 ]] || {
				usage
				return 1
			}
			case "$opt" in
			--head) head_dir="$value" ;;
			--base) base_dir="$value" ;;
			--image) IMAGE="$value" ;;
			--uid) uid="$value" ;;
			esac
			shift 2
			;;
		--forged)
			forged=1
			shift
			;;
		--sudo-session)
			sudo_session=1
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		*)
			usage
			return 1
			;;
		esac
	done
	[[ "$uid" =~ ^[1-9][0-9]*$ ]] || {
		die "--uid must be a positive integer"
		return 1
	}
	if [[ "$sudo_session" == "1" ]]; then
		main_sudo_session "${head_dir:-$(cd "$SCRIPT_DIR/../.." && pwd)}" "$base_dir" "$uid"
		return $?
	fi
	[[ -n "$head_dir" ]] || head_dir="$SCRIPT_DIR"
	local dir
	for dir in "$head_dir" ${base_dir:+"$base_dir"}; do
		[[ -f "$dir/worktree_process_proc.py" ]] || {
			die "missing worktree_process_proc.py in ${dir}"
			return 1
		}
	done
	require_runtime || return 1
	head_dir="$(cd "$head_dir" && pwd)"
	local head_out base_out=""
	if [[ -n "$base_dir" ]]; then
		base_dir="$(cd "$base_dir" && pwd)"
		base_out="$(run_report base "$base_dir" "$uid" "$forged")" || return 2
	fi
	head_out="$(run_report head "$head_dir" "$uid" "$forged")" || return 2
	if [[ -n "$base_out" ]]; then
		printf '%s\n\n' "$base_out"
	fi
	printf '%s\n' "$head_out"
	if [[ -n "$base_out" ]]; then
		printf '\n# diff base -> head\n'
		diff <(printf '%s\n' "$base_out" | tail -n +2) <(printf '%s\n' "$head_out" | tail -n +2) || true
	fi
	return 0
}

main "$@"
