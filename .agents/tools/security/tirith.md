---
description: Terminal security guard - catches homograph attacks, ANSI injection, pipe-to-shell, and credential exposure before execution
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: false
---

# Tirith - Terminal Security Guard

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Pre-execution security guard for terminal commands
- **Repo**: [github.com/sheeki03/tirith](https://github.com/sheeki03/tirith) (1.5k stars, Rust, AGPL-3.0)
- **Key trait**: Sub-millisecond overhead, fully local, no network calls, no telemetry
- **Coverage**: 30 rules across 7 categories
- **Activation**: Add the shell hook once; every later command is checked automatically

<!-- AI-CONTEXT-END -->

## Install and activate

```bash
brew install sheeki03/tap/tirith   # macOS
npm install -g tirith              # cross-platform
cargo install tirith               # from source
mise use -g tirith                 # mise
```

Also available via Nix, deb, rpm, AUR, Scoop, and Chocolatey. Add one shell hook:

```bash
eval "$(tirith init --shell zsh)"   # ~/.zshrc
eval "$(tirith init --shell bash)"  # ~/.bashrc
tirith init --shell fish | source   # ~/.config/fish/config.fish
```

## What it catches

| Category | What it stops |
|----------|---------------|
| **Homograph attacks** | Cyrillic/Greek lookalikes in hostnames, punycode domains, mixed-script labels |
| **Terminal injection** | ANSI escape sequences that rewrite display, bidi overrides, zero-width characters |
| **Pipe-to-shell** | `curl \| bash`, `wget \| sh`, `python <(curl ...)`, `eval $(wget ...)` |
| **Dotfile attacks** | Downloads targeting `~/.bashrc`, `~/.ssh/authorized_keys`, `~/.gitconfig` |
| **Insecure transport** | Plain HTTP piped to shell, `curl -k`, disabled TLS verification |
| **Ecosystem threats** | Git clone typosquats, untrusted Docker registries, pip/npm URL installs |
| **Credential exposure** | `http://user:pass@host` userinfo tricks, shortened URLs hiding destinations |

Critical rules (homograph, dotfile) **block** execution. Medium rules (pipe-to-shell with clean URL) **warn** but allow.

## Commands

```bash
tirith check -- <cmd>          # Analyze without executing
tirith score <url>             # URL trust signal breakdown
tirith diff <url>              # Byte-level suspicious character comparison
tirith run <url>               # Safe curl|bash replacement (download, review, confirm)
tirith receipt list            # Audit trail of scripts run via tirith run
tirith why                     # Explain last triggered rule
tirith doctor                  # Diagnostic check (shell, hooks, policy)
```

## Configuration

Policy lookup: `.tirith/policy.yaml` (walks up to repo root), then `~/.config/tirith/policy.yaml`.

```yaml
version: 1
allowlist:
  - "get.docker.com"
  - "sh.rustup.rs"

severity_overrides:
  docker_untrusted_registry: critical

fail_mode: open  # or "closed" for strict environments
```

Set `allow_bypass: false` to prevent per-command bypass in org environments.

Bypass (one command only, does not persist):

```bash
TIRITH=0 curl -L https://known-safe.example.com | bash
```

## Integration with aidevops

- **setup.sh**: checks for Tirith and suggests installation if missing
- **Auto-guard**: `eval "$(tirith init)"` in shell profile guards all commands spawned by aidevops scripts
- **Audit log**: `~/.local/share/tirith/log.jsonl` (timestamp, action, rule ID, redacted preview); disable with `TIRITH_LOG=0`

## Related

- `tools/security/shannon.md` — AI pentesting for web applications
- `tools/security/privacy-filter.md` — Content privacy filtering
- `tools/security/cdn-origin-ip.md` — CDN origin IP leak detection
