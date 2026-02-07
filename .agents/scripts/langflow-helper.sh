#!/usr/bin/env bash
# =============================================================================
# Langflow Helper Script
# =============================================================================
# Visual AI workflow builder setup and management
#
# Usage:
#   bash .agents/scripts/langflow-helper.sh [action]
#
# Actions:
#   setup     Complete setup of Langflow
#   start     Start Langflow server
#   stop      Stop Langflow server
#   status    Check Langflow status
#   check     Check prerequisites
#   export    Export flows to JSON
#   import    Import flows from JSON
#   help      Show this help message
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
LANGFLOW_DIR="$HOME/.aidevops/langflow"
LANGFLOW_PORT="${LANGFLOW_PORT:-7860}"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
FLOWS_DIR="$LANGFLOW_DIR/flows"
LOCALHOST_HELPER="$SCRIPTS_DIR/localhost-helper.sh"

# Helper functions
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
        print_success "Python 3 found: $python_version"
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
    
    # Check for uv (preferred) or pip
    if command -v uv &> /dev/null; then
        print_success "uv found (preferred package manager)"
    else
        print_warning "uv not found, will use pip (consider installing uv for faster installs)"
    fi
    
    if [[ $missing -eq 1 ]]; then
        print_error "Missing prerequisites. Please install them first."
        return 1
    fi
    
    print_success "All prerequisites met"
    return 0
}

# Setup Langflow
setup_langflow() {
    print_info "Setting up Langflow..."
    
    # Create directories
    mkdir -p "$LANGFLOW_DIR"
    mkdir -p "$FLOWS_DIR"
    mkdir -p "$SCRIPTS_DIR"
    
    cd "$LANGFLOW_DIR" || exit 1
    
    # Create virtual environment
    if [[ ! -d "venv" ]]; then
        print_info "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate venv
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    # Install Langflow
    print_info "Installing Langflow..."
    if command -v uv &> /dev/null; then
        uv pip install langflow -U
    else
        pip install langflow -U
    fi
    
    # Create environment template
    if [[ ! -f ".env.example" ]]; then
        cat > .env.example << 'EOF'
# Langflow Configuration for AI DevOps Framework
# Copy this file to .env and configure your API keys

# OpenAI Configuration (Required for most flows)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (Optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Google Configuration (Optional)
GOOGLE_API_KEY=your_google_key_here

# Langflow Server Configuration
LANGFLOW_HOST=0.0.0.0
LANGFLOW_PORT=7860
LANGFLOW_WORKERS=1
LANGFLOW_LOG_LEVEL=INFO

# Database Configuration (default: SQLite)
# For production, use PostgreSQL:
# LANGFLOW_DATABASE_URL=postgresql://user:password@localhost:5432/langflow

# Local LLM Configuration (Ollama)
OLLAMA_BASE_URL=http://localhost:11434

# MCP Server (enable to expose flows as MCP tools)
LANGFLOW_MCP_ENABLED=false

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
    
    # Create startup script
    cat > start_langflow.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")" || exit
source venv/bin/activate

# Load environment variables
if [[ -f .env ]]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
fi

# Start Langflow
langflow run --host "${LANGFLOW_HOST:-0.0.0.0}" --port "${LANGFLOW_PORT:-7860}"
EOF
    chmod +x start_langflow.sh
    
    # Create management scripts
    create_management_scripts
    
    print_success "Langflow setup complete"
    print_info "Directory: $LANGFLOW_DIR"
    print_info "Configure your API keys in .env file"
    return 0
}

# Create management scripts
create_management_scripts() {
    print_info "Creating management scripts..."
    
    mkdir -p "$SCRIPTS_DIR"
    
    # Create start script
    cat > "$SCRIPTS_DIR/start-langflow.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - Langflow Startup Script

LANGFLOW_DIR="$HOME/.aidevops/langflow"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
LOCALHOST_HELPER="$SCRIPTS_DIR/localhost-helper.sh"
DESIRED_PORT="${LANGFLOW_PORT:-7860}"

echo "Starting Langflow..."

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

if [[ -f "$LANGFLOW_DIR/start_langflow.sh" ]]; then
    cd "$LANGFLOW_DIR" || exit 1
    
    # Export port for the startup script
    export LANGFLOW_PORT="$DESIRED_PORT"
    
    ./start_langflow.sh &
    LANGFLOW_PID=$!
    echo "$LANGFLOW_PID" > /tmp/langflow_pid
    echo "$DESIRED_PORT" > /tmp/langflow_port
    
    # Wait for startup
    sleep 5
    
    if curl -s "http://localhost:$DESIRED_PORT/health" >/dev/null 2>&1; then
        echo ""
        echo "Langflow started successfully!"
        echo "URL: http://localhost:$DESIRED_PORT"
        echo "API Docs: http://localhost:$DESIRED_PORT/docs"
        echo ""
        echo "Use 'stop-langflow.sh' to stop the server"
    else
        echo "Langflow may still be starting. Check http://localhost:$DESIRED_PORT"
    fi
else
    echo "Langflow not set up. Run setup first:"
    echo "  bash .agents/scripts/langflow-helper.sh setup"
    exit 1
fi
EOF
    chmod +x "$SCRIPTS_DIR/start-langflow.sh"
    
    # Create stop script
    cat > "$SCRIPTS_DIR/stop-langflow.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - Langflow Stop Script

echo "Stopping Langflow..."

if [[ -f /tmp/langflow_pid ]]; then
    LANGFLOW_PID=$(cat /tmp/langflow_pid)
    if kill -0 "$LANGFLOW_PID" 2>/dev/null; then
        kill "$LANGFLOW_PID"
        echo "Stopped Langflow (PID: $LANGFLOW_PID)"
    fi
    rm -f /tmp/langflow_pid
fi

# Fallback: kill by port
pkill -f "langflow run" 2>/dev/null || true

echo "Langflow stopped"
EOF
    chmod +x "$SCRIPTS_DIR/stop-langflow.sh"
    
    # Create status script
    cat > "$SCRIPTS_DIR/langflow-status.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - Langflow Status Script

# Get actual port (from saved file or default)
if [[ -f /tmp/langflow_port ]]; then
    PORT=$(cat /tmp/langflow_port)
else
    PORT="${LANGFLOW_PORT:-7860}"
fi

echo "Langflow Status"
echo "==============="

# Check if running
if curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "Status: Running"
    echo "URL: http://localhost:$PORT"
    echo "API Docs: http://localhost:$PORT/docs"
else
    echo "Status: Not running"
fi

echo ""
echo "Process Information:"
pgrep -f "langflow" && ps aux | grep -E "langflow" | grep -v grep || echo "No Langflow processes found"
EOF
    chmod +x "$SCRIPTS_DIR/langflow-status.sh"
    
    print_success "Management scripts created in $SCRIPTS_DIR"
    return 0
}

# Start Langflow
start_langflow() {
    if [[ -f "$SCRIPTS_DIR/start-langflow.sh" ]]; then
        "$SCRIPTS_DIR/start-langflow.sh"
    else
        print_error "Langflow not set up. Run 'setup' first."
        return 1
    fi
    return 0
}

# Stop Langflow
stop_langflow() {
    if [[ -f "$SCRIPTS_DIR/stop-langflow.sh" ]]; then
        "$SCRIPTS_DIR/stop-langflow.sh"
    else
        print_warning "Stop script not found. Attempting to kill Langflow processes..."
        pkill -f "langflow run" 2>/dev/null || true
    fi
    return 0
}

# Check status
check_status() {
    if [[ -f "$SCRIPTS_DIR/langflow-status.sh" ]]; then
        "$SCRIPTS_DIR/langflow-status.sh"
    else
        if curl -s "http://localhost:$LANGFLOW_PORT/health" >/dev/null 2>&1; then
            print_success "Langflow is running at http://localhost:$LANGFLOW_PORT"
        else
            print_warning "Langflow is not running"
        fi
    fi
    return 0
}

# Export flows
export_flows() {
    local output_dir="${1:-$FLOWS_DIR}"
    
    print_info "Exporting flows to $output_dir..."
    
    if [[ ! -d "$LANGFLOW_DIR/venv" ]]; then
        print_error "Langflow not set up. Run 'setup' first."
        return 1
    fi
    
    cd "$LANGFLOW_DIR" || exit 1
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    mkdir -p "$output_dir"
    
    # Export all flows
    if langflow export --all --output "$output_dir" 2>/dev/null; then
        print_success "Flows exported to $output_dir"
    else
        print_warning "No flows to export or export failed"
    fi
    
    return 0
}

# Import flows
import_flows() {
    local input_dir="${1:-$FLOWS_DIR}"
    
    print_info "Importing flows from $input_dir..."
    
    if [[ ! -d "$LANGFLOW_DIR/venv" ]]; then
        print_error "Langflow not set up. Run 'setup' first."
        return 1
    fi
    
    if [[ ! -d "$input_dir" ]]; then
        print_error "Directory not found: $input_dir"
        return 1
    fi
    
    cd "$LANGFLOW_DIR" || exit 1
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    # Import all JSON files
    local count=0
    for flow_file in "$input_dir"/*.json; do
        if [[ -f "$flow_file" ]]; then
            if langflow import --file "$flow_file" 2>/dev/null; then
                print_success "Imported: $(basename "$flow_file")"
                ((count++))
            else
                print_warning "Failed to import: $(basename "$flow_file")"
            fi
        fi
    done
    
    if [[ $count -eq 0 ]]; then
        print_warning "No flows found to import"
    else
        print_success "Imported $count flows"
    fi
    
    return 0
}

# Show usage
show_usage() {
    echo "AI DevOps Framework - Langflow Helper"
    echo ""
    echo "Usage: $0 [action] [options]"
    echo ""
    echo "Actions:"
    echo "  setup     Complete setup of Langflow"
    echo "  start     Start Langflow server"
    echo "  stop      Stop Langflow server"
    echo "  status    Check Langflow status"
    echo "  check     Check prerequisites"
    echo "  export    Export flows to JSON (default: ~/.aidevops/langflow/flows/)"
    echo "  import    Import flows from JSON (default: ~/.aidevops/langflow/flows/)"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 setup              # Full setup"
    echo "  $0 start              # Start server"
    echo "  $0 status             # Check status"
    echo "  $0 export ./my-flows  # Export to custom directory"
    echo "  $0 import ./my-flows  # Import from custom directory"
    echo ""
    echo "URLs (after start):"
    echo "  Web UI:    http://localhost:7860"
    echo "  API Docs:  http://localhost:7860/docs"
    echo "  Health:    http://localhost:7860/health"
    return 0
}

# Main function
main() {
    local action="${1:-help}"
    shift || true
    
    case "$action" in
        "setup")
            if check_prerequisites; then
                setup_langflow
                echo ""
                print_success "Langflow setup complete!"
                echo ""
                echo "Next Steps:"
                echo "1. Configure API keys in $LANGFLOW_DIR/.env"
                echo "2. Start Langflow: $SCRIPTS_DIR/start-langflow.sh"
                echo "3. Open http://localhost:7860"
            fi
            ;;
        "start")
            start_langflow
            ;;
        "stop")
            stop_langflow
            ;;
        "status")
            check_status
            ;;
        "check")
            check_prerequisites
            ;;
        "export")
            export_flows "$@"
            ;;
        "import")
            import_flows "$@"
            ;;
        "help"|*)
            show_usage
            ;;
    esac
    return 0
}

main "$@"
