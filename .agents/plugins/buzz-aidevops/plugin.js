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

const TYPE_ID = "aidevops";
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
  if (!project) return "Set this agent's project folder in its aidevops settings tab.";
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
    let acp;
    const early = [];
    const earlyErrors = [];
    const process = await spawn("acp", {
      args,
      env: ENV,
      onStdout: (data) => (acp ? acp.read(data) : early.push(data)),
      onStderr: (data) => (acp ? acp.readError(data) : earlyErrors.push(data)),
    }).catch((error) => {
      throw /os error 2|no such file|not found/i.test(errorMessage(error))
        ? new Error(
            "aidevops is not installed or not on your PATH. Install it, then run `aidevops update`.",
          )
        : error;
    });
    acp = new Acp(process, onUpdate);
    for (const data of earlyErrors) acp.readError(data);
    for (const data of early) acp.read(data);
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
    return lines[lines.length - 1].replace(/\u001b\[[0-9;]*m/g, "").trim();
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

export function apply(ctx) {
  const React = ctx.react;
  const h = React.createElement;

  // ---- Phase 0: Settings status card --------------------------------------

  /** Runs the declared status command; null means it failed or was refused. */
  async function readStatus() {
    const output = await ctx.host.runCommand("buzz-status");
    return typeof output === "string" ? output.trim() : null;
  }

  function StatusCard() {
    const [state, setState] = React.useState({ status: "loading" });

    const refresh = React.useCallback(() => {
      let current = true;
      setState({ status: "loading" });
      readStatus().then(
        (text) => {
          if (!current) return;
          setState(
            text === null
              ? { status: "failed" }
              : { status: "ready", text, at: new Date() },
          );
        },
        (error) => {
          if (!current) return;
          setState({ status: "failed", detail: errorMessage(error) });
        },
      );
      return () => {
        current = false;
      };
    }, []);

    React.useEffect(() => refresh(), [refresh]);

    let body;
    if (state.status === "loading") {
      body = h("p", null, "Reading aidevops status…");
    } else if (state.status === "failed") {
      body = h(
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
    } else {
      body = h(
        "div",
        null,
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
      body,
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

  ctx.settingsCards.register({
    id: "status",
    title: "aidevops",
    component: StatusCard,
  });

  // ---- Phase 1: aidevops agent type ---------------------------------------

  const kit = ctx.agents.harness;
  /** One runtime per agent (membership key): its process, its one shared
   * Buzz tools server and its sessions, one per conversation. */
  const runtimes = new Map();

  function runtimeFor(key) {
    let runtime = runtimes.get(key);
    if (!runtime) {
      runtime = {
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
      runtimes.set(key, runtime);
    }
    return runtime;
  }

  function forgetSessions(runtime) {
    runtime.sessions.clear();
    runtime.byId.clear();
  }

  function onUpdate(runtime, params) {
    const session = runtime.byId.get(String(params.sessionId));
    const update = params.update;
    if (!session || !update || typeof update !== "object") return;
    session.updates += 1;
    const kind = update.sessionUpdate;
    if (kind === "agent_message_chunk" && !session.acted) {
      const text = update.content?.text;
      if (typeof text === "string")
        session.written = (session.written + text).slice(0, WRITTEN_LIMIT);
    }
    if (runtime.active !== session) return;
    const step = session.delivery?.step;
    if (!step) return;
    if (kind === "tool_call" && typeof update.title === "string")
      step(update.title.slice(0, 80));
    else if (kind === "agent_message_chunk" && session.lastStep !== "reply") {
      session.lastStep = "reply";
      step("Writing reply");
    }
  }

  /** Answers one Buzz tools MCP message. OpenCode registers MCP servers per
   * directory, so every session of the process shares this server: a call
   * goes to the session OpenCode names (`ai.opencode/sessionID`, OpenCode
   * 2.x) or else to the one turn the agent is running (turns run one at a
   * time per agent). */
  async function answerMcp(runtime, message) {
    const { id, method, params } = message ?? {};
    if (id === undefined || id === null) return undefined;
    const named = params?._meta?.["ai.opencode/sessionID"];
    const session =
      (typeof named === "string" && runtime.byId.get(named)) || runtime.active;
    const handle = session?.handle ?? runtime.handle;
    if (!handle)
      return {
        jsonrpc: "2.0",
        id,
        error: { code: -32603, message: "This aidevops agent has not started a turn" },
      };
    const answer = await kit.tools(handle, session?.conversation)(message);
    if (
      session &&
      method === "tools/call" &&
      ANSWERS.has(String(params?.name)) &&
      !answer?.error &&
      !answer?.result?.isError
    )
      session.acted = true;
    return answer;
  }

  async function ensureServer(runtime) {
    if (runtime.server) return runtime.server;
    if (!ctx.host.serveMcp) throw new Error("aidevops agents run only in the desktop app");
    const server = await ctx.host.serveMcp(
      (message) => answerMcp(runtime, message),
      { sharedSession: true },
    );
    runtime.server = server;
    void server.closed.then(() => {
      if (runtime.server !== server) return;
      runtime.server = undefined;
      forgetSessions(runtime);
    });
    return server;
  }

  async function ensureAcp(runtime, config) {
    const launch = JSON.stringify([config.member, config.project]);
    if (runtime.acp?.alive && runtime.launch === launch) return runtime.acp;
    if (runtime.acp) await runtime.acp.stop();
    forgetSessions(runtime);
    runtime.acp = undefined;
    if (!ctx.host.spawn) throw new Error("aidevops agents run only in the desktop app");
    const acp = await Acp.start(
      ctx.host.spawn.bind(ctx.host),
      ["--member", config.member, "--project", config.project],
      (params) => onUpdate(runtime, params),
    );
    runtime.acp = acp;
    runtime.launch = launch;
    void acp.exited.then(() => {
      if (runtime.acp !== acp) return;
      runtime.acp = undefined;
      forgetSessions(runtime);
    });
    return acp;
  }

  async function openSession(runtime, acp, delivery, conversation, config) {
    const server = await ensureServer(runtime);
    const system = await kit.systemPrompt(delivery, {
      scope: config.scope,
      cwd: config.project,
      instructions: "",
    });
    const standard = !!system && acp.advertises("systemPrompt");
    const opened = await acp.request(
      "session/new",
      {
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

  /** Runs one turn; the runtime's queue makes it the agent's only turn. */
  async function turn(runtime, delivery, conversation, config, control) {
    clearTimeout(runtime.idle);
    if (delivery.current?.() === false || control.stopped)
      return { ok: true, stopped: control.stopped };
    runtime.handle = delivery.agent;
    const acp = await ensureAcp(runtime, config);
    const session =
      runtime.sessions.get(conversation.key) ??
      (await openSession(runtime, acp, delivery, conversation, config));
    session.conversation = conversation;
    session.handle = delivery.agent;
    session.delivery = delivery;
    const prompt = await kit.turnPrompt(
      delivery,
      conversation,
      session.cursor ? { cursor: session.cursor } : undefined,
    );
    if (control.stopped) {
      prompt.restore();
      return { ok: true, stopped: true };
    }
    session.acted = false;
    session.written = "";
    session.updates = 0;
    session.lastStep = "";
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
    if (answer?.stopReason === "cancelled") return { ok: true, stopped: true };
    const text = replyText(session.written);
    if (!session.acted && text) await kit.reply(delivery.agent, conversation, text);
    if (answer?.stopReason === "refusal")
      return { ok: false, error: "The model refused the request" };
    return { ok: true };
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

  async function run(delivery) {
    const config = settings(delivery.config);
    const conversation = await kit.conversation(delivery, config.scope);
    if (!conversation) {
      delivery.ignored?.();
      return;
    }
    const agent = delivery.agent;
    const resolved = { ...config, member: config.member || agent.name };
    const runtime = runtimeFor(agent.key);
    const control = { stopped: false, session: undefined };
    const problem = projectProblem(resolved.project);
    const work = runtime.queue.then(() => {
      if (problem) throw new Error(problem);
      return turn(runtime, delivery, conversation, resolved, control);
    });
    const done = work.catch(async (error) => {
      const message = errorMessage(error);
      await kit
        .reply(agent, conversation, `I couldn't finish that: ${message}`, { notifyOwner: true })
        .catch(() => undefined);
      return { ok: false, error: message };
    });
    runtime.queue = done.then(
      () => scheduleIdleStop(runtime),
      () => scheduleIdleStop(runtime),
    );
    delivery.workingUntil(done);
    delivery.interruptible?.(async () => {
      control.stopped = true;
      const session = control.session;
      if (session && runtime.active === session)
        runtime.acp?.notify("session/cancel", { sessionId: session.id });
    });
  }

  // ---- Agent settings ------------------------------------------------------

  const fieldStyle = { display: "grid", gap: "var(--space-1, 4px)" };
  const hintStyle = { color: "var(--text-secondary)", margin: 0 };

  function Fields({ value, onChange, disabled, agentName }) {
    const set = (field) => (event) => onChange({ ...value, [field]: event.target.value });
    return h(
      "div",
      { style: { display: "grid", gap: "var(--space-3, 12px)" } },
      h(
        "label",
        { style: fieldStyle },
        h("span", null, "Project folder"),
        h("input", {
          type: "text",
          value: value.project ?? "",
          placeholder: "Full path to a registered repository",
          disabled,
          spellCheck: false,
          onChange: set("project"),
        }),
        h(
          "p",
          { style: hintStyle },
          "A repository registered with aidevops. The agent works in its own linked worktree of it, never in the folder itself.",
        ),
      ),
      h(
        "label",
        { style: fieldStyle },
        h("span", null, "aidevops agent"),
        h("input", {
          type: "text",
          value: value.member ?? "",
          placeholder: agentName || "aidevops-<this computer>",
          disabled,
          spellCheck: false,
          onChange: set("member"),
        }),
        h(
          "p",
          { style: hintStyle },
          "Which aidevops agent runs, named for this computer, such as aidevops-marcus-macbook-pro-01 or build-plus-marcus-macbook-pro-01. Leave empty to use this Buzz agent's name; naming the Buzz agent the same shows people which agent and computer they are addressing.",
        ),
      ),
      h(
        "label",
        { style: fieldStyle },
        h("span", null, "Conversation"),
        h(
          "select",
          { value: value.scope === "channel" ? "channel" : "thread", disabled, onChange: set("scope") },
          h("option", { value: "thread" }, "Each thread is its own session"),
          h("option", { value: "channel" }, "One session per channel"),
        ),
      ),
    );
  }

  function Create({ config, onChange, disabled }) {
    return h(Fields, { value: config ?? {}, onChange, disabled });
  }

  function SettingsTab({ agent, save }) {
    const [draft, setDraft] = React.useState(agent.config ?? {});
    const [state, setState] = React.useState({ status: "idle" });
    React.useEffect(() => setDraft(agent.config ?? {}), [agent.config]);
    const problem = projectProblem(settings(draft).project);
    const store = () => {
      setState({ status: "saving" });
      save({ ...(agent.config ?? {}), ...draft }).then(
        () => setState({ status: "saved" }),
        (error) => setState({ status: "failed", detail: errorMessage(error) }),
      );
    };
    return h(
      "section",
      { style: { display: "grid", gap: "var(--space-3, 12px)" } },
      h(Fields, {
        value: draft,
        onChange: setDraft,
        disabled: state.status === "saving",
        agentName: agent.name,
      }),
      problem ? h("p", { role: "alert", style: hintStyle }, problem) : null,
      h(
        "div",
        null,
        h(
          "button",
          { type: "button", disabled: state.status === "saving", onClick: store },
          state.status === "saving" ? "Saving…" : "Save",
        ),
        state.status === "saved" ? h("span", { style: hintStyle }, " Saved. The next message starts a fresh aidevops process.") : null,
        state.status === "failed" ? h("span", { role: "alert" }, ` ${state.detail}`) : null,
      ),
    );
  }

  ctx.agents.register({
    id: TYPE_ID,
    title: "aidevops",
    description:
      "aidevops agents in OpenCode on this computer, each in its own worktree of a registered project.",
    defaults: () => ({ config: { member: "", project: "", scope: "thread" } }),
    summary: (agent) => {
      const config = settings(agent.config);
      return config.project ? `aidevops · ${basename(config.project)}` : "aidevops · no project set";
    },
    Create,
    tabs: [{ id: "aidevops", title: "aidevops", role: "settings", component: SettingsTab }],
    timeoutMs: 30 * 60_000,
    run,
  });
}
