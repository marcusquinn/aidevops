/**
 * npm postinstall script for aidevops
 * 
 * The npm package contains only the CLI wrapper. The full agent files
 * are deployed from ~/Git/aidevops via `aidevops update`.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const agentsDir = path.join(os.homedir(), '.aidevops', 'agents');
const versionFile = path.join(agentsDir, 'VERSION');

// Check current installed version
let installedVersion = 'not installed';
if (fs.existsSync(versionFile)) {
    installedVersion = fs.readFileSync(versionFile, 'utf8').trim();
}

// Get package version
const packageJson = require('../package.json');
const packageVersion = packageJson.version;

console.log('');
console.log('aidevops CLI installed successfully!');
console.log('');
console.log(`  CLI version:    ${packageVersion}`);
console.log(`  Agents version: ${installedVersion}`);
console.log('');

if (installedVersion === 'not installed') {
    console.log('To complete installation, run:');
    console.log('');
    console.log('  aidevops update');
    console.log('');
    console.log('This will clone the repository and deploy agents to ~/.aidevops/agents/');
} else if (installedVersion !== packageVersion) {
    console.log('To update agents to match CLI version, run:');
    console.log('');
    console.log('  aidevops update');
    console.log('');
} else {
    console.log('CLI and agents are in sync. Ready to use!');
    console.log('');
    console.log('Quick start:');
    console.log('  aidevops status    # Check installation');
    console.log('  aidevops init      # Initialize in a project');
    console.log('  aidevops help      # Show all commands');
}
console.log('');
