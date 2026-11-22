// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// aidevops for Buzz Desktop (t18883).
// - Phase 0: a Settings card that shows `aidevops buzz status`.
// - Phase 1 (GH#37233): an "aidevops" agent type. Each agent runs one
//   `aidevops buzz acp` process (aidevops OpenCode over ACP, in the agent's
//   own worktree) and gets the Buzz side of each turn from the app's harness
//   kit (`ctx.agents.harness`): which messages it may act on, Buzz's prompts,
//   its Buzz tools over MCP, and its replies.
// Plugin API v1: one ES module, no imports, React from ctx.react.

export const inject = ["react", "settingsCards", "host", "agents"];

// Bump only when plugin files change; Buzz revisions are content hashes.
const PLUGIN_VERSION = "1.3.0";
const TYPE_ID = "aidevops";
/** An empty project folder means the aidevops repository registered on this
 * computer: the launcher resolves it from `repos.json`. Agents for a project
 * name that project's folder instead. */
const DEFAULT_PROJECT_LABEL = "the aidevops repository";
/** Prefilled for new agents, including drafts other agents request: the
 * standard aidevops checkout. Clearing it falls back to the registered one. */
const DEFAULT_PROJECT = "~/Git/aidevops";
/** The MCP server name each session declares; Buzz tools arrive as `buzz_*`. */
const TOOL_SERVER = "buzz";
/** Buzz tools that answer where people see it, so no fallback reply is due. */
const ANSWERS = new Set(["send", "reply_in_subthread", "edit", "react"]);
/** Covers the launcher: roster, worktree, overlay and OpenCode start-up. */
const START_TIMEOUT_MS = 180_000;
const REQUEST_TIMEOUT_MS = 60_000;
const STOP_TIMEOUT_MS = 5_000;
/** An agent's OpenCode process stops after this long without a turn. */
const IDLE_STOP_MS = 30 * 60_000;
const STDERR_LIMIT = 4_000;
const WRITTEN_LIMIT = 64_000;
const REPLY_LIMIT = 16_000;
/** Terminal colour codes in OpenCode's stderr (ESC [ … m). */
const ANSI_SGR = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, "g");
/** Never inherited by the launcher: no Buzz identity, and none of the
 * OpenCode overrides the aidevops remote-interactive launcher refuses. */
const ENV = {
  BUZZ_PRIVATE_KEY: null,
  BUZZ_AUTH_TAG: null,
  BUZZ_RELAY_URL: null,
  OPENCODE_CONFIG: null,
  OPENCODE_CONFIG_CONTENT: null,
  OPENCODE_CONFIG_DIR: null,
  OPENCODE_DISABLE_AUTOCOMPACT: null,
  OPENCODE_DISABLE_DEFAULT_PLUGINS: null,
  OPENCODE_DISABLE_PROJECT_CONFIG: null,
  OPENCODE_MODEL: null,
  OPENCODE_PURE: null,
  AIDEVOPS_REMOTE_RUNTIME_ANCHOR: null,
  AIDEVOPS_REMOTE_PROJECT_ROOT: null,
  AIDEVOPS_TEAM_INTERFACE_OVERLAY: null,
};

function errorMessage(error) {
  if (error instanceof Error) return error.message;
  if (error && typeof error === "object" && "message" in error)
    return String(error.message);
  return String(error);
}

/** The agent's settings, with defaults for anything missing or invalid. */
function settings(raw) {
  const value = raw && typeof raw === "object" ? raw : {};
  const text = (field) =>
    typeof value[field] === "string" ? value[field].trim() : "";
  return {
    member: text("member"),
    project: text("project"),
    scope: value.scope === "channel" ? "channel" : "thread",
  };
}

function projectProblem(project) {
  if (!project) return "";
  if (!project.startsWith("/") && !project.startsWith("~/"))
    return "The project folder must be a full path, or start with ~/.";
  return "";
}

function basename(path) {
  const parts = path.replace(/\/+$/, "").split("/");
  return parts[parts.length - 1] || path;
}

/** The agent's reply when it wrote one instead of calling a Buzz tool: the
 * last `<buzz-reply>` block when the aidevops runtime used one, else all. */
function replyText(written) {
  const tagged = [...written.matchAll(/<buzz-reply>([\s\S]*?)<\/buzz-reply>/g)];
  const text = tagged.length ? tagged[tagged.length - 1][1] : written;
  return text.trim().slice(0, REPLY_LIMIT);
}

/** Declines a permission prompt. The aidevops remote-interactive profile
 * already allows ordinary tools; it asks only for actions that need a person
 * at the computer (such as bounded operations), and nobody can answer here.
 * Unlike Buzz's bundled harnesses, which allow, this keeps those gates. */
function deny(params) {
  const options = Array.isArray(params?.options) ? params.options : [];
  const option = options.find((item) => item?.kind === "reject_once");
  return option && typeof option.optionId === "string"
    ? { outcome: "selected", optionId: option.optionId }
    : { outcome: "cancelled" };
}

/** One `aidevops buzz acp` process, driven over line-delimited JSON-RPC. */
class Acp {
  constructor(process, onUpdate) {
    this.process = process;
    this.onUpdate = onUpdate;
    this.calls = new Map();
    this.requests = 0;
    this.buffer = "";
    this.stderr = "";
    this.alive = true;
    this.capabilities = {};
    this.exited = process.exited.then((code) => {
      this.alive = false;
      const error = new Error(this.lastError() || `aidevops exited (${code ?? "signal"})`);
      for (const call of this.calls.values()) call.reject(error);
      this.calls.clear();
      return code;
    });
  }

  static async start(spawn, args, onUpdate) {
    // Output can arrive before the client exists; keep it until then.
    const early = { acp: undefined, out: [], errors: [] };
    const process = await spawn("acp", {
      args,
      env: ENV,
      onStdout: (data) => (early.acp ? early.acp.read(data) : early.out.push(data)),
      onStderr: (data) => (early.acp ? early.acp.readError(data) : early.errors.push(data)),
    }).catch((error) => {
      throw /os error 2|no such file|not found/i.test(errorMessage(error))
        ? new Error(
            "aidevops is not installed or not on your PATH. Install it, then run `aidevops update`.",
          )
        : error;
    });
    const acp = new Acp(process, onUpdate);
    early.acp = acp;
    for (const data of early.errors) acp.readError(data);
    for (const data of early.out) acp.read(data);
    let init;
    try {
      init = await acp.request(
        "initialize",
        {
          protocolVersion: 1,
          clientCapabilities: {},
          clientInfo: { name: "buzz-aidevops", version: "1" },
        },
        START_TIMEOUT_MS,
      );
    } catch (error) {
      await acp.stop();
      throw new Error(acp.lastError() || errorMessage(error));
    }
    acp.capabilities = init?.agentCapabilities ?? {};
    if (acp.capabilities.mcpCapabilities?.http !== true) {
      await acp.stop();
      throw new Error("This OpenCode cannot reach Buzz tools (no HTTP MCP support)");
    }
    return acp;
  }

  /** Whether `initialize` advertised `sessionCapabilities[name]`. */
  advertises(name) {
    const value = this.capabilities.sessionCapabilities?.[name];
    return typeof value === "object" && value !== null;
  }

  lastError() {
    const lines = this.stderr.trim().split("\n");
    return lines[lines.length - 1].replace(ANSI_SGR, "").trim();
  }

  request(method, params, timeout) {
    if (!this.alive) return Promise.reject(new Error("aidevops is not running"));
    const id = ++this.requests;
    const answer = new Promise((resolve, reject) => {
      let timer;
      if (timeout !== undefined)
        timer = setTimeout(() => {
          this.calls.delete(id);
          reject(new Error(`aidevops did not answer ${method} in ${Math.round(timeout / 1000)}s`));
          void this.process.kill();
        }, timeout);
      this.calls.set(id, {
        resolve: (result) => {
          clearTimeout(timer);
          resolve(result);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
    });
    this.write({ jsonrpc: "2.0", id, method, params }).catch((error) => {
      this.calls.get(id)?.reject(new Error(errorMessage(error)));
      this.calls.delete(id);
    });
    return answer;
  }

  notify(method, params) {
    void this.write({ jsonrpc: "2.0", method, params }).catch(() => undefined);
  }

  /** Stops the process; resolves once it exited or the time limit passed. */
  async stop() {
    let timer;
    await Promise.race([
      this.process
        .kill()
        .catch(() => undefined)
        .then(() => this.exited),
      new Promise((resolve) => {
        timer = setTimeout(resolve, STOP_TIMEOUT_MS);
      }),
    ]).finally(() => clearTimeout(timer));
  }

  write(message) {
    return this.process.write(`${JSON.stringify(message)}\n`);
  }

  readError(data) {
    this.stderr = (this.stderr + data).slice(-STDERR_LIMIT);
  }

  read(data) {
    this.buffer += data;
    let newline = this.buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      newline = this.buffer.indexOf("\n");
      if (!line) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }
      this.handle(message);
    }
  }

  handle(message) {
    const { id, method } = message;
    if (method === undefined) {
      const call = this.calls.get(id);
      this.calls.delete(id);
      if (message.error) call?.reject(new Error(errorMessage(message.error)));
      else call?.resolve(message.result);
      return;
    }
    if (id === undefined || id === null) {
      if (method === "session/update") this.onUpdate(message.params ?? {});
      return;
    }
    const reply =
      method === "session/request_permission"
        ? { jsonrpc: "2.0", id, result: { outcome: deny(message.params) } }
        : {
            jsonrpc: "2.0",
            id,
            error: { code: -32601, message: `Buzz does not handle ${method}` },
          };
    void this.write(reply).catch(() => undefined);
  }
}

// ---- Phase 1: aidevops agent runtime ----------------------------------------

function newRuntime(key) {
  return {
    key,
    launch: "",
    acp: undefined,
    server: undefined,
    sessions: new Map(),
    byId: new Map(),
    active: undefined,
    handle: undefined,
    queue: Promise.resolve(),
    idle: undefined,
  };
}

function forgetSessions(runtime) {
  runtime.sessions.clear();
  runtime.byId.clear();
}

function scheduleIdleStop(runtime) {
  clearTimeout(runtime.idle);
  runtime.idle = setTimeout(() => {
    const acp = runtime.acp;
    if (!acp || runtime.active) return;
    runtime.acp = undefined;
    forgetSessions(runtime);
    void acp.stop();
  }, IDLE_STOP_MS);
}

/** Keeps the text the agent writes until it calls a Buzz tool that answers. */
function keepText(session, text) {
  if (session.acted || typeof text !== "string") return;
  session.written = (session.written + text).slice(0, WRITTEN_LIMIT);
}

/** Shows the running turn's progress as Buzz steps. */
function showStep(session, kind, update) {
  const step = session.delivery?.step;
  if (!step) return;
  if (kind === "tool_call" && typeof update.title === "string") {
    step(update.title.slice(0, 80));
  } else if (kind === "agent_message_chunk" && session.lastStep !== "reply") {
    session.lastStep = "reply";
    step("Writing reply");
  }
}

/** Records one ACP `session/update`. */
function recordUpdate(runtime, params) {
  const session = runtime.byId.get(String(params.sessionId));
  const update = params.update;
  if (!session || !update || typeof update !== "object") return;
  session.updates += 1;
  const kind = update.sessionUpdate;
  if (kind === "agent_message_chunk") keepText(session, update.content?.text);
  if (runtime.active === session) showStep(session, kind, update);
}

/** Whether a Buzz tools call answered where people see it. */
function answeredPeople(message, answer) {
  if (message.method !== "tools/call") return false;
  if (!ANSWERS.has(String(message.params?.name))) return false;
  return !answer?.error && !answer?.result?.isError;
}

function resetTurn(session) {
  session.acted = false;
  session.written = "";
  session.updates = 0;
  session.lastStep = "";
}

/** Asks OpenCode to stop the agent's running turn for this delivery. */
function interrupt(runtime, control) {
  control.stopped = true;
  const session = control.session;
  if (session && runtime.active === session)
    runtime.acp?.notify("session/cancel", { sessionId: session.id });
}

/** Runs aidevops agents: one runtime per agent (membership key) with its
 * process, its one shared Buzz tools server and its sessions, one per
 * conversation. A job is one delivery: `{ delivery, conversation, config,
 * control }`. */
class Runner {
  constructor(host, kit) {
    this.host = host;
    this.kit = kit;
    this.runtimes = new Map();
  }

  runtimeFor(key) {
    if (!this.runtimes.has(key)) this.runtimes.set(key, newRuntime(key));
    return this.runtimes.get(key);
  }

  /** Reads a file the agent's Buzz tools send or upload (attachments, a
   * profile picture): absolute, `~/…`, or relative to its project folder, as
   * Buzz's bundled agent types read relative to their workspace. */
  read(project, path) {
    if (!this.host.readFile) throw new Error("aidevops agents run only in the desktop app");
    return this.host.readFile(path, { cwd: project || DEFAULT_PROJECT });
  }

  /** Answers one Buzz tools MCP message. OpenCode registers MCP servers per
   * directory, so every session of the process shares this server: a call
   * goes to the session OpenCode names (`ai.opencode/sessionID`, OpenCode
   * 2.x) or else to the one turn the agent is running (turns run one at a
   * time per agent). */
  async answerMcp(runtime, message) {
    const { id, params } = message ?? {};
    if (id === undefined || id === null) return undefined;
    const named = params?._meta?.["ai.opencode/sessionID"];
    const session = (typeof named === "string" && runtime.byId.get(named)) || runtime.active;
    const handle = session?.handle ?? runtime.handle;
    if (!handle)
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32603, message: "This aidevops agent has not started a turn" },
      };
    const answer = await this.kit.tools(handle, session?.conversation, {
      read: (path) => this.read(runtime.project, path),
    })(message);
    if (session && answeredPeople(message, answer)) session.acted = true;
    return answer;
  }

  async ensureServer(runtime) {
    if (runtime.server) return runtime.server;
    if (!this.host.serveMcp) throw new Error("aidevops agents run only in the desktop app");
    const server = await this.host.serveMcp((message) => this.answerMcp(runtime, message), {
      sharedSession: true,
    });
    runtime.server = server;
    void server.closed.then(() => {
      if (runtime.server !== server) return;
      runtime.server = undefined;
      forgetSessions(runtime);
    });
    return server;
  }

  async ensureAcp(runtime, config) {
    const launch = JSON.stringify([config.member, config.project]);
    if (runtime.acp?.alive && runtime.launch === launch) return runtime.acp;
    if (runtime.acp) await runtime.acp.stop();
    forgetSessions(runtime);
    runtime.acp = undefined;
    if (!this.host.spawn) throw new Error("aidevops agents run only in the desktop app");
    const acp = await Acp.start(
      this.host.spawn.bind(this.host),
      ["--member", config.member, ...(config.project ? ["--project", config.project] : [])],
      (params) => recordUpdate(runtime, params),
    );
    runtime.acp = acp;
    runtime.launch = launch;
    runtime.project = config.project;
    void acp.exited.then(() => {
      if (runtime.acp !== acp) return;
      runtime.acp = undefined;
      forgetSessions(runtime);
    });
    return acp;
  }

  async openSession(runtime, acp, job) {
    const { delivery, conversation, config } = job;
    const server = await this.ensureServer(runtime);
    const system = await this.kit.systemPrompt(delivery, {
      scope: config.scope,
      cwd: config.project || DEFAULT_PROJECT_LABEL,
      instructions: "",
    });
    const standard = !!system && acp.advertises("systemPrompt");
    const opened = await acp.request(
      "session/new",
      {
        // The launcher's proxy replaces this with the agent's worktree.
        cwd: config.project,
        mcpServers: [
          { type: "http", name: TOOL_SERVER, url: server.url, headers: server.headers },
        ],
        ...(standard
          ? { systemPrompt: { mode: "append", content: [{ type: "text", text: system }] } }
          : {}),
      },
      REQUEST_TIMEOUT_MS,
    );
    const session = {
      id: String(opened?.sessionId ?? ""),
      key: conversation.key,
      cursor: undefined,
      // Without the standard field, Buzz's system prompt leads the first turn.
      lead: standard ? "" : system,
      acted: false,
      written: "",
      updates: 0,
      lastStep: "",
      conversation,
      handle: delivery.agent,
      delivery,
    };
    if (!session.id) throw new Error("aidevops opened no session");
    runtime.sessions.set(conversation.key, session);
    runtime.byId.set(session.id, session);
    return session;
  }

  /** The agent's session for this conversation, opened when it has none. */
  async sessionFor(runtime, job) {
    const acp = await this.ensureAcp(runtime, job.config);
    const session =
      runtime.sessions.get(job.conversation.key) ?? (await this.openSession(runtime, acp, job));
    session.conversation = job.conversation;
    session.handle = job.delivery.agent;
    session.delivery = job.delivery;
    return { acp, session };
  }

  /** Runs one turn; the runtime's queue makes it the agent's only turn. */
  async turn(runtime, job) {
    const { delivery, conversation, control } = job;
    clearTimeout(runtime.idle);
    if (delivery.current?.() === false || control.stopped)
      return { ok: true, stopped: control.stopped };
    runtime.handle = delivery.agent;
    const { acp, session } = await this.sessionFor(runtime, job);
    const prompt = await this.kit.turnPrompt(
      delivery,
      conversation,
      session.cursor ? { cursor: session.cursor } : undefined,
    );
    if (control.stopped) {
      prompt.restore();
      return { ok: true, stopped: true };
    }
    resetTurn(session);
    runtime.active = session;
    control.session = session;
    const lead = session.lead;
    let answer;
    try {
      delivery.acknowledged?.();
      answer = await acp.request("session/prompt", {
        sessionId: session.id,
        prompt: [{ type: "text", text: lead ? `${lead}\n\n${prompt.text}` : prompt.text }],
      });
    } catch (error) {
      // Nothing reached the model: keep plugins' notes for the next turn.
      if (!session.updates) prompt.restore();
      throw error;
    } finally {
      if (runtime.active === session) runtime.active = undefined;
      control.session = undefined;
    }
    session.lead = "";
    session.cursor = prompt.cursor;
    return this.finish(job, session, answer);
  }

  /** The turn's result once OpenCode answered `session/prompt`; posts the
   * agent's written reply when it did not answer with a Buzz tool. */
  async finish(job, session, answer) {
    if (answer?.stopReason === "cancelled") return { ok: true, stopped: true };
    const text = replyText(session.written);
    if (!session.acted && text) await this.kit.reply(job.delivery.agent, job.conversation, text);
    if (answer?.stopReason === "refusal")
      return { ok: false, error: "The model refused the request" };
    return { ok: true };
  }

  async fail(job, error) {
    const message = errorMessage(error);
    await this.kit
      .reply(job.delivery.agent, job.conversation, `I couldn't finish that: ${message}`, {
        notifyOwner: true,
      })
      .catch(() => undefined);
    return { ok: false, error: message };
  }

  async run(delivery) {
    const config = settings(delivery.config);
    const conversation = await this.kit.conversation(delivery, config.scope);
    if (!conversation) {
      delivery.ignored?.();
      return;
    }
    const agent = delivery.agent;
    const job = {
      delivery,
      conversation,
      config: { ...config, member: config.member || agent.name },
      control: { stopped: false, session: undefined },
    };
    const runtime = this.runtimeFor(agent.key);
    const problem = projectProblem(job.config.project);
    const work = runtime.queue.then(() => {
      if (problem) throw new Error(problem);
      return this.turn(runtime, job);
    });
    const done = work.catch((error) => this.fail(job, error));
    runtime.queue = done.then(
      () => scheduleIdleStop(runtime),
      () => scheduleIdleStop(runtime),
    );
    delivery.workingUntil(done);
    delivery.interruptible?.(async () => interrupt(runtime, job.control));
  }
}

// ---- Settings UI ------------------------------------------------------------

const fieldStyle = { display: "grid", gap: "var(--space-1, 4px)" };
const hintStyle = { color: "var(--text-secondary)", margin: 0 };
const labelStyle = { fontWeight: 600 };
// Buzz resets form controls, so bare inputs render as plain text; give them a
// visible box using Buzz's own tokens.
const inputStyle = {
  width: "100%",
  boxSizing: "border-box",
  minHeight: "44px",
  padding: "10px 16px",
  border: "1px solid var(--border-prominent, var(--border-standard, #555))",
  borderRadius: "var(--radius-control, 8px)",
  background: "var(--surface-inset, transparent)",
  color: "var(--text-standard, inherit)",
  font: "inherit",
};
// macOS draws a native select that ignores padding and height, so drop the
// native look and draw our own chevron over it.
const selectStyle = {
  ...inputStyle,
  appearance: "none",
  WebkitAppearance: "none",
  paddingRight: "40px",
  cursor: "pointer",
};
/* Drawn with borders so its size does not depend on font glyphs. */
const chevronStyle = {
  position: "absolute",
  right: "18px",
  top: "50%",
  width: "9px",
  height: "9px",
  borderRight: "2px solid var(--text-secondary)",
  borderBottom: "2px solid var(--text-secondary)",
  transform: "translateY(-75%) rotate(45deg)",
  pointerEvents: "none",
};

/** A select styled like the text fields. */
function select(h, props, ...options) {
  return h(
    "span",
    { style: { position: "relative", display: "block" } },
    h("select", { ...props, style: selectStyle }, ...options),
    h("span", { "aria-hidden": "true", style: chevronStyle }),
  );
}

function newerDeployedVersion(text) {
  const match = /^Buzz plugin deployed: (\d+)\.(\d+)\.(\d+)$/m.exec(text);
  if (!match) return null;
  const deployed = match.slice(1).map(Number);
  const loaded = PLUGIN_VERSION.split(".").map(Number);
  for (let i = 0; i < loaded.length; i += 1) {
    if (deployed[i] !== loaded[i]) return deployed[i] > loaded[i] ? match.slice(1).join(".") : null;
  }
  return null;
}

function statusBody(h, state) {
  if (state.status === "loading") return h("p", null, "Reading aidevops status…");
  if (state.status === "failed")
    return h(
      "div",
      { role: "alert" },
      h("p", null, "Could not read aidevops status."),
      h(
        "p",
        { style: { color: "var(--text-secondary)" } },
        state.detail ||
          "Check that `aidevops` is installed and on your login shell PATH, then run `aidevops buzz status` in a terminal. The command must finish within 5 seconds.",
      ),
    );
  const newer = newerDeployedVersion(state.text);
  return h(
    "div",
    null,
    newer
      ? h(
          "p",
          { role: "status" },
          `A newer aidevops plugin (${newer}) is ready. Open Settings → Plugins → Manage plugins → aidevops and press Update.`,
        )
      : null,
    h(
      "pre",
      {
        style: {
          whiteSpace: "pre-wrap",
          overflowWrap: "anywhere",
          margin: 0,
          fontFamily: "var(--font-mono, monospace)",
        },
      },
      state.text || "(no output)",
    ),
    h(
      "p",
      { style: { color: "var(--text-secondary)" } },
      `Checked ${state.at.toLocaleTimeString()}`,
    ),
  );
}

/** The agent's settings fields; used when creating it and in its tab. */
function fields(h, { value, onChange, disabled, agentName }) {
  const set = (field) => (event) => onChange({ ...value, [field]: event.target.value });
  return h(
    "div",
    { style: { display: "grid", gap: "var(--space-3, 12px)" } },
    h(
      "label",
      { style: fieldStyle },
      h("span", { style: labelStyle }, "Project folder"),
      h("input", {
        type: "text",
        style: inputStyle,
        value: value.project ?? "",
        placeholder: `Empty: ${DEFAULT_PROJECT_LABEL}`,
        disabled,
        spellCheck: false,
        onChange: set("project"),
      }),
      h(
        "p",
        { style: hintStyle },
        `aidevops main agents use ${DEFAULT_PROJECT} (empty means ${DEFAULT_PROJECT_LABEL} registered on this computer). An agent for a project uses that project's folder in your Git folder: a full path, or one starting with ~/. It must be a repository registered with aidevops; the agent works in its own linked worktree of it, never in the folder itself.`,
      ),
    ),
    h(
      "label",
      { style: fieldStyle },
      h("span", { style: labelStyle }, "aidevops agent"),
      h("input", {
        type: "text",
        style: inputStyle,
        value: value.member ?? "",
        placeholder: "e.g. aidevops-<this computer>",
        disabled,
        spellCheck: false,
        onChange: set("member"),
      }),
      h(
        "p",
        { style: hintStyle },
        `Which aidevops agent runs, named for this computer, such as aidevops-marcus-macbook-pro-01 or build-plus-marcus-macbook-pro-01. Leave empty to use this Buzz agent's name${agentName ? ` (${agentName})` : ""}, which only works when it matches an aidevops agent.`,
      ),
    ),
    h(
      "label",
      { style: fieldStyle },
      h("span", { style: labelStyle }, "Conversation"),
      select(
        h,
        {
          value: value.scope === "channel" ? "channel" : "thread",
          disabled,
          onChange: set("scope"),
        },
        h("option", { value: "thread" }, "Each thread is its own session"),
        h("option", { value: "channel" }, "One session per channel"),
      ),
    ),
  );
}

/** The settings tab's save button and its outcome. */
function saveRow(h, state, store) {
  const saving = state.status === "saving";
  let note = null;
  if (state.status === "saved")
    note = h("span", { style: hintStyle }, " Saved. The next message starts a fresh aidevops process.");
  else if (state.status === "failed") note = h("span", { role: "alert" }, ` ${state.detail}`);
  return h(
    "div",
    null,
    h("button", { type: "button", disabled: saving, onClick: store }, saving ? "Saving…" : "Save"),
    note,
  );
}

/** Runs the declared status command; null means it failed or was refused. */
async function readStatus(host) {
  const output = await host.runCommand("buzz-status");
  return typeof output === "string" ? output.trim() : null;
}

/** Phase 0: the Settings card with this computer's `aidevops buzz status`. */
function StatusCard({ React, host }) {
  const h = React.createElement;
  const [state, setState] = React.useState({ status: "loading" });

  const refresh = React.useCallback(() => {
    let current = true;
    setState({ status: "loading" });
    readStatus(host).then(
      (text) => {
        if (!current) return;
        setState(text === null ? { status: "failed" } : { status: "ready", text, at: new Date() });
      },
      (error) => {
        if (current) setState({ status: "failed", detail: errorMessage(error) });
      },
    );
    return () => {
      current = false;
    };
  }, [host]);

  React.useEffect(() => refresh(), [refresh]);

  return h(
    "section",
    {
      className: "ui-card",
      style: {
        padding: "var(--space-panel-inset)",
        display: "grid",
        gap: "var(--space-2)",
        width: "100%",
      },
    },
    h("h2", null, "Buzz setup on this computer"),
    h("p", { style: hintStyle }, `aidevops plugin ${PLUGIN_VERSION}`),
    statusBody(h, state),
    h(
      "div",
      null,
      h(
        "button",
        {
          type: "button",
          disabled: state.status === "loading",
          onClick: () => refresh(),
        },
        "Refresh",
      ),
    ),
  );
}

/** The aidevops tab in an aidevops agent's settings. */
function SettingsTab({ React, agent, save }) {
  const h = React.createElement;
  const [draft, setDraft] = React.useState(agent.config ?? {});
  const [state, setState] = React.useState({ status: "idle" });
  React.useEffect(() => setDraft(agent.config ?? {}), [agent.config]);
  const problem = projectProblem(settings(draft).project);
  const store = () => {
    setState({ status: "saving" });
    save({ ...agent.config, ...draft }).then(
      () => setState({ status: "saved" }),
      (error) => setState({ status: "failed", detail: errorMessage(error) }),
    );
  };
  return h(
    "section",
    { style: { display: "grid", gap: "var(--space-3, 12px)" } },
    fields(h, {
      value: draft,
      onChange: setDraft,
      disabled: state.status === "saving",
      agentName: agent.name,
    }),
    problem ? h("p", { role: "alert", style: hintStyle }, problem) : null,
    saveRow(h, state, store),
  );
}

function summary(agent) {
  const config = settings(agent.config);
  return `aidevops · ${config.project ? basename(config.project) : "aidevops"}`;
}

export function apply(ctx) {
  const React = ctx.react;
  const h = React.createElement;
  const host = ctx.host;

  // ---- Phase 0: Settings status card --------------------------------------

  ctx.settingsCards.register({
    id: "status",
    title: "aidevops",
    component: (props) => h(StatusCard, { ...props, React, host }),
  });

  // ---- Phase 1: aidevops agent type ---------------------------------------

  const runner = new Runner(host, ctx.agents.harness);

  ctx.agents.register({
    id: TYPE_ID,
    title: "aidevops",
    description:
      "aidevops agents in OpenCode on this computer, each in its own worktree of a registered project.",
    defaults: () => ({ config: { member: "", project: DEFAULT_PROJECT, scope: "thread" } }),
    summary,
    Create: ({ config, onChange, disabled }) =>
      fields(h, { value: config ?? {}, onChange, disabled }),
    tabs: [
      {
        id: "aidevops",
        title: "aidevops",
        role: "settings",
        component: (props) => h(SettingsTab, { ...props, React }),
      },
    ],
    timeoutMs: 30 * 60_000,
    run: (delivery) => runner.run(delivery),
    // Reads outside turns, as for an approved external connection's tools.
    readFile: async (agent, path, signal) => {
      signal.throwIfAborted();
      return runner.read(settings(agent.config).project, path);
    },
  });
}
