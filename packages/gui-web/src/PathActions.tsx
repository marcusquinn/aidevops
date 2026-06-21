/* jshint esversion: 11 */
import { text } from "./app-model";

export function PathActions({ pathRef }: { pathRef: string }) {
  const copy = () => {
    if (typeof navigator !== "undefined" && navigator.clipboard !== undefined) {
      void navigator.clipboard.writeText(pathRef);
    }
  };

  return (
    <span className="path-actions">
      <button aria-label={text.copyPath} onClick={copy} title={text.copyPath} type="button">⧉</button>
      <button aria-label={text.folderOpenBlocked} disabled title={text.folderOpenBlocked} type="button">⌂</button>
    </span>
  );
}
