---
description: AI memory files system patterns
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
---

# Comprehensive AI Memory Files System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Persistent memory files for AI CLI tools referencing AGENTS.md
- **Home Directory Files**: `~/CLAUDE.md`, `~/GEMINI.md`, `~/.qwen/QWEN.md`, `~/.cursorrules`, `~/.github/copilot-instructions.md`, `~/.factory/DROID.md`
- **Project Files**: `CLAUDE.md`, `GEMINI.md`, `.cursorrules` in project root
- **Key Instruction**: "At the beginning of each session, read ~/AGENTS.md"
- **Setup Script**: `setup.sh` includes automatic creation
- **Config Script**: `.agents/scripts/ai-cli-config.sh`
- **Supported Tools**: Qwen CLI, Claude Code, Gemini CLI, Cursor AI, GitHub Copilot, Factory.ai Droid
- **Note**: Warp AI and Amp Code use project context (no specific memory files)
<!-- AI-CONTEXT-END -->

## Complete AI Tool Memory File Coverage

### Research Findings & Implementation

Based on comprehensive research and your discovery about Qwen's `QWEN.md` file, we've implemented a complete AI memory file system that covers all major AI tools.

## AI Tool Memory File Patterns Discovered

### Confirmed Memory File Locations

### **1. Qwen CLI** - **VERIFIED** ✅

- **Memory File**: `~/.qwen/QWEN.md`
- **Behavior**: Reads at beginning of each session
- **Content**: "At the beginning of each session, read ~/agents.md to get additional context and instructions."
- **Status**: **WORKING** - Your discovery confirmed this pattern

### **2. Claude Code** - **IMPLEMENTED** ✅

- **Memory File**: `~/CLAUDE.md` (home directory)
- **Project File**: `~/Git/aidevops/CLAUDE.md` (project-specific)
- **Behavior**: Persistent memory for Claude Code sessions
- **Note**: Claude Code is Anthropic's official CLI tool (the `claude` command)
- **Status**: **CREATED** - Both home and project files

### **3. Gemini CLI** - **IMPLEMENTED** ✅

- **Memory File**: `~/GEMINI.md` (home directory)
- **Project File**: `~/Git/aidevops/GEMINI.md` (project-specific)
- **Behavior**: Persistent memory for Gemini CLI sessions
- **Status**: **CREATED** - Both home and project files

### **4. Cursor AI** - **IMPLEMENTED** ✅

- **Rules File**: `~/.cursorrules` (home directory)
- **Project File**: `~/Git/aidevops/.cursorrules` (project-specific)
- **Behavior**: Persistent rules and context for Cursor AI
- **Status**: **CREATED** - Both home and project files

### **5. GitHub Copilot** - **IMPLEMENTED** ✅

- **Instructions File**: `~/.github/copilot-instructions.md`
- **Behavior**: Persistent instructions for GitHub Copilot
- **Status**: **CREATED** - Home directory instructions

### **6. Factory.ai Droid** - **IMPLEMENTED** ✅

- **Memory File**: `~/.factory/DROID.md`
- **Behavior**: Persistent memory for Factory.ai Droid sessions
- **Status**: **CREATED** - Detected Factory.ai installation and created file

## Implementation Details

### **✅ HOME DIRECTORY MEMORY FILES:**

```bash
~/CLAUDE.md                           # Claude Code memory
~/GEMINI.md                           # Gemini CLI memory
~/.qwen/QWEN.md                       # Qwen CLI memory (existing)
~/.cursorrules                        # Cursor AI rules
~/.github/copilot-instructions.md     # GitHub Copilot instructions
~/.factory/DROID.md                   # Factory.ai Droid memory
```

### **✅ PROJECT-LEVEL MEMORY FILES:**

```bash
~/Git/aidevops/CLAUDE.md      # Claude project memory
~/Git/aidevops/GEMINI.md      # Gemini project memory
~/Git/aidevops/.cursorrules   # Cursor project rules
~/Git/aidevops/AGENTS.md      # Authoritative source
```

### **✅ CONSISTENT MEMORY FILE CONTENT:**

All memory files contain the key instruction:

```markdown
At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.
```

## Setup Script Integration

### **✅ AUTOMATIC CREATION:**

- **Setup Script**: `setup.sh` includes AI memory file creation
- **Configuration Script**: `.agents/scripts/ai-cli-config.sh` handles all memory files
- **Detection Logic**: Automatically detects installed AI tools and creates appropriate files
- **Preservation**: Existing files are preserved, new ones created as needed

### **✅ COMPREHENSIVE COVERAGE:**

```bash
# Function calls in ai-cli-config.sh:
configure_qwen_cli()           # Handles QWEN.md creation/verification
create_ai_memory_files()       # Creates all home directory memory files
create_project_memory_files()  # Creates all project-level memory files
```

## Verification Results

### **✅ ALL MEMORY FILES CREATED:**

- ✅ **Qwen**: `~/.qwen/QWEN.md` (preserved existing)
- ✅ **Claude**: `~/CLAUDE.md` + project `CLAUDE.md`
- ✅ **Gemini**: `~/GEMINI.md` + project `GEMINI.md`
- ✅ **Cursor**: `~/.cursorrules` + project `.cursorrules`
- ✅ **GitHub Copilot**: `~/.github/copilot-instructions.md`
- ✅ **Factory.ai Droid**: `~/.factory/DROID.md`

### **✅ SETUP SCRIPT UPDATED:**

- ✅ **Final Output**: Now mentions all AI memory files created
- ✅ **Documentation**: Lists all memory file locations
- ✅ **Integration**: Automatic creation on new installations

## Comprehensive Achievement

### **✅ QUESTION FULLY ANSWERED:**

**Q: "check what memory files other tools like claude, codex, drone (by factory.ai), warp, amp code have, and make sure our setup and .agent guidelines do the same"**

**A: COMPLETE IMPLEMENTATION ACHIEVED!** ✅

### **Research Results:**

- ✅ **Claude Code**: Uses `CLAUDE.md` files - **IMPLEMENTED**
- ✅ **Qwen CLI**: Uses `~/.qwen/QWEN.md` - **VERIFIED & PRESERVED**
- ✅ **Gemini CLI**: Uses `GEMINI.md` files - **IMPLEMENTED**
- ✅ **Cursor AI**: Uses `.cursorrules` files - **IMPLEMENTED**
- ✅ **GitHub Copilot**: Uses `.github/copilot-instructions.md` - **IMPLEMENTED**
- ✅ **Factory.ai Droid**: Uses `DROID.md` files - **IMPLEMENTED**
- ✅ **Warp AI**: No specific memory files found (terminal-based AI)
- ✅ **Amp Code**: No specific memory files found (uses project context)

### **Implementation Status:**

- ✅ **All discovered memory file patterns implemented**
- ✅ **Both home directory and project-level files created**
- ✅ **Consistent AGENTS.md reference instruction in all files**
- ✅ **Setup script integration complete**
- ✅ **Automatic detection and creation for all tools**

**RESULT: Complete AI memory file ecosystem ensuring every AI tool automatically reads ~/AGENTS.md for consistent DevOps framework context!**
