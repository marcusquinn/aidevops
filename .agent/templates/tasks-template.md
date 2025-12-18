# Tasks: {Feature Name}

Based on [ai-dev-tasks](https://github.com/snarktank/ai-dev-tasks) task format.

**PRD:** [prd-{slug}.md](prd-{slug}.md)
**Created:** {YYYY-MM-DD}
**Status:** Not Started | In Progress | Blocked | Complete

## Relevant Files

- `path/to/file1.ts` - {Brief description of why this file is relevant}
- `path/to/file1.test.ts` - Unit tests for file1.ts
- `path/to/file2.ts` - {Brief description}

## Notes

- Unit tests should be placed alongside the code files they test
- Run tests with: `npm test` or `bun test` or project-specific command
- Check off tasks as you complete them by changing `- [ ]` to `- [x]`

## Instructions

**IMPORTANT:** As you complete each task, check it off by changing `- [ ]` to `- [x]`.

Update after completing each sub-task, not just parent tasks.

## Tasks

- [ ] 0.0 Create feature branch
  - [ ] 0.1 Ensure on latest main: `git checkout main && git pull origin main`
  - [ ] 0.2 Create feature branch: `git checkout -b feature/{slug}`

- [ ] 1.0 {First Parent Task}
  - [ ] 1.1 {Sub-task description}
  - [ ] 1.2 {Sub-task description}
  - [ ] 1.3 {Sub-task description}

- [ ] 2.0 {Second Parent Task}
  - [ ] 2.1 {Sub-task description}
  - [ ] 2.2 {Sub-task description}

- [ ] 3.0 {Third Parent Task}
  - [ ] 3.1 {Sub-task description}
  - [ ] 3.2 {Sub-task description}

- [ ] 4.0 Testing
  - [ ] 4.1 Write unit tests for new functionality
  - [ ] 4.2 Run full test suite and fix failures
  - [ ] 4.3 Manual testing of feature

- [ ] 5.0 Documentation
  - [ ] 5.1 Update relevant documentation
  - [ ] 5.2 Add code comments where needed
  - [ ] 5.3 Update CHANGELOG.md

- [ ] 6.0 Quality & Review
  - [ ] 6.1 Run linters: `.agent/scripts/linters-local.sh`
  - [ ] 6.2 Self-review code changes
  - [ ] 6.3 Commit with descriptive message
  - [ ] 6.4 Push branch and create PR

## Completion Checklist

Before marking this task list complete:

- [ ] All tasks checked off
- [ ] Tests passing
- [ ] Linters passing
- [ ] Documentation updated
- [ ] CHANGELOG.md updated
- [ ] PR created and ready for review
