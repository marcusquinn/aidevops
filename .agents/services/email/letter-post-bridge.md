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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Letter Post Bridge (Placeholder)

Discovery-only reference for future physical post workflows bridged through email. No provider is selected yet.

## Quick Reference

- **Outbound**: print-and-send APIs that post letters from app payloads
- **Inbound**: scan-and-receive services that forward physical mail as email/PDF
- **Bridge**: email remains the orchestration layer for confirmations, routing, and audit trails

## Candidate Providers

### Print and send

| Service | Region focus | Typical capabilities | Validate before adoption |
|---|---|---|---|
| Lob | US | Address verification; print and mail letters, postcards, checks | Current UK/EU support limits |
| ClickSend | Global; strong in AU/UK/US | Postal sending from API or email trigger | Country-by-country API parity |
| PostGrid | US/Canada; growing international | Mail API, address validation, templated sends | Production scale references |
| PostalMethods | US | Batch and API-driven letter printing and mailing | API ergonomics and webhook coverage |
| Hybrid Mail by iMail / UK hybrid mail providers | UK | API-assisted dispatch through Royal Mail-style workflows | Active API product and SLA terms |

### Scan and receive

| Service | Region focus | Typical capabilities | Validate before adoption |
|---|---|---|---|
| Earth Class Mail | US | Mailroom scanning, PDF forwarding, mailbox management | Current API and automation endpoints |
| Traveling Mailbox | US | Envelope scan, open-and-scan, digital forwarding | Programmatic access vs UI-only flows |
| VirtualPostMail | US | Postal address, scan-to-email, mail management | API support and webhook availability |
| Anytime Mailbox | Global network | Virtual mailbox operators, mail scan, forwarding | Cross-operator consistency |
| UK Postbox / UK virtual mailroom providers | UK | Scan-and-email inbound post for UK addresses | API maturity and compliance posture |

## Target Flows

- **Outbound**: app event -> render payload -> print/send API -> status callback -> email confirmation
- **Inbound**: scanned mail event -> PDF/metadata capture -> routing rules -> destination mailbox
- **Compliance**: review data residency, retention controls, and redaction support before implementation

## Shortlisting Criteria

Score 2-3 providers in each direction against:

1. API completeness: templates, status, webhooks, idempotency
2. Geographic coverage for required destinations
3. Pricing model and minimum volume commitments
4. Security/compliance: SOC 2, ISO 27001, GDPR handling
5. Operational reliability: SLA, support quality, retry semantics

## Related

- `services/email/email-agent.md`
- `services/email/email-actions.md`
- `services/email/email-providers.md`
