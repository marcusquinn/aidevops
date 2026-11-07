// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
//
// aidevops for Buzz Desktop, phase 0 (t18883): one Settings card that shows
// `aidevops buzz status` through the single command declared in manifest.json.
// Plugin API v1: one ES module, no imports, React from ctx.react.

export const inject = ["react", "settingsCards", "host"];

export function apply(ctx) {
  const React = ctx.react;
  const h = React.createElement;

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
          setState({
            status: "failed",
            detail: error instanceof Error ? error.message : String(error),
          });
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
}
