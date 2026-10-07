/** @jsxImportSource @opentui/solid */
// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// OpenCode 1.x TUI entrypoint. setup.sh registers this file in
// ~/.config/opencode/tui.json and disables the built-ins it replaces:
//   internal:sidebar-mcp    -> MCP section that starts collapsed
//   internal:sidebar-footer -> footer that adds the AIDevOps version, matching
//                              the OpenCode 2 `sidebar.footer` label
// Both views are adapted from OpenCode v1.18.35
// packages/tui/src/feature-plugins/sidebar/{mcp,footer}.tsx. Re-check them
// when OpenCode changes those built-ins. The host provides the JSX transform
// and the shared solid-js/@opentui/solid instances for file plugins.

import type { TuiPlugin, TuiPluginApi } from "@opencode-ai/plugin/tui";
import { createMemo, createSignal, For, Match, Show, Switch } from "solid-js";
import { homedir } from "node:os";
import { createVersionReader, formatVersionLabel } from "../v2-plugin/tui.mjs";

export const AIDEVOPS_V1_TUI_PLUGIN_ID = "aidevops-tui";
const VERSION_POLL_MS = 5000;

function McpView(props: { api: TuiPluginApi }) {
  // The only behavioural change from the built-in: start collapsed.
  const [open, setOpen] = createSignal(false);
  const theme = () => props.api.theme.current;
  const list = createMemo(() => props.api.state.mcp());
  const on = createMemo(() => list().filter((item) => item.status === "connected").length);
  const bad = createMemo(
    () =>
      list().filter(
        (item) =>
          item.status === "failed" || item.status === "needs_auth" || item.status === "needs_client_registration",
      ).length,
  );

  const dot = (status: string) => {
    if (status === "connected") return theme().success;
    if (status === "failed") return theme().error;
    if (status === "needs_auth") return theme().warning;
    if (status === "needs_client_registration") return theme().error;
    return theme().textMuted;
  };

  return (
    <Show when={list().length > 0}>
      <box>
        <box flexDirection="row" gap={1} onMouseDown={() => list().length > 2 && setOpen((x) => !x)}>
          <Show when={list().length > 2}>
            <text fg={theme().text}>{open() ? "▼" : "▶"}</text>
          </Show>
          <text fg={theme().text}>
            <b>MCP</b>
            <Show when={list().length > 2 && !open()}>
              <span style={{ fg: theme().textMuted }}>
                {" "}
                ({on()} active{bad() > 0 ? `, ${bad()} error${bad() > 1 ? "s" : ""}` : ""})
              </span>
            </Show>
          </text>
        </box>
        <Show when={list().length <= 2 || open()}>
          <For each={list()}>
            {(item) => (
              <box flexDirection="row" gap={1}>
                <text flexShrink={0} style={{ fg: dot(item.status) }}>
                  •
                </text>
                <text fg={theme().text} wrapMode="word">
                  {item.name}{" "}
                  <span style={{ fg: theme().textMuted }}>
                    <Switch fallback={item.status}>
                      <Match when={item.status === "connected"}>Connected</Match>
                      <Match when={item.status === "failed"}>
                        <i>{item.error}</i>
                      </Match>
                      <Match when={item.status === "disabled"}>Disabled</Match>
                      <Match when={item.status === "needs_auth"}>Needs auth</Match>
                      <Match when={item.status === "needs_client_registration"}>Needs client ID</Match>
                    </Switch>
                  </span>
                </text>
              </box>
            )}
          </For>
        </Show>
      </box>
    </Show>
  );
}

function abbreviateHome(dir: string) {
  const home = homedir();
  if (home && (dir === home || dir.startsWith(`${home}/`))) return `~${dir.slice(home.length)}`;
  return dir;
}

function FooterView(props: { api: TuiPluginApi; sessionID: string; aidevopsVersion: () => string }) {
  const theme = () => props.api.theme.current;
  const has = createMemo(() =>
    props.api.state.provider.some(
      (item) => item.id !== "opencode" || Object.values(item.models).some((model) => model.cost?.input !== 0),
    ),
  );
  const done = createMemo(() => props.api.kv.get("dismissed_getting_started", false));
  const show = createMemo(() => !has() && !done());
  const path = createMemo(() => {
    const session = props.api.state.session.get(props.sessionID);
    const dir = session?.directory || props.api.state.path.directory || process.cwd();
    const branch = session?.directory === props.api.state.path.directory ? props.api.state.vcs?.branch : undefined;
    const out = abbreviateHome(dir);
    const list = (branch ? `${out}:${branch}` : out).split("/");
    return { parent: list.slice(0, -1).join("/"), name: list.at(-1) ?? "" };
  });
  const aidevops = createMemo(() => formatVersionLabel(props.aidevopsVersion()));

  return (
    <box gap={1}>
      <Show when={show()}>
        <box
          backgroundColor={theme().backgroundElement}
          paddingTop={1}
          paddingBottom={1}
          paddingLeft={2}
          paddingRight={2}
          flexDirection="row"
          gap={1}
        >
          <text flexShrink={0} fg={theme().text}>
            ⬖
          </text>
          <box flexGrow={1} gap={1}>
            <box flexDirection="row" justifyContent="space-between">
              <text fg={theme().text}>
                <b>Getting started</b>
              </text>
              <text fg={theme().textMuted} onMouseDown={() => props.api.kv.set("dismissed_getting_started", true)}>
                ✕
              </text>
            </box>
            <text fg={theme().textMuted}>OpenCode includes free models so you can start immediately.</text>
            <text fg={theme().textMuted}>
              Connect from 75+ providers to use other models, including Claude, GPT, Gemini etc
            </text>
            <box flexDirection="row" gap={1} justifyContent="space-between">
              <text fg={theme().text}>Connect provider</text>
              <text fg={theme().textMuted}>/connect</text>
            </box>
          </box>
        </box>
      </Show>
      <text>
        <span style={{ fg: theme().textMuted }}>{path().parent}/</span>
        <span style={{ fg: theme().text }}>{path().name}</span>
      </text>
      <text fg={theme().textMuted}>
        <span style={{ fg: theme().success }}>•</span> <b>Open</b>
        <span style={{ fg: theme().text }}>
          <b>Code</b>
        </span>{" "}
        <span>{props.api.app.version}</span>
        <Show when={aidevops()}>
          <span> · {aidevops()}</span>
        </Show>
      </text>
    </box>
  );
}

const tui: TuiPlugin = async (api) => {
  // Live version signal: `aidevops update` shows without a TUI restart.
  const readVersion = createVersionReader();
  const [version, setVersion] = createSignal(readVersion());
  const timer = setInterval(() => setVersion(readVersion()), VERSION_POLL_MS);
  timer.unref?.();
  api.lifecycle.onDispose(() => clearInterval(timer));

  // Same order as the built-ins so the sidebar layout does not move.
  api.slots.register({
    order: 200,
    slots: {
      sidebar_content() {
        return <McpView api={api} />;
      },
    },
  });
  api.slots.register({
    order: 100,
    slots: {
      sidebar_footer(_ctx, props) {
        return <FooterView api={api} sessionID={props.session_id} aidevopsVersion={version} />;
      },
    },
  });
};

export default {
  id: AIDEVOPS_V1_TUI_PLUGIN_ID,
  tui,
};
