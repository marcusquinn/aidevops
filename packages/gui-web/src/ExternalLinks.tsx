import type { MouseEvent as ReactMouseEvent, ReactElement } from "react";
import { FiExternalLink } from "react-icons/fi";

export function OriginLink({ href, label }: { href: string; label: string }): ReactElement {
  if (href.length === 0) {
    return <span className="origin-missing">{label}: source pending</span>;
  }

  return <a href={href} onClick={(event) => openExternalLink(event, href)} rel="noreferrer" target="_blank" title={href}>{label} <FiExternalLink aria-hidden="true" /></a>;
}

function openExternalLink(event: ReactMouseEvent<HTMLAnchorElement>, href: string): void {
  event.stopPropagation();
  if (shouldPreserveDefaultLinkHandling(event)) {
    return;
  }

  const opened = window.open(href, "_blank", "noopener,noreferrer");
  if (opened !== null) {
    event.preventDefault();
    opened.opener = null;
  }
}

function shouldPreserveDefaultLinkHandling(event: ReactMouseEvent<HTMLAnchorElement>): boolean {
  if (event.defaultPrevented) {
    return true;
  }

  return linkClickModifierFlags(event).includes(true);
}

function linkClickModifierFlags(event: ReactMouseEvent<HTMLAnchorElement>): boolean[] {
  return [event.metaKey, event.ctrlKey, event.shiftKey, event.altKey];
}
