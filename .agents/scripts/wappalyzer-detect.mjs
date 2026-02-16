#!/usr/bin/env node

/**
 * Wappalyzer Detection Wrapper
 * Uses @ryntab/wappalyzer-node for local tech stack detection
 * Requires: @ryntab/wappalyzer-node
 */

import { scan } from '@ryntab/wappalyzer-node';

async function detect(url) {
  try {
    // Run Wappalyzer detection with basic fetch (no browser)
    const results = await scan(url, { target: 'fetch' });
    
    // Transform to common schema
    const technologies = (results.technologies || []).map(tech => {
      return {
        name: tech.name,
        slug: tech.slug || tech.name.toLowerCase().replace(/\s+/g, '-'),
        version: tech.version || null,
        category: tech.categories?.[0]?.name || 'Unknown',
        confidence: tech.confidence || 100,
        description: tech.description || null,
        website: tech.website || null,
        source: 'wappalyzer'
      };
    });
    
    const output = {
      provider: 'wappalyzer',
      url: url,
      timestamp: new Date().toISOString(),
      technologies: technologies
    };
    
    console.log(JSON.stringify(output, null, 2));
    process.exit(0);
  } catch (error) {
    console.error(`Error detecting technologies: ${error.message}`);
    process.exit(1);
  }
}

// Parse command line arguments
const args = process.argv.slice(2);

if (args.length === 0) {
  console.error('Usage: wappalyzer-detect.mjs <url>');
  process.exit(1);
}

const url = args[0];

// Validate URL
try {
  new URL(url);
} catch (error) {
  console.error(`Invalid URL: ${url}`);
  process.exit(1);
}

detect(url);
