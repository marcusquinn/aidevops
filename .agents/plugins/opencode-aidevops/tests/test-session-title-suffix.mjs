// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  createSessionTitleSuffixHandler,
  readAidevopsVersion,
  withAidevopsTitleSuffix,
} from "../session-title-suffix.mjs";
import {
  createSessionTitleFallbackHandler,
  deriveFallbackTitleFromPrompt,
  isDefaultSessionTitle,
} from "../session-title-fallback.mjs";

async function withTempAgentsDir(fn) {
  const root = mkdtempSync(join(tmpdir(), "aidevops-title-suffix-"));
  const dir = join(root, "agents");
  mkdirSync(dir);
  try {
    return await fn(dir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

async function withoutEnvVersion(fn) {
  const saved = process.env.AIDEVOPS_VERSION;
  try {
    delete process.env.AIDEVOPS_VERSION;
    return await fn();
  } finally {
    if (saved === undefined) delete process.env.AIDEVOPS_VERSION;
    else process.env.AIDEVOPS_VERSION = saved;
  }
}

function waitForTimer(ms = 5) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("title suffix appends and replaces idempotently", () => {
  assert.equal(
    withAidevopsTitleSuffix("Investigate title path", "3.20.102"),
    "Investigate title path · AIDevOps 3.20.102",
  );
  assert.equal(
    withAidevopsTitleSuffix("Investigate title path · AIDevOps 3.20.101", "3.20.102"),
    "Investigate title path · AIDevOps 3.20.102",
  );
});

test("default session title detection ignores AIDevOps suffix", () => {
  assert.equal(isDefaultSessionTitle("New session - 2026-06-20T21:27:42.505Z"), true);
  assert.equal(isDefaultSessionTitle("New session - 2026-06-20T21:27:42.505Z · AIDevOps 3.21.2"), true);
  assert.equal(isDefaultSessionTitle("Study newsjack repository capabilities · AIDevOps 3.21.2"), false);
});

test("fallback title derives concise title from first meaningful prompt line", () => {
  assert.equal(
    deriveFallbackTitleFromPrompt(`https://github.com/elvisun/newsjack

i'd like to add the capabilities this repo offers. there may be overlap`),
    "Add the capabilities this repo offers. there may be overlap",
  );
  assert.equal(deriveFallbackTitleFromPrompt("please review PR #123"), "Review PR #123");
});

test("version reader prefers deployed agents VERSION", async () => {
  await withoutEnvVersion(() =>
    withTempAgentsDir((agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.20.102\n");
      writeFileSync(join(agentsDir, "..", "version"), "2.44.2\n");

      assert.equal(readAidevopsVersion(agentsDir), "3.20.102");
    }),
  );
});

test("session.updated handler appends suffix through OpenCode session update API", async () => {
  await withoutEnvVersion(() =>
    withTempAgentsDir(async (agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.20.103\n");
      const calls = [];
      const client = {
        session: {
          update: async (payload) => {
            calls.push(payload);
            return { data: {} };
          },
        },
      };

      const handler = createSessionTitleSuffixHandler({ agentsDir, client });
      await handler({
        event: {
          type: "session.updated",
          properties: {
            sessionID: "ses_test",
            info: { id: "ses_test", title: "Work on live title fix" },
          },
        },
      });

      assert.deepEqual(calls, [
        {
          path: { id: "ses_test" },
          body: { title: "Work on live title fix · AIDevOps 3.20.103" },
        },
      ]);
    }),
  );
});

test("session.updated handler is idempotent when suffix already exists", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.103\n");
    const calls = [];
    const client = { session: { update: async (payload) => calls.push(payload) } };
    const handler = createSessionTitleSuffixHandler({ agentsDir, client });

    await handler({
      event: {
        type: "session.updated",
        properties: {
          sessionID: "ses_test",
          info: { id: "ses_test", title: "Work · AIDevOps 3.20.103" },
        },
      },
    });

    assert.deepEqual(calls, []);
  });
});

test("session.updated handler ignores default titles so stale updates do not overwrite fallback titles", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.21.4\n");
    const calls = [];
    const client = { session: { update: async (payload) => calls.push(payload) } };
    const handler = createSessionTitleSuffixHandler({ agentsDir, client });

    await handler({
      event: {
        type: "session.updated",
        properties: {
          sessionID: "ses_test",
          info: { id: "ses_test", title: "New session - 2026-06-20T22:54:09.982Z" },
        },
      },
    });
    await handler({
      event: {
        type: "session.updated",
        properties: {
          sessionID: "ses_test",
          info: { id: "ses_test", title: "New session - 2026-06-20T22:54:09.982Z · AIDevOps 3.21.4" },
        },
      },
    });

    assert.deepEqual(calls, []);
  });
});

test("session.updated handler ignores unavailable session update API", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.20.103\n");
    const handler = createSessionTitleSuffixHandler({ agentsDir, client: { session: {} } });

    await assert.doesNotReject(() =>
      handler({
        event: {
          type: "session.updated",
          properties: {
            sessionID: "ses_test",
            info: { id: "ses_test", title: "Unavailable update" },
          },
        },
      }),
    );
  });
});

test("session.updated handler falls back to sessionID path shape", async () => {
  await withoutEnvVersion(() =>
    withTempAgentsDir(async (agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.20.103\n");
      const calls = [];
      const client = {
        session: {
          update: async (payload) => {
            calls.push(payload);
            if (calls.length === 1) throw new Error("wrong path shape");
            return { data: {} };
          },
        },
      };
      const handler = createSessionTitleSuffixHandler({ agentsDir, client });

      await handler({
        event: {
          type: "session.updated",
          properties: {
            sessionID: "ses_test",
            info: { id: "ses_test", title: "Fallback path" },
          },
        },
      });

      assert.equal(calls.length, 2);
      assert.deepEqual(calls[1], {
        path: { sessionID: "ses_test" },
        body: { title: "Fallback path · AIDevOps 3.20.103" },
      });
    }),
  );
});

test("message part fallback replaces stuck New session title", async () => {
  await withoutEnvVersion(() =>
    withTempAgentsDir(async (agentsDir) => {
      writeFileSync(join(agentsDir, "VERSION"), "3.21.2\n");
      const calls = [];
      const client = { session: { update: async (payload) => calls.push(payload) } };
      const handler = createSessionTitleFallbackHandler({ agentsDir, client, fallbackDelayMs: 1 });

      await handler({
        event: {
          type: "session.updated",
          properties: {
            sessionID: "ses_test",
            info: { id: "ses_test", title: "New session - 2026-06-20T21:27:42.505Z" },
          },
        },
      });
      await handler({
        event: {
          type: "message.updated",
          properties: {
            sessionID: "ses_test",
            info: { id: "msg_user", sessionID: "ses_test", role: "user" },
          },
        },
      });
      await handler({
        event: {
          type: "message.part.updated",
          properties: {
            sessionID: "ses_test",
            part: {
              sessionID: "ses_test",
              messageID: "msg_user",
              type: "text",
              text: "please study the newsjack repository capabilities",
            },
          },
        },
      });
      await waitForTimer();

      assert.deepEqual(calls.at(-1), {
        path: { id: "ses_test" },
        body: { title: "Study the newsjack repository capabilities · AIDevOps 3.21.2" },
      });
    }),
  );
});

test("message part fallback waits for native title generation before replacing default title", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.21.6\n");
    const calls = [];
    const client = { session: { update: async (payload) => calls.push(payload) } };
    const handler = createSessionTitleFallbackHandler({ agentsDir, client, fallbackDelayMs: 5 });

    await handler({
      event: {
        type: "session.updated",
        properties: { sessionID: "ses_test", info: { id: "ses_test", title: "New session - 2026-06-20T23:27:52.727Z" } },
      },
    });
    await handler({
      event: {
        type: "message.updated",
        properties: { sessionID: "ses_test", info: { id: "msg_user", sessionID: "ses_test", role: "user" } },
      },
    });
    await handler({
      event: {
        type: "message.part.updated",
        properties: {
          sessionID: "ses_test",
          part: { sessionID: "ses_test", messageID: "msg_user", type: "text", text: "please check pulse and workers" },
        },
      },
    });
    await handler({
      event: {
        type: "session.updated",
        properties: { sessionID: "ses_test", info: { id: "ses_test", title: "Worker status check" } },
      },
    });
    await waitForTimer(10);

    assert.deepEqual(calls, []);
  });
});

test("message part fallback preserves meaningful session title", async () => {
  await withTempAgentsDir(async (agentsDir) => {
    writeFileSync(join(agentsDir, "VERSION"), "3.21.2\n");
    const calls = [];
    const client = { session: { update: async (payload) => calls.push(payload) } };
    const handler = createSessionTitleFallbackHandler({ agentsDir, client });

    await handler({
      event: {
        type: "session.updated",
        properties: { sessionID: "ses_test", info: { id: "ses_test", title: "Existing title · AIDevOps 3.21.2" } },
      },
    });
    await handler({
      event: {
        type: "message.updated",
        properties: { sessionID: "ses_test", info: { id: "msg_user", sessionID: "ses_test", role: "user" } },
      },
    });
    await handler({
      event: {
        type: "message.part.updated",
        properties: {
          sessionID: "ses_test",
          part: { sessionID: "ses_test", messageID: "msg_user", type: "text", text: "please replace me" },
        },
      },
    });

    assert.deepEqual(calls, []);
  });
});
