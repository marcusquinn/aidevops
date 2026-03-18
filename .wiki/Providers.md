# Provider Scripts Reference

Complete documentation for all 22 provider helper scripts in the AI DevOps Framework.

## Overview

Provider scripts provide standardized interfaces to interact with different services and platforms. Each script follows a consistent command structure and implements common operations.

## Common Command Pattern

All provider scripts follow this pattern:

```bash
./.agents/scripts/[provider]-helper.sh [command] [arguments...]
```

Common commands across providers:

- `list` - List available resources
- `connect` - Establish SSH connection
- `exec` - Execute remote command
- `info` - Display service information
- `help` - Show usage information

## Infrastructure & Hosting Providers

### Hostinger

**File**: `.agents/scripts/hostinger-helper.sh`

Manage Hostinger shared hosting, domains, and email services.

**Commands**:

```bash
# List all configured servers
./.agents/scripts/hostinger-helper.sh list

# Connect to server via SSH
./.agents/scripts/hostinger-helper.sh connect example.com

# Execute remote command
./.agents/scripts/hostinger-helper.sh exec example.com "uptime"

# Show configuration
./.agents/scripts/hostinger-helper.sh info
```

**Configuration**: `configs/hostinger-config.json`

**Features**:

- SSH connection management
- Remote command execution
- Server information retrieval
- Multi-account support

---

### Hetzner Cloud

**File**: `.agents/scripts/hetzner-helper.sh`

Manage Hetzner VPS servers, networking, and load balancers.

**Commands**:

```bash
# List servers in project
./.agents/scripts/hetzner-helper.sh list [project-name]

# Connect to server
./.agents/scripts/hetzner-helper.sh connect [project-name] [server-name]

# Execute command
./.agents/scripts/hetzner-helper.sh exec [project-name] [server-name] "command"

# Get server info
./.agents/scripts/hetzner-helper.sh info [project-name] [server-name]

# Manage servers
./.agents/scripts/hetzner-helper.sh create [project-name] [server-name] [type]
./.agents/scripts/hetzner-helper.sh delete [project-name] [server-name]
./.agents/scripts/hetzner-helper.sh start [project-name] [server-name]
./.agents/scripts/hetzner-helper.sh stop [project-name] [server-name]
```

**Configuration**: `configs/hetzner-config.json`

**Features**:

- Multi-project support
- Server lifecycle management
- Network configuration
- Load balancer management

---

### Coolify

**File**: `.agents/scripts/coolify-helper.sh`

Manage Coolify self-hosted PaaS and application deployments.

**Commands**:

```bash
# List applications
./.agents/scripts/coolify-helper.sh list

# Deploy application
./.agents/scripts/coolify-helper.sh deploy [app-name]

# Get application status
./.agents/scripts/coolify-helper.sh status [app-name]

# View logs
./.agents/scripts/coolify-helper.sh logs [app-name]
```

**Configuration**: `configs/coolify-config.json`

**Features**:

- Application deployment
- Container management
- Log monitoring
- Environment configuration

---

### Cloudron

**File**: `.agents/scripts/cloudron-helper.sh`

Manage Cloudron server and application platform.

**Commands**:

```bash
# List installed apps
./.agents/scripts/cloudron-helper.sh list

# Install application
./.agents/scripts/cloudron-helper.sh install [app-name]

# Manage apps
./.agents/scripts/cloudron-helper.sh start [app-name]
./.agents/scripts/cloudron-helper.sh stop [app-name]
./.agents/scripts/cloudron-helper.sh restart [app-name]

# Backup management
./.agents/scripts/cloudron-helper.sh backup [app-name]
```

**Configuration**: `configs/cloudron-config.json`

**Features**:

- App marketplace integration
- Automated backups
- User management
- Domain configuration

---

### Closte

**File**: `.agents/scripts/closte-helper.sh`

Manage Closte managed hosting and application deployment.

**Commands**:

```bash
# List sites
./.agents/scripts/closte-helper.sh list

# Site management
./.agents/scripts/closte-helper.sh info [site-name]
```

**Configuration**: `configs/closte-config.json`

---

## Domain & DNS Providers

### Cloudflare (DNS Helper)

**File**: `.agents/scripts/dns-helper.sh`

Unified DNS management across multiple providers with focus on Cloudflare.

**Commands**:

```bash
# List DNS zones
./.agents/scripts/dns-helper.sh cloudflare list-zones

# Add DNS records
./.agents/scripts/dns-helper.sh cloudflare add-record [domain] A [ip-address]
./.agents/scripts/dns-helper.sh cloudflare add-record [domain] CNAME [name] [target]
./.agents/scripts/dns-helper.sh cloudflare add-record [domain] MX [priority] [server]
./.agents/scripts/dns-helper.sh cloudflare add-record [domain] TXT [name] [value]

# Update record
./.agents/scripts/dns-helper.sh cloudflare update-record [domain] [record-id] [type] [value]

# Delete record
./.agents/scripts/dns-helper.sh cloudflare delete-record [domain] [record-id]

# List records
./.agents/scripts/dns-helper.sh cloudflare list-records [domain]

# Manage SSL
./.agents/scripts/dns-helper.sh cloudflare enable-ssl [domain]
./.agents/scripts/dns-helper.sh cloudflare set-ssl-mode [domain] [mode]
```

**Configuration**: `configs/cloudflare-config.json`

**Features**:

- DNS record management (A, AAAA, CNAME, MX, TXT)
- SSL/TLS configuration
- Zone management
- CDN settings

---

### Spaceship

**File**: `.agents/scripts/spaceship-helper.sh`

Domain registration and management via Spaceship.

**Commands**:

```bash
# Check domain availability
./.agents/scripts/spaceship-helper.sh check-availability [domain]

# Purchase domain
./.agents/scripts/spaceship-helper.sh purchase [domain]

# List owned domains
./.agents/scripts/spaceship-helper.sh list

# Manage nameservers
./.agents/scripts/spaceship-helper.sh set-nameservers [domain] [ns1] [ns2]

# Domain info
./.agents/scripts/spaceship-helper.sh info [domain]

# Renew domain
./.agents/scripts/spaceship-helper.sh renew [domain]
```

**Configuration**: `configs/spaceship-config.json`

**Features**:

- Domain availability checking
- Domain registration
- Nameserver management
- Auto-renewal configuration

---

### 101domains

**File**: `.agents/scripts/101domains-helper.sh`

Domain purchasing and DNS management via 101domains.

**Commands**:

```bash
# Check availability
./.agents/scripts/101domains-helper.sh check-availability [domain]

# Search domains
./.agents/scripts/101domains-helper.sh search [keyword]

# Purchase domain
./.agents/scripts/101domains-helper.sh purchase [domain]

# List domains
./.agents/scripts/101domains-helper.sh list

# Manage DNS
./.agents/scripts/101domains-helper.sh add-dns [domain] [type] [value]
./.agents/scripts/101domains-helper.sh list-dns [domain]
```

**Configuration**: `configs/101domains-config.json`

**Features**:

- Domain search and registration
- DNS management
- Bulk domain operations
- Transfer management

---

## Development & Git Platforms

### Git Platforms Helper

**File**: `.agents/scripts/git-platforms-helper.sh`

Unified interface for GitHub, GitLab, and Gitea.

**Commands**:

```bash
# GitHub operations
./.agents/scripts/git-platforms-helper.sh github list-repos
./.agents/scripts/git-platforms-helper.sh github create-repo [name]
./.agents/scripts/git-platforms-helper.sh github delete-repo [name]
./.agents/scripts/git-platforms-helper.sh github clone-repo [name]

# GitLab operations
./.agents/scripts/git-platforms-helper.sh gitlab list-projects
./.agents/scripts/git-platforms-helper.sh gitlab create-project [name]
./.agents/scripts/git-platforms-helper.sh gitlab delete-project [id]

# Gitea operations
./.agents/scripts/git-platforms-helper.sh gitea list-repos
./.agents/scripts/git-platforms-helper.sh gitea create-repo [name]
./.agents/scripts/git-platforms-helper.sh gitea delete-repo [name]
```

**Configuration**: `configs/git-platforms-config.json`

**Features**:

- Multi-platform support (GitHub, GitLab, Gitea)
- Repository management
- Issue tracking
- Pull request operations

---

### Pandoc Helper

**File**: `.agents/scripts/pandoc-helper.sh`

Document format conversion for AI processing.

**Commands**:

```bash
# Convert to markdown
./.agents/scripts/pandoc-helper.sh to-markdown [input-file] [output-file]

# Convert from markdown
./.agents/scripts/pandoc-helper.sh from-markdown [input-file] [format] [output-file]

# Batch conversion
./.agents/scripts/pandoc-helper.sh batch [input-dir] [output-dir] [format]

# Get info
./.agents/scripts/pandoc-helper.sh formats
```

**Supported Formats**:

- Markdown
- HTML
- PDF
- DOCX
- ODT
- LaTeX

**Features**:

- Multi-format conversion
- Batch processing
- Template support
- Metadata preservation

---

### Agno Setup

**File**: `.agents/scripts/agno-setup.sh`

Local AI agent operating system for DevOps automation.

**Commands**:

```bash
# Install Agno
./.agents/scripts/agno-setup.sh install

# Start Agno server
./.agents/scripts/agno-setup.sh start

# Stop Agno server
./.agents/scripts/agno-setup.sh stop

# Status check
./.agents/scripts/agno-setup.sh status

# Configure
./.agents/scripts/agno-setup.sh configure
```

**Configuration**: `configs/agno-config.json`

**Features**:

- Local AI agent orchestration
- DevOps workflow automation
- Tool integration
- Prompt management

---

### LocalWP Helper

**File**: `.agents/scripts/localhost-helper.sh`

WordPress local development environment management.

**Commands**:

```bash
# Create new site
./.agents/scripts/localhost-helper.sh create-site [site-name]

# List sites
./.agents/scripts/localhost-helper.sh list

# Start/stop site
./.agents/scripts/localhost-helper.sh start [site-name]
./.agents/scripts/localhost-helper.sh stop [site-name]

# Delete site
./.agents/scripts/localhost-helper.sh delete [site-name]

# Database operations
./.agents/scripts/localhost-helper.sh export-db [site-name] [output-file]
./.agents/scripts/localhost-helper.sh import-db [site-name] [input-file]
```

**Features**:

- WordPress site creation
- Database management
- Plugin/theme installation
- Local development environment

---

## WordPress & Content Management

### MainWP Helper

**File**: `.agents/scripts/mainwp-helper.sh`

Centralized WordPress management via MainWP.

**Commands**:

```bash
# List all sites
./.agents/scripts/mainwp-helper.sh list-sites

# Site management
./.agents/scripts/mainwp-helper.sh info [site-url]
./.agents/scripts/mainwp-helper.sh sync [site-url]

# Backup operations
./.agents/scripts/mainwp-helper.sh backup [site-url]
./.agents/scripts/mainwp-helper.sh restore [site-url] [backup-id]

# Update management
./.agents/scripts/mainwp-helper.sh update-core [site-url]
./.agents/scripts/mainwp-helper.sh update-plugins [site-url]
./.agents/scripts/mainwp-helper.sh update-themes [site-url]
./.agents/scripts/mainwp-helper.sh update-all [site-url]

# Security scans
./.agents/scripts/mainwp-helper.sh security-scan [site-url]
```

**Configuration**: `configs/mainwp-config.json`

**Features**:

- Multi-site management
- Automated backups
- Bulk updates
- Security monitoring
- Performance tracking

---

## Email & Communication

### AWS SES Helper

**File**: `.agents/scripts/ses-helper.sh`

Amazon Simple Email Service management.

**Commands**:

```bash
# Send email
./.agents/scripts/ses-helper.sh send [to] [subject] [body]

# Verify email address
./.agents/scripts/ses-helper.sh verify [email]

# List verified emails
./.agents/scripts/ses-helper.sh list-verified

# Get send statistics
./.agents/scripts/ses-helper.sh stats

# Manage suppression list
./.agents/scripts/ses-helper.sh list-suppressed
./.agents/scripts/ses-helper.sh remove-suppressed [email]
```

**Configuration**: `configs/ses-config.json`

**Features**:

- Email sending
- Domain verification
- Bounce handling
- Delivery tracking

---

## Security & Secrets Management

### Vaultwarden Helper

**File**: `.agents/scripts/vaultwarden-helper.sh`

Password and secrets management via Vaultwarden.

**Commands**:

```bash
# List items
./.agents/scripts/vaultwarden-helper.sh list

# Get item
./.agents/scripts/vaultwarden-helper.sh get [item-name]

# Add item
./.agents/scripts/vaultwarden-helper.sh add [item-name] [username] [password]

# Update item
./.agents/scripts/vaultwarden-helper.sh update [item-id] [field] [value]

# Delete item
./.agents/scripts/vaultwarden-helper.sh delete [item-id]

# Generate password
./.agents/scripts/vaultwarden-helper.sh generate [length]
```

**Configuration**: `configs/vaultwarden-config.json`

**Features**:

- Secure password storage
- API key management
- Secret sharing
- Password generation

---

## Performance & Quality

### PageSpeed Helper

**File**: `.agents/scripts/pagespeed-helper.sh`

Website performance auditing and optimization.

**Commands**:

```bash
# Run PageSpeed audit
./.agents/scripts/pagespeed-helper.sh audit [url]

# WordPress-specific audit
./.agents/scripts/pagespeed-helper.sh wordpress [url]

# Lighthouse audit
./.agents/scripts/pagespeed-helper.sh lighthouse [url] [format]

# Compare performance
./.agents/scripts/pagespeed-helper.sh compare [url1] [url2]

# Export report
./.agents/scripts/pagespeed-helper.sh export [url] [output-file]
```

**Configuration**: `configs/pagespeed-config.json`

**Features**:

- Performance scoring
- Core Web Vitals
- Optimization suggestions
- Mobile/desktop analysis
- Report generation

---

### Code Audit Helper

**File**: `.agents/scripts/code-audit-helper.sh`

Code quality and security auditing.

**Commands**:

```bash
# Run audit
./.agents/scripts/code-audit-helper.sh audit [directory]

# Security scan
./.agents/scripts/code-audit-helper.sh security [directory]

# Generate report
./.agents/scripts/code-audit-helper.sh report [directory] [output-file]
```

**Features**:

- Static code analysis
- Security vulnerability detection
- Code quality metrics
- Compliance checking

---

## AI & Automation

### DSPy Helper

**File**: `.agents/scripts/dspy-helper.sh`

DSPy framework integration for prompt optimization.

**Commands**:

```bash
# Install DSPy
./.agents/scripts/dspy-helper.sh install

# Run optimization
./.agents/scripts/dspy-helper.sh optimize [prompt-file]

# Test prompts
./.agents/scripts/dspy-helper.sh test [prompt-file]

# Export optimized prompts
./.agents/scripts/dspy-helper.sh export [output-file]
```

**Configuration**: `configs/dspy-config.json`

**Features**:

- Prompt optimization
- Model evaluation
- Chain-of-thought reasoning
- Multi-model support

---

### DSPyGround Helper

**File**: `.agents/scripts/dspyground-helper.sh`

DSPyGround playground for prompt experimentation.

**Commands**:

```bash
# Start playground
./.agents/scripts/dspyground-helper.sh start

# Stop playground
./.agents/scripts/dspyground-helper.sh stop

# Open in browser
./.agents/scripts/dspyground-helper.sh open
```

**Configuration**: `configs/dspyground-config.json`

---

### TOON Helper

**File**: `.agents/scripts/toon-helper.sh`

Token-Oriented Object Notation for efficient LLM data exchange.

**Commands**:

```bash
# Encode JSON to TOON
./.agents/scripts/toon-helper.sh encode [input.json] [output.toon]

# Decode TOON to JSON
./.agents/scripts/toon-helper.sh decode [input.toon] [output.json]

# Compare token efficiency
./.agents/scripts/toon-helper.sh compare [file.json]

# Batch conversion
./.agents/scripts/toon-helper.sh batch [input-dir] [output-dir] [mode]

# Get format info
./.agents/scripts/toon-helper.sh info
```

**Features**:

- 20-60% token reduction
- Human-readable format
- Schema preservation
- Batch processing

---

## Setup & Configuration

### Setup Wizard Helper

**File**: `.agents/scripts/setup-wizard-helper.sh`

Interactive setup wizard for initial configuration.

**Commands**:

```bash
# Run full setup
./.agents/scripts/setup-wizard-helper.sh

# Configure specific provider
./.agents/scripts/setup-wizard-helper.sh provider [provider-name]

# Test configuration
./.agents/scripts/setup-wizard-helper.sh test

# Reset configuration
./.agents/scripts/setup-wizard-helper.sh reset
```

**Features**:

- Interactive configuration
- Credential management
- Connection testing
- Multi-provider setup

---

### Shared Constants

**File**: `.agents/scripts/shared-constants.sh`

Common variables and functions used across all providers.

**Usage**:

```bash
# Source in scripts
source "$(dirname "$0")/shared-constants.sh"

# Available constants
echo "$COLORS_RED"
echo "$COLORS_GREEN"
echo "$CONFIG_DIR"
echo "$LOG_DIR"
```

**Provides**:

- Color codes for output
- Standard paths
- Common functions
- Error handling

---

## Usage Examples

### Multi-Provider Workflow

```bash
# 1. Purchase domain
./.agents/scripts/spaceship-helper.sh purchase example.com

# 2. Configure DNS
./.agents/scripts/dns-helper.sh cloudflare add-record example.com A 192.168.1.1
./.agents/scripts/dns-helper.sh cloudflare enable-ssl example.com

# 3. Deploy application
./.agents/scripts/coolify-helper.sh deploy myapp

# 4. Audit performance
./.agents/scripts/pagespeed-helper.sh wordpress https://example.com

# 5. Backup WordPress
./.agents/scripts/mainwp-helper.sh backup example.com
```

### Server Management Workflow

```bash
# 1. Create Hetzner server
./.agents/scripts/hetzner-helper.sh create main web-server cx11

# 2. Connect and configure
./.agents/scripts/hetzner-helper.sh connect main web-server

# 3. Install Cloudron
./.agents/scripts/cloudron-helper.sh install

# 4. Configure SSL
./.agents/scripts/dns-helper.sh cloudflare enable-ssl example.com
```

## Best Practices

### Error Handling

All scripts implement consistent error handling:

```bash
# Scripts exit with non-zero on error
if ! ./.agents/scripts/hostinger-helper.sh connect example.com; then
    echo "Connection failed"
    exit 1
fi
```

### Logging

Scripts log to `logs/` directory:

```bash
# View logs
tail -f logs/hostinger-helper.log
tail -f logs/dns-helper.log
```

### Configuration Management

Always use configuration files, never hardcode credentials:

```bash
# Good
./.agents/scripts/hostinger-helper.sh list

# Bad - don't pass credentials as arguments
```

## Extending Providers

### Creating New Provider

1. Copy template:

```bash
cp .agents/scripts/template-helper.sh .agents/scripts/newprovider-helper.sh
```

1. Implement standard functions:

- `list()` - List resources
- `connect()` - Connect to service
- `exec()` - Execute operations
- `info()` - Display information

1. Add configuration:

```bash
cp configs/template-config.json.txt configs/newprovider-config.json
```

1. Update documentation

---

**Next**: [MCP Integrations →](MCP-Integrations.md)
