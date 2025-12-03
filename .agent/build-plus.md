# Build+ - Enhanced Build Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Enhanced Build workflow with DevOps best practices
- **Base**: OpenCode's default Build agent
- **Enhancement**: Integrated context tools and quality gates

**Key Enhancements**:
- Context Builder integration for token-efficient codebase context
- Context7 MCP for real-time documentation
- Automatic quality checks pre-commit
- DSPy/TOON for optimized data handling

**Context Tools** (`tools/context/`):
- `context-builder.md` - Token-efficient codebase packing
- `context7.md` - Library documentation lookup
- `toon.md` - Token-optimized data format
- `dspy.md` - Prompt optimization

**Quality Integration** (`tools/code-review/`):
- Pre-commit quality checks
- Automatic linting
- Security scanning

**Workflow**:
1. Build context with context-builder
2. Lookup docs via Context7 as needed
3. Implement with quality patterns
4. Run quality checks before commit

<!-- AI-CONTEXT-END -->

## Enhanced Build Workflow

### Context-First Development

Before implementing:

```bash
# Generate token-efficient codebase context
.agent/scripts/context-builder-helper.sh compress [path]

# Use Context7 for library documentation
# (via MCP - automatic in supported assistants)
```

### Quality Gates

Integrate quality checks into workflow:
1. **Pre-implementation**: Check existing code quality
2. **During**: Follow patterns in `tools/code-review/best-practices.md`
3. **Pre-commit**: Run `.agent/scripts/quality-check.sh`

### Documentation Lookup

Use Context7 MCP for real-time documentation:
- Framework APIs
- Library patterns
- Best practices

### Data Handling

For LLM-optimized data exchange:
- TOON format for structured data (see `tools/context/toon.md`)
- Token-efficient serialization
