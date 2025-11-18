# AI DevOps Framework Wiki

Welcome to the AI DevOps Framework documentation. This comprehensive guide provides everything you need to understand, use, and extend this powerful infrastructure management system.

## Quick Links

- [Overview](#overview)
- [Getting Started](Getting-Started.md)
- [Architecture](Architecture.md)
- [Providers](Providers.md)
- [MCP Integrations](MCP-Integrations.md)
- [Configuration](Configuration.md)
- [API Reference](API-Reference.md)
- [Security](Security.md)
- [Quality Control](Quality-Control.md)

## Overview

**AI DevOps Framework** provides AI assistants with seamless access to your entire DevOps ecosystem across 28+ services. It enables unified infrastructure management through standardized CLI interfaces, secure credential handling, and enterprise-grade quality assurance.

### Key Features

- **28+ Service Integrations**: Hosting, DNS, Git platforms, security, monitoring
- **10 MCP Servers**: Real-time AI assistant integration with live documentation
- **Enterprise Quality**: A-grade ratings across SonarCloud, CodeFactor, Codacy
- **Unified Interface**: Consistent commands across all providers
- **Security First**: Ed25519 SSH keys, secure credential storage, comprehensive logging

### Core Components

| Component | Description |
|-----------|-------------|
| **Providers** | 25+ helper scripts for service management |
| **Configs** | Secure configuration templates |
| **Docs** | Comprehensive guides and references |
| **Scripts** | Automation and quality control tools |
| **MCP** | Model Context Protocol integrations |

## Service Coverage

### Infrastructure & Hosting (6)

Hostinger, Hetzner Cloud, Closte, Coolify, Cloudron, AWS/DigitalOcean

### Domain & DNS (5)

Cloudflare, Spaceship, 101domains, Route 53, Namecheap

### Development & Git (7)

GitHub, GitLab, Gitea, LocalWP, Pandoc, Agno, Browser Automation

### Security & Quality (5)

Vaultwarden, SonarCloud, CodeFactor, Codacy, CodeRabbit

### Performance & Analytics (2)

PageSpeed Insights, Lighthouse

### AI & Documentation (2)

Context7, LocalWP MCP

## Quick Start

```bash
# Clone repository
mkdir -p ~/git && cd ~/git
git clone https://github.com/marcusquinn/aidevops.git
cd aidevops

# Run setup
./setup.sh

# Configure providers
cp configs/hostinger-config.json.txt configs/hostinger-config.json
# Edit with your credentials

# Test connections
./scripts/servers-helper.sh list
```

## Documentation Structure

```
.wiki/
├── Home.md                    # This file - overview and navigation
├── Getting-Started.md         # Installation and setup guide
├── Architecture.md            # System design and components
├── Providers.md              # All provider scripts documentation
├── MCP-Integrations.md       # Model Context Protocol setup
├── Configuration.md          # Configuration and credentials
├── API-Reference.md          # Complete API documentation
├── Security.md               # Security best practices
└── Quality-Control.md        # Quality assurance and monitoring
```

## Version Information

- **Current Version**: 1.5.0
- **License**: MIT
- **Author**: Marcus Quinn
- **Copyright**: © 2025

## Contributing

This framework is open for contributions. See [Contributing Guide](../README.md#contributing--license) for details.

---

**Next Steps**: [Getting Started Guide →](Getting-Started.md)
