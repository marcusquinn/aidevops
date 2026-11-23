// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn
import fs from 'node:fs';
import path from 'node:path';
import { insist } from './backend-error.mjs';

const inside = (child, parent) => child === parent || child.startsWith(parent + path.sep);
const implicitTempPaths = ['/tmp/claude', '/private/tmp/claude'];

export function tightenMacProfile(profile, grants = { read: [], write: [] }) {
  insist(profile.startsWith('(version 1)\n(deny default'), 'unexpected-seatbelt-profile');
  // Remove the pinned release's explicit Mach-service allows rather than
  // assuming a broad deny overrides more specific allows. Refuse unknown forms.
  const rule = /\(allow mach-lookup\s+(?:\(global-name(?:-prefix)? "(?:[^"\\]|\\.)*"\)\s*)+\)/g;
  let strict = profile.replace(rule, '');
  insist(!/\(allow\s+mach-lookup\b/.test(strict) && !/\(import\b/.test(strict), 'unknown-mach-rule');
  strict = strict.replace(/\(allow (?:user-preference-read|ipc-posix-shm|ipc-posix-sem)\)/g, '');
  const tempDenials = temporaryHostPaths(true).flatMap(p => {
    // Seatbelt sees both /tmp and /private/tmp spellings. Envelope grants are
    // canonical, so translate exclusions for each spelling of the same root.
    let canonical = p;
    try { canonical = fs.realpathSync(p); }
    catch (error) { insist(error.code === 'ENOENT', 'temporary-path-unavailable'); }
    const filter = roots => {
      const exclusions = roots.filter(root => inside(root, canonical)).map(root =>
        `(require-not (subpath ${JSON.stringify(path.join(p, path.relative(canonical, root)))}))`);
      const parent = `(subpath ${JSON.stringify(p)})`;
      return exclusions.length ? `(require-all ${parent} ${exclusions.join(' ')})` : parent;
    };
    return [`(deny file-read* ${filter([...grants.read, ...grants.write])})`,
      `(deny file-write* file-write-create file-write-unlink ${filter(grants.write)})`];
  }).join('\n');
  return strict + '\n(deny mach-lookup)\n(deny mach-register)\n' + tempDenials + '\n';
}

// The pinned SRT always adds host /tmp/claude write binds. Apply private tmpfs
// after every upstream mount, then restore only explicit grants beneath them.
// Resolve aliases on the host too: a symlink must not expose its target through
// a canonical bind emitted by SRT. Unknown bwrap profile forms fail closed.
function temporaryHostPaths(includeSpellings = false) {
  const paths = new Set();
  for (const p of implicitTempPaths) {
    if (includeSpellings) paths.add(p);
    try { paths.add(fs.realpathSync(p)); }
    catch (error) {
      insist(error.code === 'ENOENT', 'temporary-path-unavailable');
    }
  }
  return [...paths];
}

export function tightenLinuxArgs(argv, grants = { read: [], write: [] }) {
  const boundary = argv.indexOf('--');
  insist(boundary >= 0 && !argv.slice(0, boundary).includes('--args'), 'unexpected-bwrap-profile');
  // An absent alias has no host grant to hide. Mounting it could require making
  // /private on the read-only root of an ordinary Linux filesystem. Use only
  // canonical destinations: modern bwrap refuses a symlink mount destination.
  const roots = temporaryHostPaths();
  const restored = [...grants.read.map(p => [p, '--ro-bind']), ...grants.write.map(p => [p, '--bind'])]
    .filter(([p]) => roots.some(root => inside(p, root)))
    .sort(([a], [b]) => a.length - b.length)
    .flatMap(([p, flag]) => [flag, p, p]);
  return [...argv.slice(0, boundary), ...roots.flatMap(p => ['--tmpfs', p]), ...restored, ...argv.slice(boundary)];
}
