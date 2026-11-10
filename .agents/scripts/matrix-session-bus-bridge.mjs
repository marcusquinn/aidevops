// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export function parseBusCommand(text, prefix = "!ai") {
  if (typeof text !== "string") return null;
  const match = /^!(sessions|ask|send|bind|unbind|launch)(?:\s+([\s\S]*))?$/u.exec(text.trim());
  if (!match) {
    if (text.startsWith(prefix) && text.slice(prefix.length).trim()) return { type: "ai", text: text.slice(prefix.length).trim() };
    return null;
  }
  return parseExplicitCommand(match);
}

function parseExplicitCommand(match) {
  const [, type, rest = ""] = match;
  if (type === "sessions" || type === "unbind") return { type, invalid: Boolean(rest.trim()) };
  if (type === "launch") {
    const separator = rest.indexOf(" :: ");
    return { type, title: separator < 0 ? "" : rest.slice(0, separator).trim(), text: separator < 0 ? "" : rest.slice(separator + 4).trim() };
  }
  const parts = /^(\S+)(?:\s+([\s\S]*))?$/u.exec(rest.trim());
  return { type, target: parts?.[1] || "", text: parts?.[2] || "" };
}

function validateBusCommand(command) {
  const { type, target, text, title } = command;
  if (command.invalid) throw new Error("Invalid session bus command");
  if (["ask", "send", "bind"].includes(type)) validateBusTarget(target);
  if (["ask", "send", "ai", "launch"].includes(type) && !text) throw new Error("Invalid session bus command");
  if (type === "bind" && text) throw new Error("Invalid session bus command");
  if (type === "launch" && !title) throw new Error("Invalid session bus command");
}

function validateBusTarget(target) {
  if (!target || target.startsWith("-")) throw new Error("Invalid session bus command");
}

export function busArgsFor(command, { roomId, actorEntityId, redact = false }) {
  if (!actorEntityId) throw new Error("No resolved entity for this Matrix user");
  validateBusCommand(command);
  const common = ["--origin", `chat:matrix:${roomId}`, "--actor", actorEntityId, "--json"];
  const args = commandArgsFor(command, roomId, redact);
  return { args: [...args, ...common], input: command.text || "" };
}

function commandArgsFor({ type, target, title }, roomId, redact) {
  let args;
  switch (type) {
    case "sessions": args = ["list", ...(redact ? ["--redact"] : [])]; break;
    case "ask": case "send": args = [type, target, "-"]; break;
    case "ai": args = ["ask", `channel:matrix:${roomId}`, "-"]; break;
    case "bind": args = ["bind", "matrix", roomId, target]; break;
    case "unbind": args = ["unbind", "matrix", roomId]; break;
    case "launch": args = ["launch", "--bind", `matrix:${roomId}`, "--title", title, "-"]; break;
    default: throw new Error("Unknown session bus command");
  }
  return args;
}

export async function relayOutbox({ runCli, sendText }) {
  const messages = JSON.parse(await runCli(["outbox", "matrix", "--json"]));
  for (const message of messages) {
    if (!message.channel || !message.id || typeof message.text !== "string") continue;
    try {
      await sendText(message.channel, message.text);
      await runCli(["outbox", "matrix", "--ack", message.id, "--json"]);
    } catch (error) {
      console.error(`[MATRIX-BOT] Outbox relay failed: ${error.message}`);
    }
  }
}
