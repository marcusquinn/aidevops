---
description: Complete service integration guide
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Service Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

| Category | Services |
|----------|----------|
| Infrastructure | Hostinger (shared), Hetzner (VPS), Closte (VPS), Cloudron (apps) |
| Deployment | Coolify (self-hosted PaaS) |
| Content | MainWP (WordPress management) |
| Security | Vaultwarden (passwords/secrets) |
| Quality | CodeRabbit, CodeFactor, Codacy, SonarCloud |
| Git | GitHub, GitLab, Gitea, Local Git |
| Email | Amazon SES |
| Communications | Twilio (CPaaS), Telfon (softphone) |
| Domains | Spaceship (API purchasing), 101domains |
| DNS | Cloudflare, Namecheap, Route 53 |
| Local/Dev | Localhost, LocalWP, Context7 MCP, MCP Servers, Crawl4AI |
| Setup | Intelligent Setup Wizard |

**Pattern**: `[service]-helper.sh` + `[service]-config.json` + `.agents/[service].md` for each service.

<!-- AI-CONTEXT-END -->

## Infrastructure & Hosting

### Hostinger

Budget-friendly shared hosting, WordPress-optimised. REST API for account/hosting management.

- **Helper**: `hostinger-helper.sh` | **Config**: `hostinger-config.json` | **Docs**: `.agents/hostinger.md`

### Hetzner Cloud

German cloud VPS — excellent price/performance, EU-based. Comprehensive REST API.

- **Helper**: `hetzner-helper.sh` | **Config**: `hetzner-config.json` | **Docs**: `.agents/hetzner.md`

### Closte

VPS hosting — competitive pricing, multiple locations. REST API for provisioning.

- **Helper**: `closte-helper.sh` | **Config**: `closte-config.json` | **Docs**: `.agents/closte.md`

### Cloudron

Self-hosted app platform — easy deployment, automatic updates, backup management. REST API.

- **Helper**: `cloudron-helper.sh` | **Config**: `cloudron-config.json` | **Docs**: `.agents/cloudron.md`

## Deployment & Orchestration

### Coolify

Self-hosted PaaS — Docker-based, Git integration, container orchestration. REST API.

- **Helper**: `coolify-helper.sh` | **Config**: `coolify-config.json` | **Docs**: `.agents/coolify.md`

## Content Management

### MainWP

Centralised WordPress management — bulk operations, security monitoring. REST API.

- **Helper**: `mainwp-helper.sh` | **Config**: `mainwp-config.json` | **Docs**: `.agents/mainwp.md`

## Security & Secrets

### Vaultwarden

Self-hosted Bitwarden-compatible password manager — API access, team sharing, MCP server available.

- **Helper**: `vaultwarden-helper.sh` | **Config**: `vaultwarden-config.json` | **Docs**: `.agents/vaultwarden.md`

## Code Quality & Auditing

All four services share `code-audit-helper.sh`, `code-audit-config.json`, and `.agents/code-auditing.md`.

### CodeRabbit

AI-powered code review — context-aware analysis, security scanning. MCP server available.

### CodeFactor

Automated code quality — simple setup, clear metrics, GitHub integration.

### Codacy

Comprehensive quality and security analysis — custom rules, team collaboration. MCP server available.

### SonarCloud

Industry-standard quality gates — comprehensive rules, security compliance. SonarQube MCP server available.

## Version Control & Git Platforms

GitHub, GitLab, Gitea, and Local Git share `git-platforms-helper.sh`, `git-platforms-config.json`, and `.agents/git-platforms.md`.

### GitHub

World's largest code hosting — REST API v4 + GraphQL, official MCP server available.

### GitLab

Complete DevOps platform — built-in CI/CD, security scanning, self-hosted option. Community MCP servers available.

### Gitea

Lightweight self-hosted Git — minimal resources, GitHub-compatible API. Community MCP servers available.

### Local Git

Local repository management — offline development, no external dependencies.

## Email Services

### Amazon SES

Scalable email delivery — high deliverability, analytics, AWS integration.

- **Helper**: `ses-helper.sh` | **Config**: `ses-config.json` | **Docs**: `.agents/services/email/ses.md`

## Communications Services

### Twilio

Cloud CPaaS — SMS, voice, WhatsApp, 2FA/OTP, call recording. Global coverage. Must comply with Twilio AUP.

- **Helper**: `twilio-helper.sh` | **Config**: `twilio-config.json` | **Docs**: `.agents/services/communications/twilio.md`

### Telfon

Twilio-powered softphone with mobile/desktop apps — iOS, Android, Chrome Extension, Edge Add-on. Recommended for end users needing a calling/SMS interface.

- **Website**: https://mytelfon.com/ | **Docs**: `.agents/services/communications/telfon.md`

## Domain & DNS

### Spaceship

Modern domain registrar with API purchasing — transparent pricing, portfolio management.

- **Helper**: `spaceship-helper.sh` | **Config**: `spaceship-config.json` | **Docs**: `.agents/spaceship.md`, `.agents/domain-purchasing.md`

### 101domains

Comprehensive registrar — 1000+ TLDs, bulk operations, reseller services.

- **Helper**: `101domains-helper.sh` | **Config**: `101domains-config.json` | **Docs**: `.agents/101DOMAINS.md`

Cloudflare DNS, Namecheap DNS, and Route 53 share `dns-helper.sh` and `.agents/dns-providers.md`.

### Cloudflare DNS

Global CDN + DNS — DDoS protection, performance optimisation. Config: `cloudflare-dns-config.json`.

### Namecheap DNS

DNS hosting integrated with domain registration — reliable, affordable. Config: `namecheap-dns-config.json`.

### Route 53

AWS DNS — advanced routing policies, health checks, AWS integration. Config: `route53-dns-config.json`.

## Development & Local

### Localhost

Local development with `.local` domain support.

- **Helper**: `localhost-helper.sh` | **Config**: `localhost-config.json` | **Docs**: `.agents/localhost.md`

### LocalWP

Local WordPress development — database access, dev tools. MCP server for database access.

- **Helper**: `localhost-helper.sh` (includes LocalWP) | **Config**: `localhost-config.json` | **Docs**: `.agents/localwp-mcp.md`

### Context7 MCP

Real-time documentation access for AI assistants — latest docs, contextual information.

- **Integration**: Context7 integration in all helpers | **Config**: `context7-mcp-config.json` | **Docs**: `.agents/context7-mcp-setup.md`

### MCP Servers

Model Context Protocol server management — real-time data access, standardised AI integration.

- **Integration**: MCP integration in all helpers | **Config**: `mcp-servers-config.json` | **Docs**: `.agents/mcp-servers.md`

### Crawl4AI

AI-powered web crawler — LLM-ready output, structured extraction, RAG pipelines. REST API + MCP server.

- **Helper**: `crawl4ai-helper.sh` | **Config**: `crawl4ai-config.json` | **Docs**: `.agents/crawl4ai.md`

## Setup & Configuration

### Intelligent Setup Wizard

AI-guided infrastructure setup — intelligent recommendations, integrates with all framework services.

- **Helper**: `setup-wizard-helper.sh` | **Config**: `setup-wizard-responses.json` (generated) | **Docs**: Integrated in all service documentation
