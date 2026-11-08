// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// t18886/GH#37149: deterministic session-bus behaviour (store limits, target
// resolution, claim-once delivery, reply routing) and the plugin delivery
// channels against a fake OpenCode client. Live multi-session behaviour is
// verified separately against real OpenCode processes.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, utimesSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import * as store from "../session-bus-store.mjs";
import { createSessionBus, isWakeEligible, parseRepoSlug, processKind } from "../session-bus.mjs";
import { createSessionBusTool } from "../session-bus-tool.mjs";
import { main as cliMain } from "../session-bus-cli.mjs";
import { getSessionBusState } from "../compaction.mjs";
import { messageRows, rootSessionID } from "../tui-messages.mjs";

let root;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "session-bus-test-"));
});
afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

const peer = (id, extra = {}) => ({ session_id: id, handle: `repo-${id.slice(-2)}`, repo: "owner/repo", branch: "main", origin: "opencode", ...extra });

function livePresence(id, extra = {}) {
  const record = {
    v: store.BUS_VERSION, session_id: id, pid: process.pid, start_token: store.startToken(process.pid),
    kind: "tui", messageable: true, repo: "owner/repo", worktree: `/w/${id}`, branch: "main",
    title: "", issue: null, pr: null, status: "idle", handle: `repo-${id.slice(-2)}`, ...extra,
  };
  store.writePresence(root, record);
  return record;
}

test("presence lists only live process generations and sweeps dead records", () => {
  livePresence("ses_live01");
  store.writePresence(root, { ...livePresence("ses_dead01"), pid: 999_999_9, start_token: "ps:never" });
  store.writePresence(root, { ...livePresence("ses_recy01"), start_token: "ps:recycled" });
  assert.deepEqual(store.readPresence(root).map((record) => record.session_id), ["ses_live01"]);
  store.readPresence(root, { sweep: true });
  // No start token for a live PID (ps failed) is not proof of death.
  const noTokens = { sweep: true, tokens: () => new Map() };
  assert.deepEqual(store.readPresence(root, noTokens).map((record) => record.session_id), ["ses_live01"]);
  assert.equal(store.readPresence(root).length, 1);
});

test("targets resolve by exact tier, report ambiguity, and reject self", () => {
  const records = [
    { session_id: "ses_aaaa01", handle: "aidevops-37149", issue: 37149, pr: null, repo: "o/aidevops", worktree: "/w/a", title: "Issue #37149: bus" },
    { session_id: "ses_bbbb02", handle: "aidevops-pr12", issue: null, pr: 12, repo: "o/aidevops", worktree: "/w/b", title: "PR #12: fix" },
    { session_id: "ses_cccc03", handle: "other-c03", issue: null, pr: null, repo: "o/other", worktree: "/w/c", title: "" },
  ];
  assert.equal(store.resolveTarget(records, "#37149").record.session_id, "ses_aaaa01");
  assert.equal(store.resolveTarget(records, "PR#12").record.session_id, "ses_bbbb02");
  assert.equal(store.resolveTarget(records, "AIDEVOPS-37149").record.session_id, "ses_aaaa01");
  assert.equal(store.resolveTarget(records, "other").record.session_id, "ses_cccc03");
  assert.equal(store.resolveTarget(records, "/w/b/").record.session_id, "ses_bbbb02");
  const ambiguous = store.resolveTarget(records, "aidevops");
  assert.match(ambiguous.error, /matches 2 sessions/);
  assert.equal(ambiguous.candidates.length, 2);
  assert.match(store.resolveTarget(records, "#37149", "ses_aaaa01").error, /yourself/);
  assert.equal(store.resolveTarget(records, "ses_gone99").offline, true);
  assert.match(store.resolveTarget(records, "nothing-here").error, /no live OpenCode session/);
});

test("send enforces text, rate and inbox limits", () => {
  assert.throws(() => store.sendMessage(root, { from: peer("ses_from01"), to: "ses_to0001", type: "info", text: "x".repeat(2001) }), /2000 characters/);
  assert.throws(() => store.sendMessage(root, { from: peer("ses_from01"), to: "ses_from01", type: "info", text: "hi" }), /yourself/);
  for (let index = 0; index < store.LIMITS.sendsPerMinute; index += 1) {
    store.sendMessage(root, { from: peer("ses_from01"), to: "ses_to0001", type: "info", text: `m${index}` });
  }
  assert.throws(() => store.sendMessage(root, { from: peer("ses_from01"), to: "ses_to0001", type: "info", text: "over" }), /rate limit/);
  for (let index = 0; index < store.LIMITS.inboxPending - store.LIMITS.sendsPerMinute; index += 1) {
    store.sendMessage(root, { from: peer(`ses_f${String(index).padStart(5, "0")}`), to: "ses_to0001", type: "info", text: "fill" });
  }
  assert.throws(() => store.sendMessage(root, { from: peer("ses_other1"), to: "ses_to0001", type: "info", text: "full" }), /inbox is full/);
});

test("a delivery is claimed exactly once and can be returned to the inbox", () => {
  store.sendMessage(root, { from: peer("ses_from01"), to: "ses_to0001", type: "ask", text: "status?" });
  const [entry] = store.pendingMessages(root, "ses_to0001");
  assert.equal(store.claimMessage(root, "ses_to0001", entry), true);
  assert.equal(store.claimMessage(root, "ses_to0001", entry), false);
  assert.equal(store.pendingMessages(root, "ses_to0001").length, 0);
  assert.equal(store.unclaimMessage(root, "ses_to0001", entry), true);
  assert.equal(store.pendingMessages(root, "ses_to0001").length, 1);
});

test("replies route to the asking session, or to an outbox for sessionless senders", () => {
  const ask = store.sendMessage(root, { from: peer("ses_asker1"), to: "ses_answr1", type: "ask", text: "which PR?" });
  assert.throws(() => store.sendReply(root, { from: peer("ses_answr1"), original: { ...ask, type: "info" }, text: "no" }), /only a received ask/);
  const { message } = store.sendReply(root, { from: peer("ses_answr1"), original: ask, text: "PR #12" });
  assert.equal(message.to, "ses_asker1");
  assert.equal(message.re, ask.id);
  const open = store.openAsks(root, "ses_answr1");
  assert.deepEqual(open.toAnswer, []);

  const chatAsk = store.sendMessage(root, {
    from: { session_id: "", handle: "chat:matrix", origin: "chat:matrix:!room:example.org" }, to: "ses_answr1", type: "ask", text: "status?",
  });
  const chatReply = store.sendReply(root, { from: peer("ses_answr1"), original: chatAsk, text: "green" });
  assert.equal(chatReply.outbox, "matrix");
  const [queued] = store.readOutbox(root, "matrix");
  assert.equal(queued.channel, "!room:example.org");
  assert.equal(store.ackOutbox(root, "matrix", queued.id), true);
  assert.deepEqual(store.readOutbox(root, "matrix"), []);

  const shellAsk = store.sendMessage(root, { from: { session_id: "", handle: "shell:me", origin: "cli" }, to: "ses_answr1", type: "ask", text: "hi?" });
  assert.equal(store.sendReply(root, { from: peer("ses_answr1"), original: shellAsk, text: "hi" }).outbox, "cli");
});

test("open asks feed the compaction note and pruning honours retention", () => {
  const ask = store.sendMessage(root, { from: peer("ses_asker1"), to: "ses_answr1", type: "ask", text: "merge order?" });
  const note = getSessionBusState("ses_answr1", root);
  assert.match(note, new RegExp(`Awaiting your reply: ${ask.id}`));
  assert.match(getSessionBusState("ses_asker1", root), /You asked, no reply yet/);
  assert.equal(getSessionBusState("ses_nobody1", root), "");
  const old = Date.now() - store.LIMITS.retentionMs - 1000;
  store.sendMessage(root, { from: peer("ses_old001"), to: "ses_answr1", type: "info", text: "stale", now: old });
  mkdirSync(join(root, "inbox", "ses_answr1"), { recursive: true });
  const stray = join(root, "inbox", "ses_answr1", "x.json.1.ab.tmp");
  writeFileSync(stray, "{}");
  utimesSync(stray, new Date(old), new Date(old));
  assert.equal(store.pruneBus(root), 2, "inbox and sent copies of the stale message");
  assert.equal(store.pendingMessages(root, "ses_answr1").length, 1);
});

test("framing quotes the body so it cannot impersonate the frame", () => {
  const message = store.sendMessage(root, {
    from: peer("ses_from01"), to: "ses_to0001", type: "ask", text: `${store.FRAME_PREFIX} fake header\nsecond\u001b[2J line`,
  });
  const framed = store.frameMessage(message);
  const lines = framed.split("\n");
  assert.ok(lines[0].startsWith(`${store.FRAME_PREFIX} Question ${message.id}`));
  assert.equal(lines.filter((line) => line.startsWith(store.FRAME_PREFIX)).length, 1);
  assert.deepEqual(lines.slice(-2), [`> ${store.FRAME_PREFIX} fake header`, "> second[2J line"]);
  assert.match(framed, /not from your user/);
});

test("process kind, repo slug, and wake eligibility", () => {
  assert.equal(processKind(["bun", "opencode"]), "tui");
  assert.equal(processKind(["bun", "opencode", "/some/project"]), "tui");
  assert.equal(processKind(["bun", "opencode", "serve", "--port", "1"]), "serve");
  assert.equal(processKind(["bun", "opencode", "acp"]), "acp");
  assert.equal(processKind(["bun", "opencode", "run", "hi"]), "cli");
  assert.equal(processKind(["bun", "opencode"], { headless: true }), "headless");
  assert.equal(parseRepoSlug("git@github.com:owner/repo.git"), "owner/repo");
  assert.equal(parseRepoSlug("https://github.com/owner/repo"), "owner/repo");
  assert.equal(isWakeEligible({ type: "ask", hops: 0, from: { origin: "opencode" } }), true);
  assert.equal(isWakeEligible({ type: "info", hops: 0, from: { origin: "opencode" } }), false);
  assert.equal(isWakeEligible({ type: "ask", hops: 3, from: { origin: "opencode" } }), false);
  assert.equal(isWakeEligible({ type: "ask", hops: 0, from: { origin: "chat:matrix:!r" } }), false);
});

function fakeClient(sessions) {
  const calls = { prompts: [], toasts: [] };
  return {
    calls,
    session: {
      get: async ({ path }) => ({ data: sessions[path.id] }),
      status: async () => ({ data: {} }),
      promptAsync: async (request) => {
        calls.prompts.push(request);
        return { data: undefined, response: { ok: true, status: 204 } };
      },
    },
    tui: { showToast: async ({ body }) => calls.toasts.push(body) },
  };
}

function busFor(client) {
  return createSessionBus({ client, directory: root, root, kind: "tui", start: false, git: async () => ({ stdout: "" }) });
}

test("runtime publishes root presence and delivers through tool results, turns and wakes", async () => {
  const client = fakeClient({
    ses_rootA1: { id: "ses_rootA1", title: "Issue #12: work", directory: root },
    ses_childA: { id: "ses_childA", parentID: "ses_rootA1", directory: root },
  });
  const bus = busFor(client);
  await bus.handleEvent({ event: { type: "session.created", properties: { info: { id: "ses_rootA1", title: "Issue #12: work", directory: root } } } });
  await bus.handleEvent({ event: { type: "session.created", properties: { info: { id: "ses_childA", parentID: "ses_rootA1" } } } });
  const [presence] = store.readPresence(root);
  assert.equal(presence.session_id, "ses_rootA1");
  assert.equal(presence.issue, 12);
  assert.match(presence.handle, /-12$/);

  // Busy: appended to the next tool result, never to a child session's.
  await bus.chatMessage(
    { sessionID: "ses_rootA1", agent: "Build+", model: { providerID: "anthropic", modelID: "m1" } },
    { message: { id: "msg_u1" }, parts: [{ id: "prt_1", type: "text", text: "go" }] },
  );
  store.sendMessage(root, { from: peer("ses_peer01"), to: "ses_rootA1", type: "info", text: "FYI merged" });
  const childOutput = { output: "child" };
  assert.equal(bus.toolAfter({ sessionID: "ses_childA", tool: "bash" }, childOutput), 0);
  const toolOutput = { output: "done" };
  assert.equal(bus.toolAfter({ sessionID: "ses_rootA1", tool: "bash" }, toolOutput), 1);
  assert.match(toolOutput.output, /^done\n\n\[aidevops session-bus\] Message/);

  // Next user turn: synthetic part on the user message.
  store.sendMessage(root, { from: peer("ses_peer02"), to: "ses_rootA1", type: "info", text: "later" });
  const turn = { message: { id: "msg_u2" }, parts: [{ id: "prt_2", type: "text", text: "next" }] };
  await bus.chatMessage({ sessionID: "ses_rootA1" }, turn);
  assert.equal(turn.parts.length, 2);
  assert.equal(turn.parts[1].synthetic, true);
  assert.equal(turn.parts[1].id, "prt_2zb0");
  assert.equal(turn.parts[1].messageID, "msg_u2");

  // Idle: info waits, an ask wakes with the session's agent and model.
  await bus.handleEvent({ event: { type: "session.idle", properties: { sessionID: "ses_rootA1" } } });
  store.sendMessage(root, { from: peer("ses_peer03"), to: "ses_rootA1", type: "info", text: "no wake" });
  await bus.tick();
  assert.equal(client.calls.prompts.length, 0);
  assert.equal(client.calls.toasts.length, 1);
  store.sendMessage(root, { from: peer("ses_peer04"), to: "ses_rootA1", type: "ask", text: "which branch?", hops: 1 });
  await bus.tick();
  assert.equal(client.calls.prompts.length, 1);
  const [wake] = client.calls.prompts;
  assert.equal(wake.path.id, "ses_rootA1");
  assert.equal(wake.body.agent, "Build+");
  assert.deepEqual(wake.body.model, { providerID: "anthropic", modelID: "m1" });
  assert.equal(wake.body.parts[0].synthetic, true);
  assert.match(wake.body.parts[0].text, /no wake[\s\S]*which branch\?/);
  assert.equal(store.pendingMessages(root, "ses_rootA1").length, 0);

  // The woken turn carries hops forward, so a reply from it is hop 2.
  await bus.chatMessage({ sessionID: "ses_rootA1" }, { message: { id: "msg_u3" }, parts: [] });
  const sender = await bus.sender({ sessionID: "ses_childA" });
  assert.equal(sender.sessionID, "ses_rootA1");
  assert.equal(sender.hops, 2);
});

test("wakes respect the hourly budget, hop limit and failure rollback", async () => {
  const client = fakeClient({ ses_rootB1: { id: "ses_rootB1", title: "", directory: root } });
  const bus = busFor(client);
  await bus.handleEvent({ event: { type: "session.idle", properties: { sessionID: "ses_rootB1" } } });
  store.sendMessage(root, { from: peer("ses_peer05"), to: "ses_rootB1", type: "ask", text: "loop", hops: 3 });
  await bus.tick();
  assert.equal(client.calls.prompts.length, 0, "hop 3 never wakes");
  store.pendingMessages(root, "ses_rootB1").forEach((entry) => store.claimMessage(root, "ses_rootB1", entry));

  let failures = 0;
  client.session.promptAsync = async () => {
    failures += 1;
    return { error: { name: "BadRequest" } };
  };
  store.sendMessage(root, { from: peer("ses_peer06"), to: "ses_rootB1", type: "ask", text: "retry me" });
  await bus.tick();
  assert.equal(store.pendingMessages(root, "ses_rootB1").length, 1, "failed wake returns the message");
  await bus.tick();
  assert.equal(failures, 1, "a failed wake waits before retrying");
  const clock = bus.now;
  bus.now = () => clock() + 60_000;

  let wakes = 0;
  client.session.promptAsync = async () => {
    wakes += 1;
    return { response: { ok: true, status: 204 } };
  };
  for (let index = 0; index < store.LIMITS.wakesPerHour + 2; index += 1) {
    const state = bus.state("ses_rootB1");
    state.status = "idle";
    store.sendMessage(root, { from: peer(`ses_w${String(index).padStart(5, "0")}`), to: "ses_rootB1", type: "ask", text: `q${index}` });
    await bus.tick();
  }
  assert.equal(wakes, store.LIMITS.wakesPerHour);
});

test("tool resolves the sender from context and supports list, ask, reply and idle notices", async () => {
  const client = fakeClient({
    ses_rootC1: { id: "ses_rootC1", title: "Issue #7: tool", directory: root },
  });
  const bus = busFor(client);
  const fakeTool = (definition) => definition;
  fakeTool.schema = { enum: () => ({}), string: () => ({ optional: () => ({}) }) };
  const sessionsTool = createSessionBusTool(fakeTool, bus);
  await bus.handleEvent({ event: { type: "session.created", properties: { info: { id: "ses_rootC1", title: "Issue #7: tool", directory: root } } } });
  livePresence("ses_otherD", { handle: "repo-other", status: "busy" });
  livePresence("ses_workrE", { handle: "repo-worker", kind: "headless", messageable: false });

  const listing = await sessionsTool.execute({ action: "list" }, { sessionID: "ses_rootC1" });
  assert.match(listing, /3 live OpenCode session\(s\), 2 messageable/);
  assert.match(listing, /\(you\) /);
  assert.match(listing, /read-only/);
  await assert.rejects(sessionsTool.execute({ action: "send", to: "repo-worker", text: "hi" }, { sessionID: "ses_rootC1" }), /cannot be messaged/);

  const sent = await sessionsTool.execute({ action: "ask", to: "repo-other", text: "done?" }, { sessionID: "ses_rootC1" });
  assert.match(sent, /is busy; it sees the message at its next tool result/);
  const [{ message: ask }] = store.pendingMessages(root, "ses_otherD");
  assert.equal(ask.from.session_id, "ses_rootC1", "sender comes from ToolContext");

  store.sendMessage(root, { from: peer("ses_otherD", { handle: "repo-other" }), to: "ses_rootC1", type: "ask", text: "your ETA?" });
  const inbox = await sessionsTool.execute({ action: "inbox" }, { sessionID: "ses_rootC1" });
  assert.match(inbox, /your ETA\?/);
  const [incoming] = store.recentTraffic(root, "ses_rootC1", { limit: 5 }).filter((row) => row.direction === "in");
  const replied = await sessionsTool.execute({ action: "reply", re: incoming.message.id, text: "10 min" }, { sessionID: "ses_rootC1" });
  assert.match(replied, /Sent reply/);
  assert.equal(store.pendingMessages(root, "ses_otherD").at(-1).message.type, "reply");

  const notify = await sessionsTool.execute({ action: "notify-when-idle", to: "repo-other" }, { sessionID: "ses_rootC1" });
  assert.match(notify, /one idle notice/);
  const otherBus = busFor(fakeClient({ ses_otherD: { id: "ses_otherD", title: "", directory: root } }));
  await otherBus.handleEvent({ event: { type: "session.idle", properties: { sessionID: "ses_otherD" } } });
  const notice = store.pendingMessages(root, "ses_rootC1").find((entry) => entry.message.type === "idle-notice");
  assert.ok(notice, "idle notice delivered to the subscriber");
});

test("CLI lists sessions and sends from a shell; TUI rows follow the root session", () => {
  livePresence("ses_cliT01", { handle: "repo-cli" });
  livePresence("ses_cliW01", { handle: "repo-w", kind: "headless", messageable: false });
  const output = [];
  const out = { write: (text) => output.push(text) };
  cliMain(["list"], { env: {}, out, root });
  assert.match(output.join(""), /repo-cli[\s\S]*1 headless\/read-only session\(s\) hidden/);
  output.length = 0;
  cliMain(["ask", "repo-cli", "are", "you", "there?"], { env: { USER: "me" }, out, root });
  assert.match(output.join(""), /Sent ask msg_\w+ to repo-cli\. Read the reply with: aidevops sessions outbox cli/);
  assert.throws(() => cliMain(["send", "repo-w", "x"], { env: {}, out, root }), /cannot be messaged/);
  assert.throws(() => cliMain(["send", "repo-cli", "x", "--origin", "bad"], { env: {}, out, root }), /--origin/);

  const rows = messageRows("ses_cliT01", { root });
  assert.equal(rows.length, 1);
  assert.match(rows[0].text, /^• ← shell:me: are you/);
  const sessions = { child: { parentID: "parent" }, parent: {} };
  assert.equal(rootSessionID((id) => sessions[id], "child"), "parent");
});
