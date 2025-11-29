# For Humans

A non-technical guide to understanding and using the AI DevOps Framework.

## What Problem Does This Solve?

**Before this framework:**
- AI assistants had to figure out your infrastructure from scratch each time
- Instructions were scattered across multiple files
- No consistent way to handle credentials securely
- AI might create files randomly in your home directory

**After this framework:**
- AI assistants have comprehensive knowledge of 30+ services
- One authoritative instruction file (`AGENTS.md`)
- Secure credential management built-in
- Organized working directories

## How It Works (Simple Version)

```text
You: "Help me deploy my site to Hostinger"

AI: *reads AGENTS.md*
    *reads .agent/hostinger.md*
    *uses hostinger-helper.sh*
    
AI: "I'll help you deploy. First, let me verify your account..."
```

The AI knows:
- What Hostinger is and how to use it
- Where to find configuration
- What commands are available
- Security requirements

## What You Get

### 30+ Service Integrations

| Category | Services |
|----------|----------|
| **Hosting** | Hostinger, Hetzner, Cloudflare, Vercel |
| **Domains** | Spaceship, 101domains, Namecheap |
| **Code Quality** | Codacy, CodeRabbit, SonarCloud |
| **WordPress** | MainWP, LocalWP integration |
| **Security** | Vaultwarden, Snyk |

### Workflow Guides

Pre-built processes for:
- Starting new features
- Fixing bugs
- Releasing versions
- Code reviews
- CI/CD monitoring

### 90+ Automation Scripts

Ready-to-use scripts for:
- Service management
- Quality checks
- API key setup
- Deployment tasks

## Getting Started (The Easy Way)

### Step 1: Clone the Repository

```bash
git clone https://github.com/marcusquinn/aidevops.git ~/git/aidevops
```

### Step 2: Tell Your AI

When working on DevOps tasks, tell your AI assistant:

> "Read ~/git/aidevops/AGENTS.md for guidance"

That's it! Your AI now knows about all the services and how to use them.

## Common Use Cases

### "I need to set up hosting"

Your AI will:
1. Ask which provider (Hostinger, Hetzner, etc.)
2. Guide you through configuration
3. Use the appropriate helper scripts
4. Set up securely

### "Check my code quality"

Your AI will:
1. Run quality checks (Codacy, SonarCloud, etc.)
2. Report issues found
3. Suggest or apply fixes
4. Verify improvements

### "Deploy my WordPress site"

Your AI will:
1. Check your hosting configuration
2. Handle the deployment
3. Verify it's working
4. Set up any needed DNS

### "Create a new GitHub repository"

Your AI will:
1. Create the repo with proper settings
2. Set up branch protection
3. Configure CI/CD workflows
4. Add appropriate templates

## Security (Don't Worry)

The framework handles security automatically:

- **API keys** are stored securely (not in Git)
- **Credentials** are never exposed in logs
- **Destructive operations** require confirmation
- **Files** are created in organized directories

## The Key Files

| File | What It Does |
|------|--------------|
| `AGENTS.md` | Main instructions for AI assistants |
| `.agent/` folder | All documentation and scripts |
| `~/.agent/` folder | Your personal working directory |

## FAQ

### Do I need to read all the documentation?

No! Just clone the repo and tell your AI assistant about it. The AI reads the documentation when needed.

### Will this mess up my computer?

No. The framework creates files only in organized directories (`~/.agent/work/`, etc.), never randomly in your home folder.

### Is it safe to use with my real accounts?

Yes, but always:
- Review what the AI is doing for destructive operations
- Use test environments first when possible
- Keep your API keys secure

### Can I use this with Claude/GPT/other AI?

Yes! Any AI assistant that can read files can use this framework. Just point them to `AGENTS.md`.

### What if something goes wrong?

The framework includes troubleshooting guides and the AI can check service status pages automatically.

## Need Help?

- **Issues:** [GitHub Issues](https://github.com/marcusquinn/aidevops/issues)
- **Documentation:** Browse the wiki pages
- **Source Code:** [GitHub Repository](https://github.com/marcusquinn/aidevops)

## Related Pages

- **[Getting Started](Getting-Started)** - Technical setup guide
- **[Understanding AGENTS.md](Understanding-AGENTS-md)** - How AI guidance works
- **[Workflows Guide](Workflows-Guide)** - Development processes
