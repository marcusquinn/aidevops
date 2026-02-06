#!/usr/bin/env bash
# Anti-detect browser helper - setup, profile management, launch, and testing
# Usage: anti-detect-helper.sh [command] [options]
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "$HOME/.config/aidevops/credentials.sh" ]] && source "$HOME/.config/aidevops/credentials.sh"

PROFILES_DIR="$HOME/.aidevops/.agent-workspace/browser-profiles"
VENV_DIR="$HOME/.aidevops/anti-detect-venv"
# Script directory (for relative path references)
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    cat <<'EOF'
Anti-Detect Browser Helper

USAGE:
    anti-detect-helper.sh <command> [options]

COMMANDS:
    setup               Install anti-detect tools (Camoufox, rebrowser-patches)
    launch              Launch browser with anti-detect profile
    profile             Manage browser profiles (create/list/show/delete/clone)
    cookies             Manage profile cookies (export/import/clear)
    proxy               Proxy operations (check/check-all/dns-check)
    test                Test detection status against bot-detection sites
    warmup              Warm up a profile with browsing history
    status              Show installation status of all tools

SETUP OPTIONS:
    --engine <type>     Engine to setup: all|chromium|firefox (default: all)

LAUNCH OPTIONS:
    --profile <name>    Profile to launch (required unless --disposable)
    --engine <type>     Browser engine: chromium|firefox|mullvad|random (default: firefox)
    --headless          Run headless (default: headed)
    --disposable        Single-use profile (auto-deleted)
    --url <url>         URL to navigate to after launch

PROFILE SUBCOMMANDS:
    create <name>       Create new profile
    list                List all profiles
    show <name>         Show profile details
    delete <name>       Delete profile
    clone <src> <dst>   Clone profile
    update <name>       Update profile settings
    bulk-create         Create multiple profiles
    export              Export profiles to archive
    import              Import profiles from archive

PROFILE CREATE OPTIONS:
    --type <type>       Profile type: persistent|clean|warm|disposable (default: persistent)
    --proxy <url>       Assign proxy URL
    --os <os>           Target OS: windows|macos|linux (default: random)
    --browser <type>    Browser type: firefox|chrome (default: firefox)
    --notes <text>      Profile notes

TEST OPTIONS:
    --profile <name>    Profile to test (uses its fingerprint/proxy)
    --engine <type>     Engine: chromium|firefox (default: firefox)
    --sites <list>      Comma-separated test sites (default: all)

EXAMPLES:
    anti-detect-helper.sh setup
    anti-detect-helper.sh profile create "my-account" --type persistent --proxy "http://user:pass@host:port"
    anti-detect-helper.sh launch --profile "my-account" --headless
    anti-detect-helper.sh test --profile "my-account"
    anti-detect-helper.sh warmup "my-account" --duration 30m
    anti-detect-helper.sh profile list
EOF
    return 0
}

# ─── Setup ───────────────────────────────────────────────────────────────────

setup_all() {
    local engine="${1:-all}"

    echo -e "${BLUE}Setting up anti-detect tools (engine: $engine)...${NC}"

    # Create directories
    mkdir -p "$PROFILES_DIR"/{persistent,clean/default,warmup,disposable}
    mkdir -p "$VENV_DIR"

    if [[ "$engine" == "all" || "$engine" == "firefox" ]]; then
        setup_camoufox
    fi

    if [[ "$engine" == "all" || "$engine" == "chromium" ]]; then
        setup_rebrowser
    fi

    # Create default clean profile template
    if [[ ! -f "$PROFILES_DIR/clean/default/fingerprint.json" ]]; then
        echo '{"mode": "random"}' > "$PROFILES_DIR/clean/default/fingerprint.json"
    fi

    # Create profiles index if not exists
    if [[ ! -f "$PROFILES_DIR/profiles.json" ]]; then
        echo '{"profiles": []}' > "$PROFILES_DIR/profiles.json"
    fi

    echo -e "${GREEN}Setup complete.${NC}"
    return 0
}

setup_camoufox() {
    echo -e "${BLUE}Setting up Camoufox (Firefox anti-detect)...${NC}"

    # Create/use venv
    if [[ ! -d "$VENV_DIR" ]]; then
        python3 -m venv "$VENV_DIR"
    fi

    # Install camoufox + browserforge
    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate"
    pip install --quiet --upgrade camoufox browserforge 2>/dev/null || {
        echo -e "${YELLOW}Warning: pip install failed. Trying with --break-system-packages...${NC}"
        pip install --quiet --upgrade --break-system-packages camoufox browserforge 2>/dev/null || true
    }

    # Fetch browser binary
    python3 -m camoufox fetch 2>/dev/null || {
        echo -e "${YELLOW}Warning: Camoufox binary fetch failed. May need manual download.${NC}"
    }

    deactivate 2>/dev/null || true
    echo -e "${GREEN}Camoufox installed.${NC}"
    return 0
}

setup_rebrowser() {
    echo -e "${BLUE}Setting up rebrowser-patches (Chromium stealth)...${NC}"

    # Check if playwright is installed
    if ! command -v npx &>/dev/null; then
        echo -e "${RED}Error: npx not found. Install Node.js first.${NC}" >&2
        return 1
    fi

    # Patch playwright
    npx rebrowser-patches@latest patch 2>/dev/null || {
        echo -e "${YELLOW}Warning: rebrowser-patches failed. Playwright may not be installed.${NC}"
        echo -e "${YELLOW}Run: npm install playwright && npx rebrowser-patches patch${NC}"
    }

    echo -e "${GREEN}rebrowser-patches applied.${NC}"
    return 0
}

# ─── Profile Management ─────────────────────────────────────────────────────

validate_profile_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo -e "${RED}Error: Profile name cannot be empty.${NC}" >&2
        return 1
    fi
    if [[ "$name" =~ [/\\] || "$name" == *..* ]]; then
        echo -e "${RED}Error: Profile name cannot contain '/', '\\', or '..'.${NC}" >&2
        return 1
    fi
    if [[ "$name" == -* ]]; then
        echo -e "${RED}Error: Profile name cannot start with '-'.${NC}" >&2
        return 1
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo -e "${RED}Error: Profile name must only contain letters, numbers, '.', '_', or '-'.${NC}" >&2
        return 1
    fi
    if [[ ${#name} -gt 64 ]]; then
        echo -e "${RED}Error: Profile name must be 64 characters or fewer.${NC}" >&2
        return 1
    fi
    return 0
}

profile_create() {
    local name="$1"
    local profile_type="persistent"
    local proxy=""
    local target_os="random"
    local browser_type="firefox"
    local notes=""

    local arg
    shift
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --type) profile_type="$2"; shift 2 ;;
            --proxy) proxy="$2"; shift 2 ;;
            --os) target_os="$2"; shift 2 ;;
            --browser) browser_type="$2"; shift 2 ;;
            --notes) notes="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    validate_profile_name "$name" || return 1

    # Map profile type to directory name
    local dir_type="$profile_type"
    [[ "$profile_type" == "warm" ]] && dir_type="warmup"

    local profile_dir="$PROFILES_DIR/$dir_type/$name"

    if [[ -d "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$name' already exists.${NC}" >&2
        return 1
    fi

    mkdir -p "$profile_dir"

    # Generate fingerprint
    local fingerprint
    fingerprint=$(generate_fingerprint "$target_os" "$browser_type")
    echo "$fingerprint" > "$profile_dir/fingerprint.json"

    # Save proxy config
    if [[ -n "$proxy" ]]; then
        local proxy_json
        proxy_json=$(parse_proxy_url "$proxy")
        echo "$proxy_json" > "$profile_dir/proxy.json"
    fi

    # Save metadata
    cat > "$profile_dir/metadata.json" <<METADATA
{
  "name": "$name",
  "type": "$profile_type",
  "browser": "$browser_type",
  "target_os": "$target_os",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_used": null,
  "notes": "$notes"
}
METADATA

    # Update profiles index
    update_profiles_index "$name" "$profile_type" "add"

    echo -e "${GREEN}Profile '$name' created (type: $profile_type, os: $target_os, browser: $browser_type).${NC}"
    return 0
}

profile_list() {
    local format="${1:-text}"

    if [[ "$format" == "json" ]]; then
        cat "$PROFILES_DIR/profiles.json"
        return 0
    fi

    echo -e "${BLUE}Browser Profiles:${NC}"
    echo "─────────────────────────────────────────────────────────────"
    printf "%-20s %-12s %-10s %-10s %s\n" "NAME" "TYPE" "OS" "ENGINE" "PROXY"
    echo "─────────────────────────────────────────────────────────────"

    for type_dir in "$PROFILES_DIR"/{persistent,clean,warmup,disposable}/*/; do
        [[ -d "$type_dir" ]] || continue
        local name
        name=$(basename "$type_dir")
        [[ "$name" == "default" ]] && continue

        local metadata="$type_dir/metadata.json"
        [[ -f "$metadata" ]] || continue

        local ptype pos pengine pproxy
        ptype=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('type','?'))" 2>/dev/null || echo "?")
        pos=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('target_os','?'))" 2>/dev/null || echo "?")
        pengine=$(python3 -c "import json; d=json.load(open('$metadata')); print(d.get('browser','?'))" 2>/dev/null || echo "?")

        if [[ -f "$type_dir/proxy.json" ]]; then
            pproxy="yes"
        else
            pproxy="none"
        fi

        printf "%-20s %-12s %-10s %-10s %s\n" "$name" "$ptype" "$pos" "$pengine" "$pproxy"
    done
    return 0
}

profile_show() {
    local name="$1"
    local profile_dir
    profile_dir=$(find_profile_dir "$name")

    if [[ -z "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}Profile: $name${NC}"
    echo "─────────────────────────────────────────"

    if [[ -f "$profile_dir/metadata.json" ]]; then
        echo -e "${YELLOW}Metadata:${NC}"
        python3 -c "import json; d=json.load(open('$profile_dir/metadata.json')); [print(f'  {k}: {v}') for k,v in d.items()]" 2>/dev/null
    fi

    if [[ -f "$profile_dir/fingerprint.json" ]]; then
        echo -e "${YELLOW}Fingerprint:${NC}"
        python3 -c "import json; d=json.load(open('$profile_dir/fingerprint.json')); [print(f'  {k}: {v}') for k,v in list(d.items())[:10]]" 2>/dev/null
    fi

    if [[ -f "$profile_dir/proxy.json" ]]; then
        echo -e "${YELLOW}Proxy:${NC}"
        python3 -c "import json; d=json.load(open('$profile_dir/proxy.json')); print(f'  server: {d.get(\"server\",\"?\")}')" 2>/dev/null
    fi

    if [[ -f "$profile_dir/storage-state.json" ]]; then
        local cookie_count
        cookie_count=$(python3 -c "import json; d=json.load(open('$profile_dir/storage-state.json')); print(len(d.get('cookies',[])))" 2>/dev/null || echo "0")
        echo -e "${YELLOW}State:${NC}"
        echo "  cookies: $cookie_count saved"
    fi

    return 0
}

profile_delete() {
    local name="$1"
    validate_profile_name "$name" || return 1
    local profile_dir
    profile_dir=$(find_profile_dir "$name")

    if [[ -z "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
        return 1
    fi

    rm -rf "$profile_dir"
    update_profiles_index "$name" "" "remove"
    echo -e "${GREEN}Profile '$name' deleted.${NC}"
    return 0
}

profile_clone() {
    local src="$1"
    local dst="$2"
    local src_dir
    src_dir=$(find_profile_dir "$src")

    if [[ -z "$src_dir" ]]; then
        echo -e "${RED}Error: Source profile '$src' not found.${NC}" >&2
        return 1
    fi

    local parent_dir
    parent_dir=$(dirname "$src_dir")
    local dst_dir="$parent_dir/$dst"

    if [[ -d "$dst_dir" ]]; then
        echo -e "${RED}Error: Destination profile '$dst' already exists.${NC}" >&2
        return 1
    fi

    cp -r "$src_dir" "$dst_dir"

    # Update metadata name
    if [[ -f "$dst_dir/metadata.json" ]]; then
        python3 -c "
import json
with open('$dst_dir/metadata.json', 'r+') as f:
    d = json.load(f)
    d['name'] = '$dst'
    d['created'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
    fi

    # Generate new fingerprint (don't share with source)
    local target_os
    target_os=$(python3 -c "import json; print(json.load(open('$dst_dir/metadata.json')).get('target_os','random'))" 2>/dev/null || echo "random")
    local browser_type
    browser_type=$(python3 -c "import json; print(json.load(open('$dst_dir/metadata.json')).get('browser','firefox'))" 2>/dev/null || echo "firefox")
    generate_fingerprint "$target_os" "$browser_type" > "$dst_dir/fingerprint.json"

    # Remove saved state (fresh start)
    rm -f "$dst_dir/storage-state.json" "$dst_dir/cookies.json"
    rm -rf "$dst_dir/user-data"

    update_profiles_index "$dst" "persistent" "add"
    echo -e "${GREEN}Profile '$src' cloned to '$dst' (new fingerprint, no saved state).${NC}"
    return 0
}

profile_update() {
    local name="$1"
    shift
    local profile_dir
    profile_dir=$(find_profile_dir "$name")

    if [[ -z "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$name' not found.${NC}" >&2
        return 1
    fi

    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --proxy)
                local proxy_json
                proxy_json=$(parse_proxy_url "$2")
                echo "$proxy_json" > "$profile_dir/proxy.json"
                echo -e "${GREEN}Proxy updated for '$name'.${NC}"
                shift 2
                ;;
            --notes)
                PROFILE_NOTES="$2" PROFILE_META="$profile_dir/metadata.json" python3 -c "
import json, os
meta_path = os.environ['PROFILE_META']
notes_val = os.environ['PROFILE_NOTES']
with open(meta_path, 'r+') as f:
    d = json.load(f)
    d['notes'] = notes_val
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
                echo -e "${GREEN}Notes updated for '$name'.${NC}"
                shift 2
                ;;
            *) shift ;;
        esac
    done
    return 0
}

# ─── Launch ──────────────────────────────────────────────────────────────────

launch_browser() {
    local profile_name=""
    local engine="firefox"
    local headless=""
    local disposable=""
    local url=""

    local arg
    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --profile) profile_name="$2"; shift 2 ;;
            --engine) engine="$2"; shift 2 ;;
            --headless) headless="true"; shift ;;
            --disposable) disposable="true"; shift ;;
            --url) url="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$profile_name" && -z "$disposable" ]]; then
        echo -e "${RED}Error: --profile <name> or --disposable required.${NC}" >&2
        return 1
    fi

    if [[ "$engine" == "random" ]]; then
        engine=$(python3 -c "import random; print(random.choice(['chromium','firefox','mullvad']))")
    fi

    # Update last_used timestamp
    if [[ -n "$profile_name" ]]; then
        local profile_dir
        profile_dir=$(find_profile_dir "$profile_name")
        if [[ -n "$profile_dir" && -f "$profile_dir/metadata.json" ]]; then
            python3 -c "
import json
with open('$profile_dir/metadata.json', 'r+') as f:
    d = json.load(f)
    d['last_used'] = '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
    f.seek(0)
    json.dump(d, f, indent=2)
    f.truncate()
" 2>/dev/null
        fi
    fi

    if [[ "$engine" == "firefox" ]]; then
        launch_camoufox "$profile_name" "$headless" "$url" "$disposable"
    elif [[ "$engine" == "mullvad" ]]; then
        launch_mullvad "$profile_name" "$headless" "$url" "$disposable"
    else
        launch_chromium_stealth "$profile_name" "$headless" "$url" "$disposable"
    fi
    return $?
}

launch_camoufox() {
    local profile_name="$1"
    local headless="$2"
    local url="$3"
    local disposable="$4"

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate" 2>/dev/null || {
        echo -e "${RED}Error: Camoufox venv not found. Run: anti-detect-helper.sh setup${NC}" >&2
        return 1
    }

    local profile_dir=""
    local config_arg=""
    local proxy_arg=""

    if [[ -n "$profile_name" ]]; then
        profile_dir=$(find_profile_dir "$profile_name")
        if [[ -n "$profile_dir" && -f "$profile_dir/fingerprint.json" ]]; then
            config_arg="$profile_dir/fingerprint.json"
        fi
        if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
            proxy_arg="$profile_dir/proxy.json"
        fi
    fi

    local headless_flag="True"
    [[ "$headless" != "true" ]] && headless_flag="False"

    local target_url="${url:-https://www.browserscan.net/bot-detection}"

    python3 -c "
import json
from camoufox.sync_api import Camoufox

profile_config = {}
proxy = None
headless = $headless_flag

config_file = '$config_arg'
proxy_file = '$proxy_arg'

if config_file:
    with open(config_file) as f:
        profile_config = json.load(f)

if proxy_file:
    with open(proxy_file) as f:
        proxy = json.load(f)

# Build Camoufox kwargs from profile config
kwargs = {'headless': headless}

# Pass OS constraint to BrowserForge
os_list = profile_config.get('os')
if os_list:
    kwargs['os'] = os_list

# Pass screen constraints as Screen object
screen_config = profile_config.get('screen')
if screen_config:
    from browserforge.fingerprints import Screen
    kwargs['screen'] = Screen(
        max_width=screen_config.get('maxWidth', 1920),
        max_height=screen_config.get('maxHeight', 1080),
    )

if proxy:
    kwargs['proxy'] = proxy
    kwargs['geoip'] = True

print(f'Launching Camoufox (headless={headless})...')
with Camoufox(**kwargs) as browser:
    page = browser.new_page()
    page.goto('$target_url', timeout=30000)
    print(f'Navigated to: {page.url}')
    print(f'Title: {page.title()}')

    # Save state only for persistent/warm profiles (not clean/disposable)
    profile_dir = '$profile_dir'
    if profile_dir and '$disposable' != 'true':
        import os.path
        profile_type = os.path.basename(os.path.dirname(profile_dir))
        if profile_type in ('persistent', 'warmup'):
            context = browser.contexts[0]
            cookies = context.cookies()
            state = {'cookies': cookies, 'origins': []}
            with open(f'{profile_dir}/storage-state.json', 'w') as f:
                json.dump(state, f, indent=2)
            print(f'State saved ({len(cookies)} cookies)')
        else:
            print(f'Clean profile - state not saved')

    if not headless:
        input('Press Enter to close browser...')
" 2>&1

    deactivate 2>/dev/null || true
    return 0
}

launch_mullvad() {
    local profile_name="$1"
    local headless="$2"
    local url="$3"
    local disposable="$4"

    # Find Mullvad Browser executable
    local mullvad_path=""
    if [[ -f "/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser" ]]; then
        mullvad_path="/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser"
    elif [[ -f "/usr/bin/mullvad-browser" ]]; then
        mullvad_path="/usr/bin/mullvad-browser"
    elif [[ -f "$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser" ]]; then
        mullvad_path="$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser"
    elif [[ -f "/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe" ]]; then
        mullvad_path="/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe"
    else
        echo -e "${RED}Error: Mullvad Browser not found. Install from https://mullvad.net/browser${NC}" >&2
        return 1
    fi

    local profile_dir=""
    local user_data_dir=""
    local proxy_server=""

    if [[ -n "$profile_name" ]]; then
        profile_dir=$(find_profile_dir "$profile_name")
        if [[ -n "$profile_dir" ]]; then
            user_data_dir="$profile_dir/mullvad-data"
            mkdir -p "$user_data_dir"
        fi
        if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
            proxy_server=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('server',''))" 2>/dev/null)
        fi
    fi

    local headless_flag="true"
    [[ "$headless" != "true" ]] && headless_flag="false"

    local target_url="${url:-https://www.browserscan.net/bot-detection}"

    echo -e "${BLUE}Launching Mullvad Browser (headless=$headless_flag)...${NC}"
    echo -e "${YELLOW}Note: Mullvad Browser uses Tor Browser's uniform fingerprint (no rotation).${NC}"
    echo -e "${YELLOW}For fingerprint rotation, use --engine firefox (Camoufox) instead.${NC}"

    # Use Node.js with Playwright Firefox driver
    node -e "
const { firefox } = require('playwright');

(async () => {
    const launchOpts = {
        executablePath: '$mullvad_path',
        headless: $headless_flag,
    };

    const contextOpts = {
        viewport: { width: 1280, height: 800 },  // Mullvad default
    };

    const proxyServer = '$proxy_server';
    if (proxyServer) {
        launchOpts.proxy = { server: proxyServer };
    }

    const userDataDir = '$user_data_dir';
    let browser, context, page;

    if (userDataDir && '$disposable' !== 'true') {
        // Persistent context for Mullvad
        browser = await firefox.launchPersistentContext(userDataDir, {
            ...launchOpts,
            ...contextOpts,
        });
        page = browser.pages()[0] || await browser.newPage();
    } else {
        browser = await firefox.launch(launchOpts);
        context = await browser.newContext(contextOpts);
        page = await context.newPage();
    }

    console.log('Mullvad Browser launched');
    await page.goto('$target_url', { timeout: 30000 });
    console.log('Navigated to:', page.url());
    console.log('Title:', await page.title());

    if (!$headless_flag) {
        await new Promise(r => setTimeout(r, 60000));
    }

    await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
" 2>&1

    return 0
}

launch_chromium_stealth() {
    local profile_name="$1"
    local headless="$2"
    local url="$3"
    local disposable="$4"

    local profile_dir=""
    local user_data_dir=""
    local proxy_server=""

    if [[ -n "$profile_name" ]]; then
        profile_dir=$(find_profile_dir "$profile_name")
        if [[ -n "$profile_dir" ]]; then
            user_data_dir="$profile_dir/user-data"
            mkdir -p "$user_data_dir"
        fi
        if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
            proxy_server=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('server',''))" 2>/dev/null)
            proxy_username=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('username',''))" 2>/dev/null)
            proxy_password=$(python3 -c "import json; print(json.load(open('$profile_dir/proxy.json')).get('password',''))" 2>/dev/null)
        fi
    fi

    local headless_flag="true"
    [[ "$headless" != "true" ]] && headless_flag="false"

    local target_url="${url:-https://www.browserscan.net/bot-detection}"

    # Use Node.js with patched Playwright
    node -e "
const { chromium } = require('playwright');

(async () => {
    const launchOpts = {
        headless: $headless_flag,
        args: [
            '--disable-blink-features=AutomationControlled',
            '--no-first-run',
            '--no-default-browser-check',
        ],
    };

    const contextOpts = {
        viewport: { width: 1920, height: 1080 },
        userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    };

    const proxyServer = '$proxy_server';
    const proxyUsername = '${proxy_username:-}';
    const proxyPassword = '${proxy_password:-}';
    if (proxyServer) {
        const proxyConfig = { server: proxyServer };
        if (proxyUsername) proxyConfig.username = proxyUsername;
        if (proxyPassword) proxyConfig.password = proxyPassword;
        launchOpts.proxy = proxyConfig;
    }

    const userDataDir = '$user_data_dir';
    let browser, page;

    if (userDataDir && '$disposable' !== 'true') {
        browser = await chromium.launchPersistentContext(userDataDir, {
            ...launchOpts,
            ...contextOpts,
        });
        page = browser.pages()[0] || await browser.newPage();
    } else {
        browser = await chromium.launch(launchOpts);
        const context = await browser.newContext(contextOpts);
        page = await context.newPage();
    }

    console.log('Launching Chromium (stealth patched)...');
    await page.goto('$target_url', { timeout: 30000 });
    console.log('Navigated to:', page.url());
    console.log('Title:', await page.title());

    if (!$headless_flag) {
        await new Promise(r => setTimeout(r, 60000));
    }

    await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
" 2>&1

    return 0
}

# ─── Testing ─────────────────────────────────────────────────────────────────

test_detection() {
    local profile_name=""
    local engine="firefox"
    local sites="browserscan,sannysoft"
    local arg

    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --profile) profile_name="$2"; shift 2 ;;
            --engine) engine="$2"; shift 2 ;;
            --sites) sites="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    echo -e "${BLUE}Testing bot detection (engine: $engine)...${NC}"

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate" 2>/dev/null || true

    local config_arg=""
    local proxy_arg=""

    if [[ -n "$profile_name" ]]; then
        local profile_dir
        profile_dir=$(find_profile_dir "$profile_name")
        if [[ -n "$profile_dir" && -f "$profile_dir/fingerprint.json" ]]; then
            config_arg="$profile_dir/fingerprint.json"
        fi
        if [[ -n "$profile_dir" && -f "$profile_dir/proxy.json" ]]; then
            proxy_arg="$profile_dir/proxy.json"
        fi
    fi

    python3 -c "
import json
import sys

test_sites = {
    'browserscan': 'https://www.browserscan.net/bot-detection',
    'sannysoft': 'https://bot.sannysoft.com',
    'incolumitas': 'https://bot.incolumitas.com',
    'pixelscan': 'https://pixelscan.net',
}

selected = '$sites'.split(',')
engine = '$engine'

if engine == 'firefox':
    from camoufox.sync_api import Camoufox

    profile_config = {}
    proxy = None
    config_file = '$config_arg'
    proxy_file = '$proxy_arg'

    if config_file:
        with open(config_file) as f:
            profile_config = json.load(f)

    if proxy_file:
        with open(proxy_file) as f:
            proxy = json.load(f)

    kwargs = {'headless': True}
    os_list = profile_config.get('os')
    if os_list:
        kwargs['os'] = os_list
    screen_config = profile_config.get('screen')
    if screen_config:
        from browserforge.fingerprints import Screen
        kwargs['screen'] = Screen(
            max_width=screen_config.get('maxWidth', 1920),
            max_height=screen_config.get('maxHeight', 1080),
        )
    if proxy:
        kwargs['proxy'] = proxy
        kwargs['geoip'] = True

    with Camoufox(**kwargs) as browser:
        page = browser.new_page()
        results = {}

        for site_key in selected:
            if site_key not in test_sites:
                continue
            url = test_sites[site_key]
            try:
                page.goto(url, timeout=30000)
                page.wait_for_timeout(5000)  # Wait for detection scripts
                title = page.title()
                # Take screenshot for verification
                screenshot_path = f'/tmp/anti-detect-test-{site_key}.png'
                page.screenshot(path=screenshot_path)
                results[site_key] = {'status': 'OK', 'title': title, 'screenshot': screenshot_path}
                print(f'  {site_key}: PASS - {title}')
            except Exception as e:
                results[site_key] = {'status': 'FAIL', 'error': str(e)}
                print(f'  {site_key}: FAIL - {e}')

        print()
        print(f'Results: {len([r for r in results.values() if r[\"status\"]==\"OK\"])}/{len(results)} passed')
        print(f'Screenshots saved to /tmp/anti-detect-test-*.png')
else:
    print('Chromium testing requires Node.js - use: anti-detect-helper.sh launch --engine chromium --url <test-url>')
" 2>&1

    deactivate 2>/dev/null || true
    return 0
}

# ─── Warmup ──────────────────────────────────────────────────────────────────

warmup_profile() {
    local profile_name="$1"
    shift
    local duration="30"  # minutes
    local arg

    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --duration)
                duration="${2%m}"  # Strip 'm' suffix
                shift 2
                ;;
            *) shift ;;
        esac
    done

    local profile_dir
    profile_dir=$(find_profile_dir "$profile_name")

    if [[ -z "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$profile_name' not found.${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}Warming up profile '$profile_name' for ${duration}m...${NC}"

    # shellcheck disable=SC1091
    source "$VENV_DIR/bin/activate" 2>/dev/null || {
        echo -e "${RED}Error: Camoufox venv not found. Run: anti-detect-helper.sh setup${NC}" >&2
        return 1
    }

    local config_arg=""
    local proxy_arg=""

    if [[ -f "$profile_dir/fingerprint.json" ]]; then
        config_arg="$profile_dir/fingerprint.json"
    fi
    if [[ -f "$profile_dir/proxy.json" ]]; then
        proxy_arg="$profile_dir/proxy.json"
    fi

    python3 -c "
import json
import asyncio
import random
import time

WARMUP_SITES = [
    'https://www.google.com',
    'https://www.youtube.com',
    'https://www.wikipedia.org',
    'https://www.reddit.com',
    'https://www.amazon.com',
    'https://news.ycombinator.com',
    'https://www.github.com',
    'https://stackoverflow.com',
    'https://www.bbc.com',
    'https://www.nytimes.com',
]

async def warmup():
    from camoufox.async_api import AsyncCamoufox

    profile_config = {}
    proxy = None
    config_file = '$config_arg'
    proxy_file = '$proxy_arg'

    if config_file:
        with open(config_file) as f:
            profile_config = json.load(f)

    if proxy_file:
        with open(proxy_file) as f:
            proxy = json.load(f)

    kwargs = {'headless': True, 'humanize': True}
    os_list = profile_config.get('os')
    if os_list:
        kwargs['os'] = os_list
    screen_config = profile_config.get('screen')
    if screen_config:
        from browserforge.fingerprints import Screen
        kwargs['screen'] = Screen(
            max_width=screen_config.get('maxWidth', 1920),
            max_height=screen_config.get('maxHeight', 1080),
        )
    if proxy:
        kwargs['proxy'] = proxy
        kwargs['geoip'] = True

    duration_seconds = $duration * 60
    start_time = time.time()
    sites_visited = 0

    async with AsyncCamoufox(**kwargs) as browser:
        page = await browser.new_page()

        while (time.time() - start_time) < duration_seconds:
            url = random.choice(WARMUP_SITES)
            try:
                await page.goto(url, timeout=15000)
                sites_visited += 1
                elapsed = int(time.time() - start_time)
                print(f'  [{elapsed}s] Visited: {url}')

                # Simulate reading
                await asyncio.sleep(random.uniform(3, 12))

                # Scroll
                await page.evaluate('window.scrollBy(0, window.innerHeight * Math.random())')
                await asyncio.sleep(random.uniform(1, 4))

                # Maybe click a link
                if random.random() > 0.6:
                    links = await page.query_selector_all('a[href^=\"http\"]')
                    if links and len(links) > 2:
                        link = random.choice(links[:8])
                        try:
                            await link.click(timeout=5000)
                            await asyncio.sleep(random.uniform(2, 6))
                            await page.go_back(timeout=5000)
                        except Exception:
                            pass

            except Exception as e:
                pass  # Skip failed navigations

            await asyncio.sleep(random.uniform(2, 8))

        # Save state
        context = browser.contexts[0]
        cookies = context.cookies()
        state = {'cookies': cookies, 'origins': []}
        with open('$profile_dir/storage-state.json', 'w') as f:
            json.dump(state, f, indent=2)

        print(f'\\nWarmup complete: {sites_visited} sites visited, {len(cookies)} cookies saved.')

asyncio.run(warmup())
" 2>&1

    deactivate 2>/dev/null || true
    echo -e "${GREEN}Warmup complete for '$profile_name'.${NC}"
    return 0
}

# ─── Status ──────────────────────────────────────────────────────────────────

show_status() {
    echo -e "${BLUE}Anti-Detect Browser Status:${NC}"
    echo "─────────────────────────────────────────"

    # Camoufox
    if [[ -d "$VENV_DIR" ]]; then
        local camoufox_version
        camoufox_version=$("$VENV_DIR/bin/python3" -c "from camoufox.__version__ import __version__; print(__version__)" 2>/dev/null || echo "unknown")
        echo -e "  Camoufox:          ${GREEN}installed${NC} (v$camoufox_version)"
    else
        echo -e "  Camoufox:          ${RED}not installed${NC}"
    fi

    # Mullvad Browser
    local mullvad_path=""
    if [[ -f "/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser" ]]; then
        mullvad_path="/Applications/Mullvad Browser.app/Contents/MacOS/mullvadbrowser"
    elif [[ -f "/usr/bin/mullvad-browser" ]]; then
        mullvad_path="/usr/bin/mullvad-browser"
    elif [[ -f "$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser" ]]; then
        mullvad_path="$HOME/.local/share/mullvad-browser/Browser/start-mullvad-browser"
    elif [[ -f "/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe" ]]; then
        mullvad_path="/mnt/c/Program Files/Mullvad Browser/Browser/mullvadbrowser.exe"
    fi
    if [[ -n "$mullvad_path" ]]; then
        echo -e "  Mullvad Browser:   ${GREEN}installed${NC} ($mullvad_path)"
    else
        echo -e "  Mullvad Browser:   ${YELLOW}not installed${NC} (https://mullvad.net/browser)"
    fi

    # rebrowser-patches
    if npx rebrowser-patches@latest --version &>/dev/null 2>&1; then
        echo -e "  rebrowser-patches: ${GREEN}available${NC}"
    else
        echo -e "  rebrowser-patches: ${YELLOW}not patched${NC} (run: npx rebrowser-patches patch)"
    fi

    # Playwright
    if command -v npx &>/dev/null && npx playwright --version &>/dev/null 2>&1; then
        local pw_version
        pw_version=$(npx playwright --version 2>/dev/null || echo "unknown")
        echo -e "  Playwright:        ${GREEN}installed${NC} ($pw_version)"
    else
        echo -e "  Playwright:        ${RED}not installed${NC}"
    fi

    # Profiles
    local profile_count=0
    for dir in "$PROFILES_DIR"/{persistent,clean,warmup}/*/; do
        [[ -d "$dir" ]] && [[ "$(basename "$dir")" != "default" ]] && ((profile_count++)) || true
    done
    echo -e "  Profiles:          ${GREEN}$profile_count${NC} configured"

    # Profile directory
    echo -e "  Profile dir:       $PROFILES_DIR"
    echo -e "  Venv dir:          $VENV_DIR"

    return 0
}

# ─── Proxy Operations ────────────────────────────────────────────────────────

proxy_check() {
    local proxy_url="$1"

    echo -e "${BLUE}Checking proxy: $proxy_url${NC}"

    local result
    result=$(curl -s --proxy "$proxy_url" --max-time 15 "https://httpbin.org/ip" 2>/dev/null)

    if [[ $? -eq 0 && -n "$result" ]]; then
        local ip
        ip=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('origin','unknown'))" 2>/dev/null || echo "unknown")
        echo -e "  Status: ${GREEN}OK${NC}"
        echo "  IP: $ip"

        # Get geo info
        local geo
        geo=$(curl -s --max-time 10 "https://ipinfo.io/$ip/json" 2>/dev/null)
        if [[ -n "$geo" ]]; then
            local country city isp
            country=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('country','?'))" 2>/dev/null || echo "?")
            city=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('city','?'))" 2>/dev/null || echo "?")
            isp=$(echo "$geo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('org','?'))" 2>/dev/null || echo "?")
            echo "  Location: $city, $country"
            echo "  ISP: $isp"
        fi
    else
        echo -e "  Status: ${RED}FAIL${NC} (connection timeout or refused)"
    fi
    return 0
}

proxy_check_all() {
    echo -e "${BLUE}Checking all profile proxies...${NC}"

    for type_dir in "$PROFILES_DIR"/{persistent,clean,warmup}/*/; do
        [[ -d "$type_dir" ]] || continue
        local name
        name=$(basename "$type_dir")
        [[ "$name" == "default" ]] && continue

        if [[ -f "$type_dir/proxy.json" ]]; then
            local server
            server=$(python3 -c "import json; print(json.load(open('$type_dir/proxy.json')).get('server',''))" 2>/dev/null)
            if [[ -n "$server" ]]; then
                echo -e "\n${YELLOW}Profile: $name${NC}"
                proxy_check "$server"
            fi
        fi
    done
    return 0
}

# ─── Cookie Operations ───────────────────────────────────────────────────────

cookies_export() {
    local profile_name="$1"
    shift
    local output=""
    local arg

    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --output) output="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local profile_dir
    profile_dir=$(find_profile_dir "$profile_name")

    if [[ -z "$profile_dir" || ! -f "$profile_dir/storage-state.json" ]]; then
        echo -e "${RED}Error: No saved state for profile '$profile_name'.${NC}" >&2
        return 1
    fi

    local out_file="${output:-/tmp/${profile_name}-cookies.txt}"

    python3 -c "
import json

with open('$profile_dir/storage-state.json') as f:
    state = json.load(f)

cookies = state.get('cookies', [])
lines = ['# Netscape HTTP Cookie File']

for c in cookies:
    domain = c.get('domain', '')
    flag = 'TRUE' if domain.startswith('.') else 'FALSE'
    path = c.get('path', '/')
    secure = 'TRUE' if c.get('secure', False) else 'FALSE'
    expires = str(int(c.get('expires', 0)))
    name = c.get('name', '')
    value = c.get('value', '')
    lines.append(f'{domain}\t{flag}\t{path}\t{secure}\t{expires}\t{name}\t{value}')

with open('$out_file', 'w') as f:
    f.write('\n'.join(lines))

print(f'Exported {len(cookies)} cookies to $out_file')
" 2>&1

    return 0
}

cookies_clear() {
    local profile_name="$1"
    local profile_dir
    profile_dir=$(find_profile_dir "$profile_name")

    if [[ -z "$profile_dir" ]]; then
        echo -e "${RED}Error: Profile '$profile_name' not found.${NC}" >&2
        return 1
    fi

    rm -f "$profile_dir/storage-state.json" "$profile_dir/cookies.json"
    rm -rf "$profile_dir/user-data"
    echo -e "${GREEN}Cookies cleared for '$profile_name'.${NC}"
    return 0
}

# ─── Utility Functions ───────────────────────────────────────────────────────

find_profile_dir() {
    local name="$1"
    for type in persistent clean warmup disposable; do
        local dir="$PROFILES_DIR/$type/$name"
        if [[ -d "$dir" ]]; then
            echo "$dir"
            return 0
        fi
    done
    echo ""
    return 1
}

generate_fingerprint() {
    local target_os="${1:-random}"
    local browser_type="${2:-firefox}"

    # Generate fingerprint metadata (Camoufox handles actual fingerprint via BrowserForge)
    # We store OS/screen constraints that Camoufox uses to generate consistent fingerprints
    python3 -c "
import json
import random

# Camoufox uses screen constraints, not direct property injection
# BrowserForge generates the actual fingerprint at runtime
screens = {
    'windows': [(1920, 1080), (2560, 1440), (1366, 768), (1536, 864)],
    'macos': [(1920, 1080), (2560, 1440), (1440, 900), (1680, 1050)],
    'linux': [(1920, 1080), (2560, 1440), (1366, 768)],
    'random': [(1920, 1080), (2560, 1440), (1366, 768), (1536, 864), (1440, 900)],
}

os_list = screens.get('$target_os', screens['random'])
screen = random.choice(os_list)

config = {
    'target_os': '$target_os',
    'target_browser': '$browser_type',
    'screen': {'maxWidth': screen[0], 'maxHeight': screen[1]},
}

# Store OS hint for Camoufox's BrowserForge integration
if '$target_os' == 'windows':
    config['os'] = ['windows']
elif '$target_os' == 'macos':
    config['os'] = ['macos']
elif '$target_os' == 'linux':
    config['os'] = ['linux']
else:
    config['os'] = ['windows', 'macos', 'linux']

print(json.dumps(config, indent=2))
" 2>/dev/null || echo '{"mode": "random"}'
}

parse_proxy_url() {
    local url="$1"
    python3 -c "
import json
from urllib.parse import urlparse

url = '$url'
parsed = urlparse(url)

result = {
    'server': f'{parsed.scheme}://{parsed.hostname}:{parsed.port}',
}

if parsed.username:
    result['username'] = parsed.username
if parsed.password:
    result['password'] = parsed.password

print(json.dumps(result, indent=2))
" 2>/dev/null || echo "{\"server\": \"$url\"}"
}

update_profiles_index() {
    local name="$1"
    local profile_type="$2"
    local action="$3"

    python3 -c "
import json
from pathlib import Path

index_file = Path('$PROFILES_DIR/profiles.json')
if index_file.exists():
    data = json.loads(index_file.read_text())
else:
    data = {'profiles': []}

if '$action' == 'add':
    # Remove existing entry if any
    data['profiles'] = [p for p in data['profiles'] if p.get('name') != '$name']
    data['profiles'].append({'name': '$name', 'type': '$profile_type'})
elif '$action' == 'remove':
    data['profiles'] = [p for p in data['profiles'] if p.get('name') != '$name']

index_file.write_text(json.dumps(data, indent=2))
" 2>/dev/null || true
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        setup)
            local engine="all"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --engine) engine="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            setup_all "$engine"
            ;;
        launch)
            launch_browser "$@"
            ;;
        profile)
            local subcmd="${1:-list}"
            shift 2>/dev/null || true
            case "$subcmd" in
                create) profile_create "$@" ;;
                list) profile_list "$@" ;;
                show) profile_show "$@" ;;
                delete) profile_delete "$@" ;;
                clone) profile_clone "$@" ;;
                update) profile_update "$@" ;;
                *) echo -e "${RED}Unknown profile command: $subcmd${NC}"; show_help ;;
            esac
            ;;
        cookies)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                export) cookies_export "$@" ;;
                clear) cookies_clear "$@" ;;
                *) echo -e "${RED}Unknown cookies command: $subcmd${NC}"; show_help ;;
            esac
            ;;
        proxy)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                check) proxy_check "$@" ;;
                check-all) proxy_check_all ;;
                *) echo -e "${RED}Unknown proxy command: $subcmd${NC}"; show_help ;;
            esac
            ;;
        test)
            test_detection "$@"
            ;;
        warmup)
            warmup_profile "$@"
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo -e "${RED}Unknown command: $command${NC}"
            show_help
            return 1
            ;;
    esac
}

main "$@"
