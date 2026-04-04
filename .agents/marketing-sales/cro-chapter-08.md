<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chapter 8: Form Optimization and Field Reduction

Each field added costs ~4-7% conversion rate.

| Metric | Finding |
|--------|---------|
| Per-field impact | ~4-7% CVR reduction |
| 3 vs 9 fields | 25-40% higher CVR with fewer |
| 11→4 fields | +120% conversions (HubSpot) |
| Multi-step vs single | +10-30% CVR |
| Autofill enabled | Up to +30% CVR |
| Single vs multi-column | 15-20% better single-column |

**Example**: 10K visitors, 12 fields at 5% = 500 conversions. 4 fields at 8% = 800 (+60%).

## Essential Fields by Form Type

| Form Type | Essential | Defer/Enrich |
|-----------|-----------|--------------|
| E-commerce | Email, shipping, payment, name | Phone, company, birthdate, referral source |
| B2B lead gen | Email, company, first name | Last name, phone, title (LinkedIn), size (domain lookup) |
| Newsletter | Email only | First name (optional personalization) |
| SaaS trial | Email, password, company (B2B) | Phone, title, employee count |

**"Can We Get This Later?" test** — remove/make optional if: (1) collectable post-conversion, (2) inferable/enrichable, (3) no immediate user value, (4) not required to serve the user.

## Progressive Profiling

| Step | Form | New Fields | Rate |
|------|------|-----------|------|
| Newsletter | Email | 1 | 12% of visitors |
| Content download | Email (pre-filled) + first name | 1 | 40% of subscribers |
| Webinar | Email + name (pre-filled) + company | 1 | 25% |
| Free trial | All pre-filled + phone | 1 | 15% |

**Result**: Email from 12% of visitors; complete profile for 2.1% — far higher than asking all upfront.

**Requirements**: Marketing automation (HubSpot, Marketo, Pardot) + cookie tracking. Known visitor → load existing data, show only missing fields (max 2-3 new).

```javascript
hbspt.forms.create({ portalId: "ID", formId: "ID", enableProgressiveFields: true });
```

## Multi-Step Forms

| Use | Avoid |
|-----|-------|
| 6+ fields | ≤3 fields |
| Mix of easy/complex fields | Single-purpose (newsletter) |
| Lead gen, registration, complex config | Speed-critical (checkout payment) |

### Step Sequencing

| Step | Content | Psychology |
|------|---------|-----------|
| 1 | Easy, engaging ("What's your biggest challenge?") | Build momentum, commitment |
| 2 | Identification (name, email, company) | Expected; user is invested |
| 3 | Detailed/sensitive (phone, role, size) | Sunk cost drives completion |
| 4 | Final low-friction items | Finish line in sight |

**Progress**: `[■■■■■■□□□□] 60% Complete — Step 2 of 3`. Back always allowed (preserve data). Forward disabled until required fields complete. Skip link for optional steps.

**Mobile**: One field per screen, large touch targets (min 44px), auto-focus next field.

## Field Optimization

- Labels above fields (visible, accessible, mobile-friendly). Placeholders for format hints only.
- Correct HTML input types: `type="email"`, `type="tel"`, `type="url"`, `type="date"`, `type="number"`.
- `autocomplete` attributes — up to 30% CVR improvement. Key values: `name`, `email`, `tel`, `organization`, `street-address`, `address-level2` (city), `address-level1` (state), `postal-code`, `country-name`, `cc-name`, `cc-number`, `cc-exp`, `cc-csc`.

### Smart Defaults

- Country: detect from IP, pre-select
- Quantity: default to 1
- Time zone: `Intl.DateTimeFormat().resolvedOptions().timeZone`
- Newsletter opt-in: unchecked (explicit consent required)

### Field-Specific Rules

| Field | Rule |
|-------|------|
| Name | Single "Full Name" field; parse first/last on backend |
| Email | No "Confirm Email" field; auto-lowercase; detect typos (Mailcheck.js) |
| Phone | Accept any format; standardize on backend; make optional; show format in placeholder |
| Address | Use Google Places autocomplete; adapt fields by country; hide "Apt/Suite" behind link |
| Password | Show requirements before typing; live checklist; strength bar; show/hide toggle |
| Date | Native `<input type="date">` preferred; custom: Flatpickr, Pikaday |
| Checkboxes/Radio | Full label clickable; 44px touch target; radio = mutually exclusive, checkbox = multi-select |
| Dropdowns | 5+ options → dropdown; 2-4 options → radio buttons; searchable for long lists (React-Select) |

## Validation and Error Handling

Validate on blur (not keystroke): focus → type → blur → validate → show result.

**Error messages** — specific, not accusatory:

| Bad | Good |
|-----|------|
| "Error" / "Invalid input" | "Please enter a valid email (e.g., user@example.com)" |
| "You failed to enter your email" | "Please enter your email address" |
| "Wrong format" | "Please use format: (555) 555-5555" |

Multiple errors: linked summary at top + inline per-field. Preserve all data on error.

## Trust and Anxiety Reduction

```text
Email: [___________]  🔒 We'll never share your email. Unsubscribe anytime.
Card:  [____ ____ ____]  🔒 Encrypted  [SSL] [Norton]
Phone: [___________]  We'll only call to schedule delivery
```

Social proof near form: testimonials, subscriber count ("Join 50,000+"), trust badges near submit button.

## Advanced Techniques

- **Conditional logic**: show/hide fields based on prior answers — shorter perceived length, personalized.
- **Save and continue**: auto-save to `localStorage` every 30s for long forms; offer "email me a link."
- **Dynamic button text**: "Get Started" → "Continue" → "Submit Application" → "Processing..." → "✓ Submitted!"
- **Conversational forms**: one question at a time (Typeform, Tally) — higher completion, better mobile, slower for scan-first users.

## Testing Priority

| Priority | What to Test |
|----------|-------------|
| High | Field count, single vs multi-step, labels, button copy/color/size, required vs optional |
| Medium | Error wording, validation timing, progress indicators, autofill, field order, privacy assurances |
| Lower | Placeholder text, input styling, checkbox styling, help text placement |

## Form Analytics

**Form-level**: views, starts, submissions, CVR, completion rate, time to complete, abandonment rate.

**Field-level**: interaction rate, completion rate, correction rate, time per field, error rate, abandonment points.

**Key technique**: field abandonment analysis — phone shows 96% interaction but 75% completion (21% drop) → test making it optional or removing it.

**Tools**: GA Enhanced Form Tracking, Hotjar Form Analytics, Zuko Analytics.

## Launch Checklist

- **Design**: single-column · labels above fields · 44px min height · clear hierarchy · mobile-optimized
- **Fields**: essential only · correct input types · autocomplete attrs · smart defaults · no confirmation fields
- **Validation**: inline on blur · specific positive-language errors · success states · error summary · data preserved
- **UX**: privacy assurances near sensitive fields · loading state on submit · no double-submit · progress + back nav (multi-step)
- **Technical**: form + field analytics · cross-browser + mobile tested · keyboard nav + ARIA labels · spam protection (CAPTCHA/honeypot)

## Case Studies

| Test | Before | After | Lift |
|------|--------|-------|------|
| B2B lead: 12 fields → 4 (email, company, open-ended challenge, optional phone) | 3.2% CVR | 9.7% CVR | +203% |
| SaaS trial: single-page 8 fields → 3-step (email+pw / name+company / goal+size) | 12% CVR | 17.5% CVR | +46% |
| Field reorder: engaging question first, phone optional | 38% abandonment | 22% abandonment | -42% |
