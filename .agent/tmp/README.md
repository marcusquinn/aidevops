# AI Assistant Temporary Working Directory

This directory is designated for AI assistants to use for temporary files, scripts, and working data during operations.

## 🎯 **Purpose**

AI assistants should use this directory for:
- **Temporary scripts** created during operations
- **Working files** that need to be processed
- **Intermediate data** during multi-step operations
- **Backup files** before making changes
- **Log files** from operations
- **Analysis outputs** and reports

## 📋 **Usage Guidelines**

### **✅ DO Use This Directory For:**
- Any temporary files created during AI operations
- Scripts generated for one-time use
- Working copies of files being modified
- Temporary backups before making changes
- Log outputs from commands and operations
- Analysis results and intermediate data

### **❌ DON'T Use This Directory For:**
- Permanent files or configurations
- User-facing documentation
- Production scripts or tools
- Long-term storage of important data

## 🧹 **Cleanup Policy**

- **Automatic cleanup**: Files older than 7 days may be automatically removed
- **Manual cleanup**: AI assistants should clean up their own temporary files when operations complete
- **Gitignore**: This directory is ignored by Git to prevent temporary files from being committed

## 📁 **Recommended Structure**

```
.agent/tmp/
├── session-{timestamp}/     # Per-session working directories
├── backups/                 # Temporary backups
├── logs/                    # Operation logs
├── analysis/                # Analysis outputs
└── scripts/                 # Temporary scripts
```

## 🔧 **Example Usage**

```bash
# Create a session-specific working directory
mkdir -p .agent/tmp/session-$(date +%Y%m%d_%H%M%S)

# Create temporary backup before modifications
cp important-file.sh .agent/tmp/backups/important-file.sh.bak

# Generate temporary analysis script
cat > .agent/tmp/scripts/analyze-logs.sh << 'EOF'
#!/bin/bash
# Temporary script for log analysis
EOF

# Clean up after operations
rm -rf .agent/tmp/session-*
```

This directory enables AI assistants to work efficiently while keeping the main repository clean and organized.
