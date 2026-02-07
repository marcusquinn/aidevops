#!/usr/bin/env bash
# x-helper.sh - Fetch X/Twitter posts via fxtwitter API (no auth required)
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   x-helper.sh [command] [options]
#
# Commands:
#   fetch <url>       Fetch a tweet/post by URL (x.com or twitter.com)
#   thread <url>      Fetch a thread starting from the given post
#   user <handle>     Fetch recent posts from a user (limited)
#   help              Show this help
#
# Options:
#   --json            Output raw JSON
#   --format md       Output as markdown (default)
#   --format text     Output as plain text
#
# Uses fxtwitter.com API (no authentication required).
# Ref: https://github.com/FixTweet/FxTwitter

set -euo pipefail

readonly FXTWITTER_API="https://api.fxtwitter.com"

readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_success() { printf "${GREEN}%s${NC}\n" "$1"; }
print_warning() { printf "${YELLOW}%s${NC}\n" "$1"; }
print_error() { printf "${RED}%s${NC}\n" "$1" >&2; }

extract_tweet_path() {
    local url="$1"
    # Extract username/status/id from various URL formats
    # Handles: x.com/user/status/123, twitter.com/user/status/123
    local path
    path=$(echo "$url" | sed -E 's|https?://(x\.com|twitter\.com)/||' | sed 's|[?#].*||')
    echo "$path"
}

extract_username() {
    local url="$1"
    echo "$url" | sed -E 's|https?://(x\.com|twitter\.com)/||' | sed 's|/.*||' | sed 's|^@||'
}

cmd_fetch() {
    local url="${1:-}"
    local output_format="${2:-md}"
    local raw_json="${3:-false}"

    if [[ -z "$url" ]]; then
        print_error "URL required. Usage: x-helper.sh fetch <url>"
        return 1
    fi

    local path
    path=$(extract_tweet_path "$url")

    local response
    response=$(curl -fsS --max-time 20 --retry 2 --retry-connrefused \
        "${FXTWITTER_API}/${path}" 2>/dev/null) || {
        print_error "Failed to fetch tweet"
        return 1
    }

    if [[ "$raw_json" == "true" ]]; then
        echo "$response" | jq . 2>/dev/null || echo "$response"
        return 0
    fi

    # Parse JSON and format output
    local author author_handle text created_at likes retweets replies
    author=$(echo "$response" | jq -r '.tweet.author.name // "Unknown"' 2>/dev/null || echo "Unknown")
    author_handle=$(echo "$response" | jq -r '.tweet.author.screen_name // "unknown"' 2>/dev/null || echo "unknown")
    text=$(echo "$response" | jq -r '.tweet.text // ""' 2>/dev/null || echo "")
    created_at=$(echo "$response" | jq -r '.tweet.created_at // ""' 2>/dev/null || echo "")
    likes=$(echo "$response" | jq -r '.tweet.likes // 0' 2>/dev/null || echo "0")
    retweets=$(echo "$response" | jq -r '.tweet.retweets // 0' 2>/dev/null || echo "0")
    replies=$(echo "$response" | jq -r '.tweet.replies // 0' 2>/dev/null || echo "0")

    if [[ "$output_format" == "text" ]]; then
        echo "@${author_handle} (${author})"
        echo "${created_at}"
        echo ""
        echo "${text}"
        echo ""
        echo "Likes: ${likes} | Retweets: ${retweets} | Replies: ${replies}"
    else
        # Markdown format
        printf "**%s** (@%s)\n" "$author" "$author_handle"
        printf "*%s*\n\n" "$created_at"
        printf "%s\n\n" "$text"
        printf "Likes: %s | Retweets: %s | Replies: %s\n" "$likes" "$retweets" "$replies"
        printf "\nSource: %s\n" "$url"
    fi

    return 0
}

cmd_thread() {
    local url="${1:-}"

    if [[ -z "$url" ]]; then
        print_error "URL required. Usage: x-helper.sh thread <url>"
        return 1
    fi

    # fxtwitter doesn't have a native thread endpoint, but we can fetch
    # the conversation by following reply chains
    print_warning "Thread fetching is limited - fxtwitter returns individual posts"
    print_warning "Fetching initial post..."
    echo ""
    cmd_fetch "$url" "md" "false"

    return 0
}

cmd_user() {
    local handle="${1:-}"

    if [[ -z "$handle" ]]; then
        print_error "Handle required. Usage: x-helper.sh user <handle>"
        return 1
    fi

    # Remove @ prefix if present
    handle="${handle#@}"

    local response
    response=$(curl -fsS --max-time 20 --retry 2 --retry-connrefused \
        "${FXTWITTER_API}/${handle}" 2>/dev/null) || {
        print_error "Failed to fetch user profile"
        return 1
    }

    # Parse user info
    local name followers following description
    name=$(echo "$response" | jq -r '.user.name // "Unknown"' 2>/dev/null || echo "Unknown")
    followers=$(echo "$response" | jq -r '.user.followers // 0' 2>/dev/null || echo "0")
    following=$(echo "$response" | jq -r '.user.following // 0' 2>/dev/null || echo "0")
    description=$(echo "$response" | jq -r '.user.description // ""' 2>/dev/null || echo "")

    printf "**%s** (@%s)\n" "$name" "$handle"
    printf "Followers: %s | Following: %s\n\n" "$followers" "$following"
    if [[ -n "$description" ]]; then
        printf "%s\n" "$description"
    fi

    return 0
}

cmd_help() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
    return 0
}

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    local output_format="md"
    local raw_json="false"
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) raw_json="true"; shift ;;
            --format) [[ $# -lt 2 ]] && { print_error "--format requires a value"; return 1; }; output_format="$2"; shift 2 ;;
            *) args+=("$1"); shift ;;
        esac
    done

    case "$command" in
        fetch)   cmd_fetch "${args[0]:-}" "$output_format" "$raw_json" ;;
        thread)  cmd_thread "${args[0]:-}" ;;
        user)    cmd_user "${args[0]:-}" ;;
        help|-h|--help) cmd_help ;;
        *)
            print_error "Unknown command: ${command}"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
