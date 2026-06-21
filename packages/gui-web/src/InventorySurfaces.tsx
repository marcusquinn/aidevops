/* jshint esversion: 11 */
import { useState } from "react";
import { appRows, installationRows, text } from "./app-model";
import type { InventoryColumn } from "./app-model";

export function AppsSurface() {
  return (
    <section className="panel" aria-label={text.apps}>
      <div className="section-heading">
        <p className="eyebrow">{text.inventory}</p>
        <h2>{text.apps}</h2>
        <p>{text.appsIntro}</p>
      </div>
      <div className="data-table">
        <div className="data-row header-row"><span>{text.name}</span><span>{text.latest}</span><span>{text.channel}</span><span>{text.website}</span></div>
        {appRows.map((row) => (
          <div className="data-row" key={row.name}><span>{row.name}</span><span>{row.latest}</span><span>{row.channel}</span><span>{row.website}</span></div>
        ))}
      </div>
    </section>
  );
}

export function InstallationSurface() {
  return (
    <section className="panel" aria-label={text.installation}>
      <div className="section-heading">
        <p className="eyebrow">{text.setup}</p>
        <h2>{text.installation}</h2>
        <p>{text.installationIntro}</p>
      </div>
      <div className="installation-list">
        {installationRows.map((row) => (
          <article className="install-row" key={row.name}>
            <div><strong>{row.name}</strong><small>{row.scope}</small></div>
            <TogglePill checked={row.install} label={text.install} />
            <TogglePill checked={row.update} label={text.update} />
          </article>
        ))}
      </div>
      <p className="empty-state">{text.plannedNotice}</p>
    </section>
  );
}

function TogglePill({ checked, label }: { checked: boolean; label: string }) {
  return <span className={checked ? "toggle-pill checked" : "toggle-pill"}>{label}</span>;
}

export function EditableInventorySurface({ columns, initialRows, intro, title }: {
  columns: InventoryColumn[];
  initialRows: Record<string, string>[];
  intro: string;
  title: string;
}) {
  const [draftRows, setDraftRows] = useState(initialRows);

  function updateDraftRow(rowIndex: number, key: string, value: string): void {
    setDraftRows((currentRows) => currentRows.map((row, index) => index === rowIndex ? { ...row, [key]: value } : row));
  }

  function addDraftRow(): void {
    const emptyRow: Record<string, string> = {};
    for (const column of columns) {
      emptyRow[column.key] = "";
    }
    setDraftRows((currentRows) => [...currentRows, emptyRow]);
  }

  return (
    <section className="panel" aria-label={title}>
      <div className="section-heading split-heading">
        <div>
          <p className="eyebrow">{text.inventory}</p>
          <h2>{title}</h2>
          <p>{intro}</p>
        </div>
        <button className="secondary-action" onClick={addDraftRow} type="button">{text.addRow}</button>
      </div>
      <p className="notice compact-notice">{text.draftOnly}</p>
      <div className="editable-table">
        <div className="editable-row header-row">
          {columns.map((column) => <span key={column.key}>{column.label}</span>)}
        </div>
        {draftRows.map((row, rowIndex) => (
          <div className="editable-row" key={`${title}:${rowIndex}`}>
            {columns.map((column) => (
              <input
                aria-label={`${title} ${column.label}`}
                key={column.key}
                onChange={(event) => updateDraftRow(rowIndex, column.key, event.currentTarget.value)}
                placeholder={column.label}
                value={row[column.key] ?? ""}
              />
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}
