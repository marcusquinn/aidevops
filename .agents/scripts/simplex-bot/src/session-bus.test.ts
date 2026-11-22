import { describe, expect, test } from "bun:test";
import { mkdir, readFile, rm, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { CommandRouter } from "./router";
import { busCommand, chatRef, relayOutbox, type BusRunner } from "./session-bus";
import type { CommandContext } from "./types";

const result = (output = "", success = true) => ({ output, success, error: "", exitCode: success ? 0 : 1, durationMs: 0 });
function context(group = false): CommandContext {
  const rawText = "/ask target --test $(touch bad)";
  const parsed = new CommandRouter().parse(rawText);
  if (!parsed) throw new Error("Expected a slash command");
  return {
    ...parsed, rawText,
    chatItem: { chatItem: { content: { type: "rcvMsgContent", msgContent: { type: "text" } } } },
    ...(group ? { group: { groupId: 7, localDisplayName: "g", groupProfile: { displayName: "g" } } } : { contact: { contactId: 42, localDisplayName: "c", profile: { displayName: "c" } } }),
    reply: async () => {},
  };
}

describe("session bus bridge", () => {
  test("parses incoming command arguments across spaces and tabs", () => {
    const router = new CommandRouter();
    expect(router.parse("/ask target --plain hello")).toEqual({ command: "ask", args: ["target", "--plain", "hello"] });
    expect(router.parse("/send\ttarget\t--plain")).toEqual({ command: "send", args: ["target", "--plain"] });
    expect(router.parse("/sessions")).toEqual({ command: "sessions", args: [] });
  });

  test("passes text in a private file, never as options", async () => {
    const root = join(process.env.AIDEVOPS_TEMP_DIR ?? join(homedir(), ".aidevops/.agent-workspace/tmp"), `simplex-test-${process.pid}`);
    await mkdir(root, { recursive: true });
    const calls: string[][] = [];
    let path = "";
    const run: BusRunner = async args => {
      calls.push(args);
      if (args[0].endsWith("entity-helper.sh")) return result('[{"id":"ent_1"}]');
      path = args[args.indexOf("--text-file") + 1];
      expect(await readFile(path, "utf8")).toBe("--test $(touch bad)");
      expect((await stat(path)).mode & 0o777).toBe(0o600);
      return result("sent");
    };
    try {
      expect(await busCommand(context(), "ask", root, run)).toBe("sent");
      expect(calls[1]).toContain("chat:simplex:c42");
      expect(calls[1]).toContain("ent_1");
      expect(calls[1]).not.toContain("--test");
      expect(await Bun.file(path).exists()).toBe(false);
      expect(chatRef(context(true))).toBe("g7");
    } finally { await rm(root, { recursive: true, force: true }); }
  });

  test("group listing is redacted and never assumes an actor", async () => {
    const calls: string[][] = [];
    const run: BusRunner = async args => { calls.push(args); return result("rows"); };
    expect(await busCommand(context(true), "sessions", undefined, run)).toBe("rows");
    expect(calls).toEqual([["aidevops", "sessions", "list", "--redact"]]);
  });

  test("acknowledges only successful delivery", async () => {
    const calls: string[][] = [];
    const run: BusRunner = async args => {
      calls.push(args);
      return result(args.includes("--json") ? JSON.stringify([{ id: "m1", channel: "c1", text: "one" }, { id: "m2", channel: "g2", text: "two" }]) : "ok");
    };
    await relayOutbox(async channel => { if (channel === "c1") throw new Error("offline"); }, run);
    expect(calls.filter(args => args.includes("--ack"))).toEqual([["aidevops", "sessions", "outbox", "simplex", "--ack", "m2"]]);
  });
});
