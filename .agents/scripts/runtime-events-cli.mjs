// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

function optionValue(args, name, fallback = "") {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
}

function readJsonInput(value) {
  const text = !value || value === "-" ? readFileSync(0, "utf8") : value;
  return JSON.parse(text);
}

function cliSubject(args) {
  return optionValue(args, "--subject") || process.env.AIDEVOPS_WORKER_ID || process.env.AIDEVOPS_SESSION_ID;
}

function printJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function commandFailureCode(command) {
  return command === "emit" || command === "state" ? 0 : 1;
}

function emitPayload(args) {
  const payloadText = optionValue(args, "--payload");
  const payload = payloadText ? JSON.parse(payloadText) : {};
  const additions = {
    attempt_id: process.env.AIDEVOPS_ATTEMPT_ID || "",
    classification: optionValue(args, "--classification"),
    run_id: process.env.AIDEVOPS_RUN_ID || "",
    source: optionValue(args, "--source"),
    status: optionValue(args, "--status"),
  };
  return Object.fromEntries([
    ...Object.entries(payload),
    ...Object.entries(additions).filter(([, value]) => value),
  ]);
}

function emitCommand(args, runtime) {
  const generatedEventId = optionValue(args, "--event-id") ||
    (args.includes("--root-dispatch") ? randomUUID() : undefined);
  const envelope = runtime.appendRuntimeEventSync({
    eventId: generatedEventId,
    eventType: args[1],
    subjectId: cliSubject(args),
    workerId: optionValue(args, "--worker") || undefined,
    parentWorkerId: optionValue(args, "--parent-worker") || undefined,
    rootWorkerId: optionValue(args, "--root-worker") || undefined,
    correlationId: optionValue(args, "--correlation") || undefined,
    causationId: optionValue(args, "--causation") || undefined,
    rootEventId: optionValue(args, "--root-event") ||
      (args.includes("--root-dispatch") ? process.env.AIDEVOPS_ROOT_EVENT_ID || generatedEventId : undefined),
    parentEventId: optionValue(args, "--parent-event") || undefined,
    payload: emitPayload(args),
  });
  if (envelope) {
    if (args.includes("--print-id")) process.stdout.write(`${envelope.eventId}\n`);
    else printJson(envelope);
  }
  return 0;
}

function stateCommand(args, runtime) {
  const envelope = runtime.appendProjectedState({
    state: readJsonInput(args[3]),
    subjectId: args[2],
  }, args[1] || "auto");
  if (envelope) printJson(envelope);
  return 0;
}

function queryCommand(args, runtime) {
  printJson(runtime.queryRuntimeEvents({
    correlationId: optionValue(args, "--correlation"),
    eventType: optionValue(args, "--type"),
    limit: optionValue(args, "--limit", "100"),
    subjectId: optionValue(args, "--subject"),
    workerId: optionValue(args, "--worker"),
  }));
  return 0;
}

function lineageCommand(args, runtime) {
  printJson(runtime.queryWorkerLineage(args[1], { limit: optionValue(args, "--limit", "250") }));
  return 0;
}

function verifyCommand(_args, runtime) {
  const result = runtime.verifyRuntimeEventStore();
  printJson(result);
  return result.ok ? 0 : 1;
}

const COMMANDS = Object.freeze({
  emit: emitCommand,
  lineage: lineageCommand,
  query: queryCommand,
  state: stateCommand,
  verify: verifyCommand,
});

export async function runCli(args, runtime) {
  const command = args[0] || "help";
  if (["help", "--help", "-h"].includes(command)) {
    process.stdout.write("Usage: runtime-events.mjs emit|state|query|lineage|verify [options]\n");
    return 0;
  }
  if (!runtime.initialiseRuntimeEventStore()) return commandFailureCode(command);
  const handler = COMMANDS[command];
  if (!handler) throw new TypeError(`unknown runtime-events command: ${command}`);
  return handler(args, runtime);
}
