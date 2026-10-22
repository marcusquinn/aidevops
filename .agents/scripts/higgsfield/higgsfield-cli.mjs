// CLI argument definitions and parsing for the Higgsfield automation suite.

// Declarative flag definitions: [cliFlag, optionKey, type, alias?]
export const FLAG_DEFS = [
  ['--prompt',           'prompt',           'string', '-p'],
  ['--model',            'model',            'string', '-m'],
  ['--aspect',           'aspect',           'string', '-a'],
  ['--duration',         'duration',         'string', '-d'],
  ['--quality',          'quality',          'string', '-q'],
  ['--batch',            'batch',            'int',    '-b'],
  ['--seed',             'seed',             'int'          ],
  ['--seed-range',       'seedRange',        'string'       ],
  ['--brief',            'brief',            'string'       ],
  ['--scenes',           'scenes',           'int'          ],
  ['--preset',           'preset',           'string', '-s'],
  ['--effect',           'effect',           'string'       ],
  ['--camera',           'camera',           'string'       ],
  ['--lens',             'lens',             'string'       ],
  ['--output',           'output',           'string', '-o'],
  ['--image-url',        'imageUrl',         'string', '-i'],
  ['--image-file',       'imageFile',        'string'       ],
  ['--image-file2',      'imageFile2',       'string'       ],
  ['--video-file',       'videoFile',        'string'       ],
  ['--motion-ref',       'motionRef',        'string'       ],
  ['--character-image',  'characterImage',   'string'       ],
  ['--dialogue',         'dialogue',         'string'       ],
  ['--asset-action',     'assetAction',      'string'       ],
  ['--asset-type',       'assetType',        'string'       ],
  ['--asset-index',      'assetIndex',       'int'          ],
  ['--chain-action',     'chainAction',      'string'       ],
  ['--filter',           'filter',           'string'       ],
  ['--tab',              'tab',              'string'       ],
  ['--feature',          'feature',          'string'       ],
  ['--subtype',          'subtype',          'string'       ],
  ['--project',          'project',          'string'       ],
  ['--limit',            'limit',            'int'          ],
  ['--timeout',          'timeout',          'int'          ],
  ['--count',            'count',            'int',    '-c'],
  ['--concurrency',      'concurrency',      'int',    '-C'],
  ['--batch-file',       'batchFile',        'string'       ],
  ['--headed',           'headed',           'true'         ],
  ['--headless',         'headless',         'true'         ],
  ['--wait',             'wait',             'true'         ],
  ['--unlimited',        'unlimited',        'true'         ],
  ['--force',            'force',            'true'         ],
  ['--dry-run',          'dryRun',           'true'         ],
  ['--no-retry',         'noRetry',          'true'         ],
  ['--no-sidecar',       'noSidecar',        'true'         ],
  ['--no-dedup',         'noDedup',          'true'         ],
  ['--resume',           'resume',           'true'         ],
  ['--api',              'useApi',           'true'         ],
  ['--no-enhance',       'enhance',          'false'        ],
  ['--no-sound',         'sound',            'false'        ],
  ['--no-prefer-unlimited', 'preferUnlimited', 'false'     ],
  ['--enhance',          'enhance',          'true'         ],
  ['--sound',            'sound',            'true'         ],
  ['--prefer-unlimited', 'preferUnlimited',  'true'         ],
  ['--api-only',         null,               'compound'     ],
];

export const FLAG_MAP = new Map();
for (const [flag, key, type, alias] of FLAG_DEFS) {
  FLAG_MAP.set(flag, { key, type });
  if (alias) FLAG_MAP.set(alias, { key, type });
}

function applyFlagValue(options, def, args, i) {
  if (def.type === 'string') {
    options[def.key] = args[i + 1];
    return i + 1;
  }
  if (def.type === 'int') {
    options[def.key] = parseInt(args[i + 1], 10);
    return i + 1;
  }
  if (def.type === 'true') { options[def.key] = true; return i; }
  if (def.type === 'false') { options[def.key] = false; return i; }
  if (def.type === 'compound' && args[i] === '--api-only') {
    options.useApi = true;
    options.apiOnly = true;
  }
  return i;
}

export function parseArgs() {
  const args = process.argv.slice(2);
  const command = args[0];
  const options = {};

  for (let i = 1; i < args.length; i++) {
    const def = FLAG_MAP.get(args[i]);
    if (!def) continue;
    i = applyFlagValue(options, def, args, i);
  }

  return { command, options };
}
