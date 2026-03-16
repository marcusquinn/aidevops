---
description: Placeholder guide for bridging physical letter post workflows with email
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
---

# Letter Post Bridge (Placeholder)

This placeholder captures candidate providers for future implementation of physical mail workflows that integrate with email systems.

## Scope

- Outbound: print-and-send APIs for posting letters from digital payloads
- Inbound: scan-and-receive services that forward physical post as email/PDF
- Status: discovery only (no provider selected yet)

## Candidate Print-and-Send APIs

| Service | Region focus | Typical capabilities | Notes for future evaluation |
|---|---|---|---|
| Lob | US | Address verification, print and mail letters/postcards/checks | Mature API footprint; verify current UK/EU support limits |
| ClickSend | Global (strong in AU/UK/US) | Programmatic postal sending from API or email trigger | Confirm API feature parity by country |
| PostGrid | US/Canada (growing international) | Mail API, address validation, templated document sends | Validate production scale references |
| PostalMethods | US | Batch and API-driven letter printing/mailing | Check modern API ergonomics and webhook coverage |
| Hybrid Mail by iMail (formerly UK hybrid mail providers) | UK | API-assisted letter dispatch through Royal Mail workflows | Confirm active API product and SLA terms |

## Candidate Scan-and-Receive Services

| Service | Region focus | Typical capabilities | Notes for future evaluation |
|---|---|---|---|
| Earth Class Mail | US | Mailroom scanning, PDF forwarding, mailbox management | Verify current API/automation endpoints |
| Traveling Mailbox | US | Envelope scan + open/scan + digital forwarding | Confirm programmatic access vs UI-only operations |
| VirtualPostMail | US | Postal address, scan-to-email, mail management | Assess API support and webhook availability |
| Anytime Mailbox | Global network | Virtual mailbox operators, mail scan and forwarding | Check consistency across operator locations |
| UK Postbox / UK virtual mailroom providers | UK | Scan-and-email inbound post for UK addresses | Compare provider API maturity and compliance posture |

## Integration Intent (Future)

- Treat email as the orchestration bridge for physical post events
- Outbound flow target: app event -> render payload -> print/send API -> status callback -> email confirmation
- Inbound flow target: scanned mail event -> PDF/metadata capture -> routing rules -> destination mailbox
- Compliance checks to include data residency, retention controls, and redaction support

## Next Step Criteria

Before implementation, shortlist 2-3 providers in each direction and score against:

1. API completeness (templates, status, webhooks, idempotency)
2. Geographic coverage for required destinations
3. Pricing model and minimum volume commitments
4. Security/compliance (SOC 2, ISO 27001, GDPR handling)
5. Operational reliability (SLA, support quality, retry semantics)

## Related

- `services/email/email-agent.md`
- `services/email/email-actions.md`
- `services/email/email-providers.md`
