#!/bin/bash
# =============================================================================
# AutoGen Helper Script
# =============================================================================
# Microsoft AutoGen agentic AI framework setup and management
#
# Usage:
#   bash .agent/scripts/autogen-helper.sh [action]
#
# Actions:
#   setup     Complete setup of AutoGen
#   start     Start AutoGen Studio
#   stop      Stop AutoGen Studio
#   status    Check AutoGen status
#   check     Check prerequisites
#   help      Show this help message
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
AUTOGEN_DIR="$HOME/.aidevops/autogen"
AUTOGEN_STUDIO_PORT="${AUTOGEN_STUDIO_PORT:-8081}"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
LOCALHOST_HELPER="$SCRIPTS_DIR/localhost-helper.sh"

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Port management integration with localhost-helper.sh
# Returns available port (original if free, or next available)
get_available_port() {
    local desired_port="$1"
    
    # Use localhost-helper.sh if available
    if [[ -x "$LOCALHOST_HELPER" ]]; then
        if "$LOCALHOST_HELPER" check-port "$desired_port" >/dev/null 2>&1; then
            echo "$desired_port"
            return 0
        else
            # Port in use, find alternative
            local suggested
            suggested=$("$LOCALHOST_HELPER" find-port "$((desired_port + 1))" 2>/dev/null)
            if [[ -n "$suggested" ]]; then
                print_warning "Port $desired_port in use, using $suggested instead"
                echo "$suggested"
                return 0
            fi
        fi
    fi
    
    # Fallback: basic port check using lsof
    if ! lsof -i :"$desired_port" >/dev/null 2>&1; then
        echo "$desired_port"
        return 0
    fi
    
    # Find next available port
    local port="$desired_port"
    while lsof -i :"$port" >/dev/null 2>&1 && [[ $port -lt 65535 ]]; do
        ((port++))
    done
    
    if [[ $port -lt 65535 ]]; then
        print_warning "Port $desired_port in use, using $port instead"
        echo "$port"
        return 0
    fi
    
    print_error "No available ports found"
    return 1
}

# Check prerequisites
check_prerequisites() {
    local missing=0
    
    print_info "Checking prerequisites..."
    
    # Check Python
    if command -v python3 &> /dev/null; then
        local python_version
        python_version=$(python3 --version 2>&1 | cut -d' ' -f2)
        local major minor
        major=$(echo "$python_version" | cut -d. -f1)
        minor=$(echo "$python_version" | cut -d. -f2)
        
        if [[ $major -ge 3 ]] && [[ $minor -ge 10 ]]; then
            print_success "Python $python_version found (3.10+ required)"
        else
            print_error "Python 3.10+ required, found $python_version"
            missing=1
        fi
    else
        print_error "Python 3 not found"
        missing=1
    fi
    
    # Check pip
    if command -v pip3 &> /dev/null || python3 -m pip --version &> /dev/null; then
        print_success "pip found"
    else
        print_error "pip not found"
        missing=1
    fi
    
    # Check for uv (preferred)
    if command -v uv &> /dev/null; then
        print_success "uv found (preferred package manager)"
    else
        print_warning "uv not found, will use pip"
    fi
    
    if [[ $missing -eq 1 ]]; then
        print_error "Missing prerequisites. Please install them first."
        return 1
    fi
    
    print_success "All prerequisites met"
    return 0
}

# Setup AutoGen
setup_autogen() {
    print_info "Setting up AutoGen..."
    
    # Create directories
    mkdir -p "$AUTOGEN_DIR"
    mkdir -p "$SCRIPTS_DIR"
    
    cd "$AUTOGEN_DIR" || exit 1
    
    # Create virtual environment
    if [[ ! -d "venv" ]]; then
        print_info "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate venv
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    # Install AutoGen
    print_info "Installing AutoGen..."
    if command -v uv &> /dev/null; then
        uv pip install autogen-agentchat -U
        uv pip install 'autogen-ext[openai]' -U
        uv pip install autogenstudio -U
    else
        pip install autogen-agentchat -U
        pip install 'autogen-ext[openai]' -U
        pip install autogenstudio -U
    fi
    
    # Create environment template
    if [[ ! -f ".env.example" ]]; then
        cat > .env.example << 'EOF'
# AutoGen Configuration for AI DevOps Framework
# Copy this file to .env and configure your API keys

# OpenAI Configuration (Required for most agents)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (Optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Azure OpenAI Configuration (Optional)
AZURE_OPENAI_API_KEY=your_azure_key_here
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/

# Google Configuration (Optional)
GOOGLE_API_KEY=your_google_key_here

# Local LLM Configuration (Ollama)
OLLAMA_BASE_URL=http://localhost:11434

# AutoGen Studio Configuration
AUTOGEN_STUDIO_PORT=8081
AUTOGEN_STUDIO_APPDIR=./studio-data

# Security Note: All processing runs locally
# No data is sent to external services unless you configure external LLMs
EOF
        print_success "Created environment template"
    fi
    
    # Copy template to .env if not exists
    if [[ ! -f ".env" ]]; then
        cp .env.example .env
        print_info "Created .env file - please configure your API keys"
    fi
    
    # Create example script
    create_example_script
    
    # Create management scripts
    create_management_scripts
    
    print_success "AutoGen setup complete"
    print_info "Directory: $AUTOGEN_DIR"
    print_info "Configure your API keys in .env file"
    return 0
}

# Create example script
create_example_script() {
    print_info "Creating example script..."
    
    cat > "$AUTOGEN_DIR/hello_autogen.py" << 'EXAMPLEEOF'
"""
AutoGen Hello World Example
AI DevOps Framework Integration
"""
import asyncio
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

async def main():
    from autogen_agentchat.agents import AssistantAgent
    from autogen_ext.models.openai import OpenAIChatCompletionClient
    
    # Create model client
    model_client = OpenAIChatCompletionClient(model="gpt-4o-mini")
    
    # Create agent
    agent = AssistantAgent(
        "assistant",
        model_client=model_client,
        system_message="You are a helpful AI assistant."
    )
    
    # Run a simple task
    print("Running AutoGen agent...")
    result = await agent.run(task="Say 'Hello from AutoGen!' and explain what AutoGen is in one sentence.")
    print(f"\nResult: {result}")
    
    # Clean up
    await model_client.close()

if __name__ == "__main__":
    asyncio.run(main())
EXAMPLEEOF
    
    print_success "Created example script: hello_autogen.py"
    return 0
}

# Create management scripts
create_management_scripts() {
    print_info "Creating management scripts..."
    
    mkdir -p "$SCRIPTS_DIR"
    
    # Create start script
    cat > "$SCRIPTS_DIR/start-autogen-studio.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - AutoGen Studio Startup Script

AUTOGEN_DIR="$HOME/.aidevops/autogen"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
LOCALHOST_HELPER="$SCRIPTS_DIR/localhost-helper.sh"
DESIRED_PORT="${AUTOGEN_STUDIO_PORT:-8081}"
APPDIR="${AUTOGEN_STUDIO_APPDIR:-$AUTOGEN_DIR/studio-data}"

echo "Starting AutoGen Studio..."

# Check port availability using localhost-helper.sh
if [[ -x "$LOCALHOST_HELPER" ]]; then
    if ! "$LOCALHOST_HELPER" check-port "$DESIRED_PORT" >/dev/null 2>&1; then
        echo "[WARNING] Port $DESIRED_PORT is in use"
        SUGGESTED=$("$LOCALHOST_HELPER" find-port "$((DESIRED_PORT + 1))" 2>/dev/null)
        if [[ -n "$SUGGESTED" ]]; then
            echo "[INFO] Using alternative port: $SUGGESTED"
            DESIRED_PORT="$SUGGESTED"
        fi
    fi
else
    # Fallback port check
    if lsof -i :"$DESIRED_PORT" >/dev/null 2>&1; then
        echo "[WARNING] Port $DESIRED_PORT is in use, finding alternative..."
        while lsof -i :"$DESIRED_PORT" >/dev/null 2>&1 && [[ $DESIRED_PORT -lt 65535 ]]; do
            ((DESIRED_PORT++))
        done
        echo "[INFO] Using port: $DESIRED_PORT"
    fi
fi

if [[ -d "$AUTOGEN_DIR/venv" ]]; then
    cd "$AUTOGEN_DIR" || exit 1
    
    # Activate venv
    source venv/bin/activate
    
    # Load environment
    if [[ -f .env ]]; then
        set -a
        source .env
        set +a
    fi
    
    # Create app directory
    mkdir -p "$APPDIR"
    
    # Start AutoGen Studio with available port
    autogenstudio ui --port "$DESIRED_PORT" --appdir "$APPDIR" &
    STUDIO_PID=$!
    echo "$STUDIO_PID" > /tmp/autogen_studio_pid
    echo "$DESIRED_PORT" > /tmp/autogen_studio_port
    
    sleep 5
    
    echo ""
    echo "AutoGen Studio started!"
    echo "URL: http://localhost:$DESIRED_PORT"
    echo ""
    echo "Use 'stop-autogen-studio.sh' to stop"
else
    echo "AutoGen not set up. Run setup first:"
    echo "  bash .agent/scripts/autogen-helper.sh setup"
    exit 1
fi
EOF
    chmod +x "$SCRIPTS_DIR/start-autogen-studio.sh"
    
    # Create stop script
    cat > "$SCRIPTS_DIR/stop-autogen-studio.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - AutoGen Studio Stop Script

echo "Stopping AutoGen Studio..."

if [[ -f /tmp/autogen_studio_pid ]]; then
    STUDIO_PID=$(cat /tmp/autogen_studio_pid)
    if kill -0 "$STUDIO_PID" 2>/dev/null; then
        kill "$STUDIO_PID"
        echo "Stopped AutoGen Studio (PID: $STUDIO_PID)"
    fi
    rm -f /tmp/autogen_studio_pid
fi

# Fallback: kill autogenstudio processes
pkill -f "autogenstudio" 2>/dev/null || true

echo "AutoGen Studio stopped"
EOF
    chmod +x "$SCRIPTS_DIR/stop-autogen-studio.sh"
    
    # Create status script
    cat > "$SCRIPTS_DIR/autogen-status.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - AutoGen Status Script

# Get actual port (from saved file or default)
if [[ -f /tmp/autogen_studio_port ]]; then
    PORT=$(cat /tmp/autogen_studio_port)
else
    PORT="${AUTOGEN_STUDIO_PORT:-8081}"
fi

echo "AutoGen Status"
echo "=============="

# Check if Studio is running
if curl -s "http://localhost:$PORT" >/dev/null 2>&1; then
    echo "AutoGen Studio: Running"
    echo "URL: http://localhost:$PORT"
else
    echo "AutoGen Studio: Not running"
fi

echo ""
echo "Process Information:"
pgrep -f "autogenstudio" && ps aux | grep -E "autogenstudio" | grep -v grep || echo "No AutoGen Studio processes found"

# Check AutoGen packages
echo ""
echo "Installed Packages:"
AUTOGEN_DIR="$HOME/.aidevops/autogen"
if [[ -d "$AUTOGEN_DIR/venv" ]]; then
    source "$AUTOGEN_DIR/venv/bin/activate"
    pip list 2>/dev/null | grep -E "autogen" || echo "AutoGen packages not found"
else
    echo "AutoGen venv not found"
fi
EOF
    chmod +x "$SCRIPTS_DIR/autogen-status.sh"
    
    print_success "Management scripts created in $SCRIPTS_DIR"
    return 0
}

# Start AutoGen Studio
start_studio() {
    if [[ -f "$SCRIPTS_DIR/start-autogen-studio.sh" ]]; then
        "$SCRIPTS_DIR/start-autogen-studio.sh"
    else
        print_error "AutoGen not set up. Run 'setup' first."
        return 1
    fi
    return 0
}

# Stop AutoGen Studio
stop_studio() {
    if [[ -f "$SCRIPTS_DIR/stop-autogen-studio.sh" ]]; then
        "$SCRIPTS_DIR/stop-autogen-studio.sh"
    else
        pkill -f "autogenstudio" 2>/dev/null || true
    fi
    return 0
}

# Check status
check_status() {
    if [[ -f "$SCRIPTS_DIR/autogen-status.sh" ]]; then
        "$SCRIPTS_DIR/autogen-status.sh"
    else
        if curl -s "http://localhost:$AUTOGEN_STUDIO_PORT" >/dev/null 2>&1; then
            print_success "AutoGen Studio is running at http://localhost:$AUTOGEN_STUDIO_PORT"
        else
            print_warning "AutoGen Studio is not running"
        fi
    fi
    return 0
}

# Show usage
show_usage() {
    echo "AI DevOps Framework - AutoGen Helper"
    echo ""
    echo "Usage: $0 [action]"
    echo ""
    echo "Actions:"
    echo "  setup     Complete setup of AutoGen"
    echo "  start     Start AutoGen Studio"
    echo "  stop      Stop AutoGen Studio"
    echo "  status    Check AutoGen status"
    echo "  check     Check prerequisites"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 setup    # Full setup"
    echo "  $0 start    # Start Studio"
    echo "  $0 status   # Check status"
    echo ""
    echo "URLs (after start):"
    echo "  AutoGen Studio: http://localhost:8081"
    return 0
}

# Main function
main() {
    local action="${1:-help}"
    shift || true
    
    case "$action" in
        "setup")
            if check_prerequisites; then
                setup_autogen
                echo ""
                print_success "AutoGen setup complete!"
                echo ""
                echo "Next Steps:"
                echo "1. Configure API keys in $AUTOGEN_DIR/.env"
                echo "2. Start AutoGen Studio: $SCRIPTS_DIR/start-autogen-studio.sh"
                echo "3. Or run example: cd $AUTOGEN_DIR && source venv/bin/activate && python hello_autogen.py"
            fi
            ;;
        "start")
            start_studio
            ;;
        "stop")
            stop_studio
            ;;
        "status")
            check_status
            ;;
        "check")
            check_prerequisites
            ;;
        "help"|*)
            show_usage
            ;;
    esac
    return 0
}

main "$@"
