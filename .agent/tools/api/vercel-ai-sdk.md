---
description: Vercel AI SDK - streaming chat, useChat hook, AI providers
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

# Vercel AI SDK - AI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build AI-powered applications with streaming support
- **Packages**: `ai`, `@ai-sdk/react`, `@ai-sdk/openai`
- **Docs**: Use Context7 MCP for current documentation

**Key Components**:
- `useChat` - React hook for chat interfaces
- `streamText` - Server-side streaming
- Provider adapters (OpenAI, Anthropic, etc.)

**Basic Chat Implementation**:

```tsx
// Client: useChat hook
"use client";
import { useChat } from "@ai-sdk/react";

function Chat() {
  const { messages, input, handleInputChange, handleSubmit, status } = useChat({
    api: "/api/chat",
  });

  return (
    <div>
      {messages.map((m) => (
        <div key={m.id}>
          {m.role}: {m.content}
        </div>
      ))}
      <form onSubmit={handleSubmit}>
        <input value={input} onChange={handleInputChange} />
        <button type="submit" disabled={status === "streaming"}>
          Send
        </button>
      </form>
    </div>
  );
}
```

```tsx
// Server: API route
import { openai } from "@ai-sdk/openai";
import { streamText } from "ai";

export async function POST(req: Request) {
  const { messages } = await req.json();

  const result = streamText({
    model: openai("gpt-4o"),
    messages,
  });

  return result.toDataStreamResponse();
}
```

**Custom Transport** (for Hono/custom APIs):

```tsx
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";

const { messages, sendMessage, status } = useChat({
  transport: new DefaultChatTransport({
    api: "/api/ai/chat",
  }),
});
```

**Message Parts** (for rich content):

```tsx
messages.map((message) => (
  <div key={message.id}>
    {message.parts.map((part, i) => {
      if (part.type === "text") {
        return <p key={i}>{part.text}</p>;
      }
      if (part.type === "tool-call") {
        return <ToolResult key={i} call={part} />;
      }
      return null;
    })}
  </div>
));
```

**Status Values**:

| Status | Meaning |
|--------|---------|
| `idle` | No request in progress |
| `submitted` | Request sent, waiting for response |
| `streaming` | Receiving streamed response |
| `error` | Request failed |

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Full Chat Component

```tsx
"use client";

import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";
import { marked } from "marked";
import { useState, useRef, useEffect } from "react";

export function AIChatSidebar() {
  const [input, setInput] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);

  const { messages, error, sendMessage, status } = useChat({
    transport: new DefaultChatTransport({
      api: "/api/ai/chat",
    }),
    onError: (err) => console.error("Chat Error:", err),
  });

  // Filter to user/assistant messages only
  const displayMessages = messages.filter((m) =>
    ["assistant", "user"].includes(m.role)
  );

  const isLoading = ["submitted", "streaming"].includes(status);

  // Auto-scroll on new messages
  useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages]);

  const handleSubmit = () => {
    if (input.trim()) {
      sendMessage({ text: input });
      setInput("");
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
    }
  };

  if (error) {
    return <div>Error: {error.message}</div>;
  }

  return (
    <div className="flex flex-col h-full">
      <div ref={scrollRef} className="flex-1 overflow-auto p-4">
        {displayMessages.map((message) => (
          <div
            key={message.id}
            className={message.role === "user" ? "text-right" : "text-left"}
          >
            {message.parts.map((part, i) => {
              if (part.type === "text") {
                return message.role === "assistant" ? (
                  <div
                    key={i}
                    dangerouslySetInnerHTML={{
                      __html: marked.parse(part.text),
                    }}
                  />
                ) : (
                  <p key={i}>{part.text}</p>
                );
              }
              return null;
            })}
          </div>
        ))}
        {isLoading && <div>Thinking...</div>}
      </div>
      <div className="p-4 border-t">
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          disabled={isLoading}
          placeholder="Type a message..."
        />
        <button onClick={handleSubmit} disabled={isLoading || !input.trim()}>
          Send
        </button>
      </div>
    </div>
  );
}
```

### Server Route with Hono

```tsx
// packages/api/src/routes/ai.ts
import { Hono } from "hono";
import { openai } from "@ai-sdk/openai";
import { streamText } from "ai";

export const aiRoutes = new Hono()
  .post("/chat", async (c) => {
    const { messages } = await c.req.json();

    const result = streamText({
      model: openai("gpt-4o"),
      system: "You are a helpful assistant.",
      messages,
    });

    return result.toDataStreamResponse();
  });
```

### Tool Calling

```tsx
import { openai } from "@ai-sdk/openai";
import { streamText, tool } from "ai";
import { z } from "zod";

const result = streamText({
  model: openai("gpt-4o"),
  messages,
  tools: {
    getWeather: tool({
      description: "Get weather for a location",
      parameters: z.object({
        location: z.string(),
      }),
      execute: async ({ location }) => {
        // Call weather API
        return { temperature: 72, condition: "sunny" };
      },
    }),
  },
});
```

### Multiple Providers

```tsx
import { openai } from "@ai-sdk/openai";
import { anthropic } from "@ai-sdk/anthropic";

// Use different models
const openaiResult = streamText({
  model: openai("gpt-4o"),
  messages,
});

const claudeResult = streamText({
  model: anthropic("claude-3-5-sonnet-20241022"),
  messages,
});
```

### Structured Output

```tsx
import { generateObject } from "ai";
import { z } from "zod";

const result = await generateObject({
  model: openai("gpt-4o"),
  schema: z.object({
    title: z.string(),
    summary: z.string(),
    tags: z.array(z.string()),
  }),
  prompt: "Analyze this article...",
});

console.log(result.object); // Typed!
```

## Common Mistakes

1. **Not handling all message parts**
   - Messages can have multiple parts (text, tool-call, etc.)
   - Always iterate over `message.parts`

2. **Forgetting to filter messages**
   - `messages` includes system messages
   - Filter to `user` and `assistant` for display

3. **Not checking status**
   - Disable input during `streaming`
   - Show loading indicator

4. **Missing error handling**
   - Always handle `error` from `useChat`
   - Provide retry mechanism

## Related

- `tools/api/hono.md` - API routes for AI endpoints
- `tools/ui/react-context.md` - Managing chat state
- Context7 MCP for AI SDK documentation
