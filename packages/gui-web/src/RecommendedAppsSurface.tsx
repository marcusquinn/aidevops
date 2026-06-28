import type { ReactElement } from "react";
import type { IconType } from "react-icons";
import { FaApple, FaLinux, FaWindows } from "react-icons/fa";
import { FiCode, FiGlobe, FiMonitor, FiTerminal } from "react-icons/fi";
import { IoLogoAndroid } from "react-icons/io";
import { SiIos } from "react-icons/si";
import { text } from "./app-model";
import { TabNav } from "./AppTabs";
import { OriginLink } from "./ExternalLinks";
import { recommendedOsTabs, recommendedPlatformTabs, type RecommendedApp, type RecommendedOsId, type RecommendedPlatformFilterId, type RecommendedPlatformId } from "./recommended-apps";

interface RecommendedAppsSurfaceProps {
  apps: RecommendedApp[];
  os: RecommendedOsId;
  platform: RecommendedPlatformFilterId;
  setOs: (os: RecommendedOsId) => void;
  setPlatform: (platform: RecommendedPlatformFilterId) => void;
}

const platformIcons: Record<RecommendedPlatformId, { Icon: IconType; label: string }> = {
  webapp: { Icon: FiMonitor, label: "WebApp" },
  saas: { Icon: FiGlobe, label: "SaaS" },
  cli: { Icon: FiTerminal, label: "CLI" },
  api: { Icon: FiCode, label: "API" },
};

const osIcons: Record<RecommendedOsId, { Icon: IconType; label: string }> = {
  all: { Icon: FiGlobe, label: "Web app" },
  macos: { Icon: FaApple, label: "macOS" },
  linux: { Icon: FaLinux, label: "Linux" },
  windows: { Icon: FaWindows, label: "Windows" },
  ios: { Icon: SiIos, label: "iOS" },
  android: { Icon: IoLogoAndroid, label: "Android" },
};

export function RecommendedAppsSurface({ apps, os, platform, setOs, setPlatform }: RecommendedAppsSurfaceProps): ReactElement {
  return <>
    <div className="recommended-filter-tabs">
      <TabNav label="Recommended app platform filters" tabs={recommendedPlatformTabs} value={platform} onChange={setPlatform} />
      <TabNav label="Recommended app operating system filters" tabs={recommendedOsTabs} value={os} onChange={setOs} />
    </div>
    <div className="recommended-app-grid">
      {apps.map((app) => <RecommendedAppCard app={app} key={app.name} setOs={setOs} setPlatform={setPlatform} />)}
    </div>
  </>;
}

function RecommendedAppCard({ app, setOs, setPlatform }: { app: RecommendedApp; setOs: (os: RecommendedOsId) => void; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement {
  return <article className="recommended-app-card">
    <div>
      <strong>{app.name}</strong>
      <p>{app.description}</p>
    </div>
    <div className="app-icon-groups">
      <PlatformIconList platforms={app.platforms} setPlatform={setPlatform} />
      <OsIconList os={app.os} setOs={setOs} />
    </div>
    <div className="managed-app-links plain-links">
      <OriginLink href={app.websiteUrl} label={text.website} />
      {app.alternativeToUrl ? <OriginLink href={app.alternativeToUrl} label="AlternativeTo" /> : null}
      {app.repoUrl ? <OriginLink href={app.repoUrl} label="Repo" /> : null}
      {app.iosUrl ? <OriginLink href={app.iosUrl} label="iOS" /> : null}
      {app.androidUrl ? <OriginLink href={app.androidUrl} label="Android" /> : null}
      {app.fdroidUrl ? <OriginLink href={app.fdroidUrl} label="F-Droid" /> : null}
      {app.obtainiumUrl ? <OriginLink href={app.obtainiumUrl} label="Obtainium" /> : null}
    </div>
  </article>;
}

function PlatformIconList({ platforms, setPlatform }: { platforms: RecommendedPlatformId[]; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement | null {
  if (platforms.length === 0) {
    return null;
  }

  return <span className="os-icon-list platform-icon-list">{platforms.map((platform) => <PlatformIcon id={platform} key={platform} setPlatform={setPlatform} />)}</span>;
}

function PlatformIcon({ id, setPlatform }: { id: RecommendedPlatformId; setPlatform: (platform: RecommendedPlatformFilterId) => void }): ReactElement {
  const { Icon, label } = platformIcons[id];

  return <button aria-label={`Filter by ${label}`} data-tooltip={`Filter by ${label}`} onClick={() => setPlatform(id)} title={`Filter by ${label}`} type="button"><Icon aria-hidden="true" focusable="false" /></button>;
}

function OsIconList({ os, setOs }: { os: RecommendedOsId[]; setOs: (os: RecommendedOsId) => void }): ReactElement | null {
  if (os.length === 0) {
    return null;
  }

  return <span className="os-icon-list">{os.map((item) => <OsIcon id={item} key={item} setOs={setOs} />)}</span>;
}

function OsIcon({ id, setOs }: { id: RecommendedOsId; setOs: (os: RecommendedOsId) => void }): ReactElement {
  const { Icon, label } = osIcons[id];

  return <button aria-label={`Filter by ${label}`} data-tooltip={`Filter by ${label}`} onClick={() => setOs(id)} title={`Filter by ${label}`} type="button"><Icon aria-hidden="true" focusable="false" /></button>;
}
