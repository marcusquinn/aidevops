// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { join } from "node:path";
import { hasBoundedReadTarget, isWithin } from "./permission-broker-read-target.mjs";
import { resolveReal } from "./permission-broker-read-only-root.mjs";
import { isManagedToolOutputRead } from "./permission-broker-tool-output.mjs";

// OpenCode may ask for a parent wildcard. Require a recorded concrete target;
// never infer it from a broad /dev/* ask or untrusted request metadata.
const RUNTIME_DEVICE = /^\/dev\/(?:null|stdin|stdout|stderr|fd\/[0-9]+|u?random)$/;
const DEVICE_DIAGNOSTIC = /^\/dev\/(?:null|stdin|stdout|stderr|fd\/[0-9]+|u?random|tty[0-9]*|[shv]d[a-z][0-9]*|nvme[0-9]+n[0-9]+(?:p[0-9]+)?)$/;

// Paths only, from the recorded call, never request metadata or command text in
// the persisted capture. Unknown names/expansions are omitted rather than guessed.
export function recordedDeviceTargets(call) {
  const candidates = call?.tool === "bash"
    ? String(call.command || "").match(/\/dev\/[A-Za-z0-9_./-]+/g) || []
    : [call?.target];
  return [...new Set(candidates.filter((target) => DEVICE_DIAGNOSTIC.test(target)))].slice(0, 20);
}

// A small, fail-closed shell grammar: plain words, literal device paths,
// redirects and pipelines/AND/OR lists only. No expansion, quoting, grouping,
// arbitrary paths or unsupported redirect operators. Bash authorization remains
// independent; this only resolves the device directory ask.
export function runtimeRedirectionTargets(command) {
  if (typeof command !== "string" || command.length > 10000 || /[\r\n\u0000]/.test(command)) return [];
  const token = /\s+|[0-9]*>&[0-9]+|[0-9]*(?:>>|>|<)|\|\||&&|\||(?:\/dev\/[A-Za-z0-9_./-]+|[A-Za-z0-9_.-]+)(?=$|[\s<>|&])/gy;
  const tokens = [];
  let offset = 0;
  while (offset < command.length) {
    token.lastIndex = offset;
    const match = token.exec(command);
    if (!match) return [];
    offset = token.lastIndex;
    if (!/^\s+$/.test(match[0])) tokens.push(match[0]);
  }
  const targets = [];
  let executable = "";
  for (let i = 0; i < tokens.length; i++) {
    const value = tokens[i];
    if (["|", "&&", "||"].includes(value)) {
      if (!executable) return [];
      executable = "";
    } else if (/^[0-9]*>&[0-9]+$/.test(value)) {
      // Descriptor duplication opens no path.
    } else if (/^[0-9]*(?:>>|>|<)$/.test(value)) {
      const target = tokens[++i];
      if (!RUNTIME_DEVICE.test(target || "")) return [];
      if (!value.endsWith("<") && target !== "/dev/null") return [];
      targets.push(target);
    } else if (value.startsWith("/dev/")) {
      // Only known read-only utilities may take a device as a file operand.
      if (!["cat", "head", "tail", "od"].includes(executable) || !RUNTIME_DEVICE.test(value)) return [];
      targets.push(value);
    } else if (!executable) {
      executable = value;
    }
  }
  return executable ? [...new Set(targets)] : [];
}

function isManagedTempRead(context, target, forbidden) {
  const root = join(context.home, ".aidevops", ".agent-workspace", "tmp");
  // A link in the managed root itself must not redefine the authorized root.
  const realRoot = join(resolveReal(context.home), ".aidevops", ".agent-workspace", "tmp");
  if (!isWithin(root, target) || resolveReal(root) !== realRoot) return false;
  const realTarget = resolveReal(target);
  if (!realTarget || forbidden.test(realTarget)) return false;
  return isWithin(realRoot, realTarget);
}

export function isWorkerRuntimeRead(context, raw, forbidden) {
  if ((raw?.permission || raw?.type) !== "external_directory") return false;
  const call = context.toolCalls.get(raw?.tool?.callID || raw?.callID || "");
  if (call?.tool === "bash") {
    const targets = runtimeRedirectionTargets(call.command);
    const source = raw?.patterns ?? raw?.pattern ?? [];
    const patterns = Array.isArray(source) ? source : [source];
    return targets.length > 0 && patterns.length > 0 && patterns.every((pattern) =>
      targets.some((target) => hasBoundedReadTarget({ patterns: [pattern] }, target, forbidden)));
  }
  const target = call?.tool === "read" ? call.target : "";
  if (!hasBoundedReadTarget(raw, target, forbidden)) return false;
  if (RUNTIME_DEVICE.test(target)) return true;
  return call.tool === "read" && isManagedTempRead(context, target, forbidden);
}

// Reads allowed without a post-allow audit record.
export function isUnauditedRuntimeRead(context, raw, forbidden) {
  return isWorkerRuntimeRead(context, raw, forbidden)
    || isManagedToolOutputRead(context.toolCalls, raw, context.dataHome);
}
