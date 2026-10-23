#!/bin/bash
# SPDX-License-Identifier: MIT
# Research prototype, not an installed aidevops command.
# Configure dev-alpha/dev-beta privately in OpenSSH; no deployment data belongs here.
set -euo pipefail

action="${1:-}"
server="${2:-}"
key="${3:-}"
# A sentinel preserves an empty optional argument through Tabby's CLI parser.
if [[ "$key" == "-" ]]; then
    key=""
fi

case "$action" in
    new|restore|_attach) ;;
    *)
        printf 'Usage: bash %s restore [alpha|beta] [KEY_PATH]\n' "$0" >&2
        printf '       bash %s new alpha|beta [KEY_PATH]\n' "$0" >&2
        exit 1
        ;;
esac

if [[ "$action" == "restore" && -z "$server" ]]; then
    result=0
    for target in alpha beta; do
        printf '\nRestoring %s\n' "$target"
        if bash "${BASH_SOURCE[0]}" restore "$target" "$key"; then
            :
        else
            printf 'Restore failed for %s; continuing with remaining hosts\n' "$target" >&2
            result=1
        fi
    done
    exit "$result"
fi

case "$server" in
    alpha) host="${OPENCODE_TABS_ALPHA_HOST:-dev-alpha}" ;;
    beta) host="${OPENCODE_TABS_BETA_HOST:-dev-beta}" ;;
    *)
        printf 'Unknown host ID. Use alpha or beta\n' >&2
        exit 1
        ;;
esac

if [[ -z "$host" || "$host" == -* || "$host" == *[!a-zA-Z0-9_.@:-]* ]]; then
    printf 'Invalid SSH host alias\n' >&2
    exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
    printf 'Perl is required for portable connection locking\n' >&2
    exit 1
fi

umask 077
if [[ ! -d "$HOME" ]]; then
    printf 'Home directory not found\n' >&2
    exit 1
fi
lock_dir="$HOME/.local/state/opencode-tabs"
mkdir -p "$lock_dir"
if [[ -L "$lock_dir" || ! -O "$lock_dir" || ! -d "$lock_dir" ]]; then
    printf 'Connection lock directory must be owned by the current user\n' >&2
    exit 1
fi

# Keep lock inodes: deleting one while active would defeat mutual exclusion.
connection_lock() {
    local mode="$1"
    local lock_file="$2"
    shift 2
    if perl -MFcntl=:flock,:DEFAULT -MErrno=EAGAIN,EWOULDBLOCK -e '
        use strict;
        use warnings;
        my ($mode, $file) = splice @ARGV, 0, 2;
        sysopen(my $lock, $file, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
            or die "Cannot open connection lock: $!\n";
        die "Invalid connection lock\n" unless -f $lock && (stat($lock))[4] == $<;
        unless (flock($lock, LOCK_EX | LOCK_NB)) {
            exit 75 if $! == EAGAIN || $! == EWOULDBLOCK;
            die "Cannot acquire connection lock: $!\n";
        }
        my $pending = <$lock> // "";
        if ($mode eq "reserve") {
            my ($pending_until) = $pending =~ /^pending (\d+) /;
            exit 75 if defined($pending_until) && $pending_until > time;
            my $launch_id = time . "-$$-" . int(rand(1000000000));
            seek($lock, 0, 0) or die "Cannot seek connection lock: $!\n";
            truncate($lock, 0) or die "Cannot clear connection lock: $!\n";
            print {$lock} "pending ", time + 120, " $launch_id\n"
                or die "Cannot reserve connection: $!\n";
            print "$launch_id\n";
            exit 0;
        }
        my $launch_id = shift @ARGV // "";
        exit 75 unless length($launch_id) && $pending =~ /^pending \d+ \Q$launch_id\E\n$/;
        seek($lock, 0, 0) or die "Cannot seek connection lock: $!\n";
        truncate($lock, 0) or die "Cannot clear connection lock: $!\n";
        exit 0 if $mode eq "cancel";
        die "Invalid lock operation\n" unless $mode eq "hold";
        die "Missing SSH command\n" unless @ARGV;
        my $status = system { $ARGV[0] } @ARGV;
        exit 1 if $status == -1;
        exit(128 + ($status & 127)) if $status & 127;
        exit($status >> 8);
    ' -- "$mode" "$lock_file" "$@"; then
        return 0
    else
        return "$?"
    fi
}

has_local_connection() {
    local target_host="$1"
    local target_session="$2"
    if ps -ww -U "$UID" -o comm= -o args= | perl -e '
        use strict;
        use warnings;
        my ($host, $session) = @ARGV;
        my $found = 0;
        while (<STDIN>) {
            next unless /^\s*(?:\S*\/)?ssh\s/;
            next unless /(?:^|[\s\x27\x22])\Q$host\E(?=[\s\x27\x22]|$)/;
            next unless /\btmux\s+(?:attach-session|attach|new-session|new)\b/;
            next unless /(?:^|\s)-[ts]\s*[\x27\x22]?\Q$session\E(?=[\s\x27\x22]|$)/;
            $found = 1;
        }
        exit($found ? 0 : 1);
    ' -- "$target_host" "$target_session"; then
        return 0
    else
        return "$?"
    fi
}

ssh_options=(-o ConnectTimeout=15)
if [[ -n "$key" ]]; then
    if [[ ! -r "$key" ]]; then
        printf 'Explicit SSH identity file is not readable\n' >&2
        exit 1
    fi
    ssh_options+=(-o IdentitiesOnly=yes -i "$key")
fi

if [[ "$action" == "_attach" ]]; then
    session="${4:-}"
    launch_id="${5:-}"
    if [[ "$session" != oc-* || "$session" == *[!a-zA-Z0-9_-]* ]]; then
        printf 'Invalid working session name\n' >&2
        exit 1
    fi
    if has_local_connection "$host" "$session"; then
        if connection_lock cancel "$lock_dir/$server-$session.lock" "$launch_id"; then
            :
        else
            printf 'Launch reservation already changed\n' >&2
        fi
        printf 'Already connected locally: %s / %s\n' "$server" "$session"
        exit 0
    fi
    if connection_lock hold "$lock_dir/$server-$session.lock" "$launch_id" \
        /usr/bin/ssh "${ssh_options[@]}" -t "$host" \
        "tmux attach-session -t '$session'"; then
        exit 0
    else
        result="$?"
        if [[ "$result" -eq 75 ]]; then
            printf 'Already connected locally: %s / %s\n' "$server" "$session"
            exit 0
        fi
        exit "$result"
    fi
fi

if command -v tabby >/dev/null 2>&1; then
    tabby_bin="$(command -v tabby)"
elif [[ -x "/Applications/Tabby.app/Contents/MacOS/Tabby" ]]; then
    tabby_bin="/Applications/Tabby.app/Contents/MacOS/Tabby"
else
    printf 'Tabby executable not found\n' >&2
    exit 1
fi
case "${BASH_SOURCE[0]}" in
    /*) script_path="${BASH_SOURCE[0]}" ;;
    *) script_path="$PWD/${BASH_SOURCE[0]}" ;;
esac

sessions="$(ssh "${ssh_options[@]}" "$host" \
    "command -v tmux >/dev/null || exit 127
     tmux list-sessions -F '#{session_name}' 2>/dev/null || true")"

if [[ "$action" == "restore" ]]; then
    sessions="$(printf '%s\n' "$sessions" | perl -e '
        use strict;
        use warnings;
        my @names = grep { length } map { chomp; $_ } <STDIN>;
        my @sorted = sort {
            my ($left) = $a =~ /^oc-(\d+)$/;
            my ($right) = $b =~ /^oc-(\d+)$/;
            defined($left) && defined($right) ? ($left <=> $right || $a cmp $b)
                : defined($left) ? -1
                : defined($right) ? 1
                : $a cmp $b;
        } @names;
        print "$_\n" for @sorted;
    ')"
fi

if [[ "$action" == "new" ]]; then
    max=0
    while IFS= read -r name; do
        if [[ "$name" =~ ^oc-([0-9]+)$ ]]; then
            number=$((10#${BASH_REMATCH[1]}))
            if (( number > max )); then
                max="$number"
            fi
        fi
    done <<< "$sessions"
    printf -v session 'oc-%03d' "$((max + 1))"
    if ! ssh "${ssh_options[@]}" "$host" tmux new-session -d -s "$session"; then
        printf 'Could not create %s on %s; no tab opened\n' "$session" "$server" >&2
        exit 1
    fi
    sessions="$session"
fi

count=0
skipped=0
while IFS= read -r session; do
    case "$session" in
        oc-*) ;;
        *) continue ;;
    esac
    case "$session" in
        *[!a-zA-Z0-9_-]*) continue ;;
    esac
    if has_local_connection "$host" "$session"; then
        printf 'Skipping existing SSH connection: %s / %s\n' "$server" "$session"
        skipped=$((skipped + 1))
        continue
    fi
    if launch_id="$(connection_lock reserve "$lock_dir/$server-$session.lock")"; then
        :
    else
        result="$?"
        if [[ "$result" -ne 75 ]]; then
            exit "$result"
        fi
        printf 'Skipping connected or pending session: %s / %s\n' "$server" "$session"
        skipped=$((skipped + 1))
        continue
    fi
    printf 'Opening %s / %s\n' "$server" "$session"
    if "$tabby_bin" run \
        --command=/bin/bash \
        "--command=$script_path" \
        --command=_attach \
        "--command=$server" \
        "--command=${key:--}" \
        "--command=$session" \
        "--command=$launch_id"; then
        :
    else
        result="$?"
        if connection_lock cancel "$lock_dir/$server-$session.lock" "$launch_id"; then
            :
        else
            printf 'Could not clear launch reservation for %s\n' "$session" >&2
        fi
        exit "$result"
    fi
    sleep 5
    count=$((count + 1))
done <<< "$sessions"
printf 'Requested %s tabs on %s; skipped %s existing connections\n' "$count" "$server" "$skipped"
