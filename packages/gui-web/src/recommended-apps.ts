import type { TabOption } from "./AppTabs";

export type RecommendedOsId = "all" | "macos" | "linux" | "windows" | "ios" | "android";
export type RecommendedPlatformId = "webapp" | "saas" | "cli" | "api";
export type RecommendedPlatformFilterId = "all" | RecommendedPlatformId;

export interface RecommendedApp {
  name: string;
  description: string;
  websiteUrl: string;
  alternativeToUrl?: string;
  repoUrl?: string;
  iosUrl?: string;
  androidUrl?: string;
  fdroidUrl?: string;
  obtainiumUrl?: string;
  os: RecommendedOsId[];
  platforms: RecommendedPlatformId[];
}

export const recommendedPlatformTabs: TabOption<RecommendedPlatformFilterId>[] = [
  { id: "all", label: "All" },
  { id: "webapp", label: "WebApp" },
  { id: "saas", label: "SaaS" },
  { id: "cli", label: "CLI" },
  { id: "api", label: "API" },
];

export const recommendedOsTabs: TabOption<RecommendedOsId>[] = [
  { id: "all", label: "All OS" },
  { id: "macos", label: "macOS" },
  { id: "linux", label: "Linux" },
  { id: "windows", label: "Windows" },
  { id: "ios", label: "iOS" },
  { id: "android", label: "Android" },
];

export const recommendedApps = ([
  { name: "Affinity Studio", description: "Creative design suite.", websiteUrl: "https://www.affinity.studio/", alternativeToUrl: "https://alternativeto.net/software/affinity-1/", os: ["macos", "windows", "ios"], platforms: [] },
  { name: "Bitwarden", description: "Open source password manager.", websiteUrl: "https://bitwarden.com", alternativeToUrl: "https://alternativeto.net/software/bitwarden--free-password-manager/", repoUrl: "https://github.com/bitwarden", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Brave Browser", description: "Privacy-focused web browser.", websiteUrl: "https://brave.com/", alternativeToUrl: "https://alternativeto.net/software/brave/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "Cloudron", description: "Self-hosted app platform.", websiteUrl: "https://www.cloudron.io/", alternativeToUrl: "https://alternativeto.net/software/cloudron/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "Collabora Online", description: "Online office collaboration.", websiteUrl: "https://www.collaboraonline.com/collabora-online/", alternativeToUrl: "https://alternativeto.net/software/collabora-online/", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "Cometly", description: "Marketing attribution analytics.", websiteUrl: "https://www.cometly.com/", os: [], platforms: ["saas", "api"] },
  { name: "DaVinci Resolve", description: "Professional video editing, color, VFX, and audio post-production.", websiteUrl: "https://www.blackmagicdesign.com/products/davinciresolve/", alternativeToUrl: "https://alternativeto.net/software/davinci-resolve/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "DocuSeal", description: "Open source document signing.", websiteUrl: "https://www.docuseal.com/", alternativeToUrl: "https://alternativeto.net/software/docuseal/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Element", description: "Matrix messaging client.", websiteUrl: "https://element.io/", alternativeToUrl: "https://alternativeto.net/software/element-app/", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp"] },
  { name: "Enpass", description: "Offline-first password manager.", websiteUrl: "https://www.enpass.io/", alternativeToUrl: "https://alternativeto.net/software/enpass/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "EspoCRM", description: "Open source CRM.", websiteUrl: "https://www.espocrm.com/", alternativeToUrl: "https://alternativeto.net/software/espocrm/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Fathom Analytics", description: "Privacy-first analytics.", websiteUrl: "https://usefathom.com/", alternativeToUrl: "https://alternativeto.net/software/fathom-analytics/", os: [], platforms: ["saas", "api"] },
  { name: "FontBase", description: "Font management and reference tool.", websiteUrl: "https://fontba.se/", alternativeToUrl: "https://alternativeto.net/software/fontbase/", os: ["macos"], platforms: [] },
  { name: "Forgejo", description: "Self-hosted Git forge.", websiteUrl: "https://forgejo.org/", alternativeToUrl: "https://alternativeto.net/software/forgejo/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "Ghost", description: "Publishing platform.", websiteUrl: "https://ghost.org/", alternativeToUrl: "https://alternativeto.net/software/ghost/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Gitea", description: "Self-hosted Git service.", websiteUrl: "https://about.gitea.com/", alternativeToUrl: "https://alternativeto.net/software/gitea/", os: ["linux", "windows"], platforms: ["webapp", "cli", "api"] },
  { name: "GitLab", description: "DevSecOps and Git hosting platform.", websiteUrl: "https://gitlab.com/", alternativeToUrl: "https://alternativeto.net/software/gitlab/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "LibreOffice", description: "Open source office suite.", websiteUrl: "https://www.libreoffice.org/", alternativeToUrl: "https://alternativeto.net/software/libreoffice/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "LocalWP", description: "Local WordPress development.", websiteUrl: "https://localwp.com/", alternativeToUrl: "https://alternativeto.net/software/local-by-flywheel/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Matomo", description: "Open analytics platform.", websiteUrl: "https://matomo.org/", alternativeToUrl: "https://alternativeto.net/software/piwik/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "Nextcloud", description: "Open source content collaboration platform.", websiteUrl: "https://nextcloud.com/", alternativeToUrl: "https://alternativeto.net/software/nextcloud/", repoUrl: "https://github.com/nextcloud", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "api"] },
  { name: "Nextcloud Talk", description: "Open source video calls, chat, and collaboration for Nextcloud.", websiteUrl: "https://nextcloud.com/talk/", repoUrl: "https://github.com/nextcloud/spreed", iosUrl: "https://apps.apple.com/us/app/nextcloud-talk/id1296825574", androidUrl: "https://play.google.com/store/apps/details?id=com.nextcloud.talk2&hl=en", os: ["ios", "android"], platforms: ["webapp"] },
  { name: "OBS Studio", description: "Open source video recording and live streaming.", websiteUrl: "https://obsproject.com/", alternativeToUrl: "https://alternativeto.net/software/open-broadcaster-software/", repoUrl: "https://github.com/obsproject/obs-studio", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "ONLYOFFICE", description: "Office and document collaboration.", websiteUrl: "https://www.onlyoffice.com/", alternativeToUrl: "https://alternativeto.net/software/onlyoffice/", repoUrl: "https://github.com/ONLYOFFICE/", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "saas", "api"] },
  { name: "OpenScreen", description: "Open screen-sharing project.", websiteUrl: "https://github.com/getopenscreen/openscreen/releases", alternativeToUrl: "https://alternativeto.net/software/openscreen/", repoUrl: "https://github.com/getopenscreen/openscreen", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Osaurus", description: "AI app workspace.", websiteUrl: "https://osaurus.ai/", alternativeToUrl: "https://alternativeto.net/software/osaurus/", os: ["macos"], platforms: [] },
  { name: "Parallels Desktop", description: "Run Windows, Linux, and virtual machines on macOS.", websiteUrl: "https://www.parallels.com/products/desktop/", alternativeToUrl: "https://alternativeto.net/software/parallels-desktop/about/", os: ["macos"], platforms: [] },
  { name: "PDF Studio", description: "PDF editor.", websiteUrl: "https://www.qoppa.com/pdfstudio/", alternativeToUrl: "https://alternativeto.net/software/qoppa-pdf-studio/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Pixelmator Pro", description: "Professional image editor for macOS.", websiteUrl: "https://www.apple.com/pixelmator-pro/", os: ["macos"], platforms: [] },
  { name: "PostHog", description: "Product analytics platform.", websiteUrl: "https://posthog.com/", alternativeToUrl: "https://alternativeto.net/software/posthog/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Postiz", description: "Social media scheduling.", websiteUrl: "https://postiz.com/", alternativeToUrl: "https://alternativeto.net/software/postiz/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "PrivateBin", description: "Zero-knowledge pastebin.", websiteUrl: "https://privatebin.info/", alternativeToUrl: "https://alternativeto.net/software/privatebin/", repoUrl: "https://github.com/PrivateBin/PrivateBin", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "Proxmox", description: "Virtualization platform.", websiteUrl: "https://www.proxmox.com/", alternativeToUrl: "https://alternativeto.net/software/proxmox-virtual-environment/", os: ["linux"], platforms: ["webapp", "cli", "api"] },
  { name: "QuickFile", description: "Accounting platform.", websiteUrl: "https://www.quickfile.co.uk/", os: [], platforms: ["saas", "api"] },
  { name: "Reframed", description: "Creative framing utility.", websiteUrl: "https://www.reframed.dev/", alternativeToUrl: "https://alternativeto.net/software/reframed/", os: ["macos"], platforms: [] },
  { name: "Rybbit", description: "Web analytics.", websiteUrl: "https://rybbit.com/", alternativeToUrl: "https://alternativeto.net/software/rybbit/", os: ["linux"], platforms: ["webapp", "saas", "api"] },
  { name: "SchildiChat", description: "Matrix messaging client.", websiteUrl: "https://schildi.chat/", alternativeToUrl: "https://alternativeto.net/software/schildichat/", os: ["macos", "linux", "windows", "android"], platforms: ["webapp"] },
  { name: "ScreenFlow", description: "Screen recording and editing.", websiteUrl: "https://www.telestream.net/screenflow/", alternativeToUrl: "https://alternativeto.net/software/screenflow/", os: ["macos", "ios"], platforms: [] },
  { name: "SEO Utils", description: "Desktop SEO tools.", websiteUrl: "https://seoutils.app/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Shottr", description: "macOS screenshot utility.", websiteUrl: "https://shottr.cc/", alternativeToUrl: "https://alternativeto.net/software/shottr/", os: ["macos"], platforms: [] },
  { name: "Signal", description: "Private messenger.", websiteUrl: "https://signal.org/", alternativeToUrl: "https://alternativeto.net/software/signal-private-messenger/", os: ["macos", "linux", "windows", "ios", "android"], platforms: [] },
  { name: "SimpleX Chat", description: "Private messenger with no user IDs.", websiteUrl: "https://simplex.chat/", alternativeToUrl: "https://alternativeto.net/software/simplex-chat/about/", repoUrl: "https://github.com/simplex-chat", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["cli"] },
  { name: "Telegram", description: "Cloud-based mobile and desktop messaging app.", websiteUrl: "https://telegram.org/", iosUrl: "https://telegram.org/dl/ios", androidUrl: "https://telegram.org/android", os: ["macos", "linux", "windows", "ios", "android"], platforms: ["webapp", "api"] },
  { name: "Thunderbird", description: "Email and calendar app.", websiteUrl: "https://www.thunderbird.net/", alternativeToUrl: "https://alternativeto.net/software/mozilla-thunderbird/about/", os: ["macos", "linux", "windows"], platforms: [] },
  { name: "Ubicloud", description: "Open cloud platform.", websiteUrl: "https://www.ubicloud.com/", alternativeToUrl: "https://alternativeto.net/software/ubicloud/about/", repoUrl: "https://github.com/ubicloud/ubicloud", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
  { name: "Vaultwarden", description: "Alternative Bitwarden server implementation.", websiteUrl: "https://github.com/dani-garcia/vaultwarden", alternativeToUrl: "https://alternativeto.net/software/vaultwarden/", repoUrl: "https://github.com/dani-garcia/vaultwarden", os: ["linux"], platforms: ["webapp", "api"] },
  { name: "VideoProc", description: "Video processing toolkit.", websiteUrl: "https://www.videoproc.com/", alternativeToUrl: "https://alternativeto.net/software/videoproc/about/", os: ["macos", "windows"], platforms: [] },
  { name: "VirtualBox", description: "Virtualization app.", websiteUrl: "https://www.virtualbox.org/", alternativeToUrl: "https://alternativeto.net/software/virtualbox/about/", os: ["macos", "linux", "windows"], platforms: ["cli"] },
  { name: "WordPress", description: "Open source publishing platform.", websiteUrl: "https://wordpress.org/", alternativeToUrl: "https://alternativeto.net/software/wordpress/about/", os: ["linux"], platforms: ["webapp", "saas", "cli", "api"] },
] satisfies RecommendedApp[]).sort((left, right) => left.name.localeCompare(right.name, undefined, { sensitivity: "base" }));

export function recommendedAppMatchesFilters(app: RecommendedApp, platform: RecommendedPlatformFilterId, os: RecommendedOsId): boolean {
  if (!platformFilterMatches(app, platform)) {
    return false;
  }

  return osFilterMatches(app, os);
}

function platformFilterMatches(app: RecommendedApp, platform: RecommendedPlatformFilterId): boolean {
  if (platform === "all") {
    return true;
  }

  return app.platforms.includes(platform);
}

function osFilterMatches(app: RecommendedApp, os: RecommendedOsId): boolean {
  if (os === "all") {
    return true;
  }

  return app.os.includes(os);
}
