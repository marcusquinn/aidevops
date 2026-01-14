/**
 * npm postinstall script for aidevops
 * 
 * The npm package contains only the CLI wrapper. The full agent files
 * are deployed from ~/Git/aidevops via `aidevops update`.
 * 
 * Note: Uses stderr so output is visible (npm suppresses stdout for lifecycle scripts)
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const agentsDir = path.join(os.homedir(), '.aidevops', 'agents');
const versionFile = path.join(agentsDir, 'VERSION');

// Use stderr so npm doesn't suppress the output
const log = (msg = '') => process.stderr.write(msg + '\n');

// Check current installed version
let installedVersion = 'not installed';
if (fs.existsSync(versionFile)) {
    installedVersion = fs.readFileSync(versionFile, 'utf8').trim();
}

// Get package version
const packageJson = require('../package.json');
const packageVersion = packageJson.version;

log('');
log('aidevops CLI installed successfully!');
log('');
log(`  CLI version:    ${packageVersion}`);
log(`  Agents version: ${installedVersion}`);
log('');

if (installedVersion === 'not installed') {
    log('To complete installation, run:');
    log('');
    log('  aidevops update');
    log('');
    log('This will clone the repository and deploy agents to ~/.aidevops/agents/');
} else if (installedVersion !== packageVersion) {
    log('To update agents to match CLI version, run:');
    log('');
    log('  aidevops update');
    log('');
} else {
    log('CLI and agents are in sync. Ready to use!');
    log('');
    log('Quick start:');
    log('  aidevops status    # Check installation');
    log('  aidevops init      # Initialize in a project');
    log('  aidevops help      # Show all commands');
}
log('');
