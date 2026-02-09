#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155
set -euo pipefail

# YouTube Data API Helper Script
# Query YouTube channels, videos, and playlists via the YouTube Data API v3
# using a Google Cloud service account for authentication.
#
# Usage: ./youtube-helper.sh [command] [args] [options]
# Commands:
#   channel <handle|id|url>     - Get channel metadata and statistics
#   videos <channel_handle>     - List all videos from a channel
#   video <video_id|url>        - Get video details and statistics
#   search <query>              - Search YouTube videos/channels
#   transcript <video_id|url>   - Extract video transcript via yt-dlp
#   trending <niche>            - Find trending videos in a niche
#   competitors <handle> [...]  - Compare multiple channels side-by-side
#   quota                       - Show estimated quota usage for the day
#   auth-test                   - Test service account authentication
#   help                        - Show this help message
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# Constants
readonly YT_API_BASE="https://www.googleapis.com/youtube/v3"
readonly YT_TOKEN_URL="https://oauth2.googleapis.com/token"
readonly YT_GRANT_TYPE="urn:ietf:params:oauth:grant-type:jwt-bearer"
readonly YT_SCOPE="https://www.googleapis.com/auth/youtube.readonly"
readonly YT_CACHE_DIR="$HOME/.cache/aidevops/youtube"
readonly YT_QUOTA_FILE="$YT_CACHE_DIR/quota-$(date +%Y-%m-%d).json"
readonly HELP_SHOW_MESSAGE="Show this help message"

# Resolve service account key file
resolve_sa_key() {
    local key_file=""

    # Check environment variable first
    if [[ -n "${GCP_SA_KEY_FILE:-}" ]]; then
        key_file="$GCP_SA_KEY_FILE"
    fi

    # Check credentials.sh
    if [[ -z "$key_file" ]] && [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
        key_file=$(grep -oP 'GCP_SA_KEY_FILE="\K[^"]+' "$HOME/.config/aidevops/credentials.sh" 2>/dev/null | head -1 || true)
        # Expand $HOME if present
        key_file="${key_file/\$HOME/$HOME}"
    fi

    # Default location
    if [[ -z "$key_file" ]]; then
        key_file="$HOME/.config/aidevops/keys/evergreen-je-sa.json"
    fi

    if [[ ! -f "$key_file" ]]; then
        print_error "Service account key not found at: $key_file"
        print_info "Store your key: cp <key.json> ~/.config/aidevops/keys/evergreen-je-sa.json && chmod 600 ~/.config/aidevops/keys/evergreen-je-sa.json"
        print_info "Then add to credentials.sh: export GCP_SA_KEY_FILE=\"\$HOME/.config/aidevops/keys/evergreen-je-sa.json\""
        return 1
    fi

    echo "$key_file"
    return 0
}

# Get OAuth2 access token from service account
get_access_token() {
    local key_file
    key_file=$(resolve_sa_key) || return 1

    # Check cache (tokens last 1 hour, cache for 50 minutes)
    local token_cache="$YT_CACHE_DIR/token.json"
    if [[ -f "$token_cache" ]]; then
        local cached_exp
        cached_exp=$(node -e "const t=JSON.parse(require('fs').readFileSync('$token_cache','utf8')); console.log(t.expires_at||0)" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        if [[ "$cached_exp" -gt "$now" ]]; then
            node -e "console.log(JSON.parse(require('fs').readFileSync('$token_cache','utf8')).access_token)" 2>/dev/null
            return 0
        fi
    fi

    mkdir -p "$YT_CACHE_DIR"

    # Generate JWT and exchange for access token using Node.js
    local token_json
    token_json=$(node -e "
const crypto = require('crypto');
const fs = require('fs');
const { execSync } = require('child_process');
const sa = JSON.parse(fs.readFileSync('$key_file', 'utf8'));

const header = Buffer.from(JSON.stringify({alg:'RS256',typ:'JWT'})).toString('base64url');
const now = Math.floor(Date.now()/1000);
const payload = Buffer.from(JSON.stringify({
    iss: sa.client_email,
    scope: '$YT_SCOPE',
    aud: '$YT_TOKEN_URL',
    iat: now,
    exp: now + 3600
})).toString('base64url');

const sign = crypto.createSign('RSA-SHA256');
sign.update(header + '.' + payload);
const signature = sign.sign(sa.private_key, 'base64url');
const jwt = header + '.' + payload + '.' + signature;

fs.writeFileSync('/tmp/yt_jwt_assertion.txt',
    'grant_type=' + encodeURIComponent('$YT_GRANT_TYPE') + '&assertion=' + jwt);

const result = execSync(
    'curl -s -X POST $YT_TOKEN_URL ' +
    '-H \"Content-Type: application/x-www-form-urlencoded\" ' +
    '-d @/tmp/yt_jwt_assertion.txt',
    {encoding: 'utf8'}
);
fs.unlinkSync('/tmp/yt_jwt_assertion.txt');

const tok = JSON.parse(result);
if (tok.access_token) {
    tok.expires_at = now + (tok.expires_in || 3600) - 600;
    console.log(JSON.stringify(tok));
} else {
    console.error(JSON.stringify(tok));
    process.exit(1);
}
" 2>/dev/null) || {
        print_error "Failed to obtain access token from Google OAuth2"
        return 1
    }

    # Cache the token
    echo "$token_json" > "$token_cache"
    chmod 600 "$token_cache"

    echo "$token_json" | node -e "process.stdin.on('data',d=>console.log(JSON.parse(d).access_token))"
    return 0
}

# Make authenticated YouTube API request
yt_api_request() {
    local endpoint="$1"
    local params="$2"
    local quota_cost="${3:-1}"

    local token
    token=$(get_access_token) || return 1

    local url="${YT_API_BASE}/${endpoint}?${params}"
    local response
    response=$(curl -s -w "\n%{http_code}" "$url" \
        -H "Authorization: Bearer $token" \
        -H "$USER_AGENT") || {
        print_error "API request failed: $endpoint"
        return 1
    }

    local http_code
    http_code=$(echo "$response" | tail -1)
    local body
    body=$(echo "$response" | sed '$d')

    # Track quota usage
    track_quota "$quota_cost" "$endpoint"

    if [[ "$http_code" -ge 400 ]]; then
        local error_msg
        error_msg=$(echo "$body" | node -e "process.stdin.on('data',d=>{try{const e=JSON.parse(d).error;console.log(e.code+': '+e.message)}catch(x){console.log(d.toString().substring(0,200))}})" 2>/dev/null || echo "$body")
        print_error "YouTube API error ($http_code): $error_msg"
        return 1
    fi

    echo "$body"
    return 0
}

# Track daily quota usage
track_quota() {
    local cost="$1"
    local endpoint="$2"

    mkdir -p "$YT_CACHE_DIR"

    local current=0
    if [[ -f "$YT_QUOTA_FILE" ]]; then
        current=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$YT_QUOTA_FILE','utf8')).total||0)" 2>/dev/null || echo "0")
    fi

    local new_total=$((current + cost))
    node -e "
const fs = require('fs');
const file = '$YT_QUOTA_FILE';
let data = {};
try { data = JSON.parse(fs.readFileSync(file, 'utf8')); } catch(e) { data = {total:0, calls:[]}; }
data.total = $new_total;
data.calls = data.calls || [];
data.calls.push({endpoint:'$endpoint', cost:$cost, time:new Date().toISOString()});
fs.writeFileSync(file, JSON.stringify(data, null, 2));
" 2>/dev/null
    return 0
}

# Extract video ID from URL or return as-is
extract_video_id() {
    local input="$1"
    if [[ "$input" =~ v=([a-zA-Z0-9_-]{11}) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$input" =~ youtu\.be/([a-zA-Z0-9_-]{11}) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^[a-zA-Z0-9_-]{11}$ ]]; then
        echo "$input"
    else
        echo "$input"
    fi
    return 0
}

# Extract channel handle from URL or return as-is
extract_channel_handle() {
    local input="$1"
    # Remove URL prefix if present
    if [[ "$input" =~ youtube\.com/@([a-zA-Z0-9._-]+) ]]; then
        echo "@${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^@ ]]; then
        echo "$input"
    else
        echo "@$input"
    fi
    return 0
}

# ============================================================================
# Commands
# ============================================================================

# Get channel metadata and statistics
cmd_channel() {
    local input="${1:?Channel handle, ID, or URL required}"
    local format="${2:-pretty}"

    local params=""
    local parts="snippet,statistics,contentDetails,brandingSettings"

    # Detect input type
    if [[ "$input" =~ ^UC[a-zA-Z0-9_-]{22}$ ]]; then
        params="part=$parts&id=$input"
    elif [[ "$input" =~ ^@ ]] || [[ "$input" =~ youtube\.com/@ ]]; then
        local handle
        handle=$(extract_channel_handle "$input")
        params="part=$parts&forHandle=${handle#@}"
    else
        params="part=$parts&forHandle=$input"
    fi

    local response
    response=$(yt_api_request "channels" "$params" 1) || return 1

    if [[ "$format" == "json" ]]; then
        echo "$response"
    else
        echo "$response" | node -e "
process.stdin.on('data', d => {
    const data = JSON.parse(d);
    if (!data.items || data.items.length === 0) {
        console.log('Channel not found');
        process.exit(1);
    }
    const ch = data.items[0];
    const s = ch.snippet;
    const st = ch.statistics;
    const cd = ch.contentDetails;

    console.log('Channel: ' + s.title);
    console.log('Handle:  @' + (s.customUrl || 'N/A'));
    console.log('ID:      ' + ch.id);
    console.log('Created: ' + s.publishedAt?.substring(0, 10));
    console.log('');
    console.log('Subscribers: ' + Number(st.subscriberCount).toLocaleString());
    console.log('Total Views: ' + Number(st.viewCount).toLocaleString());
    console.log('Videos:      ' + Number(st.videoCount).toLocaleString());
    console.log('');
    console.log('Uploads Playlist: ' + cd?.relatedPlaylists?.uploads);
    console.log('');
    console.log('Description:');
    console.log((s.description || 'N/A').substring(0, 500));
});
"
    fi
    return 0
}

# List all videos from a channel (via uploads playlist)
cmd_videos() {
    local input="${1:?Channel handle, ID, or URL required}"
    local limit="${2:-50}"
    local format="${3:-pretty}"

    # First get the channel's uploads playlist ID
    local channel_json
    channel_json=$(cmd_channel "$input" "json") || return 1

    local uploads_playlist
    uploads_playlist=$(echo "$channel_json" | node -e "
process.stdin.on('data', d => {
    const data = JSON.parse(d);
    if (data.items?.[0]?.contentDetails?.relatedPlaylists?.uploads) {
        console.log(data.items[0].contentDetails.relatedPlaylists.uploads);
    } else {
        console.error('No uploads playlist found');
        process.exit(1);
    }
});
" 2>/dev/null) || {
        print_error "Could not find uploads playlist for channel"
        return 1
    }

    print_info "Fetching videos from playlist: $uploads_playlist"

    local all_video_ids=()
    local page_token=""
    local fetched=0

    while [[ $fetched -lt $limit ]]; do
        local page_size=$((limit - fetched))
        if [[ $page_size -gt 50 ]]; then
            page_size=50
        fi

        local params="part=snippet,contentDetails&playlistId=$uploads_playlist&maxResults=$page_size"
        if [[ -n "$page_token" ]]; then
            params="$params&pageToken=$page_token"
        fi

        local response
        response=$(yt_api_request "playlistItems" "$params" 1) || return 1

        # Extract video IDs and basic info
        local page_data
        page_data=$(echo "$response" | node -e "
process.stdin.on('data', d => {
    const data = JSON.parse(d);
    const items = (data.items || []).map(i => ({
        videoId: i.contentDetails?.videoId || i.snippet?.resourceId?.videoId,
        title: i.snippet?.title,
        publishedAt: i.snippet?.publishedAt?.substring(0, 10),
        position: i.snippet?.position
    }));
    console.log(JSON.stringify({
        items: items,
        nextPageToken: data.nextPageToken || '',
        totalResults: data.pageInfo?.totalResults || 0
    }));
});
" 2>/dev/null) || break

        local video_ids
        video_ids=$(echo "$page_data" | node -e "process.stdin.on('data',d=>JSON.parse(d).items.forEach(i=>console.log(i.videoId)))" 2>/dev/null)

        while IFS= read -r vid; do
            [[ -n "$vid" ]] && all_video_ids+=("$vid")
        done <<< "$video_ids"

        fetched=${#all_video_ids[@]}

        page_token=$(echo "$page_data" | node -e "process.stdin.on('data',d=>console.log(JSON.parse(d).nextPageToken))" 2>/dev/null)
        if [[ -z "$page_token" ]]; then
            break
        fi
    done

    if [[ ${#all_video_ids[@]} -eq 0 ]]; then
        print_warning "No videos found"
        return 0
    fi

    # Fetch full video details in batches of 50
    local all_videos="[]"
    local i=0
    while [[ $i -lt ${#all_video_ids[@]} ]]; do
        local batch=()
        local j=0
        while [[ $j -lt 50 ]] && [[ $((i + j)) -lt ${#all_video_ids[@]} ]]; do
            batch+=("${all_video_ids[$((i + j))]}")
            j=$((j + 1))
        done

        local ids_param
        ids_param=$(IFS=,; echo "${batch[*]}")

        local video_response
        video_response=$(yt_api_request "videos" "part=snippet,statistics,contentDetails&id=$ids_param" 1) || break

        all_videos=$(node -e "
const existing = $all_videos;
const newData = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
const merged = existing.concat(newData.items || []);
console.log(JSON.stringify(merged));
" <<< "$video_response" 2>/dev/null)

        i=$((i + 50))
    done

    if [[ "$format" == "json" ]]; then
        echo "$all_videos"
    else
        echo "$all_videos" | node -e "
process.stdin.on('data', d => {
    const videos = JSON.parse(d);
    console.log('Videos found: ' + videos.length);
    console.log('');
    console.log('Views       | Likes    | Date       | Duration | Title');
    console.log('------------|----------|------------|----------|------');
    videos.forEach(v => {
        const views = Number(v.statistics?.viewCount || 0).toLocaleString().padStart(11);
        const likes = Number(v.statistics?.likeCount || 0).toLocaleString().padStart(8);
        const date = (v.snippet?.publishedAt || '').substring(0, 10);
        const dur = v.contentDetails?.duration?.replace('PT','').replace('H','h').replace('M','m').replace('S','s') || 'N/A';
        const title = (v.snippet?.title || 'N/A').substring(0, 60);
        console.log(views + ' | ' + likes + ' | ' + date + ' | ' + dur.padEnd(8) + ' | ' + title);
    });
});
"
    fi
    return 0
}

# Get video details
cmd_video() {
    local input="${1:?Video ID or URL required}"
    local format="${2:-pretty}"

    local video_id
    video_id=$(extract_video_id "$input")

    local response
    response=$(yt_api_request "videos" "part=snippet,statistics,contentDetails,topicDetails&id=$video_id" 1) || return 1

    if [[ "$format" == "json" ]]; then
        echo "$response"
    else
        echo "$response" | node -e "
process.stdin.on('data', d => {
    const data = JSON.parse(d);
    if (!data.items || data.items.length === 0) {
        console.log('Video not found');
        process.exit(1);
    }
    const v = data.items[0];
    const s = v.snippet;
    const st = v.statistics;
    const cd = v.contentDetails;

    console.log('Title:       ' + s.title);
    console.log('Channel:     ' + s.channelTitle + ' (' + s.channelId + ')');
    console.log('Published:   ' + s.publishedAt?.substring(0, 10));
    console.log('Duration:    ' + (cd.duration || 'N/A').replace('PT','').replace('H','h ').replace('M','m ').replace('S','s'));
    console.log('');
    console.log('Views:       ' + Number(st.viewCount || 0).toLocaleString());
    console.log('Likes:       ' + Number(st.likeCount || 0).toLocaleString());
    console.log('Comments:    ' + Number(st.commentCount || 0).toLocaleString());
    console.log('');
    const tags = (s.tags || []).slice(0, 15).join(', ');
    console.log('Tags:        ' + (tags || 'None'));
    console.log('Category:    ' + (s.categoryId || 'N/A'));
    console.log('');
    console.log('Description:');
    console.log((s.description || 'N/A').substring(0, 500));
});
"
    fi
    return 0
}

# Search YouTube
cmd_search() {
    local query="${1:?Search query required}"
    local type="${2:-video}"
    local limit="${3:-10}"
    local format="${4:-pretty}"

    local params="part=snippet&q=$(urlencode "$query")&type=$type&maxResults=$limit&order=relevance"

    local response
    response=$(yt_api_request "search" "$params" 100) || return 1

    if [[ "$format" == "json" ]]; then
        echo "$response"
    else
        echo "$response" | node -e "
process.stdin.on('data', d => {
    const data = JSON.parse(d);
    const items = data.items || [];
    console.log('Results for: \"' + '$query' + '\" (' + items.length + ' found)');
    console.log('');
    items.forEach((item, i) => {
        const s = item.snippet;
        const id = item.id?.videoId || item.id?.channelId || item.id?.playlistId || 'N/A';
        console.log((i+1) + '. ' + s.title);
        console.log('   Channel: ' + s.channelTitle + ' | Published: ' + s.publishedAt?.substring(0, 10));
        console.log('   ID: ' + id + ' | Type: ' + (item.id?.kind || '').split('#')[1]);
        console.log('');
    });
});
"
    fi
    return 0
}

# Extract transcript via yt-dlp
cmd_transcript() {
    local input="${1:?Video ID or URL required}"
    local lang="${2:-en}"

    local video_id
    video_id=$(extract_video_id "$input")
    local url="https://www.youtube.com/watch?v=$video_id"

    if ! command -v yt-dlp &> /dev/null; then
        print_error "yt-dlp is required for transcript extraction"
        print_info "Run: yt-dlp-helper.sh install"
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    yt-dlp \
        --skip-download \
        --write-auto-subs \
        --write-subs \
        --sub-langs "$lang" \
        --convert-subs srt \
        -o "$tmp_dir/transcript.%(ext)s" \
        "$url" 2>/dev/null

    local srt_file
    srt_file=$(find "$tmp_dir" -name "*.srt" -type f | head -1)

    if [[ -n "$srt_file" ]] && [[ -f "$srt_file" ]]; then
        # Convert SRT to plain text (strip timestamps and formatting)
        sed -E '/^[0-9]+$/d; /^[0-9]{2}:[0-9]{2}:[0-9]{2}/d; /^$/d; s/<[^>]*>//g' "$srt_file"
    else
        print_warning "No transcript found for video $video_id (language: $lang)"
        print_info "Try: youtube-helper.sh transcript $video_id all"
    fi

    rm -rf "$tmp_dir"
    return 0
}

# Find trending videos in a niche
cmd_trending() {
    local niche="${1:?Niche/topic required}"
    local limit="${2:-20}"

    print_info "Searching trending videos for: $niche"

    # Search with relevance + recent uploads
    local params="part=snippet&q=$(urlencode "$niche")&type=video&maxResults=$limit&order=viewCount&publishedAfter=$(date -u -v-30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d '30 days ago' +%Y-%m-%dT00:00:00Z 2>/dev/null)"

    local search_response
    search_response=$(yt_api_request "search" "$params" 100) || return 1

    # Get video IDs
    local video_ids
    video_ids=$(echo "$search_response" | node -e "
process.stdin.on('data', d => {
    const items = JSON.parse(d).items || [];
    console.log(items.map(i => i.id?.videoId).filter(Boolean).join(','));
});
" 2>/dev/null)

    if [[ -z "$video_ids" ]]; then
        print_warning "No trending videos found for: $niche"
        return 0
    fi

    # Get full video details
    local video_response
    video_response=$(yt_api_request "videos" "part=snippet,statistics,contentDetails&id=$video_ids" 1) || return 1

    echo "$video_response" | node -e "
process.stdin.on('data', d => {
    const videos = (JSON.parse(d).items || [])
        .sort((a, b) => Number(b.statistics?.viewCount || 0) - Number(a.statistics?.viewCount || 0));

    console.log('Trending in \"$niche\" (last 30 days, sorted by views):');
    console.log('');
    console.log('Views       | Likes    | Comments | Channel                  | Title');
    console.log('------------|----------|----------|--------------------------|------');
    videos.forEach(v => {
        const views = Number(v.statistics?.viewCount || 0).toLocaleString().padStart(11);
        const likes = Number(v.statistics?.likeCount || 0).toLocaleString().padStart(8);
        const comments = Number(v.statistics?.commentCount || 0).toLocaleString().padStart(8);
        const channel = (v.snippet?.channelTitle || 'N/A').substring(0, 24).padEnd(24);
        const title = (v.snippet?.title || 'N/A').substring(0, 50);
        console.log(views + ' | ' + likes + ' | ' + comments + ' | ' + channel + ' | ' + title);
    });
});
"
    return 0
}

# Compare multiple channels side-by-side
cmd_competitors() {
    if [[ $# -lt 1 ]]; then
        print_error "At least one channel handle required"
        print_info "Usage: youtube-helper.sh competitors @channel1 @channel2 @channel3"
        return 1
    fi

    local channels=("$@")
    local all_data="[]"

    for ch in "${channels[@]}"; do
        print_info "Fetching: $ch"
        local ch_json
        ch_json=$(cmd_channel "$ch" "json") || continue

        all_data=$(node -e "
const existing = $all_data;
const newData = JSON.parse(require('fs').readFileSync('/dev/stdin','utf8'));
if (newData.items?.[0]) existing.push(newData.items[0]);
console.log(JSON.stringify(existing));
" <<< "$ch_json" 2>/dev/null)
    done

    echo "$all_data" | node -e "
process.stdin.on('data', d => {
    const channels = JSON.parse(d);
    if (channels.length === 0) {
        console.log('No channels found');
        return;
    }

    console.log('Channel Comparison (' + channels.length + ' channels):');
    console.log('');

    // Header
    const nameWidth = 25;
    console.log('Channel'.padEnd(nameWidth) + ' | Subscribers  | Total Views     | Videos | Created');
    console.log('-'.repeat(nameWidth) + '-|--------------|-----------------|--------|--------');

    // Sort by subscribers
    channels.sort((a, b) => Number(b.statistics?.subscriberCount || 0) - Number(a.statistics?.subscriberCount || 0));

    channels.forEach(ch => {
        const name = (ch.snippet?.title || 'N/A').substring(0, nameWidth - 1).padEnd(nameWidth);
        const subs = Number(ch.statistics?.subscriberCount || 0).toLocaleString().padStart(12);
        const views = Number(ch.statistics?.viewCount || 0).toLocaleString().padStart(15);
        const vids = String(ch.statistics?.videoCount || 0).padStart(6);
        const created = (ch.snippet?.publishedAt || '').substring(0, 10);
        console.log(name + ' | ' + subs + ' | ' + views + ' | ' + vids + ' | ' + created);
    });

    // Derived metrics
    console.log('');
    console.log('Derived Metrics:');
    console.log('Channel'.padEnd(nameWidth) + ' | Views/Video  | Views/Sub');
    console.log('-'.repeat(nameWidth) + '-|--------------|----------');

    channels.forEach(ch => {
        const name = (ch.snippet?.title || 'N/A').substring(0, nameWidth - 1).padEnd(nameWidth);
        const views = Number(ch.statistics?.viewCount || 0);
        const vids = Number(ch.statistics?.videoCount || 1);
        const subs = Number(ch.statistics?.subscriberCount || 1);
        const vpv = Math.round(views / vids).toLocaleString().padStart(12);
        const vps = (views / subs).toFixed(1).padStart(9);
        console.log(name + ' | ' + vpv + ' | ' + vps);
    });
});
"
    return 0
}

# Show quota usage
cmd_quota() {
    if [[ ! -f "$YT_QUOTA_FILE" ]]; then
        print_info "No API calls made today"
        print_info "Daily quota: 10,000 units"
        return 0
    fi

    node -e "
const data = JSON.parse(require('fs').readFileSync('$YT_QUOTA_FILE', 'utf8'));
console.log('YouTube API Quota Usage (today):');
console.log('');
console.log('Total used:  ' + data.total + ' / 10,000 units');
console.log('Remaining:   ' + (10000 - data.total) + ' units');
console.log('API calls:   ' + (data.calls || []).length);
console.log('');

// Group by endpoint
const byEndpoint = {};
(data.calls || []).forEach(c => {
    byEndpoint[c.endpoint] = (byEndpoint[c.endpoint] || 0) + c.cost;
});
console.log('By endpoint:');
Object.entries(byEndpoint).sort((a,b) => b[1] - a[1]).forEach(([ep, cost]) => {
    console.log('  ' + ep.padEnd(30) + ' ' + cost + ' units');
});
"
    return 0
}

# Test authentication
cmd_auth_test() {
    print_info "Testing YouTube Data API authentication..."

    local token
    token=$(get_access_token) || {
        print_error "Authentication failed"
        return 1
    }

    print_success "Authentication successful (token obtained)"

    # Test with a simple API call
    local response
    response=$(yt_api_request "channels" "part=snippet&forHandle=youtube" 1) || {
        print_error "API call failed despite valid token"
        return 1
    }

    local channel_name
    channel_name=$(echo "$response" | node -e "process.stdin.on('data',d=>{const i=JSON.parse(d).items;console.log(i?.[0]?.snippet?.title||'unknown')})" 2>/dev/null)

    print_success "API call successful (fetched: $channel_name)"

    local key_file
    key_file=$(resolve_sa_key)
    local sa_email
    sa_email=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$key_file','utf8')).client_email)" 2>/dev/null)
    print_info "Service account: $sa_email"

    return 0
}

# URL encode helper
urlencode() {
    local string="$1"
    node -e "console.log(encodeURIComponent('$string'))" 2>/dev/null
    return 0
}

# Show help
show_help() {
    cat << 'EOF'
YouTube Data API Helper - Channel & Video Research

Usage: youtube-helper.sh <command> [args] [options]

Commands:
  channel <handle|id|url>       Get channel metadata and statistics
  videos <handle|id|url> [n]    List videos from a channel (default: 50)
  video <video_id|url>          Get video details and statistics
  search <query> [type] [n]     Search YouTube (type: video|channel, default: 10)
  transcript <video_id|url>     Extract video transcript (via yt-dlp)
  trending <niche> [n]          Find trending videos in a niche (last 30 days)
  competitors <h1> <h2> [...]   Compare multiple channels side-by-side
  quota                         Show estimated API quota usage today
  auth-test                     Test service account authentication
  help                          Show this help message

Output format:
  Add "json" as the last argument for raw JSON output:
    youtube-helper.sh channel @mkbhd json
    youtube-helper.sh videos @mkbhd 100 json

Quota costs (10,000 units/day free):
  channel, videos, video:  1 unit per request
  search, trending:        100 units per request (use sparingly)

Examples:
  youtube-helper.sh channel @mkbhd
  youtube-helper.sh videos @mkbhd 200
  youtube-helper.sh video "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
  youtube-helper.sh search "AI coding tools" video 20
  youtube-helper.sh transcript dQw4w9WgXcQ
  youtube-helper.sh trending "machine learning" 15
  youtube-helper.sh competitors @mkbhd @unboxtherapy @LinusTechTips
  youtube-helper.sh quota

Authentication:
  Uses Google Cloud service account (YouTube Data API v3).
  Key file: ~/.config/aidevops/keys/evergreen-je-sa.json
  Set via: export GCP_SA_KEY_FILE="path/to/key.json"
  Test:    youtube-helper.sh auth-test
EOF
    return 0
}

# Main entry point
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        "channel")
            cmd_channel "$@"
            ;;
        "videos")
            cmd_videos "$@"
            ;;
        "video")
            cmd_video "$@"
            ;;
        "search")
            cmd_search "$@"
            ;;
        "transcript")
            cmd_transcript "$@"
            ;;
        "trending")
            cmd_trending "$@"
            ;;
        "competitors")
            cmd_competitors "$@"
            ;;
        "quota")
            cmd_quota
            ;;
        "auth-test")
            cmd_auth_test
            ;;
        "help"|"-h"|"--help"|"")
            show_help
            ;;
        *)
            print_error "$ERROR_UNKNOWN_COMMAND $command"
            show_help
            return 1
            ;;
    esac
}

main "$@"
