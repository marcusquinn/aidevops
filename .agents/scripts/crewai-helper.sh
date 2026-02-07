#!/usr/bin/env bash
# =============================================================================
# CrewAI Helper Script
# =============================================================================
# Multi-agent orchestration framework setup and management
#
# Usage:
#   bash .agents/scripts/crewai-helper.sh [action]
#
# Actions:
#   setup     Complete setup of CrewAI
#   start     Start CrewAI Studio
#   stop      Stop CrewAI Studio
#   status    Check CrewAI status
#   check     Check prerequisites
#   create    Create a new crew project
#   run       Run a crew
#   help      Show this help message
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
CREWAI_DIR="$HOME/.aidevops/crewai"
CREWAI_STUDIO_PORT="${CREWAI_STUDIO_PORT:-8501}"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
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

# Setup CrewAI
setup_crewai() {
    print_info "Setting up CrewAI..."
    
    # Create directories
    mkdir -p "$CREWAI_DIR"
    mkdir -p "$SCRIPTS_DIR"
    
    cd "$CREWAI_DIR" || exit 1
    
    # Create virtual environment
    if [[ ! -d "venv" ]]; then
        print_info "Creating virtual environment..."
        python3 -m venv venv
    fi
    
    # Activate venv
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    # Install CrewAI
    print_info "Installing CrewAI..."
    if command -v uv &> /dev/null; then
        uv pip install crewai -U
        uv pip install 'crewai[tools]' -U
        uv pip install streamlit -U
    else
        pip install crewai -U
        pip install 'crewai[tools]' -U
        pip install streamlit -U
    fi
    
    # Create environment template
    if [[ ! -f ".env.example" ]]; then
        cat > .env.example << 'EOF'
# CrewAI Configuration for AI DevOps Framework
# Copy this file to .env and configure your API keys

# OpenAI Configuration (Required for most crews)
OPENAI_API_KEY=your_openai_api_key_here

# Anthropic Configuration (Optional)
ANTHROPIC_API_KEY=your_anthropic_key_here

# Serper API for web search (Optional)
SERPER_API_KEY=your_serper_key_here

# Google Configuration (Optional)
GOOGLE_API_KEY=your_google_key_here

# Local LLM Configuration (Ollama)
OLLAMA_BASE_URL=http://localhost:11434

# CrewAI Configuration
CREWAI_TELEMETRY=false

# CrewAI Studio Port
CREWAI_STUDIO_PORT=8501

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
    
    # Create a simple studio app
    create_studio_app
    
    # Create management scripts
    create_management_scripts
    
    print_success "CrewAI setup complete"
    print_info "Directory: $CREWAI_DIR"
    print_info "Configure your API keys in .env file"
    return 0
}

# Create a simple CrewAI Studio app
create_studio_app() {
    print_info "Creating CrewAI Studio app..."
    
    cat > "$CREWAI_DIR/studio_app.py" << 'STUDIOEOF'
"""
CrewAI Studio - Simple Streamlit Interface
AI DevOps Framework Integration
"""
import streamlit as st
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

st.set_page_config(
    page_title="CrewAI Studio",
    page_icon="🤖",
    layout="wide"
)

st.title("🤖 CrewAI Studio")
st.markdown("*AI DevOps Framework - Multi-Agent Orchestration*")

# Sidebar configuration
st.sidebar.header("Configuration")

# API Key status
openai_key = os.getenv("OPENAI_API_KEY", "")
if openai_key and openai_key != "your_openai_api_key_here":
    st.sidebar.success("✅ OpenAI API Key configured")
else:
    st.sidebar.warning("⚠️ OpenAI API Key not configured")

# Model selection
model = st.sidebar.selectbox(
    "Select Model",
    ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo", "ollama/llama3.2"]
)

# Main content
tab1, tab2, tab3 = st.tabs(["Quick Crew", "Custom Crew", "Documentation"])

with tab1:
    st.header("Quick Crew Builder")
    
    topic = st.text_input("Research Topic", placeholder="Enter a topic to research...")
    
    col1, col2 = st.columns(2)
    with col1:
        num_agents = st.slider("Number of Agents", 1, 5, 2)
    with col2:
        process_type = st.selectbox("Process Type", ["sequential", "hierarchical"])
    
    if st.button("Run Crew", type="primary"):
        if topic:
            with st.spinner("Running crew..."):
                try:
                    from crewai import Agent, Crew, Task, Process
                    
                    # Create agents
                    researcher = Agent(
                        role="Senior Researcher",
                        goal=f"Research {topic} thoroughly",
                        backstory="Expert researcher with deep knowledge.",
                        verbose=True
                    )
                    
                    writer = Agent(
                        role="Content Writer",
                        goal="Create engaging content",
                        backstory="Skilled writer who makes complex topics accessible.",
                        verbose=True
                    )
                    
                    # Create tasks
                    research_task = Task(
                        description=f"Research the topic: {topic}",
                        expected_output="Comprehensive research summary",
                        agent=researcher
                    )
                    
                    writing_task = Task(
                        description="Write a report based on the research",
                        expected_output="Well-written report in markdown",
                        agent=writer
                    )
                    
                    # Create crew
                    crew = Crew(
                        agents=[researcher, writer],
                        tasks=[research_task, writing_task],
                        process=Process.sequential if process_type == "sequential" else Process.hierarchical,
                        verbose=True
                    )
                    
                    result = crew.kickoff()
                    
                    st.success("Crew completed!")
                    st.markdown("### Result")
                    st.markdown(str(result))
                    
                except Exception as e:
                    st.error(f"Error: {str(e)}")
        else:
            st.warning("Please enter a topic")

with tab2:
    st.header("Custom Crew Configuration")
    st.info("For advanced crews, use the CrewAI CLI:")
    st.code("""
# Create a new crew project
crewai create crew my-project

# Navigate to project
cd my-project

# Edit configuration
# - src/my_project/config/agents.yaml
# - src/my_project/config/tasks.yaml

# Run the crew
crewai run
    """, language="bash")

with tab3:
    st.header("Documentation")
    st.markdown("""
    ### Quick Links
    - [CrewAI Documentation](https://docs.crewai.com)
    - [CrewAI GitHub](https://github.com/crewAIInc/crewAI)
    - [CrewAI Examples](https://github.com/crewAIInc/crewAI-examples)
    
    ### Key Concepts
    
    **Agents**: AI entities with roles, goals, and backstories
    
    **Tasks**: Specific assignments with descriptions and expected outputs
    
    **Crews**: Teams of agents working together on tasks
    
    **Flows**: Event-driven workflows for complex orchestration
    
    ### Process Types
    
    - **Sequential**: Tasks executed one after another
    - **Hierarchical**: Manager agent delegates to workers
    """)

# Footer
st.markdown("---")
st.markdown("*Part of the [AI DevOps Framework](https://github.com/marcusquinn/aidevops)*")
STUDIOEOF
    
    print_success "Created CrewAI Studio app"
    return 0
}

# Create management scripts
create_management_scripts() {
    print_info "Creating management scripts..."
    
    mkdir -p "$SCRIPTS_DIR"
    
    # Create start script
    cat > "$SCRIPTS_DIR/start-crewai-studio.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - CrewAI Studio Startup Script

CREWAI_DIR="$HOME/.aidevops/crewai"
SCRIPTS_DIR="$HOME/.aidevops/scripts"
LOCALHOST_HELPER="$SCRIPTS_DIR/localhost-helper.sh"
DESIRED_PORT="${CREWAI_STUDIO_PORT:-8501}"

echo "Starting CrewAI Studio..."

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

if [[ -f "$CREWAI_DIR/studio_app.py" ]]; then
    cd "$CREWAI_DIR" || exit 1
    
    # Activate venv
    source venv/bin/activate
    
    # Load environment
    if [[ -f .env ]]; then
        set -a
        source .env
        set +a
    fi
    
    # Start Streamlit with available port
    streamlit run studio_app.py --server.port "$DESIRED_PORT" --server.headless true &
    STUDIO_PID=$!
    echo "$STUDIO_PID" > /tmp/crewai_studio_pid
    echo "$DESIRED_PORT" > /tmp/crewai_studio_port
    
    sleep 3
    
    echo ""
    echo "CrewAI Studio started!"
    echo "URL: http://localhost:$DESIRED_PORT"
    echo ""
    echo "Use 'stop-crewai-studio.sh' to stop"
else
    echo "CrewAI Studio not set up. Run setup first:"
    echo "  bash .agents/scripts/crewai-helper.sh setup"
    exit 1
fi
EOF
    chmod +x "$SCRIPTS_DIR/start-crewai-studio.sh"
    
    # Create stop script
    cat > "$SCRIPTS_DIR/stop-crewai-studio.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - CrewAI Studio Stop Script

echo "Stopping CrewAI Studio..."

if [[ -f /tmp/crewai_studio_pid ]]; then
    STUDIO_PID=$(cat /tmp/crewai_studio_pid)
    if kill -0 "$STUDIO_PID" 2>/dev/null; then
        kill "$STUDIO_PID"
        echo "Stopped CrewAI Studio (PID: $STUDIO_PID)"
    fi
    rm -f /tmp/crewai_studio_pid
fi

# Fallback: kill streamlit processes
pkill -f "streamlit run studio_app.py" 2>/dev/null || true

echo "CrewAI Studio stopped"
EOF
    chmod +x "$SCRIPTS_DIR/stop-crewai-studio.sh"
    
    # Create status script
    cat > "$SCRIPTS_DIR/crewai-status.sh" << 'EOF'
#!/bin/bash
# AI DevOps Framework - CrewAI Status Script

# Get actual port (from saved file or default)
if [[ -f /tmp/crewai_studio_port ]]; then
    PORT=$(cat /tmp/crewai_studio_port)
else
    PORT="${CREWAI_STUDIO_PORT:-8501}"
fi

echo "CrewAI Status"
echo "============="

# Check if Studio is running
if curl -s "http://localhost:$PORT" >/dev/null 2>&1; then
    echo "CrewAI Studio: Running"
    echo "URL: http://localhost:$PORT"
else
    echo "CrewAI Studio: Not running"
fi

echo ""
echo "Process Information:"
pgrep -f "streamlit.*studio_app" && ps aux | grep -E "streamlit.*studio_app" | grep -v grep || echo "No CrewAI Studio processes found"

# Check CrewAI CLI
echo ""
echo "CrewAI CLI:"
if command -v crewai &> /dev/null; then
    crewai --version 2>/dev/null || echo "CrewAI CLI available"
else
    echo "CrewAI CLI not in PATH (activate venv first)"
fi
EOF
    chmod +x "$SCRIPTS_DIR/crewai-status.sh"
    
    print_success "Management scripts created in $SCRIPTS_DIR"
    return 0
}

# Create a new crew project
create_crew() {
    local project_name="${1:-my-crew}"
    
    print_info "Creating new crew project: $project_name"
    
    if [[ ! -d "$CREWAI_DIR/venv" ]]; then
        print_error "CrewAI not set up. Run 'setup' first."
        return 1
    fi
    
    cd "$CREWAI_DIR" || exit 1
    # shellcheck source=/dev/null
    source venv/bin/activate
    
    crewai create crew "$project_name"
    
    print_success "Created crew project: $project_name"
    print_info "Next steps:"
    echo "  cd $CREWAI_DIR/$project_name"
    echo "  crewai install"
    echo "  crewai run"
    
    return 0
}

# Run a crew
run_crew() {
    local project_dir="${1:-.}"
    
    if [[ ! -d "$CREWAI_DIR/venv" ]]; then
        print_error "CrewAI not set up. Run 'setup' first."
        return 1
    fi
    
    # shellcheck source=/dev/null
    source "$CREWAI_DIR/venv/bin/activate"
    
    cd "$project_dir" || exit 1
    
    if [[ -f "pyproject.toml" ]]; then
        crewai run
    else
        print_error "Not a CrewAI project directory (no pyproject.toml found)"
        return 1
    fi
    
    return 0
}

# Start CrewAI Studio
start_studio() {
    if [[ -f "$SCRIPTS_DIR/start-crewai-studio.sh" ]]; then
        "$SCRIPTS_DIR/start-crewai-studio.sh"
    else
        print_error "CrewAI not set up. Run 'setup' first."
        return 1
    fi
    return 0
}

# Stop CrewAI Studio
stop_studio() {
    if [[ -f "$SCRIPTS_DIR/stop-crewai-studio.sh" ]]; then
        "$SCRIPTS_DIR/stop-crewai-studio.sh"
    else
        pkill -f "streamlit run studio_app.py" 2>/dev/null || true
    fi
    return 0
}

# Check status
check_status() {
    if [[ -f "$SCRIPTS_DIR/crewai-status.sh" ]]; then
        "$SCRIPTS_DIR/crewai-status.sh"
    else
        if curl -s "http://localhost:$CREWAI_STUDIO_PORT" >/dev/null 2>&1; then
            print_success "CrewAI Studio is running at http://localhost:$CREWAI_STUDIO_PORT"
        else
            print_warning "CrewAI Studio is not running"
        fi
    fi
    return 0
}

# Show usage
show_usage() {
    echo "AI DevOps Framework - CrewAI Helper"
    echo ""
    echo "Usage: $0 [action] [options]"
    echo ""
    echo "Actions:"
    echo "  setup     Complete setup of CrewAI"
    echo "  start     Start CrewAI Studio"
    echo "  stop      Stop CrewAI Studio"
    echo "  status    Check CrewAI status"
    echo "  check     Check prerequisites"
    echo "  create    Create a new crew project"
    echo "  run       Run a crew (in current directory)"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 setup                    # Full setup"
    echo "  $0 start                    # Start Studio"
    echo "  $0 create my-research-crew  # Create new project"
    echo "  $0 run                      # Run crew in current dir"
    echo ""
    echo "URLs (after start):"
    echo "  CrewAI Studio: http://localhost:8501"
    return 0
}

# Main function
main() {
    local action="${1:-help}"
    shift || true
    
    case "$action" in
        "setup")
            if check_prerequisites; then
                setup_crewai
                echo ""
                print_success "CrewAI setup complete!"
                echo ""
                echo "Next Steps:"
                echo "1. Configure API keys in $CREWAI_DIR/.env"
                echo "2. Start CrewAI Studio: $SCRIPTS_DIR/start-crewai-studio.sh"
                echo "3. Or create a project: crewai create crew my-project"
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
        "create")
            create_crew "$@"
            ;;
        "run")
            run_crew "$@"
            ;;
        "help"|*)
            show_usage
            ;;
    esac
    return 0
}

main "$@"
