#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

import { lstatSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const TASK_ID = /^(?:t[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17}){0,8}|to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(?:\.[1-9][0-9]{0,17}){0,8})$/;
const TARGET_CHECKBOX = new Map([
  ["task.available", " "],
  ["task.claimed", null],
  ["task.completed", "x"],
  ["task.metadata_changed", null],
  ["task.reconcile_requested", null],
]);

function option(args, name) {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : "";
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function projectTransition(source, transition) {
  const taskId = transition?.taskId;
  const transitionKind = transition?.kind;
  if (!TASK_ID.test(taskId)) throw new TypeError("task_id is not canonical");
  if (!TARGET_CHECKBOX.has(transitionKind)) throw new TypeError("unsupported task projection transition");
  const matcher = new RegExp(`^([ \\t]*-[ \\t]+\\[)([ xX])(\\][ \\t]+${escapeRegExp(taskId)})(?=[ \\t]|$)`, "gm");
  const matches = [...source.matchAll(matcher)];
  if (matches.length !== 1) throw new Error(`expected exactly one TODO projection for ${taskId}; found ${matches.length}`);
  const target = TARGET_CHECKBOX.get(transitionKind);
  if (target === null || matches[0][2].toLowerCase() === target) return source;
  return source.replace(matcher, (_line, prefix, _checkbox, suffix) => `${prefix}${target}${suffix}`);
}

export function reduceTodoTransitions({ repositoryPath, transitions }) {
  if (typeof repositoryPath !== "string" || !repositoryPath.startsWith("/") || repositoryPath.includes("\0")) throw new TypeError("repository_path must be absolute");
  if (!Array.isArray(transitions) || transitions.length < 1 || transitions.length > 1000) throw new TypeError("transitions must contain 1..1000 entries");
  const todoPath = resolve(repositoryPath, "TODO.md");
  const metadata = lstatSync(todoPath);
  if (!metadata.isFile() || metadata.isSymbolicLink()) throw new TypeError("TODO.md must be a regular file");
  const source = readFileSync(todoPath, "utf8");
  const projected = transitions.reduce(projectTransition, source);
  if (projected !== source) writeFileSync(todoPath, projected, "utf8");
  return { changed: projected !== source, transitionCount: transitions.length };
}

export function run(args = process.argv.slice(2)) {
  const transitions = JSON.parse(readFileSync(0, "utf8"));
  const result = reduceTodoTransitions({
    repositoryPath: option(args, "--repository-path"),
    transitions,
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try { process.exitCode = run(); } catch (error) { process.stderr.write(`task-projection-reducer: ${error.message}\n`); process.exitCode = 1; }
}
