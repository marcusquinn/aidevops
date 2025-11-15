# TOON Format Integration - AI DevOps Framework

**Token-Oriented Object Notation (TOON)** - Compact, human-readable, schema-aware JSON for LLM prompts.

## 🎯 **Overview**

TOON is a revolutionary data format designed specifically for Large Language Models (LLMs), offering:

- **20-60% token reduction** compared to JSON
- **Human-readable tabular format** for structured data
- **Schema-aware** with explicit array lengths and field headers
- **Better LLM comprehension** and generation accuracy
- **Supports nested structures** and mixed data types

## 🚀 **Quick Start**

### **Installation**

TOON CLI is automatically available through npx (no installation required):

```bash
# Test TOON CLI
npx @toon-format/cli --help

# Or use the AI DevOps helper
./providers/toon-helper.sh info
```

### **Basic Usage**

```bash
# Convert JSON to TOON
./providers/toon-helper.sh encode data.json output.toon

# Convert TOON back to JSON
./providers/toon-helper.sh decode output.toon restored.json

# Show token efficiency comparison
./providers/toon-helper.sh compare large-dataset.json

# Validate TOON format
./providers/toon-helper.sh validate data.toon
```

## 📊 **Format Examples**

### **Simple Object**
```json
{"id": 1, "name": "Alice", "active": true}
```
**TOON:**
```toon
id: 1
name: Alice
active: true
```

### **Tabular Data (Most Efficient)**
```json
{
  "users": [
    {"id": 1, "name": "Alice", "role": "admin"},
    {"id": 2, "name": "Bob", "role": "user"}
  ]
}
```
**TOON:**
```toon
users[2]{id,name,role}:
  1,Alice,admin
  2,Bob,user
```

### **Nested Structures**
```json
{
  "project": {
    "name": "AI DevOps",
    "metrics": [
      {"date": "2025-01-01", "users": 100},
      {"date": "2025-01-02", "users": 150}
    ]
  }
}
```
**TOON:**
```toon
project:
  name: AI DevOps
  metrics[2]{date,users}:
    2025-01-01,100
    2025-01-02,150
```

## 🛠️ **Helper Script Commands**

### **File Conversion**

```bash
# Basic conversion
./providers/toon-helper.sh encode input.json output.toon

# With tab delimiter (often more efficient)
./providers/toon-helper.sh encode input.json output.toon '\t' true

# Decode with lenient validation
./providers/toon-helper.sh decode input.toon output.json false
```

### **Batch Processing**

```bash
# Convert directory of JSON files to TOON
./providers/toon-helper.sh batch ./json-files ./toon-files json-to-toon

# Convert directory of TOON files to JSON
./providers/toon-helper.sh batch ./toon-files ./json-files toon-to-json '\t'
```

### **Stream Processing**

```bash
# Convert from stdin
cat data.json | ./providers/toon-helper.sh stdin-encode
echo '{"name": "test"}' | ./providers/toon-helper.sh stdin-encode '\t' true

# Decode from stdin
cat data.toon | ./providers/toon-helper.sh stdin-decode
```

## 🎯 **AI DevOps Use Cases**

### **1. Configuration Data**
Perfect for server configurations, deployment settings, and infrastructure data:

```bash
# Convert server inventory to TOON for AI analysis
./providers/toon-helper.sh encode servers.json servers.toon '\t' true
```

### **2. API Response Formatting**
Reduce token costs when sending API responses to LLMs:

```bash
# Convert API responses for efficient LLM processing
curl -s "https://api.example.com/data" | ./providers/toon-helper.sh stdin-encode
```

### **3. Database Exports**
Efficient format for database query results:

```bash
# Export database results in TOON format
mysql -e "SELECT * FROM users" --json | ./providers/toon-helper.sh stdin-encode '\t'
```

### **4. Log Analysis**
Structure log data for AI analysis:

```bash
# Convert structured logs to TOON
./providers/toon-helper.sh batch ./logs/json ./logs/toon json-to-toon
```

## 📈 **Token Efficiency**

TOON provides significant token savings, especially for tabular data:

| Data Type | JSON Tokens | TOON Tokens | Savings |
|-----------|-------------|-------------|---------|
| Employee Records | 126,860 | 49,831 | 60.7% |
| Time Series | 22,250 | 9,120 | 59.0% |
| GitHub Repos | 15,145 | 8,745 | 42.3% |
| E-commerce Orders | 108,806 | 72,771 | 33.1% |

## 🔧 **Configuration**

Copy and customize the configuration template:

```bash
cp configs/toon-config.json.txt configs/toon-config.json
# Edit with your preferences
```

Key configuration options:
- **default_delimiter**: Choose between `,`, `\t`, or `|`
- **key_folding**: Enable path compression for nested data
- **batch_processing**: Configure concurrent conversions
- **ai_prompts**: Optimize for LLM interactions

## 🤖 **LLM Integration**

### **Sending TOON to LLMs**
```markdown
Data is in TOON format (2-space indent, arrays show length and fields):

```toon
users[3]{id,name,role,lastLogin}:
  1,Alice,admin,2025-01-15T10:30:00Z
  2,Bob,user,2025-01-14T15:22:00Z
  3,Charlie,user,2025-01-13T09:45:00Z
```

Task: Return only users with role "user" as TOON.
```

### **Generating TOON from LLMs**
- Show expected header format: `users[N]{id,name,role}:`
- Specify rules: 2-space indent, no trailing spaces, [N] matches row count
- Request code block output only

## 🔍 **Validation & Quality**

```bash
# Validate TOON format
./providers/toon-helper.sh validate data.toon

# Compare efficiency
./providers/toon-helper.sh compare large-dataset.json

# Show format information
./providers/toon-helper.sh info
```

## 📚 **Resources**

- **Official Website**: https://toonformat.dev
- **GitHub Repository**: https://github.com/toon-format/toon
- **Specification**: https://github.com/toon-format/toon/blob/main/spec.md
- **Benchmarks**: https://github.com/toon-format/toon#benchmarks
- **TypeScript SDK**: `npm install @toon-format/toon`

## 🛡️ **Security & Best Practices**

- **Validate input**: Always validate TOON data before processing
- **Use strict mode**: Enable strict validation for production use
- **Backup originals**: Keep JSON backups when converting
- **Test conversions**: Verify round-trip conversion accuracy
- **Monitor token usage**: Track actual token savings in your use case

---

**Integration Status**: ✅ **Fully Integrated** with AI DevOps Framework  
**Maintenance**: Automated updates via npm/npx  
**Support**: Community-driven with active development
