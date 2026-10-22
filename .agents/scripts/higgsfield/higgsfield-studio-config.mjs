// Studio route discovery and option names, separate from browser command execution.
import { existsSync, readFileSync } from 'node:fs';

export function resolveVibeMotionSubtype(subtype) {
  const subtypeMap = {
    infographics: 'Infographics',
    'text-animation': 'Text Animation',
    text: 'Text Animation',
    posters: 'Posters',
    poster: 'Posters',
    presentation: 'Presentation',
    scratch: 'From Scratch',
    'from-scratch': 'From Scratch',
  };
  return subtypeMap[subtype.toLowerCase()] || subtype;
}

export function resolvePresetUrl(presetName, presets) {
  const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');
  let presetUrl = presets[presetKey];
  if (!presetUrl) {
    const match = Object.keys(presets).find(k => k.includes(presetKey) || presetKey.includes(k));
    if (match) {
      presetUrl = presets[match];
      console.log(`Fuzzy matched preset: ${presetName} → ${match}`);
    }
  }
  return presetUrl;
}

export function listMotionPresets(routesCache) {
  if (!existsSync(routesCache)) {
    console.log('No discovery cache found. Run "discover" first.');
    return;
  }
  const cache = JSON.parse(readFileSync(routesCache, 'utf-8'));
  const motions = cache.motions || {};
  const names = Object.keys(motions);
  console.log(`Available motion presets (${names.length}):`);
  // biome-ignore lint/suspicious/useIterableCallbackReturn: forEach for logging
  names.slice(0, 50).forEach(n => console.log(`  ${n} → ${motions[n]}`));
  if (names.length > 50) console.log(`  ... and ${names.length - 50} more`);
}

export function resolveMotionPresetUrl(presetName, routesCache) {
  let presetUrl = null;

  if (existsSync(routesCache)) {
    const cache = JSON.parse(readFileSync(routesCache, 'utf-8'));
    const motions = cache.motions || {};
    const presetKey = presetName.toLowerCase().replace(/[\s-]+/g, '_');

    presetUrl = motions[presetKey];
    if (!presetUrl) {
      const match = Object.keys(motions).find(k =>
        k.includes(presetKey) || presetKey.includes(k) ||
        k.toLowerCase().includes(presetName.toLowerCase())
      );
      if (match) {
        presetUrl = motions[match];
        console.log(`Fuzzy matched: ${presetName} → ${match}`);
      }
    }
  }

  if (!presetUrl && presetName.includes('/')) {
    presetUrl = presetName.startsWith('/') ? presetName : `/motion/${presetName}`;
  }
  if (!presetUrl && presetName.match(/^[0-9a-f-]{36}$/i)) {
    presetUrl = `/motion/${presetName}`;
  }

  return presetUrl;
}

export const FEATURE_MAP = {
  'fashion-factory': { url: '/fashion-factory', name: 'Fashion Factory' },
  fashion: { url: '/fashion-factory', name: 'Fashion Factory' },
  'ugc-factory': { url: '/ugc-factory', name: 'UGC Factory' },
  ugc: { url: '/ugc-factory', name: 'UGC Factory' },
  'photodump-studio': { url: '/photodump-studio', name: 'Photodump Studio' },
  photodump: { url: '/photodump-studio', name: 'Photodump Studio' },
  'camera-controls': { url: '/camera-controls', name: 'Camera Controls' },
  camera: { url: '/camera-controls', name: 'Camera Controls' },
  effects: { url: '/effects', name: 'Effects' },
};
