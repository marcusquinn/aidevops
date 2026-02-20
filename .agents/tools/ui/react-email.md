---
description: React Email - build and send beautiful transactional emails with React components
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# React Email - Email Templates with React

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build responsive, cross-client email templates using React components
- **Docs**: Use Context7 MCP for latest React Email documentation
- **GitHub**: https://github.com/resend/react-email (15k+ stars, MIT)
- **Website**: https://react.email
- **Used by**: TurboStarter (`~/Git/turbostarter/core/packages/email/`)

**Why React Email**:

- Write emails as React components (familiar DX)
- Preview emails in browser during development
- Renders to cross-client compatible HTML
- Built-in components handle email client quirks
- Works with any email provider (Resend, SendGrid, Postmark, SES)

<!-- AI-CONTEXT-END -->

## Quick Start

```bash
# Add to existing project
npm install @react-email/components react-email

# Or create standalone email project
npx create-email@latest
```

## Components

React Email provides pre-built components that render correctly across email clients:

| Component | Purpose |
|-----------|---------|
| `<Html>` | Root element with DOCTYPE |
| `<Head>` | Email head (meta, title) |
| `<Preview>` | Preview text (shown in inbox list) |
| `<Body>` | Email body |
| `<Container>` | Centered content wrapper (max-width) |
| `<Section>` | Row grouping |
| `<Row>` / `<Column>` | Grid layout |
| `<Text>` | Paragraph text |
| `<Heading>` | Headings (h1-h6) |
| `<Link>` | Anchor links |
| `<Button>` | CTA buttons |
| `<Img>` | Images |
| `<Hr>` | Horizontal rule |
| `<Code>` / `<CodeBlock>` | Code formatting |
| `<Markdown>` | Render markdown content |
| `<Font>` | Custom font loading |
| `<Tailwind>` | Tailwind CSS support in emails |

## Example Template

```tsx
import {
  Body,
  Button,
  Container,
  Head,
  Heading,
  Html,
  Preview,
  Section,
  Text,
  Tailwind,
} from '@react-email/components';

interface WelcomeEmailProps {
  name: string;
  actionUrl: string;
}

export default function WelcomeEmail({ name, actionUrl }: WelcomeEmailProps) {
  return (
    <Html>
      <Head />
      <Preview>Welcome to our app, {name}!</Preview>
      <Tailwind>
        <Body className="bg-gray-100 font-sans">
          <Container className="mx-auto max-w-xl bg-white rounded-lg p-8">
            <Heading className="text-2xl font-bold text-gray-900">
              Welcome, {name}!
            </Heading>
            <Text className="text-gray-600 text-base leading-6">
              Thanks for signing up. Click below to get started.
            </Text>
            <Section className="text-center mt-8">
              <Button
                className="bg-blue-600 text-white px-6 py-3 rounded-md font-medium"
                href={actionUrl}
              >
                Get Started
              </Button>
            </Section>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  );
}
```

## Development Preview

```bash
# Start preview server
npx react-email dev

# Opens browser at http://localhost:3000
# Live reload as you edit templates
```

## Rendering to HTML

```typescript
import { render } from '@react-email/render';
import WelcomeEmail from './emails/welcome';

// Render to HTML string
const html = await render(WelcomeEmail({ name: 'John', actionUrl: 'https://...' }));

// Render to plain text (for text/plain fallback)
const text = await render(WelcomeEmail({ name: 'John', actionUrl: 'https://...' }), {
  plainText: true,
});
```

## Sending with Providers

### Resend (Recommended)

```typescript
import { Resend } from 'resend';
import WelcomeEmail from './emails/welcome';

const resend = new Resend(process.env.RESEND_API_KEY);

await resend.emails.send({
  from: 'App <hello@example.com>',
  to: 'user@example.com',
  subject: 'Welcome!',
  react: WelcomeEmail({ name: 'John', actionUrl: 'https://...' }),
});
```

### Nodemailer (Self-Hosted)

```typescript
import nodemailer from 'nodemailer';
import { render } from '@react-email/render';
import WelcomeEmail from './emails/welcome';

const html = await render(WelcomeEmail({ name: 'John', actionUrl: 'https://...' }));

const transporter = nodemailer.createTransport({ /* SMTP config */ });
await transporter.sendMail({
  from: 'hello@example.com',
  to: 'user@example.com',
  subject: 'Welcome!',
  html,
});
```

## Project Structure (TurboStarter Pattern)

```text
packages/email/
├── src/
│   ├── templates/           # Email templates
│   │   ├── welcome.tsx
│   │   ├── reset-password.tsx
│   │   ├── invoice.tsx
│   │   └── notification.tsx
│   ├── components/          # Shared email components
│   │   ├── header.tsx
│   │   ├── footer.tsx
│   │   └── button.tsx
│   └── providers/           # Email sending providers
│       ├── resend.ts
│       └── nodemailer.ts
├── package.json
└── tsconfig.json
```

## Best Practices

- **Preview all templates** in the dev server before sending
- **Test across clients** (Gmail, Outlook, Apple Mail — they all render differently)
- **Use Tailwind** via `<Tailwind>` component for consistent styling
- **Keep emails simple** — complex layouts break in Outlook
- **Always include plain text** fallback
- **Use absolute URLs** for images (email clients don't load relative paths)
- **Inline styles** are more reliable than CSS classes (React Email handles this)

## Related

- `tools/ui/tailwind-css.md` - Tailwind CSS (used within email templates)
- `services/email/email-testing.md` - Email testing and delivery verification
- `services/email/email-design-test.md` - Cross-client rendering tests
- `tools/api/hono.md` - API routes for email sending endpoints
