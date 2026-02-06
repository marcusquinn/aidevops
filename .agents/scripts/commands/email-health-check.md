---
description: Check email deliverability health for a domain (SPF, DKIM, DMARC, MX, blacklists)
agent: Build+
mode: subagent
---

Check email authentication and deliverability configuration for a domain.

Domain: $ARGUMENTS

## Workflow

### Step 1: Run Health Check

```bash
~/.aidevops/agents/scripts/email-health-check-helper.sh check "$ARGUMENTS"
```

### Step 2: Present Results

Format the output as a clear report:

```text
Email Health Check: {domain}

SPF:       {status} - {details}
DKIM:      {status} - {selectors found}
DMARC:     {status} - {policy}
MX:        {status} - {record count}
Blacklist: {status} - {listed/clean}

Issues Found:
- {issue 1}
- {issue 2}

Recommendations:
1. {recommendation 1}
2. {recommendation 2}
```

### Step 3: Offer Follow-up Actions

```text
Actions:
1. Check specific DKIM selector
2. View detailed blacklist report
3. Get mail-tester.com instructions
4. Show DNS records to add/fix
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-health-check example.com` | Full health check |
| `/email-health-check example.com spf` | SPF only |
| `/email-health-check example.com dkim google` | DKIM with selector |
| `/email-health-check example.com dmarc` | DMARC only |

## Examples

**Basic check:**

```text
User: /email-health-check example.com
AI: Running email health check for example.com...

    Email Health Check: example.com
    
    SPF:       OK - v=spf1 include:_spf.google.com ~all
    DKIM:      OK - Found: google, selector1
    DMARC:     WARN - p=none (monitoring only)
    MX:        OK - 2 records (redundant)
    Blacklist: OK - Not listed
    
    Recommendations:
    1. Upgrade DMARC policy from p=none to p=quarantine
    2. Consider adding rua= for DMARC reports
    
    Would you like to:
    1. See the recommended DMARC record
    2. Run a mail-tester.com deliverability test
    3. Check another domain
```

**DKIM with specific selector:**

```text
User: /email-health-check example.com dkim k1
AI: Checking DKIM for selector 'k1' on example.com...

    DKIM Record Found:
    Selector: k1._domainkey.example.com
    Key Type: RSA
    Status: Valid
    
    This is a Mailchimp DKIM selector.
```

## Related

- `services/email/email-health-check.md` - Full documentation
- `services/email/ses.md` - Amazon SES integration
- `services/hosting/dns.md` - DNS management
