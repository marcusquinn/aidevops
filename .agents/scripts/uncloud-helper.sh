#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

# Uncloud Helper Script
# CLI wrapper for common Uncloud (uc) operations
# Docs: https://uncloud.run/docs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Check if uc CLI is installed
check_uc() {
    if ! command -v uc >/dev/null 2>&1; then
        print_error "Uncloud CLI (uc) is not installed"
        print_info "Install via Homebrew: brew install psviderski/tap/uncloud"
        print_info "Install via curl: curl -fsS https://get.uncloud.run/install.sh | sh"
        return 1
    fi
    return 0
}

# Show cluster status (machines + services)
cmd_status() {
    check_uc || return 1

    print_info "Cluster machines:"
    uc machine ls 2>&1 || print_warning "No cluster configured or machines unreachable"

    echo ""
    print_info "Services:"
    uc ls 2>&1 || print_warning "No services running"

    echo ""
    print_info "Containers:"
    uc ps 2>&1 || print_warning "No containers running"

    return 0
}

# List machines
cmd_machines() {
    check_uc || return 1
    uc machine ls
    return 0
}

# List services
cmd_services() {
    check_uc || return 1
    uc ls
    return 0
}

# Deploy from compose.yaml
cmd_deploy() {
    local compose_file="${1:-}"
    check_uc || return 1

    local args=()
    if [[ -n "$compose_file" ]]; then
        args+=("-f" "$compose_file")
    fi

    print_info "Deploying services..."
    uc deploy "${args[@]}"
    return 0
}

# Run a service from an image
cmd_run() {
    check_uc || return 1

    if [[ $# -eq 0 ]]; then
        print_error "Usage: run <image> [uc run flags]"
        print_info "Example: run my-app:latest -p app.example.com:8000/https"
        return 1
    fi

    uc run "$@"
    return 0
}

# Scale a service
cmd_scale() {
    local service="${1:-}"
    local replicas="${2:-}"
    check_uc || return 1

    if [[ -z "$service" || -z "$replicas" ]]; then
        print_error "Usage: scale <service> <replicas>"
        return 1
    fi

    print_info "Scaling $service to $replicas replicas..."
    uc scale "$service" "$replicas"
    return 0
}

# View service logs
cmd_logs() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: logs <service> [--follow]"
        return 1
    fi

    shift
    uc logs "$service" "$@"
    return 0
}

# Execute command in a service container
cmd_exec() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: exec <service> [-- command]"
        return 1
    fi

    shift
    uc exec "$service" "$@"
    return 0
}

# Inspect a service
cmd_inspect() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: inspect <service>"
        return 1
    fi

    uc inspect "$service"
    return 0
}

# Volume management
cmd_volumes() {
    check_uc || return 1
    uc volume ls
    return 0
}

# DNS management
cmd_dns() {
    check_uc || return 1
    uc dns show
    return 0
}

# Caddy management
cmd_caddy() {
    local subcmd="${1:-config}"
    check_uc || return 1

    case "$subcmd" in
        config)
            uc caddy config
            ;;
        deploy)
            uc caddy deploy
            ;;
        *)
            print_error "Unknown caddy subcommand: $subcmd"
            print_info "Available: config, deploy"
            return 1
            ;;
    esac
    return 0
}

# Machine init (initialise new cluster)
cmd_init() {
    local ssh_target="${1:-}"
    local name="${2:-}"
    check_uc || return 1

    if [[ -z "$ssh_target" ]]; then
        print_error "Usage: init <user@host> [--name machine-name]"
        return 1
    fi

    local args=("$ssh_target")
    if [[ -n "$name" ]]; then
        args=("--name" "$name" "$ssh_target")
    fi

    print_info "Initialising cluster with machine $ssh_target..."
    uc machine init "${args[@]}"
    return 0
}

# Add machine to cluster
cmd_add_machine() {
    local ssh_target="${1:-}"
    local name="${2:-}"
    check_uc || return 1

    if [[ -z "$ssh_target" ]]; then
        print_error "Usage: add-machine <user@host> [machine-name]"
        return 1
    fi

    local args=("$ssh_target")
    if [[ -n "$name" ]]; then
        args=("--name" "$name" "$ssh_target")
    fi

    print_info "Adding machine $ssh_target to cluster..."
    uc machine add "${args[@]}"
    return 0
}

# Remove a service
cmd_rm() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: rm <service>"
        return 1
    fi

    print_warning "Removing service: $service"
    uc rm "$service"
    return 0
}

# Stop a service
cmd_stop() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: stop <service>"
        return 1
    fi

    uc stop "$service"
    return 0
}

# Start a service
cmd_start() {
    local service="${1:-}"
    check_uc || return 1

    if [[ -z "$service" ]]; then
        print_error "Usage: start <service>"
        return 1
    fi

    uc start "$service"
    return 0
}

# Push image to cluster
cmd_push() {
    local image="${1:-}"
    check_uc || return 1

    if [[ -z "$image" ]]; then
        print_error "Usage: push <image:tag>"
        return 1
    fi

    print_info "Pushing image $image to cluster..."
    uc image push "$image"
    return 0
}

# WireGuard network info
cmd_network() {
    check_uc || return 1
    uc wg show
    return 0
}

# Context management
cmd_context() {
    local subcmd="${1:-ls}"
    check_uc || return 1

    case "$subcmd" in
        ls|list)
            uc ctx ls
            ;;
        use)
            local ctx="${2:-}"
            if [[ -z "$ctx" ]]; then
                print_error "Usage: context use <context-name>"
                return 1
            fi
            uc ctx use "$ctx"
            ;;
        *)
            print_error "Unknown context subcommand: $subcmd"
            print_info "Available: ls, use"
            return 1
            ;;
    esac
    return 0
}

# Show help
cmd_help() {
    echo "Uncloud Helper Script"
    echo "${HELP_LABEL_USAGE} $0 [command] [args]"
    echo ""
    echo "Cluster Management:"
    echo "  status                          - Show cluster status (machines, services, containers)"
    echo "  init <user@host> [name]         - Initialise a new cluster with first machine"
    echo "  add-machine <user@host> [name]  - Add a machine to the cluster"
    echo "  machines                        - List machines in the cluster"
    echo "  network                         - Show WireGuard network info"
    echo "  context [ls|use <name>]         - Manage cluster contexts"
    echo ""
    echo "Service Management:"
    echo "  services                        - List services"
    echo "  deploy [compose-file]           - Deploy services from compose.yaml"
    echo "  run <image> [flags]             - Run a service from a Docker image"
    echo "  scale <service> <replicas>      - Scale a service"
    echo "  start <service>                 - Start a service"
    echo "  stop <service>                  - Stop a service"
    echo "  rm <service>                    - Remove a service"
    echo "  logs <service> [--follow]       - View service logs"
    echo "  exec <service> [-- cmd]         - Execute command in service container"
    echo "  inspect <service>               - Show service details"
    echo ""
    echo "Infrastructure:"
    echo "  push <image:tag>                - Push Docker image to cluster (Unregistry)"
    echo "  volumes                         - List volumes"
    echo "  dns                             - Show cluster DNS domain"
    echo "  caddy [config|deploy]           - Manage Caddy reverse proxy"
    echo ""
    echo "${HELP_LABEL_EXAMPLES}"
    echo "  $0 status"
    echo "  $0 init root@server.example.com my-server"
    echo "  $0 deploy"
    echo "  $0 run my-app:latest -p app.example.com:8000/https"
    echo "  $0 scale my-service 3"
    echo "  $0 logs my-service --follow"
    echo ""
    echo "Requirements:"
    echo "  - uc CLI (brew install psviderski/tap/uncloud)"
    echo "  - SSH access to target machines"
    echo "  - Docs: https://uncloud.run/docs"
    return 0
}

# Main function
main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "$command" in
        status)         cmd_status ;;
        machines)       cmd_machines ;;
        services)       cmd_services ;;
        deploy)         cmd_deploy "$@" ;;
        run)            cmd_run "$@" ;;
        scale)          cmd_scale "$@" ;;
        logs)           cmd_logs "$@" ;;
        exec)           cmd_exec "$@" ;;
        inspect)        cmd_inspect "$@" ;;
        volumes)        cmd_volumes ;;
        dns)            cmd_dns ;;
        caddy)          cmd_caddy "$@" ;;
        init)           cmd_init "$@" ;;
        add-machine)    cmd_add_machine "$@" ;;
        rm)             cmd_rm "$@" ;;
        stop)           cmd_stop "$@" ;;
        start)          cmd_start "$@" ;;
        push)           cmd_push "$@" ;;
        network)        cmd_network ;;
        context)        cmd_context "$@" ;;
        help|-h|--help) cmd_help ;;
        *)
            print_error "${ERROR_UNKNOWN_COMMAND} ${command}"
            print_info "Run '$0 help' for usage information"
            return 1
            ;;
    esac
    return 0
}

main "$@"
