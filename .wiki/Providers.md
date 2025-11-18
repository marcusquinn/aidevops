# Provider Scripts Reference

Complete documentation for all 22 provider helper scripts in the AI DevOps Framework.

## Overview

Provider scripts provide standardized interfaces to interact with different services and platforms. Each script follows a consistent command structure and implements common operations.

## Common Command Pattern

All provider scripts follow this pattern:

```bash
./providers/[provider]-helper.sh [command] [arguments...]
```

Common commands across providers:

- `list` - List available resources
- `connect` - Establish SSH connection
- `exec` - Execute remote command
- `info` - Display service information
- `help` - Show usage information

## Infrastructure & Hosting Providers

### Hostinger

**File**: `providers/hostinger-helper.sh`

Manage Hostinger shared hosting, domains, and email services.

**Commands**:

```bash
# List all configured servers
./providers/hostinger-helper.sh list

# Connect to server via SSH
./providers/hostinger-helper.sh connect example.com

# Execute remote command
./providers/hostinger-helper.sh exec example.com "uptime"

# Show configuration
./providers/hostinger-helper.sh info
```

**Configuration**: `configs/hostinger-config.json`

**Features**:

- SSH connection management
- Remote command execution
- Server information retrieval
- Multi-account support

---

### Hetzner Cloud

**File**: `providers/hetzner-helper.sh`

Manage Hetzner VPS servers, networking, and load balancers.

**Commands**:

```bash
# List servers in project
./providers/hetzner-helper.sh list [project-name]

# Connect to server
./providers/hetzner-helper.sh connect [project-name] [server-name]

# Execute command
./providers/hetzner-helper.sh exec [project-name] [server-name] "command"

# Get server info
./providers/hetzner-helper.sh info [project-name] [server-name]

# Manage servers
./providers/hetzner-helper.sh create [project-name] [server-name] [type]
./providers/hetzner-helper.sh delete [project-name] [server-name]
./providers/hetzner-helper.sh start [project-name] [server-name]
./providers/hetzner-helper.sh stop [project-name] [server-name]
```

**Configuration**: `configs/hetzner-config.json`

**Features**:

- Multi-project support
- Server lifecycle management
- Network configuration
- Load balancer management

---

### Coolify

**File**: `providers/coolify-helper.sh`

Manage Coolify self-hosted PaaS and application deployments.

**Commands**:

```bash
# List applications
./providers/coolify-helper.sh list

# Deploy application
./providers/coolify-helper.sh deploy [app-name]

# Get application status
./providers/coolify-helper.sh status [app-name]

# View logs
./providers/coolify-helper.sh logs [app-name]
```

**Configuration**: `configs/coolify-config.json`

**Features**:

- Application deployment
- Container management
- Log monitoring
- Environment configuration

---

### Cloudron

**File**: `providers/cloudron-helper.sh`

Manage Cloudron server and application platform.

**Commands**:

```bash
# List installed apps
./providers/cloudron-helper.sh list

# Install application
./providers/cloudron-helper.sh install [app-name]

# Manage apps
./providers/cloudron-helper.sh start [app-name]
./providers/cloudron-helper.sh stop [app-name]
./providers/cloudron-helper.sh restart [app-name]

# Backup management
./providers/cloudron-helper.sh backup [app-name]
```

**Configuration**: `configs/cloudron-config.json`

**Features**:

- App marketplace integration
- Automated backups
- User management
- Domain configuration

---

### Closte

**File**: `providers/closte-helper.sh`

Manage Closte managed hosting and application deployment.

**Commands**:

```bash
# List sites
./providers/closte-helper.sh list

# Site management
./providers/closte-helper.sh info [site-name]
```

**Configuration**: `configs/closte-config.json`

---

## Domain & DNS Providers

### Cloudflare (DNS Helper)

**File**: `providers/dns-helper.sh`

Unified DNS management across multiple providers with focus on Cloudflare.

**Commands**:

```bash
# List DNS zones
./providers/dns-helper.sh cloudflare list-zones

# Add DNS records
./providers/dns-helper.sh cloudflare add-record [domain] A [ip-address]
./providers/dns-helper.sh cloudflare add-record [domain] CNAME [name] [target]
./providers/dns-helper.sh cloudflare add-record [domain] MX [priority] [server]
./providers/dns-helper.sh cloudflare add-record [domain] TXT [name] [value]

# Update record
./providers/dns-helper.sh cloudflare update-record [domain] [record-id] [type] [value]

# Delete record
./providers/dns-helper.sh cloudflare delete-record [domain] [record-id]

# List records
./providers/dns-helper.sh cloudflare list-records [domain]

# Manage SSL
./providers/dns-helper.sh cloudflare enable-ssl [domain]
./providers/dns-helper.sh cloudflare set-ssl-mode [domain] [mode]
```

**Configuration**: `configs/cloudflare-config.json`

**Features**:

- DNS record management (A, AAAA, CNAME, MX, TXT)
- SSL/TLS configuration
- Zone management
- CDN settings

---

### Spaceship

**File**: `providers/spaceship-helper.sh`

Domain registration and management via Spaceship.

**Commands**:

```bash
# Check domain availability
./providers/spaceship-helper.sh check-availability [domain]

# Purchase domain
./providers/spaceship-helper.sh purchase [domain]

# List owned domains
./providers/spaceship-helper.sh list

# Manage nameservers
./providers/spaceship-helper.sh set-nameservers [domain] [ns1] [ns2]

# Domain info
./providers/spaceship-helper.sh info [domain]

# Renew domain
./providers/spaceship-helper.sh renew [domain]
```

**Configuration**: `configs/spaceship-config.json`

**Features**:

- Domain availability checking
- Domain registration
- Nameserver management
- Auto-renewal configuration

---

### 101domains

**File**: `providers/101domains-helper.sh`

Domain purchasing and DNS management via 101domains.

**Commands**:

```bash
# Check availability
./providers/101domains-helper.sh check-availability [domain]

# Search domains
./providers/101domains-helper.sh search [keyword]

# Purchase domain
./providers/101domains-helper.sh purchase [domain]

# List domains
./providers/101domains-helper.sh list

# Manage DNS
./providers/101domains-helper.sh add-dns [domain] [type] [value]
./providers/101domains-helper.sh list-dns [domain]
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

**File**: `providers/git-platforms-helper.sh`

Unified interface for GitHub, GitLab, and Gitea.

**Commands**:

```bash
# GitHub operations
./providers/git-platforms-helper.sh github list-repos
./providers/git-platforms-helper.sh github create-repo [name]
./providers/git-platforms-helper.sh github delete-repo [name]
./providers/git-platforms-helper.sh github clone-repo [name]

# GitLab operations
./providers/git-platforms-helper.sh gitlab list-projects
./providers/git-platforms-helper.sh gitlab create-project [name]
./providers/git-platforms-helper.sh gitlab delete-project [id]

# Gitea operations
./providers/git-platforms-helper.sh gitea list-repos
./providers/git-platforms-helper.sh gitea create-repo [name]
./providers/git-platforms-helper.sh gitea delete-repo [name]
```

**Configuration**: `configs/git-platforms-config.json`

**Features**:

- Multi-platform support (GitHub, GitLab, Gitea)
- Repository management
- Issue tracking
- Pull request operations

---

### Pandoc Helper

**File**: `providers/pandoc-helper.sh`

Document format conversion for AI processing.

**Commands**:

```bash
# Convert to markdown
./providers/pandoc-helper.sh to-markdown [input-file] [output-file]

# Convert from markdown
./providers/pandoc-helper.sh from-markdown [input-file] [format] [output-file]

# Batch conversion
./providers/pandoc-helper.sh batch [input-dir] [output-dir] [format]

# Get info
./providers/pandoc-helper.sh formats
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

**File**: `providers/agno-setup.sh`

Local AI agent operating system for DevOps automation.

**Commands**:

```bash
# Install Agno
./providers/agno-setup.sh install

# Start Agno server
./providers/agno-setup.sh start

# Stop Agno server
./providers/agno-setup.sh stop

# Status check
./providers/agno-setup.sh status

# Configure
./providers/agno-setup.sh configure
```

**Configuration**: `configs/agno-config.json`

**Features**:

- Local AI agent orchestration
- DevOps workflow automation
- Tool integration
- Prompt management

---

### LocalWP Helper

**File**: `providers/localhost-helper.sh`

WordPress local development environment management.

**Commands**:

```bash
# Create new site
./providers/localhost-helper.sh create-site [site-name]

# List sites
./providers/localhost-helper.sh list

# Start/stop site
./providers/localhost-helper.sh start [site-name]
./providers/localhost-helper.sh stop [site-name]

# Delete site
./providers/localhost-helper.sh delete [site-name]

# Database operations
./providers/localhost-helper.sh export-db [site-name] [output-file]
./providers/localhost-helper.sh import-db [site-name] [input-file]
```

**Features**:

- WordPress site creation
- Database management
- Plugin/theme installation
- Local development environment

---

## WordPress & Content Management

### MainWP Helper

**File**: `providers/mainwp-helper.sh`

Centralized WordPress management via MainWP.

**Commands**:

```bash
# List all sites
./providers/mainwp-helper.sh list-sites

# Site management
./providers/mainwp-helper.sh info [site-url]
./providers/mainwp-helper.sh sync [site-url]

# Backup operations
./providers/mainwp-helper.sh backup [site-url]
./providers/mainwp-helper.sh restore [site-url] [backup-id]

# Update management
./providers/mainwp-helper.sh update-core [site-url]
./providers/mainwp-helper.sh update-plugins [site-url]
./providers/mainwp-helper.sh update-themes [site-url]
./providers/mainwp-helper.sh update-all [site-url]

# Security scans
./providers/mainwp-helper.sh security-scan [site-url]
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

**File**: `providers/ses-helper.sh`

Amazon Simple Email Service management.

**Commands**:

```bash
# Send email
./providers/ses-helper.sh send [to] [subject] [body]

# Verify email address
./providers/ses-helper.sh verify [email]

# List verified emails
./providers/ses-helper.sh list-verified

# Get send statistics
./providers/ses-helper.sh stats

# Manage suppression list
./providers/ses-helper.sh list-suppressed
./providers/ses-helper.sh remove-suppressed [email]
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

**File**: `providers/vaultwarden-helper.sh`

Password and secrets management via Vaultwarden.

**Commands**:

```bash
# List items
./providers/vaultwarden-helper.sh list

# Get item
./providers/vaultwarden-helper.sh get [item-name]

# Add item
./providers/vaultwarden-helper.sh add [item-name] [username] [password]

# Update item
./providers/vaultwarden-helper.sh update [item-id] [field] [value]

# Delete item
./providers/vaultwarden-helper.sh delete [item-id]

# Generate password
./providers/vaultwarden-helper.sh generate [length]
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

**File**: `providers/pagespeed-helper.sh`

Website performance auditing and optimization.

**Commands**:

```bash
# Run PageSpeed audit
./providers/pagespeed-helper.sh audit [url]

# WordPress-specific audit
./providers/pagespeed-helper.sh wordpress [url]

# Lighthouse audit
./providers/pagespeed-helper.sh lighthouse [url] [format]

# Compare performance
./providers/pagespeed-helper.sh compare [url1] [url2]

# Export report
./providers/pagespeed-helper.sh export [url] [output-file]
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

**File**: `providers/code-audit-helper.sh`

Code quality and security auditing.

**Commands**:

```bash
# Run audit
./providers/code-audit-helper.sh audit [directory]

# Security scan
./providers/code-audit-helper.sh security [directory]

# Generate report
./providers/code-audit-helper.sh report [directory] [output-file]
```

**Features**:

- Static code analysis
- Security vulnerability detection
- Code quality metrics
- Compliance checking

---

## AI & Automation

### DSPy Helper

**File**: `providers/dspy-helper.sh`

DSPy framework integration for prompt optimization.

**Commands**:

```bash
# Install DSPy
./providers/dspy-helper.sh install

# Run optimization
./providers/dspy-helper.sh optimize [prompt-file]

# Test prompts
./providers/dspy-helper.sh test [prompt-file]

# Export optimized prompts
./providers/dspy-helper.sh export [output-file]
```

**Configuration**: `configs/dspy-config.json`

**Features**:

- Prompt optimization
- Model evaluation
- Chain-of-thought reasoning
- Multi-model support

---

### DSPyGround Helper

**File**: `providers/dspyground-helper.sh`

DSPyGround playground for prompt experimentation.

**Commands**:

```bash
# Start playground
./providers/dspyground-helper.sh start

# Stop playground
./providers/dspyground-helper.sh stop

# Open in browser
./providers/dspyground-helper.sh open
```

**Configuration**: `configs/dspyground-config.json`

---

### TOON Helper

**File**: `providers/toon-helper.sh`

Token-Oriented Object Notation for efficient LLM data exchange.

**Commands**:

```bash
# Encode JSON to TOON
./providers/toon-helper.sh encode [input.json] [output.toon]

# Decode TOON to JSON
./providers/toon-helper.sh decode [input.toon] [output.json]

# Compare token efficiency
./providers/toon-helper.sh compare [file.json]

# Batch conversion
./providers/toon-helper.sh batch [input-dir] [output-dir] [mode]

# Get format info
./providers/toon-helper.sh info
```

**Features**:

- 20-60% token reduction
- Human-readable format
- Schema preservation
- Batch processing

---

## Setup & Configuration

### Setup Wizard Helper

**File**: `providers/setup-wizard-helper.sh`

Interactive setup wizard for initial configuration.

**Commands**:

```bash
# Run full setup
./providers/setup-wizard-helper.sh

# Configure specific provider
./providers/setup-wizard-helper.sh provider [provider-name]

# Test configuration
./providers/setup-wizard-helper.sh test

# Reset configuration
./providers/setup-wizard-helper.sh reset
```

**Features**:

- Interactive configuration
- Credential management
- Connection testing
- Multi-provider setup

---

### Shared Constants

**File**: `providers/shared-constants.sh`

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
./providers/spaceship-helper.sh purchase example.com

# 2. Configure DNS
./providers/dns-helper.sh cloudflare add-record example.com A 192.168.1.1
./providers/dns-helper.sh cloudflare enable-ssl example.com

# 3. Deploy application
./providers/coolify-helper.sh deploy myapp

# 4. Audit performance
./providers/pagespeed-helper.sh wordpress https://example.com

# 5. Backup WordPress
./providers/mainwp-helper.sh backup example.com
```

### Server Management Workflow

```bash
# 1. Create Hetzner server
./providers/hetzner-helper.sh create main web-server cx11

# 2. Connect and configure
./providers/hetzner-helper.sh connect main web-server

# 3. Install Cloudron
./providers/cloudron-helper.sh install

# 4. Configure SSL
./providers/dns-helper.sh cloudflare enable-ssl example.com
```

## Best Practices

### Error Handling

All scripts implement consistent error handling:

```bash
# Scripts exit with non-zero on error
if ! ./providers/hostinger-helper.sh connect example.com; then
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
./providers/hostinger-helper.sh list

# Bad - don't pass credentials as arguments
```

## Extending Providers

### Creating New Provider

1. Copy template:

```bash
cp providers/template-helper.sh providers/newprovider-helper.sh
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
