/**
 * npm postinstall script for aidevops
 * 
 * The npm package contains only the CLI wrapper. The full agent files
 * are deployed from ~/Git/aidevops via `aidevops update`.
 * 
 * Note: Writes directly to /dev/tty to bypass npm's output suppression.
 * Falls back to stderr if tty is not available (e.g., CI environments).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

const agentsDir = path.join(os.homedir(), '.aidevops', 'agents');
const versionFile = path.join(agentsDir, 'VERSION');

// Try to open tty synchronously to bypass npm's output suppression
let ttyFd = null;
try {
    ttyFd = fs.openSync('/dev/tty', 'w');
} catch {
    // tty not available (CI, non-interactive, Windows)
}

const log = (msg = '') => {
    const line = msg + '\n';
    if (ttyFd !== null) {
        fs.writeSync(ttyFd, line);
    } else {
        process.stderr.write(line);
    }
};

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

// Clean up
if (ttyFd !== null) {
    fs.closeSync(ttyFd);
}
