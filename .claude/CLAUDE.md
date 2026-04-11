# Claude Code Configuration

See [AGENTS.md](../AGENTS.md) for project architecture, build commands, structure, and conventions.

## Behavioral Rules

- Don't add co-authored-by to commits
- Use pnpm, never npm/npx
- Before implementing, ask clarifying questions about scope (guidance vs full implementation, library author vs consumer perspective). Don't over-help when the user just wants validation.
- When fixing bugs, verify no regressions in surrounding functionality. If an approach fails 3 times, stop and propose an alternative.
- Always clarify whether new state should be global (`AppSettings`) or per-instance (`TabState`) BEFORE implementing. Default to asking if unclear.
- Don't remove Swift memberwise initializers without a project-wide grep for the init signature. swift-format hooks may silently revert manual changes.
- Shell scripts must be compatible with bash 3.2 (no associative arrays, no bash 4+ features).
