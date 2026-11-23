// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// GH#39958: replayed media is budgeted in tokens, PDFs become labels with
// their paths, the replay stays within a share of the window, and media is
// dropped when the request after the previous compaction was near the limit.

import assert from "node:assert/strict";
import test from "node:test";

import { buildReplayParts, planReplay } from "../compaction-replay-budget.mjs";
import { attachmentLabel } from "../compaction-replay-collect.mjs";
import { createCompactionInputReplay, resolveReplayLimits } from "../compaction-pinned-input.mjs";
import {
  CHARS_PER_TOKEN,
  estimateMediaTokens,
  PDF_TOKENS_PER_PAGE,
  postCompactionPressure,
  replayWindowTokens,
} from "../compaction-replay-sizing.mjs";
import { pruneMedia } from "../compaction-replay-v2-store.mjs";

function pdfPart(pages, name) {
  const body = `%PDF-1.7\n${"1 0 obj << /Type /Page /Parent 2 0 R >> endobj\n".repeat(pages)}2 0 obj << /Type /Pages /Count ${pages} >> endobj\n`;
  return {
    type: "file",
    mime: "application/pdf",
    filename: name,
    url: `data:application/pdf;base64,${Buffer.from(body, "latin1").toString("base64")}`,
    source: { type: "file", path: `docs/${name}` },
  };
}

function pngPart(width, height, name) {
  const header = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(header, 0);
  header.write("IHDR", 12, "ascii");
  header.writeUInt32BE(width, 16);
  header.writeUInt32BE(height, 20);
  return { type: "file", mime: "image/png", filename: name, url: `data:image/png;base64,${header.toString("base64")}` };
}

const attachments = () => [
  pdfPart(35, "spec-a.pdf"), pdfPart(35, "spec-b.pdf"), pdfPart(10, "notes.pdf"), pdfPart(3, "brief.pdf"),
  pngPart(400, 300, "screen-1.png"), pngPart(800, 600, "screen-2.png"),
];

const limitsFor = (overrides = {}) => resolveReplayLimits({ maxMediaTokens: 12_000, maxContextPercent: 15, replayPdfs: false, ...overrides });
const textChars = (parts) => parts.filter((part) => part.type === "text").reduce((sum, part) => sum + part.text.length, 0);
const filesOf = (parts) => parts.filter((part) => part.type === "file");
const labelsOf = (parts) => parts.filter((part) => part.type === "text" && part.text.startsWith("[Attached"));

test("token estimates: PDFs by page objects, images by dimensions, missing data never fits", () => {
  assert.equal(estimateMediaTokens(pdfPart(35, "a.pdf")), 35 * PDF_TOKENS_PER_PAGE);
  assert.equal(estimateMediaTokens(pngPart(400, 300, "a.png")), 160);
  assert.equal(estimateMediaTokens(pngPart(4000, 3000, "big.png")), 1600);
  assert.equal(estimateMediaTokens({ mime: "image/png", url: "data:image/png;base64,AA==" }), 1600);
  assert.equal(estimateMediaTokens({ mime: "image/png", url: "file:///tmp/a.png" }), Infinity);
  assert.equal(replayWindowTokens({ context: 250_000, output: 32_000 }), 218_000);
  assert.equal(replayWindowTokens({ context: 400_000, input: 272_000, output: 128_000 }), 272_000);
  assert.equal(replayWindowTokens(undefined), 0);
});

test("attachment labels keep the original path of inlined attachments", () => {
  assert.equal(attachmentLabel(pdfPart(1, "a.pdf"), "r"), "[Attached application/pdf: a.pdf (docs/a.pdf) — r]");
  assert.equal(attachmentLabel({ mime: "image/png", filename: "x.png", url: "file:///tmp/x%20y.png" }, ""), "[Attached image/png: x.png (/tmp/x y.png)]");
  assert.equal(attachmentLabel({ mime: "image/png", filename: "x.png", url: "file:///tmp/%E0" }, ""), "[Attached image/png: x.png (/tmp/%E0)]");
});

test("four large PDFs become labels with paths; small images replay inline within the cap", () => {
  const entries = [{ id: "u1", created: 1, text: "Review these specs against the screenshots.", notes: [], media: attachments() }];
  const limits = limitsFor();
  const windowTokens = 218_000;
  const { selection, maxMediaTokens, totalTokens } = planReplay(entries, limits, windowTokens);
  const built = buildReplayParts(selection, {
    sessionID: "s", anchorID: "a", overflow: false, maxMedia: limits.maxMedia, maxMediaTokens, replayPdfs: false,
  });
  const files = filesOf(built.parts);
  assert.deepEqual(files.map((part) => part.filename), ["screen-1.png", "screen-2.png"]);
  assert.equal(built.media, 2);
  assert.equal(built.mediaTokens, 160 + 640);
  const labels = labelsOf(built.parts).map((part) => part.text);
  assert.equal(labels.length, 4);
  for (const name of ["spec-a.pdf", "spec-b.pdf", "notes.pdf", "brief.pdf"]) {
    assert.ok(labels.some((label) => label.includes(`(docs/${name})`) && label.includes("read the pages you need")), name);
  }
  assert.equal(totalTokens, 32_700);
  assert.ok(Math.ceil(textChars(built.parts) / CHARS_PER_TOKEN) + built.mediaTokens <= totalTokens);
});

test("opted-in PDFs are still charged by tokens; the context share shrinks the media budget", () => {
  const entries = [{ id: "u1", created: 1, text: "aim", notes: [], media: attachments() }];
  const optedIn = planReplay(entries, limitsFor({ replayPdfs: true }), 218_000);
  const built = buildReplayParts(optedIn.selection, {
    sessionID: "s", anchorID: "a", overflow: false, maxMedia: 6, maxMediaTokens: optedIn.maxMediaTokens, replayPdfs: true,
  });
  assert.deepEqual(filesOf(built.parts).map((part) => part.filename), ["brief.pdf", "screen-1.png", "screen-2.png"]);
  assert.ok(built.mediaTokens <= 12_000);

  const long = [{ id: "u1", created: 1, text: "x".repeat(200_000), notes: [], media: attachments() }];
  const small = planReplay(long, limitsFor(), 40_000);
  assert.equal(small.totalTokens, 6_000);
  assert.ok(small.selection.chars <= 6_000 * CHARS_PER_TOKEN);
  assert.ok(small.maxMediaTokens <= 6_000 - Math.ceil(small.selection.chars / CHARS_PER_TOKEN));
  const unknown = planReplay(long, limitsFor(), 0);
  assert.equal(unknown.totalTokens, null);
  assert.equal(unknown.maxMediaTokens, 12_000);
});

test("V2 store pruning labels PDFs and keeps only media within the token budget", () => {
  const prompts = [{ id: "p1", notes: [], media: attachments() }];
  pruneMedia(prompts, { maxMedia: 4, maxMediaTokens: 12_000, replayPdfs: false });
  assert.deepEqual(prompts[0].media.map((part) => part.filename), ["screen-1.png", "screen-2.png"]);
  assert.equal(prompts[0].notes.filter((note) => note.includes("PDF not replayed")).length, 4);
});

function historyWithLoop(firstRequestTokens) {
  const media = attachments();
  return [
    { info: { id: "u1", role: "user", sessionID: "s", time: { created: 1 } }, parts: [{ type: "text", text: "Review these specs." }, ...media] },
    { info: { id: "a1", role: "assistant", parentID: "u1", tokens: { input: 5, cache: { read: 0, write: 230_000 } } }, parts: [] },
    { info: { id: "c1", role: "user", sessionID: "s" }, parts: [{ type: "compaction", auto: true, overflow: false }] },
    { info: { id: "s1", role: "assistant", parentID: "c1", summary: true, finish: "stop", tokens: { input: 20_000 } }, parts: [] },
    { info: { id: "a2", role: "assistant", parentID: "c1", tokens: { input: 3, cache: { read: 37_357, write: firstRequestTokens - 37_360 } } }, parts: [] },
    { info: { id: "c2", role: "user", sessionID: "s" }, parts: [{ type: "compaction", auto: true, overflow: false }] },
    { info: { id: "s2", role: "assistant", parentID: "c2", summary: true, finish: "stop", tokens: { input: 21_000 } }, parts: [] },
  ];
}

async function replayAfterSecondCompaction(firstRequestTokens) {
  const history = historyWithLoop(firstRequestTokens);
  const logs = [];
  const client = { session: { messages: async () => ({ data: history }) } };
  const replay = createCompactionInputReplay(client, { qualityLog: (level, message) => logs.push(message), limits: limitsFor() });
  replay.chatParams({ sessionID: "s", agent: "build", model: { limit: { context: 250_000, output: 32_000 } } });
  replay.chatParams({ sessionID: "s", agent: "compaction", model: { limit: { context: 1_000_000, output: 32_000 } } });
  const output = { messages: [structuredClone(history[5]), structuredClone(history[6])] };
  const result = await replay.inject({}, output);
  return { result, logs, parts: output.messages[0].parts.filter((part) => part.metadata?.aidevops_pinned_user_input) };
}

test("loop backstop drops replayed media when the previous post-compaction request was near the limit", async () => {
  assert.equal(postCompactionPressure(historyWithLoop(232_000), "s2", 218_000), 106);
  assert.equal(postCompactionPressure(historyWithLoop(232_000), "s1", 218_000), null);
  // Unknown window: the session's peak request (here that same request) stands in.
  assert.equal(postCompactionPressure(historyWithLoop(232_000), "s2", 0), 100);
  assert.equal(postCompactionPressure(historyWithLoop(40_000), "s2", 0), 17);

  const looping = await replayAfterSecondCompaction(232_000);
  assert.equal(looping.result.injected, true);
  assert.equal(filesOf(looping.parts).length, 0);
  assert.ok(looping.logs.includes("[compaction-replay] media dropped: post-compaction context 106%"));
  assert.ok(looping.logs.some((line) => line.includes("0 attachment(s)") && line.includes("context cap 32700 tokens")));
  assert.ok(labelsOf(looping.parts).some((part) => part.text.includes("screen-2.png") && part.text.includes("media dropped")));

  const healthy = await replayAfterSecondCompaction(40_000);
  assert.deepEqual(filesOf(healthy.parts).map((part) => part.filename), ["screen-1.png", "screen-2.png"]);
  assert.ok(!healthy.logs.some((line) => line.includes("media dropped")));
});
