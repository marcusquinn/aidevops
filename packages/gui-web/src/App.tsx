import React, { useEffect, useState } from "react";
import type { GuiResponseEnvelope, GuiStatusData } from "../../gui-shared/src";
import { fetchStatus, mockedStatus } from "./status-client";

export function App() {
  const [status, setStatus] = useState<GuiResponseEnvelope<GuiStatusData>>(mockedStatus());
  const [warning, setWarning] = useState<string | null>("Using local fixture until the API responds.");

  useEffect(() => {
    fetchStatus()
      .then((nextStatus) => {
        setStatus(nextStatus);
        setWarning(null);
      })
      .catch(() => {
        setWarning("API unavailable; showing read-only fixture data.");
      });
  }, []);

  return (
    <main>
      <section aria-label="aidevops status">
        <p className="eyebrow">Read-only local dashboard scaffold</p>
        <h1>aidevops control plane</h1>
        {warning ? <p role="status">{warning}</p> : null}
        {status.data.update.restart_required ? (
          <p role="alert">
            {status.data.update.message} Running {status.data.update.running_version}; installed {status.data.update.installed_version}.
          </p>
        ) : (
          <p role="status">{status.data.update.message}</p>
        )}
        <dl>
          <dt>Version</dt>
          <dd>{status.data.aidevops_version}</dd>
          <dt>API</dt>
          <dd>{status.data.runtime.api}</dd>
        </dl>
        <h2>Path health</h2>
        <ul>
          {status.data.paths.map((path) => (
            <li key={path.label}>
              <strong>{path.label}</strong>: {path.health} <code>{path.path_ref}</code>
            </li>
          ))}
        </ul>
        <h2>Helper availability</h2>
        <ul>
          {status.data.helper_availability.map((helper) => (
            <li key={helper.name}>
              {helper.name}: {helper.status}
            </li>
          ))}
        </ul>
        <h2>Secret references</h2>
        <ul>
          {status.data.secrets.map((secret) => (
            <li key={secret.name}>
              {secret.name}: {secret.status}
            </li>
          ))}
        </ul>
        <p>{status.data.placeholders[0]}</p>
      </section>
    </main>
  );
}
