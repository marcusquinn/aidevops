// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

import {
  boundedInteger,
  canTerminate,
  commandError,
  scalar,
  withinRoot,
} from "./bounded-operation-values.mjs";
import {
  appendCapture,
  disposeOperations,
  observeProgress,
  operationReceipt,
  signalSupervisor,
  trimTerminalOperations,
} from "./bounded-operation-runtime.mjs";
import {
  cancelOperation,
  operationOutput,
  operationStatus,
} from "./bounded-operation-access.mjs";
import { resolveSessionOwnedWorktreeRoot } from "./gpt-image-worktree.mjs";

const MAX_OPERATIONS = 24;
const SUPERVISOR_PATH = fileURLToPath(new URL("./bounded-operation-supervisor.mjs", import.meta.url));
const SUPERVISOR_RUNTIME = "node";

export class BoundedInteractiveOperationManager {
  constructor(options = {}) {
    this.projectRoot = realpathSync(options.projectRoot || process.cwd());
    this.scriptsDir = options.scriptsDir;
    this.worktreeResolver = options.resolveWorktreeRoot || resolveSessionOwnedWorktreeRoot;
    this.spawn = options.spawn || spawn;
    this.now = options.now || Date.now;
    this.makeID = options.makeID || (() => `op_${this.now()}_${randomBytes(6).toString("hex")}`);
    this.recordOutput = options.recordOutput || (async () => "");
    this.readOutput = options.readOutput || (async () => {
      throw new Error("stored output retrieval is unavailable");
    });
    this.kill = options.kill || signalSupervisor;
    this.killGraceMs = options.killGraceMs ?? 500;
    this.setTimer = options.setTimer || setTimeout;
    this.clearTimer = options.clearTimer || clearTimeout;
    this.supervisorRuntime = options.supervisorRuntime || SUPERVISOR_RUNTIME;
    this.operations = new Map();
  }

  async resolveCwd(requested, context) {
    const cwd = realpathSync(requested || this.projectRoot);
    if (withinRoot(cwd, this.projectRoot)) return cwd;
    const resolved = await this.worktreeResolver(cwd, this.projectRoot, context, {
      allowStartupRoot: true,
      scriptsDir: this.scriptsDir,
      subject: "Operation",
    });
    return resolved.root;
  }

  trimTerminalOperations() {
    trimTerminalOperations(this.operations, MAX_OPERATIONS);
  }

  attachOutput(operation, child) {
    for (const stream of [child.stdout, child.stderr]) {
      stream?.on("data", (chunk) => {
        appendCapture(operation, chunk);
        if (observeProgress(operation, chunk, this.now)) this.notifyStatusWaiters(operation);
      });
    }
  }

  statusVersion(operation) {
    return `${operation.state}:${operation.restorationState}:${operation.progressEvents}`;
  }

  notifyStatusWaiters(operation) {
    const version = this.statusVersion(operation);
    for (const waiter of operation.statusWaiters) {
      if (waiter.version === version) continue;
      waiter.finish();
    }
  }

  clearStatusWaiters(operation) {
    for (const waiter of operation.statusWaiters) waiter.finish();
  }

  spawnOwned(operation, command, stage) {
    const childBudgetMs = command === operation.command ? operation.budgetMs : operation.restorationBudgetMs;
    const child = this.spawn(this.supervisorRuntime, [SUPERVISOR_PATH], {
      cwd: operation.cwd,
      detached: true,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe", "ipc"],
    });
    child.on("message", (message) => {
      if (message?.type !== "aidevops.operation" || message.event !== "command_started"
        || message.operationID !== operation.id) return;
      if (stage === "main") {
        operation.commandStarted = true;
        operation.supervisorRuntime = scalar(message.runtime);
      } else {
        operation.restorationCommandStarted = true;
      }
    });
    child.stdin.end(JSON.stringify({
      budgetMs: childBudgetMs,
      command,
      killGraceMs: this.killGraceMs,
      operationID: operation.id,
    }));
    this.attachOutput(operation, child);
    return child;
  }

  async start(args, context = {}) {
    const owner = scalar(context.sessionID);
    if (!owner) throw new Error("runtime session identity is required");
    const invalid = commandError(args.command) || (args.restorationCommand ? commandError(args.restorationCommand) : "");
    if (invalid) throw new Error(invalid);
    this.trimTerminalOperations();

    const startedAt = this.now();
    const operation = {
      id: this.makeID(),
      owner,
      cwd: await this.resolveCwd(args.cwd, context),
      command: [...args.command],
      restorationCommand: args.restorationCommand ? [...args.restorationCommand] : null,
      budgetMs: boundedInteger(args.budgetMs, 15 * 60 * 1000, 10, 24 * 60 * 60 * 1000),
      progressIntervalMs: boundedInteger(args.progressIntervalMs, 15 * 60 * 1000, 10, 60 * 60 * 1000),
      restorationBudgetMs: boundedInteger(args.restorationBudgetMs, 60 * 1000, 10, 10 * 60 * 1000),
      startedAt,
      state: "starting",
      disposition: "running",
      processExit: null,
      processSignal: "",
      commandStarted: false,
      supervisorRuntime: "",
      restorationState: args.restorationCommand ? "pending" : "not_required",
      restorationExit: null,
      restorationCommandStarted: false,
      lastMeaningfulProgressAt: null,
      progressEvents: 0,
      progressRemainder: "",
      output: [],
      outputBytes: 0,
      outputTruncated: false,
      outputID: "",
      ownerDeleted: false,
      child: null,
      childExited: false,
      restorationChild: null,
      restorationChildExited: false,
      restorationTimer: null,
      budgetTimer: null,
      killTimer: null,
      statusWaiters: new Set(),
    };
    this.operations.set(operation.id, operation);

    await new Promise((resolve) => {
      const child = this.spawnOwned(operation, operation.command, "main");
      operation.child = child;
      child.once("exit", () => { operation.childExited = true; });
      child.once("spawn", () => {
        operation.state = "running";
        this.notifyStatusWaiters(operation);
        operation.budgetTimer = this.setTimer(() => this.requestTermination(operation, "timed_out"), operation.budgetMs);
        resolve();
      });
      child.once("error", async () => {
        operation.spawnFailed = true;
        operation.disposition = "failed";
        operation.child = null;
        if (operation.restorationCommand) await this.runRestoration(operation);
        await this.finalize(operation);
        resolve();
      });
      child.once("close", (code, signal) => {
        if (!operation.spawnFailed) this.mainClosed(operation, code, signal);
      });
    });
    return this.receipt(operation);
  }

  requestTermination(operation, disposition) {
    if (!canTerminate(operation)) return false;
    operation.disposition = disposition;
    operation.state = disposition === "cancelled" ? "cancelling" : "timing_out";
    this.notifyStatusWaiters(operation);
    operation.processSignal = "SIGTERM";
    const signalled = this.kill(operation.child, "SIGTERM");
    return signalled;
  }

  async mainClosed(operation, code, signal) {
    if (operation.budgetTimer) this.clearTimer(operation.budgetTimer);
    if (operation.killTimer) this.clearTimer(operation.killTimer);
    operation.child = null;
    operation.processExit = Number.isInteger(code) ? code : null;
    operation.processSignal = scalar(signal);
    if (operation.disposition === "running") {
      operation.disposition = code === 0 && operation.commandStarted ? "succeeded" : "failed";
    }
    if (operation.restorationCommand) await this.runRestoration(operation);
    await this.finalize(operation);
  }

  async runRestoration(operation) {
    operation.state = "restoring";
    operation.restorationState = "running";
    this.notifyStatusWaiters(operation);
    await new Promise((resolve) => {
      let settled = false;
      const finish = (state, code = null) => {
        if (settled) return;
        settled = true;
        if (operation.restorationTimer) this.clearTimer(operation.restorationTimer);
        operation.restorationChild = null;
        operation.restorationExit = Number.isInteger(code) ? code : null;
        operation.restorationState = state;
        this.notifyStatusWaiters(operation);
        resolve();
      };
      const child = this.spawnOwned(operation, operation.restorationCommand, "restoration");
      operation.restorationChild = child;
      operation.restorationChildExited = false;
      child.once("exit", () => { operation.restorationChildExited = true; });
      operation.restorationTimer = this.setTimer(() => {
        operation.restorationState = "timing_out";
        this.notifyStatusWaiters(operation);
        if (!operation.restorationChildExited && child.exitCode === null && child.signalCode === null) {
          this.kill(child, "SIGTERM");
        }
      }, operation.restorationBudgetMs);
      child.once("error", () => finish("failed"));
      child.once("close", (code, signal) => {
        const timedOut = operation.restorationState === "timing_out";
        finish(timedOut ? "timed_out" : (code === 0 && operation.restorationCommandStarted ? "succeeded" : "failed"), code);
      });
    });
  }

  async finalize(operation) {
    const finalState = !["not_required", "succeeded"].includes(operation.restorationState)
      && operation.disposition === "succeeded"
      ? "restoration_failed"
      : operation.disposition;
    operation.state = "finalizing";
    this.notifyStatusWaiters(operation);
    try {
      operation.outputID = await this.recordOutput(Buffer.concat(operation.output), {
        exitCode: operation.processExit,
        state: finalState,
      });
    } catch {
      operation.outputID = "";
    }
    operation.output = [];
    operation.state = finalState;
    this.notifyStatusWaiters(operation);
    if (operation.ownerDeleted) this.operations.delete(operation.id);
  }

  ownedOperation(id, context = {}) {
    const operation = this.operations.get(scalar(id));
    if (!operation) throw new Error("operation is unavailable or belongs to an expired generation");
    if (!scalar(context.sessionID) || operation.owner !== scalar(context.sessionID)) {
      throw new Error("operation owner mismatch");
    }
    return operation;
  }

  status(id, context = {}, requested = {}) {
    return operationStatus(this, id, context, requested);
  }

  async output(id, context = {}, requested = {}) {
    return operationOutput(this, id, context, requested);
  }

  cancel(id, context = {}) {
    return cancelOperation(this, id, context);
  }

  handleEvent(input) {
    const event = input?.event || input;
    if (event?.type !== "session.deleted") return;
    const owner = scalar(event.properties?.info?.id || event.properties?.sessionID);
    if (!owner) return;
    for (const operation of this.operations.values()) {
      if (operation.owner !== owner) continue;
      operation.ownerDeleted = true;
      this.requestTermination(operation, "cancelled");
      if (!operation.child && !operation.restorationChild) this.operations.delete(operation.id);
    }
  }

  receipt(operation) {
    return operationReceipt(operation, this.now());
  }

  dispose() {
    for (const operation of this.operations.values()) this.clearStatusWaiters(operation);
    disposeOperations(this.operations, this.kill, this.clearTimer);
    this.recordOutput.dispose?.();
    this.readOutput.dispose?.();
  }
}
