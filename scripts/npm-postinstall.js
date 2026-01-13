#!/usr/bin/env node
/**
 * npm postinstall script for aidevops
 * Runs setup.sh to deploy agents after npm install -g
 */

const { execSync, spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const packageDir = path.resolve(__dirname, '..');
const setupScript = path.join(packageDir, 'setup.sh');
const agentsDir = path.join(require('os').homedir(), '.aidevops', 'agents');

// Check if this is a global install
const isGlobalInstall = process.env.npm_config_global === 'true' || 
                        process.argv.includes('--global') ||
                        process.argv.includes('-g');

// Skip if not global install (local dev doesn't need postinstall)
if (!isGlobalInstall && fs.existsSync(agentsDir)) {
    console.log('aidevops: Local install detected, skipping setup (agents already deployed)');
    process.exit(0);
}

// Check if setup.sh exists
if (!fs.existsSync(setupScript)) {
    console.log('aidevops: setup.sh not found, skipping postinstall');
    process.exit(0);
}

console.log('aidevops: Running setup to deploy agents...');
console.log('');

try {
    // Run setup.sh non-interactively
    execSync(`bash "${setupScript}"`, {
        stdio: 'inherit',
        cwd: packageDir,
        env: {
            ...process.env,
            // Skip interactive prompts
            AIDEVOPS_NONINTERACTIVE: '1'
        }
    });
    
    console.log('');
    console.log('aidevops installed successfully!');
    console.log('');
    console.log('Quick start:');
    console.log('  aidevops status    # Check installation');
    console.log('  aidevops init      # Initialize in a project');
    console.log('  aidevops help      # Show all commands');
    console.log('');
} catch (error) {
    console.error('aidevops: Setup encountered issues (non-critical)');
    console.error('Run manually: bash ~/.aidevops/setup.sh');
    // Don't fail the install
    process.exit(0);
}
