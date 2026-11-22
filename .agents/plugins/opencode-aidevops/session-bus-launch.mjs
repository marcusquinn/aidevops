// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18892: `aidevops sessions launch` creates a titled session on an
// `opencode serve` instance (`POST /session`, as matrix-bot.mjs.template does),
// then uses the bus instead of `/session/{id}/message`: it binds the chat
// channel, enables owner chat wakes for that session and sends the task text as
// a chat-origin `ask` from the verified owner. The server's plugin then lists
// and wakes the session like any other.
//
// OpenCode 1.19.5 `POST /session` takes `{ title }` in the body and an optional
// `?directory=` query, so `--directory` picks the project; without it the
// session uses the server's own directory.

import { BUS_VERSION, isSafeId } from "./session-bus-files.mjs";
import { channelLabel, parseChannelRef, writeBinding } from "./session-bus-bindings.mjs";
import { sendMessage, validBody } from "./session-bus-messages.mjs";
import { chatTrust, setChatWake } from "./session-bus-chat-trust.mjs";

export const DEFAULT_SERVER = "http://127.0.0.1:4096";
export const LAUNCH_PARTIAL_EXIT = 4;
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const REQUEST_TIMEOUT_MS = 15_000;
const TITLE_CHARS = 200;
const CONTROL = /[\u0000-\u001F\u007F]/g;

/** Normalised server URL. Plain http is accepted only for loopback hosts. */
export function validServerUrl(value) {
  let url;
  try {
    url = new URL(String(value || DEFAULT_SERVER));
  } catch {
    throw new Error(`--server must be a URL such as ${DEFAULT_SERVER}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("--server must use http or https");
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("--server must not contain credentials, a query or a fragment");
  }
  if (url.protocol === "http:" && !LOOPBACK_HOSTS.has(url.hostname)) {
    throw new Error("--server over plain http must be loopback (localhost, 127.0.0.1 or [::1]); use https for any other host");
  }
  return `${url.origin}${url.pathname.replace(/\/+$/, "")}`;
}

function validTitle(value) {
  const title = String(value ?? "").replace(CONTROL, " ").trim();
  if (!title) throw new Error("launch needs --title, for example \"Issue #123: short description\"");
  if (Array.from(title).length > TITLE_CHARS) throw new Error(`--title exceeds ${TITLE_CHARS} characters`);
  return title;
}

function validDirectory(value) {
  if (!value) return "";
  const directory = String(value);
  if (!directory.startsWith("/") || /[\u0000-\u001F\u007F]/.test(directory)) throw new Error("--directory must be an absolute path");
  return directory;
}

async function createSession(fetchImpl, server, { title, directory }) {
  const url = new URL(`${server}/session`);
  if (directory) url.searchParams.set("directory", directory);
  let response;
  try {
    response = await fetchImpl(url.href, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
      // A 307/308 would replay the POST to another host, past the
      // loopback-or-https check above; refuse redirects outright.
      redirect: "error",
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    if (error?.cause?.code === "ECONNREFUSED" || error?.code === "ECONNREFUSED") {
      throw new Error(`could not reach ${server} (connection refused); no session was created`);
    }
    const reason = error?.name === "TimeoutError" ? "timed out" : "connection failed or redirected";
    throw new Error(`could not reach ${server} (${reason}); a session may have been created; check its session list before retrying`);
  }
  if (!response?.ok) throw new Error(`${server} returned a session creation error (HTTP ${response?.status}); check its session list before retrying`);
  const session = await response.json().catch(() => null);
  if (!isSafeId(session?.id) || !session.id.startsWith("ses")) {
    throw new Error(`${server} answered without a usable session ID; check its session list before retrying`);
  }
  return session;
}

// Owner trust is checked, and the task text scanned, before any server call.
function verifiedOwner(chat, actor, text, env) {
  if (!isSafeId(actor)) throw new Error("launch needs --actor <entity-id> (the verified owner)");
  const trust = chatTrust(`chat:${chat.app}:${chat.channel}`, actor, text, env);
  if (!trust.verified || !trust.owner) {
    throw new Error(`launch refused: ${actor} is not the verified owner for ${channelLabel(chat)}; no session was created`);
  }
  return trust;
}

function report(out, options, value, line) {
  out.write(`${options.json ? JSON.stringify(value, null, 2) : line}\n`);
}

// After the server returned an ID: bind, opt in, ask. A failure here keeps
// whatever was written (the binding lets a retried `send channel:...` reach
// the session) and exits 4 with the created session ID.
function finishLaunch({ root, options, out }, { chat, session, server, trust, text }) {
  const sessionID = session.id;
  const label = channelLabel(chat);
  let step = "bind the channel";
  try {
    const { previous } = writeBinding(root, { app: chat.app, channel: chat.channel, sessionID, actor: trust.actor, server });
    step = "enable chat wakes";
    setChatWake(root, sessionID, true);
    step = "send the task ask";
    const origin = `chat:${chat.app}:${chat.channel}`;
    const from = { session_id: "", handle: `chat:${chat.app}`, repo: "", branch: "", origin, trust };
    const message = sendMessage(root, { from, to: sessionID, type: "ask", text });
    const replaced = previous && previous.session_id !== sessionID ? ` (replaces ${previous.session_id})` : "";
    report(out, options, { v: BUS_VERSION, session_id: sessionID, title: session.title || "", server, binding: label, ask_id: message.id },
      `Launched ${sessionID} on ${server}; bound ${label}${replaced}; sent ask ${message.id}. Read the reply with: aidevops sessions outbox ${chat.app}`);
    return 0;
  } catch (error) {
    report(out, options, { v: BUS_VERSION, session_id: sessionID, server, binding: label, failed_step: step, error: error.message },
      `Launched ${sessionID} on ${server}, but could not ${step}: ${error.message}. Bind or retry with: aidevops sessions send ${label} …, or delete the session on the server.`);
    return LAUNCH_PARTIAL_EXIT;
  }
}

/**
 * `launch --server <url> --title <t> --bind <app>:<channel> --actor <id>` with
 * the task text. Returns a Promise of the exit code: 0 launched, 4 the session
 * exists but bind/opt-in/ask failed. Refusals before the server call throw.
 * `context.fetch` is injectable for tests.
 */
export async function launchCommand(context, rawText) {
  const { options, env } = context;
  const fetchImpl = context.fetch || globalThis.fetch;
  const server = validServerUrl(options.server);
  if (!options.bind) throw new Error("launch needs --bind <app>:<channel>");
  const chat = parseChannelRef(options.bind);
  const title = validTitle(options.title);
  const directory = validDirectory(options.directory);
  const text = validBody(rawText);
  const trust = verifiedOwner(chat, options.actor, text, env);
  const session = await createSession(fetchImpl, server, { title, directory });
  return finishLaunch(context, { chat, session, server, trust, text });
}
