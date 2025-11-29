# Provider Scripts Reference

Complete documentation for all 22 provider helper scripts in the AI DevOps Framework.

## Overview

Provider scripts provide standardized interfaces to interact with different services and platforms. Each script follows a consistent command structure and implements common operations.

## Common Command Pattern

All provider scripts follow this pattern:

```bash
./.agent/scripts/[provider]-helper.sh [command] [arguments...]
```

Common commands across providers:

- `list` - List available resources
- `connect` - Establish SSH connection
- `exec` - Execute remote command
- `info` - Display service information
- `help` - Show usage information

## Infrastructure & Hosting Providers

### Hostinger

**File**: `.agent/scripts/hostinger-helper.sh`

Manage Hostinger shared hosting, domains, and email services.

**Commands**:

```bash
# List all configured servers
./.agent/scripts/hostinger-helper.sh list

# Connect to server via SSH
./.agent/scripts/hostinger-helper.sh connect example.com

# Execute remote command
./.agent/scripts/hostinger-helper.sh exec example.com "uptime"

# Show configuration
./.agent/scripts/hostinger-helper.sh info
```

**Configuration**: `configs/hostinger-config.json`

**Features**:

- SSH connection management
- Remote command execution
- Server information retrieval
- Multi-account support

---

### Hetzner Cloud

**File**: `.agent/scripts/hetzner-helper.sh`

Manage Hetzner VPS servers, networking, and load balancers.

**Commands**:

```bash
# List servers in project
./.agent/scripts/hetzner-helper.sh list [project-name]

# Connect to server
./.agent/scripts/hetzner-helper.sh connect [project-name] [server-name]

# Execute command
./.agent/scripts/hetzner-helper.sh exec [project-name] [server-name] "command"

# Get server info
./.agent/scripts/hetzner-helper.sh info [project-name] [server-name]

# Manage servers
./.agent/scripts/hetzner-helper.sh create [project-name] [server-name] [type]
./.agent/scripts/hetzner-helper.sh delete [project-name] [server-name]
./.agent/scripts/hetzner-helper.sh start [project-name] [server-name]
./.agent/scripts/hetzner-helper.sh stop [project-name] [server-name]
```

**Configuration**: `configs/hetzner-config.json`

**Features**:

- Multi-project support
- Server lifecycle management
- Network configuration
- Load balancer management

---

### Coolify

**File**: `.agent/scripts/coolify-helper.sh`

Manage Coolify self-hosted PaaS and application deployments.

**Commands**:

```bash
# List applications
./.agent/scripts/coolify-helper.sh list

# Deploy application
./.agent/scripts/coolify-helper.sh deploy [app-name]

# Get application status
./.agent/scripts/coolify-helper.sh status [app-name]

# View logs
./.agent/scripts/coolify-helper.sh logs [app-name]
```

**Configuration**: `configs/coolify-config.json`

**Features**:

- Application deployment
- Container management
- Log monitoring
- Environment configuration

---

### Cloudron

**File**: `.agent/scripts/cloudron-helper.sh`

Manage Cloudron server and application platform.

**Commands**:

```bash
# List installed apps
./.agent/scripts/cloudron-helper.sh list

# Install application
./.agent/scripts/cloudron-helper.sh install [app-name]

# Manage apps
./.agent/scripts/cloudron-helper.sh start [app-name]
./.agent/scripts/cloudron-helper.sh stop [app-name]
./.agent/scripts/cloudron-helper.sh restart [app-name]

# Backup management
./.agent/scripts/cloudron-helper.sh backup [app-name]
```

**Configuration**: `configs/cloudron-config.json`

**Features**:

- App marketplace integration
- Automated backups
- User management
- Domain configuration

---

### Closte

**File**: `.agent/scripts/closte-helper.sh`

Manage Closte managed hosting and application deployment.

**Commands**:

```bash
# List sites
./.agent/scripts/closte-helper.sh list

# Site management
./.agent/scripts/closte-helper.sh info [site-name]
```

**Configuration**: `configs/closte-config.json`

---

## Domain & DNS Providers

### Cloudflare (DNS Helper)

**File**: `.agent/scripts/dns-helper.sh`

Unified DNS management across multiple providers with focus on Cloudflare.

**Commands**:

```bash
# List DNS zones
./.agent/scripts/dns-helper.sh cloudflare list-zones

# Add DNS records
./.agent/scripts/dns-helper.sh cloudflare add-record [domain] A [ip-address]
./.agent/scripts/dns-helper.sh cloudflare add-record [domain] CNAME [name] [target]
./.agent/scripts/dns-helper.sh cloudflare add-record [domain] MX [priority] [server]
./.agent/scripts/dns-helper.sh cloudflare add-record [domain] TXT [name] [value]

# Update record
./.agent/scripts/dns-helper.sh cloudflare update-record [domain] [record-id] [type] [value]

# Delete record
./.agent/scripts/dns-helper.sh cloudflare delete-record [domain] [record-id]

# List records
./.agent/scripts/dns-helper.sh cloudflare list-records [domain]

# Manage SSL
./.agent/scripts/dns-helper.sh cloudflare enable-ssl [domain]
./.agent/scripts/dns-helper.sh cloudflare set-ssl-mode [domain] [mode]
```

**Configuration**: `configs/cloudflare-config.json`

**Features**:

- DNS record management (A, AAAA, CNAME, MX, TXT)
- SSL/TLS configuration
- Zone management
- CDN settings

---

### Spaceship

**File**: `.agent/scripts/spaceship-helper.sh`

Domain registration and management via Spaceship.

**Commands**:

```bash
# Check domain availability
./.agent/scripts/spaceship-helper.sh check-availability [domain]

# Purchase domain
./.agent/scripts/spaceship-helper.sh purchase [domain]

# List owned domains
./.agent/scripts/spaceship-helper.sh list

# Manage nameservers
./.agent/scripts/spaceship-helper.sh set-nameservers [domain] [ns1] [ns2]

# Domain info
./.agent/scripts/spaceship-helper.sh info [domain]

# Renew domain
./.agent/scripts/spaceship-helper.sh renew [domain]
```

**Configuration**: `configs/spaceship-config.json`

**Features**:

- Domain availability checking
- Domain registration
- Nameserver management
- Auto-renewal configuration

---

### 101domains

**File**: `.agent/scripts/101domains-helper.sh`

Domain purchasing and DNS management via 101domains.

**Commands**:

```bash
# Check availability
./.agent/scripts/101domains-helper.sh check-availability [domain]

# Search domains
./.agent/scripts/101domains-helper.sh search [keyword]

# Purchase domain
./.agent/scripts/101domains-helper.sh purchase [domain]

# List domains
./.agent/scripts/101domains-helper.sh list

# Manage DNS
./.agent/scripts/101domains-helper.sh add-dns [domain] [type] [value]
./.agent/scripts/101domains-helper.sh list-dns [domain]
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

**File**: `.agent/scripts/git-platforms-helper.sh`

Unified interface for GitHub, GitLab, and Gitea.

**Commands**:

```bash
# GitHub operations
./.agent/scripts/git-platforms-helper.sh github list-repos
./.agent/scripts/git-platforms-helper.sh github create-repo [name]
./.agent/scripts/git-platforms-helper.sh github delete-repo [name]
./.agent/scripts/git-platforms-helper.sh github clone-repo [name]

# GitLab operations
./.agent/scripts/git-platforms-helper.sh gitlab list-projects
./.agent/scripts/git-platforms-helper.sh gitlab create-project [name]
./.agent/scripts/git-platforms-helper.sh gitlab delete-project [id]

# Gitea operations
./.agent/scripts/git-platforms-helper.sh gitea list-repos
./.agent/scripts/git-platforms-helper.sh gitea create-repo [name]
./.agent/scripts/git-platforms-helper.sh gitea delete-repo [name]
```

**Configuration**: `configs/git-platforms-config.json`

**Features**:

- Multi-platform support (GitHub, GitLab, Gitea)
- Repository management
- Issue tracking
- Pull request operations

---

### Pandoc Helper

**File**: `.agent/scripts/pandoc-helper.sh`

Document format conversion for AI processing.

**Commands**:

```bash
# Convert to markdown
./.agent/scripts/pandoc-helper.sh to-markdown [input-file] [output-file]

# Convert from markdown
./.agent/scripts/pandoc-helper.sh from-markdown [input-file] [format] [output-file]

# Batch conversion
./.agent/scripts/pandoc-helper.sh batch [input-dir] [output-dir] [format]

# Get info
./.agent/scripts/pandoc-helper.sh formats
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

**File**: `.agent/scripts/agno-setup.sh`

Local AI agent operating system for DevOps automation.

**Commands**:

```bash
# Install Agno
./.agent/scripts/agno-setup.sh install

# Start Agno server
./.agent/scripts/agno-setup.sh start

# Stop Agno server
./.agent/scripts/agno-setup.sh stop

# Status check
./.agent/scripts/agno-setup.sh status

# Configure
./.agent/scripts/agno-setup.sh configure
```

**Configuration**: `configs/agno-config.json`

**Features**:

- Local AI agent orchestration
- DevOps workflow automation
- Tool integration
- Prompt management

---

### LocalWP Helper

**File**: `.agent/scripts/localhost-helper.sh`

WordPress local development environment management.

**Commands**:

```bash
# Create new site
./.agent/scripts/localhost-helper.sh create-site [site-name]

# List sites
./.agent/scripts/localhost-helper.sh list

# Start/stop site
./.agent/scripts/localhost-helper.sh start [site-name]
./.agent/scripts/localhost-helper.sh stop [site-name]

# Delete site
./.agent/scripts/localhost-helper.sh delete [site-name]

# Database operations
./.agent/scripts/localhost-helper.sh export-db [site-name] [output-file]
./.agent/scripts/localhost-helper.sh import-db [site-name] [input-file]
```

**Features**:

- WordPress site creation
- Database management
- Plugin/theme installation
- Local development environment

---

## WordPress & Content Management

### MainWP Helper

**File**: `.agent/scripts/mainwp-helper.sh`

Centralized WordPress management via MainWP.

**Commands**:

```bash
# List all sites
./.agent/scripts/mainwp-helper.sh list-sites

# Site management
./.agent/scripts/mainwp-helper.sh info [site-url]
./.agent/scripts/mainwp-helper.sh sync [site-url]

# Backup operations
./.agent/scripts/mainwp-helper.sh backup [site-url]
./.agent/scripts/mainwp-helper.sh restore [site-url] [backup-id]

# Update management
./.agent/scripts/mainwp-helper.sh update-core [site-url]
./.agent/scripts/mainwp-helper.sh update-plugins [site-url]
./.agent/scripts/mainwp-helper.sh update-themes [site-url]
./.agent/scripts/mainwp-helper.sh update-all [site-url]

# Security scans
./.agent/scripts/mainwp-helper.sh security-scan [site-url]
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

**File**: `.agent/scripts/ses-helper.sh`

Amazon Simple Email Service management.

**Commands**:

```bash
# Send email
./.agent/scripts/ses-helper.sh send [to] [subject] [body]

# Verify email address
./.agent/scripts/ses-helper.sh verify [email]

# List verified emails
./.agent/scripts/ses-helper.sh list-verified

# Get send statistics
./.agent/scripts/ses-helper.sh stats

# Manage suppression list
./.agent/scripts/ses-helper.sh list-suppressed
./.agent/scripts/ses-helper.sh remove-suppressed [email]
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

**File**: `.agent/scripts/vaultwarden-helper.sh`

Password and secrets management via Vaultwarden.

**Commands**:

```bash
# List items
./.agent/scripts/vaultwarden-helper.sh list

# Get item
./.agent/scripts/vaultwarden-helper.sh get [item-name]

# Add item
./.agent/scripts/vaultwarden-helper.sh add [item-name] [username] [password]

# Update item
./.agent/scripts/vaultwarden-helper.sh update [item-id] [field] [value]

# Delete item
./.agent/scripts/vaultwarden-helper.sh delete [item-id]

# Generate password
./.agent/scripts/vaultwarden-helper.sh generate [length]
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

**File**: `.agent/scripts/pagespeed-helper.sh`

Website performance auditing and optimization.

**Commands**:

```bash
# Run PageSpeed audit
./.agent/scripts/pagespeed-helper.sh audit [url]

# WordPress-specific audit
./.agent/scripts/pagespeed-helper.sh wordpress [url]

# Lighthouse audit
./.agent/scripts/pagespeed-helper.sh lighthouse [url] [format]

# Compare performance
./.agent/scripts/pagespeed-helper.sh compare [url1] [url2]

# Export report
./.agent/scripts/pagespeed-helper.sh export [url] [output-file]
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

**File**: `.agent/scripts/code-audit-helper.sh`

Code quality and security auditing.

**Commands**:

```bash
# Run audit
./.agent/scripts/code-audit-helper.sh audit [directory]

# Security scan
./.agent/scripts/code-audit-helper.sh security [directory]

# Generate report
./.agent/scripts/code-audit-helper.sh report [directory] [output-file]
```

**Features**:

- Static code analysis
- Security vulnerability detection
- Code quality metrics
- Compliance checking

---

## AI & Automation

### DSPy Helper

**File**: `.agent/scripts/dspy-helper.sh`

DSPy framework integration for prompt optimization.

**Commands**:

```bash
# Install DSPy
./.agent/scripts/dspy-helper.sh install

# Run optimization
./.agent/scripts/dspy-helper.sh optimize [prompt-file]

# Test prompts
./.agent/scripts/dspy-helper.sh test [prompt-file]

# Export optimized prompts
./.agent/scripts/dspy-helper.sh export [output-file]
```

**Configuration**: `configs/dspy-config.json`

**Features**:

- Prompt optimization
- Model evaluation
- Chain-of-thought reasoning
- Multi-model support

---

### DSPyGround Helper

**File**: `.agent/scripts/dspyground-helper.sh`

DSPyGround playground for prompt experimentation.

**Commands**:

```bash
# Start playground
./.agent/scripts/dspyground-helper.sh start

# Stop playground
./.agent/scripts/dspyground-helper.sh stop

# Open in browser
./.agent/scripts/dspyground-helper.sh open
```

**Configuration**: `configs/dspyground-config.json`

---

### TOON Helper

**File**: `.agent/scripts/toon-helper.sh`

Token-Oriented Object Notation for efficient LLM data exchange.

**Commands**:

```bash
# Encode JSON to TOON
./.agent/scripts/toon-helper.sh encode [input.json] [output.toon]

# Decode TOON to JSON
./.agent/scripts/toon-helper.sh decode [input.toon] [output.json]

# Compare token efficiency
./.agent/scripts/toon-helper.sh compare [file.json]

# Batch conversion
./.agent/scripts/toon-helper.sh batch [input-dir] [output-dir] [mode]

# Get format info
./.agent/scripts/toon-helper.sh info
```

**Features**:

- 20-60% token reduction
- Human-readable format
- Schema preservation
- Batch processing

---

## Setup & Configuration

### Setup Wizard Helper

**File**: `.agent/scripts/setup-wizard-helper.sh`

Interactive setup wizard for initial configuration.

**Commands**:

```bash
# Run full setup
./.agent/scripts/setup-wizard-helper.sh

# Configure specific provider
./.agent/scripts/setup-wizard-helper.sh provider [provider-name]

# Test configuration
./.agent/scripts/setup-wizard-helper.sh test

# Reset configuration
./.agent/scripts/setup-wizard-helper.sh reset
```

**Features**:

- Interactive configuration
- Credential management
- Connection testing
- Multi-provider setup

---

### Shared Constants

**File**: `.agent/scripts/shared-constants.sh`

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
./.agent/scripts/spaceship-helper.sh purchase example.com

# 2. Configure DNS
./.agent/scripts/dns-helper.sh cloudflare add-record example.com A 192.168.1.1
./.agent/scripts/dns-helper.sh cloudflare enable-ssl example.com

# 3. Deploy application
./.agent/scripts/coolify-helper.sh deploy myapp

# 4. Audit performance
./.agent/scripts/pagespeed-helper.sh wordpress https://example.com

# 5. Backup WordPress
./.agent/scripts/mainwp-helper.sh backup example.com
```

### Server Management Workflow

```bash
# 1. Create Hetzner server
./.agent/scripts/hetzner-helper.sh create main web-server cx11

# 2. Connect and configure
./.agent/scripts/hetzner-helper.sh connect main web-server

# 3. Install Cloudron
./.agent/scripts/cloudron-helper.sh install

# 4. Configure SSL
./.agent/scripts/dns-helper.sh cloudflare enable-ssl example.com
```

## Best Practices

### Error Handling

All scripts implement consistent error handling:

```bash
# Scripts exit with non-zero on error
if ! ./.agent/scripts/hostinger-helper.sh connect example.com; then
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
./.agent/scripts/hostinger-helper.sh list

# Bad - don't pass credentials as arguments
```

## Extending Providers

### Creating New Provider

1. Copy template:

```bash
cp .agent/scripts/template-helper.sh .agent/scripts/newprovider-helper.sh
```

2. Implement standard functions:

- `list()` - List resources
- `connect()` - Connect to service
- `exec()` - Execute operations
- `info()` - Display information

3. Add configuration:

```bash
cp configs/template-config.json.txt configs/newprovider-config.json
```

4. Update documentation

---

**Next**: [MCP Integrations →](MCP-Integrations.md)
