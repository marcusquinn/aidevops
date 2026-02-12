#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2155

# Pipecat Helper Script
# Manages the Pipecat local voice agent: setup, start, stop, status, client
#
# Pipeline: Mic -> Soniox STT -> Anthropic/OpenAI LLM -> Cartesia TTS -> Speaker
# Transport: SmallWebRTCTransport (local, serverless) or Daily.co (cloud)
#
# Usage: ./pipecat-helper.sh [command] [options]
# Commands:
#   setup       - Install Pipecat and dependencies into a virtual environment
#   start       - Start the Pipecat voice agent server
#   stop        - Stop the running voice agent server
#   status      - Check component availability and API connectivity
#   client      - Launch the web client (voice-ui-kit)
#   keys        - Check which API keys are configured
#   logs        - Show recent agent logs
#   help        - Show this help message
#
# Related: pipecat-opencode.md, voice-helper.sh, voice-pipeline-helper.sh
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

# ─── Constants ─────────────────────────────────────────────────────────

readonly PIPECAT_DIR="${HOME}/.aidevops/.agent-workspace/work/pipecat-voice-agent"
readonly PIPECAT_VENV="${PIPECAT_DIR}/.venv"
readonly PIPECAT_BOT="${PIPECAT_DIR}/bot.py"
readonly PIPECAT_PID_FILE="${HOME}/.aidevops/.agent-workspace/tmp/.pipecat-agent.pid"
readonly PIPECAT_LOG_FILE="${HOME}/.aidevops/logs/pipecat-agent.log"
readonly CLIENT_DIR="${PIPECAT_DIR}/client"
readonly CLIENT_PID_FILE="${HOME}/.aidevops/.agent-workspace/tmp/.pipecat-client.pid"

readonly DEFAULT_SERVER_PORT=7860
readonly DEFAULT_CLIENT_PORT=3000
readonly DEFAULT_LLM_PROVIDER="anthropic"
readonly DEFAULT_ANTHROPIC_MODEL="claude-sonnet-4-20250514"
readonly DEFAULT_OPENAI_MODEL="gpt-4o"
readonly DEFAULT_CARTESIA_VOICE_ID="71a7ad14-091c-4e8e-a314-022ece01c121"
readonly DEFAULT_PYTHON="python3.12"

# Minimum Pipecat version
readonly MIN_PIPECAT_VERSION="0.0.80"

# ─── API Key Management ───────────────────────────────────────────────

# Load a single API key from environment, gopass, or credentials file.
# Usage: load_api_key "SONIOX_API_KEY"
# Sets the variable in the current shell. Never prints the value.
load_api_key() {
	local key_name="$1"

	# 1. Already in environment
	local current_val="${!key_name:-}"
	if [[ -n "${current_val}" ]]; then
		return 0
	fi

	# 2. Try gopass (encrypted)
	if command -v gopass &>/dev/null; then
		local key
		key=$(gopass show -o "aidevops/${key_name}" 2>/dev/null) || true
		if [[ -n "${key:-}" ]]; then
			export "${key_name}=${key}"
			return 0
		fi
	fi

	# 3. Try credentials.sh (plaintext fallback)
	local cred_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "${cred_file}" ]]; then
		local key
		key=$(bash -c "source '${cred_file}' 2>/dev/null && echo \"\${${key_name}:-}\"") || true
		if [[ -n "${key:-}" ]]; then
			export "${key_name}=${key}"
			return 0
		fi
	fi

	# 4. Try tenant credentials
	local tenant_file="${HOME}/.config/aidevops/tenants/default/credentials.sh"
	if [[ -f "${tenant_file}" ]]; then
		local key
		key=$(bash -c "source '${tenant_file}' 2>/dev/null && echo \"\${${key_name}:-}\"") || true
		if [[ -n "${key:-}" ]]; then
			export "${key_name}=${key}"
			return 0
		fi
	fi

	return 1
}

# Check if a key is available (without printing it)
has_api_key() {
	local key_name="$1"
	load_api_key "${key_name}" 2>/dev/null
}

# ─── Dependency Checks ────────────────────────────────────────────────

check_python() {
	local python_cmd="${1:-${DEFAULT_PYTHON}}"

	if command -v "${python_cmd}" &>/dev/null; then
		local version
		version=$("${python_cmd}" --version 2>&1 | awk '{print $2}')
		local major minor
		major=$(echo "${version}" | cut -d. -f1)
		minor=$(echo "${version}" | cut -d. -f2)
		if [[ "${major}" -ge 3 ]] && [[ "${minor}" -ge 10 ]]; then
			return 0
		fi
		print_error "Python ${version} found but 3.10+ required"
		return 1
	fi

	# Fallback to python3
	if command -v python3 &>/dev/null; then
		local version
		version=$(python3 --version 2>&1 | awk '{print $2}')
		local major minor
		major=$(echo "${version}" | cut -d. -f1)
		minor=$(echo "${version}" | cut -d. -f2)
		if [[ "${major}" -ge 3 ]] && [[ "${minor}" -ge 10 ]]; then
			return 0
		fi
	fi

	print_error "Python 3.10+ is required but not found"
	print_info "Install: brew install python@3.12 (macOS) or apt install python3.12 (Linux)"
	return 1
}

find_python() {
	if command -v "${DEFAULT_PYTHON}" &>/dev/null; then
		echo "${DEFAULT_PYTHON}"
	elif command -v python3.12 &>/dev/null; then
		echo "python3.12"
	elif command -v python3.11 &>/dev/null; then
		echo "python3.11"
	elif command -v python3.10 &>/dev/null; then
		echo "python3.10"
	elif command -v python3 &>/dev/null; then
		echo "python3"
	else
		echo "python3"
	fi
}

check_node() {
	if ! command -v node &>/dev/null; then
		print_error "Node.js is required for the web client"
		print_info "Install: brew install node (macOS) or see https://nodejs.org/"
		return 1
	fi
	return 0
}

check_npm() {
	if ! command -v npm &>/dev/null; then
		print_error "npm is required for the web client"
		return 1
	fi
	return 0
}

check_venv() {
	if [[ ! -d "${PIPECAT_VENV}" ]]; then
		print_error "Pipecat virtual environment not found at ${PIPECAT_VENV}"
		print_info "Run: pipecat-helper.sh setup"
		return 1
	fi
	return 0
}

check_pipecat_installed() {
	if ! "${PIPECAT_VENV}/bin/python" -c "import pipecat" 2>/dev/null; then
		print_error "Pipecat is not installed in the virtual environment"
		print_info "Run: pipecat-helper.sh setup"
		return 1
	fi
	return 0
}

# ─── Bot Template ──────────────────────────────────────────────────────

# Generate the bot.py file with the specified LLM provider
generate_bot_template() {
	local llm_provider="${1:-${DEFAULT_LLM_PROVIDER}}"
	# $2 (server_port) is accepted for API compatibility but not used in the template
	# (the heredoc uses single-quoted delimiter, so the bot reads --port from argparse)
	local voice_id="${3:-${DEFAULT_CARTESIA_VOICE_ID}}"

	mkdir -p "$(dirname "${PIPECAT_BOT}")"

	cat >"${PIPECAT_BOT}" <<'BOTEOF'
"""Pipecat local voice agent with Soniox STT + LLM + Cartesia TTS.

Pipeline: Mic -> SmallWebRTC -> Soniox STT -> LLM -> Cartesia TTS -> Speaker
Transport: SmallWebRTCTransport (local, serverless)

Requires API keys: SONIOX_API_KEY, CARTESIA_API_KEY, and ANTHROPIC_API_KEY or OPENAI_API_KEY.
Store keys via: aidevops secret set <KEY_NAME>

Usage:
    python bot.py [--port PORT] [--llm anthropic|openai] [--voice-id VOICE_ID]
"""

import argparse
import os
import sys
from typing import Dict

from dotenv import load_dotenv
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.background import BackgroundTask
from starlette.responses import JSONResponse

from pipecat.audio.vad.silero import SileroVADAnalyzer, VADParams
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.openai_llm_context import OpenAILLMContext
from pipecat.processors.frameworks.rtvi import (
    RTVIConfig,
    RTVIObserver,
    RTVIProcessor,
)
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.soniox.stt import SonioxSTTService
from pipecat.transports.network.small_webrtc import SmallWebRTCTransport
from pipecat.transports.network.webrtc_connection import (
    IceServer,
    SmallWebRTCConnection,
)
from pipecat.transports.base_transport import TransportParams

load_dotenv(override=True)

# ─── Configuration ─────────────────────────────────────────────────────

DEFAULT_PORT = 7860
DEFAULT_LLM = "anthropic"
DEFAULT_VOICE_ID = "71a7ad14-091c-4e8e-a314-022ece01c121"  # British Reading Lady

SYSTEM_PROMPT = (
    "You are an AI DevOps assistant in a real-time voice conversation. "
    "Keep responses to 1-3 short sentences. Use plain spoken English "
    "suitable for text-to-speech output. Avoid markdown, code blocks, "
    "bullet points, or special formatting. When asked to perform tasks "
    "(edit files, run commands, git operations), confirm the action and "
    "report the outcome briefly. If genuinely ambiguous, ask one short "
    "clarifying question."
)

# ─── App Setup ─────────────────────────────────────────────────────────

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Track active WebRTC connections for renegotiation
pcs_map: Dict[str, SmallWebRTCConnection] = {}


def get_llm_service(provider: str):
    """Create the LLM service based on provider choice."""
    if provider == "anthropic":
        from pipecat.services.anthropic.llm import AnthropicLLMService

        api_key = os.getenv("ANTHROPIC_API_KEY")
        if not api_key:
            print("ERROR: ANTHROPIC_API_KEY not set. Run: aidevops secret set ANTHROPIC_API_KEY")
            sys.exit(1)
        return AnthropicLLMService(
            api_key=api_key,
            model=os.getenv("PIPECAT_ANTHROPIC_MODEL", "claude-sonnet-4-20250514"),
        )
    elif provider == "openai":
        from pipecat.services.openai.llm import OpenAILLMService

        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            print("ERROR: OPENAI_API_KEY not set. Run: aidevops secret set OPENAI_API_KEY")
            sys.exit(1)
        return OpenAILLMService(
            api_key=api_key,
            model=os.getenv("PIPECAT_OPENAI_MODEL", "gpt-4o"),
        )
    elif provider == "local":
        # Use OpenAI-compatible API for local LLM (LM Studio, Ollama, etc.)
        from pipecat.services.openai.llm import OpenAILLMService

        base_url = os.getenv("PIPECAT_LOCAL_LLM_URL", "http://127.0.0.1:1234/v1")
        model = os.getenv("PIPECAT_LOCAL_LLM_MODEL", "local-model")
        return OpenAILLMService(
            api_key="not-needed",
            model=model,
            base_url=base_url,
        )
    else:
        print(f"ERROR: Unknown LLM provider: {provider}")
        print("Supported: anthropic, openai, local")
        sys.exit(1)


async def run_bot(
    webrtc_connection: SmallWebRTCConnection,
    llm_provider: str,
    voice_id: str,
):
    """Run the Pipecat voice agent pipeline for a single connection."""
    # STT: Soniox (real-time streaming, 60+ languages)
    soniox_key = os.getenv("SONIOX_API_KEY")
    if not soniox_key:
        print("ERROR: SONIOX_API_KEY not set. Run: aidevops secret set SONIOX_API_KEY")
        return

    stt = SonioxSTTService(api_key=soniox_key)

    # TTS: Cartesia Sonic (low-latency streaming, word timestamps)
    cartesia_key = os.getenv("CARTESIA_API_KEY")
    if not cartesia_key:
        print("ERROR: CARTESIA_API_KEY not set. Run: aidevops secret set CARTESIA_API_KEY")
        return

    tts = CartesiaTTSService(
        api_key=cartesia_key,
        voice_id=voice_id,
    )

    # LLM: Anthropic, OpenAI, or local
    llm = get_llm_service(llm_provider)

    # Context with system prompt
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    context = OpenAILLMContext(messages)
    context_aggregator = llm.create_context_aggregator(context)

    # RTVI processor for client UI events
    rtvi = RTVIProcessor(config=RTVIConfig(config=[]))

    # Transport (local serverless WebRTC)
    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
            vad_enabled=True,
            vad_analyzer=SileroVADAnalyzer(
                params=VADParams(stop_secs=0.3),
            ),
        ),
    )

    # Pipeline: input -> STT -> RTVI -> user context -> LLM -> TTS -> output -> assistant context
    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            rtvi,
            context_aggregator.user(),
            llm,
            tts,
            transport.output(),
            context_aggregator.assistant(),
        ]
    )

    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            allow_interruptions=True,
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )

    # Handle client ready event
    @rtvi.event_handler("on_client_ready")
    async def on_client_ready(rtvi_processor):
        await rtvi_processor.set_bot_ready()

    runner = PipelineRunner(handle_sigint=False)
    await runner.run(task)


def create_app(llm_provider: str, voice_id: str) -> FastAPI:
    """Configure the FastAPI app with the specified settings."""

    @app.post("/api/offer")
    async def offer(request: Request):
        """Handle WebRTC signaling offer from the client."""
        body = await request.json()
        pc_id = body.get("pc_id")

        # Renegotiate existing connection or create new one
        if pc_id and pc_id in pcs_map:
            pc = pcs_map[pc_id]
            await pc.renegotiate(
                sdp=body["sdp"],
                type=body["type"],
            )
            return JSONResponse(
                content={
                    "sdp": pc.get_local_description()["sdp"],
                    "type": pc.get_local_description()["type"],
                    "pc_id": pc_id,
                }
            )

        # New connection
        pc = SmallWebRTCConnection(
            ice_servers=[IceServer(urls="stun:stun.l.google.com:19302")],
        )
        await pc.initialize(sdp=body["sdp"], type=body["type"])

        pc_id = pc.pc_id
        pcs_map[pc_id] = pc

        task = BackgroundTask(
            run_bot,
            webrtc_connection=pc,
            llm_provider=llm_provider,
            voice_id=voice_id,
        )

        return JSONResponse(
            content={
                "sdp": pc.get_local_description()["sdp"],
                "type": pc.get_local_description()["type"],
                "pc_id": pc_id,
            },
            background=task,
        )

    @app.get("/api/status")
    async def status():
        """Health check endpoint."""
        return {
            "status": "running",
            "connections": len(pcs_map),
            "llm_provider": llm_provider,
        }

    return app


# ─── CLI Entry Point ───────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn

    parser = argparse.ArgumentParser(description="Pipecat local voice agent")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Server port")
    parser.add_argument(
        "--llm",
        choices=["anthropic", "openai", "local"],
        default=DEFAULT_LLM,
        help="LLM provider",
    )
    parser.add_argument("--voice-id", default=DEFAULT_VOICE_ID, help="Cartesia voice ID")
    args = parser.parse_args()

    create_app(args.llm, args.voice_id)

    print(f"Starting Pipecat voice agent on port {args.port}")
    print(f"LLM: {args.llm}")
    print(f"Pipeline: Soniox STT -> {args.llm} LLM -> Cartesia TTS")
    print(f"Connect web client to: http://localhost:{args.port}/api/offer")
    print()

    uvicorn.run(app, host="0.0.0.0", port=args.port, log_level="warning")
BOTEOF

	# Patch the default values based on arguments (portable sed in-place)
	if [[ "${llm_provider}" != "anthropic" ]]; then
		local tmp_bot
		tmp_bot="$(mktemp)"
		sed "s/DEFAULT_LLM = \"anthropic\"/DEFAULT_LLM = \"${llm_provider}\"/" "${PIPECAT_BOT}" >"$tmp_bot" && mv "$tmp_bot" "${PIPECAT_BOT}"
	fi
	if [[ "${voice_id}" != "${DEFAULT_CARTESIA_VOICE_ID}" ]]; then
		local tmp_bot2
		tmp_bot2="$(mktemp)"
		sed "s/${DEFAULT_CARTESIA_VOICE_ID}/${voice_id}/g" "${PIPECAT_BOT}" >"$tmp_bot2" && mv "$tmp_bot2" "${PIPECAT_BOT}"
	fi

	print_success "Bot template generated: ${PIPECAT_BOT}"
	return 0
}

# ─── Commands ──────────────────────────────────────────────────────────

cmd_setup() {
	local llm_provider="${1:-${DEFAULT_LLM_PROVIDER}}"
	local with_client="${2:-true}"

	echo ""
	echo "=== Pipecat Voice Agent Setup ==="
	echo ""

	# Check Python
	local python_cmd
	python_cmd=$(find_python)
	check_python "${python_cmd}" || return 1
	print_success "Python: $(${python_cmd} --version 2>&1)"

	# Create project directory
	mkdir -p "${PIPECAT_DIR}"
	mkdir -p "$(dirname "${PIPECAT_PID_FILE}")"
	mkdir -p "$(dirname "${PIPECAT_LOG_FILE}")"

	# Create virtual environment
	if [[ ! -d "${PIPECAT_VENV}" ]]; then
		print_info "Creating virtual environment..."
		"${python_cmd}" -m venv "${PIPECAT_VENV}"
		print_success "Virtual environment created: ${PIPECAT_VENV}"
	else
		print_success "Virtual environment exists: ${PIPECAT_VENV}"
	fi

	# Upgrade pip
	"${PIPECAT_VENV}/bin/python" -m pip install --upgrade pip --quiet 2>&1 | tail -1

	# Install Pipecat with required services
	print_info "Installing Pipecat with Soniox STT, Cartesia TTS, Silero VAD, WebRTC..."
	local pip_extras="soniox,cartesia,silero,webrtc"

	# Add LLM provider
	case "${llm_provider}" in
	anthropic)
		pip_extras="${pip_extras},anthropic"
		;;
	openai)
		pip_extras="${pip_extras},openai"
		;;
	local)
		pip_extras="${pip_extras},openai" # OpenAI-compatible API
		;;
	both)
		pip_extras="${pip_extras},anthropic,openai"
		;;
	*)
		print_warning "Unknown LLM provider: ${llm_provider}, installing both"
		pip_extras="${pip_extras},anthropic,openai"
		;;
	esac

	"${PIPECAT_VENV}/bin/python" -m pip install "pipecat-ai[${pip_extras}]" --quiet 2>&1 | tail -3

	# Install additional dependencies
	"${PIPECAT_VENV}/bin/python" -m pip install \
		python-dotenv uvicorn fastapi --quiet 2>&1 | tail -1

	# Verify installation
	local pipecat_version
	pipecat_version=$("${PIPECAT_VENV}/bin/python" -c "import pipecat; print(pipecat.__version__)" 2>/dev/null || echo "unknown")
	print_success "Pipecat installed: v${pipecat_version}"

	# Generate bot template
	print_info "Generating bot template..."
	generate_bot_template "${llm_provider}" "${DEFAULT_SERVER_PORT}" "${DEFAULT_CARTESIA_VOICE_ID}"

	# Create .env template (without actual keys)
	if [[ ! -f "${PIPECAT_DIR}/.env" ]]; then
		cat >"${PIPECAT_DIR}/.env" <<'ENVEOF'
# Pipecat Voice Agent Configuration
# Store actual keys via: aidevops secret set <KEY_NAME>
# Or uncomment and fill in below (less secure)

# SONIOX_API_KEY=
# CARTESIA_API_KEY=
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=

# Optional: Local LLM settings
# PIPECAT_LOCAL_LLM_URL=http://127.0.0.1:1234/v1
# PIPECAT_LOCAL_LLM_MODEL=local-model

# Optional: Override default models
# PIPECAT_ANTHROPIC_MODEL=claude-sonnet-4-20250514
# PIPECAT_OPENAI_MODEL=gpt-4o
ENVEOF
		print_success "Environment template created: ${PIPECAT_DIR}/.env"
	fi

	# Setup web client
	if [[ "${with_client}" == "true" ]]; then
		cmd_setup_client
	fi

	echo ""
	echo "=== Setup Complete ==="
	echo ""
	echo "Next steps:"
	echo "  1. Store API keys:  aidevops secret set SONIOX_API_KEY"
	echo "                      aidevops secret set CARTESIA_API_KEY"
	echo "                      aidevops secret set ANTHROPIC_API_KEY"
	echo "  2. Start agent:     pipecat-helper.sh start"
	echo "  3. Open client:     http://localhost:${DEFAULT_CLIENT_PORT}"
	echo ""

	return 0
}

cmd_setup_client() {
	echo ""
	echo "--- Web Client Setup ---"

	check_node || return 1
	check_npm || return 1

	if [[ -d "${CLIENT_DIR}/node_modules" ]]; then
		print_success "Web client already installed: ${CLIENT_DIR}"
		return 0
	fi

	mkdir -p "${CLIENT_DIR}"

	# Create a minimal Next.js client using voice-ui-kit
	if [[ ! -f "${CLIENT_DIR}/package.json" ]]; then
		print_info "Creating web client with voice-ui-kit..."

		cat >"${CLIENT_DIR}/package.json" <<'PKGEOF'
{
  "name": "pipecat-voice-client",
  "version": "1.0.0",
  "private": true,
  "scripts": {
    "dev": "next dev --port 3000",
    "build": "next build",
    "start": "next start --port 3000"
  },
  "dependencies": {
    "@pipecat-ai/client-js": "^1.2.0",
    "@pipecat-ai/client-react": "^1.0.1",
    "@pipecat-ai/small-webrtc-transport": "^1.2.0",
    "@pipecat-ai/voice-ui-kit": "^0.7.0",
    "next": "^15.0.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "@types/react": "^19.0.0",
    "typescript": "^5.7.0"
  }
}
PKGEOF

		# Create Next.js config
		cat >"${CLIENT_DIR}/next.config.ts" <<'NEXTEOF'
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `http://localhost:${process.env.PIPECAT_PORT || 7860}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
NEXTEOF

		# Create tsconfig
		cat >"${CLIENT_DIR}/tsconfig.json" <<'TSEOF'
{
  "compilerOptions": {
    "target": "ES2017",
    "lib": ["dom", "dom.iterable", "esnext"],
    "allowJs": true,
    "skipLibCheck": true,
    "strict": true,
    "noEmit": true,
    "esModuleInterop": true,
    "module": "esnext",
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "isolatedModules": true,
    "jsx": "preserve",
    "incremental": true,
    "plugins": [{ "name": "next" }],
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
  "exclude": ["node_modules"]
}
TSEOF

		# Create app directory
		mkdir -p "${CLIENT_DIR}/src/app"

		# Create layout
		cat >"${CLIENT_DIR}/src/app/layout.tsx" <<'LAYOUTEOF'
import type { Metadata } from "next";
import "@pipecat-ai/voice-ui-kit/styles";

export const metadata: Metadata = {
  title: "Pipecat Voice Agent",
  description: "AI DevOps voice assistant powered by Pipecat",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
LAYOUTEOF

		# Create main page with ConsoleTemplate
		cat >"${CLIENT_DIR}/src/app/page.tsx" <<'PAGEEOF'
"use client";

import { ConsoleTemplate, ThemeProvider } from "@pipecat-ai/voice-ui-kit";

export default function Home() {
  return (
    <ThemeProvider>
      <ConsoleTemplate
        transportType="smallwebrtc"
        connectParams={{ webrtcUrl: "/api/offer" }}
        title="AI DevOps Voice Agent"
        subtitle="Powered by Pipecat + Soniox + Cartesia"
      />
    </ThemeProvider>
  );
}
PAGEEOF
	fi

	# Install dependencies
	print_info "Installing client dependencies (this may take a moment)..."
	(cd "${CLIENT_DIR}" && npm install --silent 2>&1 | tail -3)

	if [[ -d "${CLIENT_DIR}/node_modules" ]]; then
		print_success "Web client installed: ${CLIENT_DIR}"
	else
		print_warning "Web client installation may have issues — check ${CLIENT_DIR}"
	fi

	return 0
}

cmd_start() {
	local llm_provider="${1:-${DEFAULT_LLM_PROVIDER}}"
	local server_port="${2:-${DEFAULT_SERVER_PORT}}"
	local voice_id="${3:-${DEFAULT_CARTESIA_VOICE_ID}}"
	local with_client="${4:-true}"

	check_venv || return 1
	check_pipecat_installed || return 1

	# Check if already running
	if [[ -f "${PIPECAT_PID_FILE}" ]]; then
		local existing_pid
		existing_pid=$(cat "${PIPECAT_PID_FILE}")
		if kill -0 "${existing_pid}" 2>/dev/null; then
			print_warning "Pipecat agent already running (PID: ${existing_pid})"
			print_info "Stop it first: pipecat-helper.sh stop"
			return 1
		fi
		rm -f "${PIPECAT_PID_FILE}"
	fi

	# Load API keys from secure storage
	local keys_ok=true
	if ! has_api_key "SONIOX_API_KEY"; then
		print_error "SONIOX_API_KEY not found"
		print_info "Set it: aidevops secret set SONIOX_API_KEY"
		keys_ok=false
	fi
	if ! has_api_key "CARTESIA_API_KEY"; then
		print_error "CARTESIA_API_KEY not found"
		print_info "Set it: aidevops secret set CARTESIA_API_KEY"
		keys_ok=false
	fi

	case "${llm_provider}" in
	anthropic)
		if ! has_api_key "ANTHROPIC_API_KEY"; then
			print_error "ANTHROPIC_API_KEY not found"
			print_info "Set it: aidevops secret set ANTHROPIC_API_KEY"
			keys_ok=false
		fi
		;;
	openai)
		if ! has_api_key "OPENAI_API_KEY"; then
			print_error "OPENAI_API_KEY not found"
			print_info "Set it: aidevops secret set OPENAI_API_KEY"
			keys_ok=false
		fi
		;;
	local)
		print_info "Using local LLM — ensure it's running at ${PIPECAT_LOCAL_LLM_URL:-http://127.0.0.1:1234/v1}"
		;;
	esac

	if [[ "${keys_ok}" != "true" ]]; then
		print_error "Missing API keys — cannot start"
		return 1
	fi

	# Regenerate bot if needed
	if [[ ! -f "${PIPECAT_BOT}" ]]; then
		generate_bot_template "${llm_provider}" "${server_port}" "${voice_id}"
	fi

	echo ""
	echo "=== Starting Pipecat Voice Agent ==="
	echo ""
	echo "  Pipeline: Soniox STT -> ${llm_provider} LLM -> Cartesia TTS"
	echo "  Server:   http://localhost:${server_port}"
	echo "  Signaling: http://localhost:${server_port}/api/offer"
	echo ""

	# Start the bot server
	"${PIPECAT_VENV}/bin/python" "${PIPECAT_BOT}" \
		--port "${server_port}" \
		--llm "${llm_provider}" \
		--voice-id "${voice_id}" \
		>>"${PIPECAT_LOG_FILE}" 2>&1 &

	local bot_pid=$!
	echo "${bot_pid}" >"${PIPECAT_PID_FILE}"

	# Wait for server to be ready
	local attempts=0
	while [[ ${attempts} -lt 20 ]]; do
		if curl -s --max-time 1 "http://127.0.0.1:${server_port}/api/status" >/dev/null 2>&1; then
			print_success "Voice agent started (PID: ${bot_pid})"
			break
		fi
		sleep 0.5
		attempts=$((attempts + 1))
	done

	if [[ ${attempts} -ge 20 ]]; then
		print_warning "Server slow to start — check logs: pipecat-helper.sh logs"
	fi

	# Start web client
	if [[ "${with_client}" == "true" ]] && [[ -d "${CLIENT_DIR}/node_modules" ]]; then
		cmd_start_client "${DEFAULT_CLIENT_PORT}"
	fi

	echo ""
	echo "Voice agent is running. Open http://localhost:${DEFAULT_CLIENT_PORT} to talk."
	echo "Stop with: pipecat-helper.sh stop"
	echo ""

	return 0
}

cmd_start_client() {
	local client_port="${1:-${DEFAULT_CLIENT_PORT}}"

	if [[ ! -d "${CLIENT_DIR}/node_modules" ]]; then
		print_warning "Web client not installed — run: pipecat-helper.sh setup"
		return 1
	fi

	# Check if client already running
	if [[ -f "${CLIENT_PID_FILE}" ]]; then
		local existing_pid
		existing_pid=$(cat "${CLIENT_PID_FILE}")
		if kill -0 "${existing_pid}" 2>/dev/null; then
			print_success "Web client already running (PID: ${existing_pid})"
			return 0
		fi
		rm -f "${CLIENT_PID_FILE}"
	fi

	print_info "Starting web client on port ${client_port}..."
	(cd "${CLIENT_DIR}" && npm run dev -- --port "${client_port}" >>"${PIPECAT_LOG_FILE}" 2>&1 &)
	local client_pid=$!
	echo "${client_pid}" >"${CLIENT_PID_FILE}"

	# Wait briefly for client to start
	sleep 2
	if kill -0 "${client_pid}" 2>/dev/null; then
		print_success "Web client started: http://localhost:${client_port} (PID: ${client_pid})"
	else
		print_warning "Web client may have failed to start — check logs"
	fi

	return 0
}

cmd_stop() {
	echo "=== Stopping Pipecat Voice Agent ==="
	echo ""

	local stopped=false

	# Stop bot server
	if [[ -f "${PIPECAT_PID_FILE}" ]]; then
		local pid
		pid=$(cat "${PIPECAT_PID_FILE}")
		if kill -0 "${pid}" 2>/dev/null; then
			kill "${pid}" 2>/dev/null || true
			sleep 1
			if kill -0 "${pid}" 2>/dev/null; then
				kill -9 "${pid}" 2>/dev/null || true
			fi
			print_success "Voice agent stopped (PID: ${pid})"
			stopped=true
		fi
		rm -f "${PIPECAT_PID_FILE}"
	fi

	# Stop web client
	if [[ -f "${CLIENT_PID_FILE}" ]]; then
		local pid
		pid=$(cat "${CLIENT_PID_FILE}")
		if kill -0 "${pid}" 2>/dev/null; then
			kill "${pid}" 2>/dev/null || true
			print_success "Web client stopped (PID: ${pid})"
			stopped=true
		fi
		rm -f "${CLIENT_PID_FILE}"
	fi

	if [[ "${stopped}" != "true" ]]; then
		print_info "No running Pipecat processes found"
	fi

	echo ""
	return 0
}

cmd_status() {
	echo ""
	echo "=== Pipecat Voice Agent Status ==="
	echo ""

	# Check venv and Pipecat
	echo "--- Installation ---"
	if [[ -d "${PIPECAT_VENV}" ]]; then
		print_success "Virtual environment: ${PIPECAT_VENV}"
		if "${PIPECAT_VENV}/bin/python" -c "import pipecat" 2>/dev/null; then
			local version
			version=$("${PIPECAT_VENV}/bin/python" -c "import pipecat; print(pipecat.__version__)" 2>/dev/null || echo "unknown")
			print_success "Pipecat: v${version}"
		else
			print_error "Pipecat: not installed"
		fi
	else
		print_error "Virtual environment: not found"
		print_info "Run: pipecat-helper.sh setup"
	fi

	# Check bot template
	if [[ -f "${PIPECAT_BOT}" ]]; then
		print_success "Bot template: ${PIPECAT_BOT}"
	else
		print_warning "Bot template: not generated"
	fi

	# Check web client
	if [[ -d "${CLIENT_DIR}/node_modules" ]]; then
		print_success "Web client: installed"
	else
		print_warning "Web client: not installed"
	fi

	echo ""

	# Check running processes
	echo "--- Processes ---"
	if [[ -f "${PIPECAT_PID_FILE}" ]]; then
		local pid
		pid=$(cat "${PIPECAT_PID_FILE}")
		if kill -0 "${pid}" 2>/dev/null; then
			print_success "Voice agent: running (PID: ${pid})"

			# Check API endpoint
			local status_response
			status_response=$(curl -s --max-time 2 "http://127.0.0.1:${DEFAULT_SERVER_PORT}/api/status" 2>/dev/null || echo "")
			if [[ -n "${status_response}" ]]; then
				local connections llm_prov
				connections=$(echo "${status_response}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connections',0))" 2>/dev/null || echo "?")
				llm_prov=$(echo "${status_response}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('llm_provider','?'))" 2>/dev/null || echo "?")
				echo "  Connections: ${connections}"
				echo "  LLM provider: ${llm_prov}"
			fi
		else
			print_warning "Voice agent: stale PID file (not running)"
			rm -f "${PIPECAT_PID_FILE}"
		fi
	else
		print_info "Voice agent: not running"
	fi

	if [[ -f "${CLIENT_PID_FILE}" ]]; then
		local pid
		pid=$(cat "${CLIENT_PID_FILE}")
		if kill -0 "${pid}" 2>/dev/null; then
			print_success "Web client: running (PID: ${pid})"
		else
			print_warning "Web client: stale PID file (not running)"
			rm -f "${CLIENT_PID_FILE}"
		fi
	else
		print_info "Web client: not running"
	fi

	echo ""

	# Check API keys
	cmd_keys

	# Check services
	echo "--- Service Availability ---"
	if [[ -d "${PIPECAT_VENV}" ]]; then
		# Check Soniox
		if "${PIPECAT_VENV}/bin/python" -c "from pipecat.services.soniox.stt import SonioxSTTService" 2>/dev/null; then
			print_success "Soniox STT: module available"
		else
			print_warning "Soniox STT: module not installed"
		fi

		# Check Cartesia
		if "${PIPECAT_VENV}/bin/python" -c "from pipecat.services.cartesia.tts import CartesiaTTSService" 2>/dev/null; then
			print_success "Cartesia TTS: module available"
		else
			print_warning "Cartesia TTS: module not installed"
		fi

		# Check Anthropic
		if "${PIPECAT_VENV}/bin/python" -c "from pipecat.services.anthropic.llm import AnthropicLLMService" 2>/dev/null; then
			print_success "Anthropic LLM: module available"
		else
			print_warning "Anthropic LLM: module not installed"
		fi

		# Check OpenAI
		if "${PIPECAT_VENV}/bin/python" -c "from pipecat.services.openai.llm import OpenAILLMService" 2>/dev/null; then
			print_success "OpenAI LLM: module available"
		else
			print_warning "OpenAI LLM: module not installed"
		fi

		# Check WebRTC transport
		if "${PIPECAT_VENV}/bin/python" -c "from pipecat.transports.network.small_webrtc import SmallWebRTCTransport" 2>/dev/null; then
			print_success "SmallWebRTC: module available"
		else
			print_warning "SmallWebRTC: module not installed"
		fi
	fi

	echo ""
	return 0
}

cmd_keys() {
	echo "--- API Keys ---"

	if has_api_key "SONIOX_API_KEY"; then
		print_success "SONIOX_API_KEY: configured"
	else
		print_error "SONIOX_API_KEY: not found"
	fi

	if has_api_key "CARTESIA_API_KEY"; then
		print_success "CARTESIA_API_KEY: configured"
	else
		print_error "CARTESIA_API_KEY: not found"
	fi

	if has_api_key "ANTHROPIC_API_KEY"; then
		print_success "ANTHROPIC_API_KEY: configured"
	else
		print_warning "ANTHROPIC_API_KEY: not found (needed for Anthropic LLM)"
	fi

	if has_api_key "OPENAI_API_KEY"; then
		print_success "OPENAI_API_KEY: configured"
	else
		print_warning "OPENAI_API_KEY: not found (needed for OpenAI LLM)"
	fi

	echo ""
	return 0
}

cmd_logs() {
	local lines="${1:-50}"

	if [[ ! -f "${PIPECAT_LOG_FILE}" ]]; then
		print_info "No log file found at ${PIPECAT_LOG_FILE}"
		return 0
	fi

	echo "=== Pipecat Agent Logs (last ${lines} lines) ==="
	echo ""
	tail -n "${lines}" "${PIPECAT_LOG_FILE}"
	echo ""

	return 0
}

cmd_client() {
	local client_port="${1:-${DEFAULT_CLIENT_PORT}}"

	if [[ ! -d "${CLIENT_DIR}/node_modules" ]]; then
		print_info "Web client not installed. Setting up..."
		cmd_setup_client || return 1
	fi

	cmd_start_client "${client_port}"
	return 0
}

# ─── Help ──────────────────────────────────────────────────────────────

cmd_help() {
	cat <<'EOF'
Pipecat Helper - Local voice agent with Soniox STT + LLM + Cartesia TTS

Usage: pipecat-helper.sh <command> [options]

Commands:
  setup [llm] [--no-client]    Install Pipecat and dependencies
  start [llm] [port] [voice]   Start the voice agent server + web client
  stop                         Stop all Pipecat processes
  status                       Check installation, processes, and API keys
  client [port]                Launch the web client only
  keys                         Check API key availability
  logs [lines]                 Show recent agent logs
  help                         Show this help

LLM Providers:
  anthropic    Claude Sonnet (default, recommended)
  openai       GPT-4o
  local        OpenAI-compatible local server (LM Studio, Ollama)
  both         Install both Anthropic and OpenAI

Pipeline:
  Mic -> [SmallWebRTC] -> [Soniox STT] -> [LLM] -> [Cartesia TTS] -> Speaker

Setup:
  1. pipecat-helper.sh setup              # Install everything
  2. aidevops secret set SONIOX_API_KEY   # Store API keys
     aidevops secret set CARTESIA_API_KEY
     aidevops secret set ANTHROPIC_API_KEY
  3. pipecat-helper.sh start              # Start agent + client
  4. Open http://localhost:3000           # Talk to your agent

Examples:
  pipecat-helper.sh setup                 # Setup with Anthropic (default)
  pipecat-helper.sh setup openai          # Setup with OpenAI
  pipecat-helper.sh setup both            # Setup with both LLM providers
  pipecat-helper.sh start                 # Start with defaults
  pipecat-helper.sh start openai 8080     # Start with OpenAI on port 8080
  pipecat-helper.sh start local           # Start with local LLM
  pipecat-helper.sh status                # Full status check
  pipecat-helper.sh logs 100              # Last 100 log lines

Environment Variables:
  SONIOX_API_KEY           Soniox STT API key (required)
  CARTESIA_API_KEY         Cartesia TTS API key (required)
  ANTHROPIC_API_KEY        Anthropic LLM key (for anthropic provider)
  OPENAI_API_KEY           OpenAI LLM key (for openai provider)
  PIPECAT_LOCAL_LLM_URL    Local LLM endpoint (default: http://127.0.0.1:1234/v1)
  PIPECAT_LOCAL_LLM_MODEL  Local LLM model name
  PIPECAT_ANTHROPIC_MODEL  Override Anthropic model (default: claude-sonnet-4-20250514)
  PIPECAT_OPENAI_MODEL     Override OpenAI model (default: gpt-4o)

Directories:
  Agent:  ~/.aidevops/.agent-workspace/work/pipecat-voice-agent/
  Client: ~/.aidevops/.agent-workspace/work/pipecat-voice-agent/client/
  Logs:   ~/.aidevops/logs/pipecat-agent.log

See also:
  tools/voice/pipecat-opencode.md    Pipecat architecture and service options
  voice-helper.sh                    Simple terminal voice bridge
  voice-pipeline-helper.sh           Audio production pipeline
EOF
	return 0
}

# ─── Main ──────────────────────────────────────────────────────────────

main() {
	local command="${1:-help}"
	shift || true

	case "${command}" in
	setup | install)
		cmd_setup "$@"
		;;
	start | run)
		cmd_start "$@"
		;;
	stop | kill)
		cmd_stop
		;;
	status | check)
		cmd_status
		;;
	client | ui)
		cmd_client "$@"
		;;
	keys | api-keys)
		cmd_keys
		;;
	logs | log)
		cmd_logs "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "${ERROR_UNKNOWN_COMMAND}: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
