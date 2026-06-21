/* jshint esversion: 11 */
import type { GuiStatusData } from "../../gui-shared/src";
import { plannedHomes, text } from "./app-model";
import { PathActions } from "./PathActions";

export function OverviewSurface({ status }: { status: GuiStatusData }) {
  const metrics = [
    { label: text.setup, value: status.update.restart_required ? "restart" : "current", detail: status.update.installed_version },
    { label: text.projects, value: String(status.repos.total), detail: status.repos.health },
    { label: text.config, value: String(status.settings.key_count), detail: status.settings.value_policy },
    { label: text.security, value: String(status.secrets.length), detail: "secret references" },
  ];

  return (
    <section className="surface-page" aria-label="Overview">
      <div className="hero-panel compact-hero">
        <p className="eyebrow">{text.roadmapIntro}</p>
        <h2>{text.aidevops}</h2>
      </div>
      <div className="metric-grid">
        {metrics.map((metric) => (
          <article className="metric-card" key={metric.label}>
            <span>{metric.label}</span>
            <strong>{metric.value}</strong>
            <small>{metric.detail}</small>
          </article>
        ))}
      </div>
      <section className="panel">
        <div className="section-heading">
          <p className="eyebrow">{text.plannedHomes}</p>
          <h2>{text.fileBrowser}</h2>
        </div>
        <div className="planned-home-grid">
          {plannedHomes.map((home) => (
            <article className="planned-home" key={home.area}>
              <span>{home.phase}</span>
              <strong>{home.area}</strong>
              <small>{home.home}</small>
            </article>
          ))}
        </div>
      </section>
      <section className="panel">
        <div className="section-heading">
          <p className="eyebrow">{text.path}</p>
          <h2>{text.localSetup}</h2>
        </div>
        <ul className="object-list">
          {status.paths.map((path) => (
            <li key={path.label}>
              <strong>{path.label}</strong>
              <span>{path.health}</span>
              <code>{path.path_ref}</code>
              <PathActions pathRef={path.path_ref} />
            </li>
          ))}
        </ul>
      </section>
    </section>
  );
}

export function ProjectsSurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label={text.projects}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.inventory}</p>
          <h2>{text.projects}</h2>
          <p>{status.repos.path_ref}</p>
        </div>
        <PathActions pathRef={status.repos.path_ref} />
      </div>
      {status.repos.repos.length === 0 ? (
        <p className="empty-state">{text.noProjectEntries}</p>
      ) : (
        <ul className="object-list">
          {status.repos.repos.map((repo) => (
            <li key={`${repo.platform}:${repo.slug}`}>
              <strong>{repo.name}</strong>
              <span>{repo.platform}</span>
              <small>{repo.slug}</small>
              <small>{repo.local_path_status}</small>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

export function SecuritySurface({ status }: { status: GuiStatusData }) {
  return (
    <section className="panel" aria-label={text.security}>
      <div className="section-heading">
        <p className="eyebrow">{text.readOnly}</p>
        <h2>{text.security}</h2>
        <p>{text.securityBoundary}</p>
      </div>
      <ul className="object-list">
        {status.secrets.map((secret) => (
          <li key={secret.name}>
            <strong>{secret.name}</strong>
            <span>{secret.status}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

export function PlannedSurface({ detail, label }: { detail: string; label: string }) {
  return (
    <section className="panel" aria-label={label}>
      <div className="section-heading">
        <p className="eyebrow">{text.planned}</p>
        <h2>{label}</h2>
        <p>{detail}</p>
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}
