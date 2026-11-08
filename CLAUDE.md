# Claude Code Configuration

See [AGENTS.md](AGENTS.md) for project architecture, build commands, structure, and conventions.

## Behavioral Rules

- Use pnpm, never npm/npx
- Before implementing, ask clarifying questions about scope (guidance vs full implementation, library author vs consumer perspective). Don't over-help when the user just wants validation.
- When fixing bugs, verify no regressions in surrounding functionality. If an approach fails 3 times, stop and propose an alternative.
- Always clarify whether new state should be global (`AppSettings`) or per-instance (`TabState`) BEFORE implementing. Default to asking if unclear.
- Don't remove Swift memberwise initializers without a project-wide grep for the init signature. swift-format hooks may silently revert manual changes.
- Shell scripts must be compatible with bash 3.2 (no associative arrays, no bash 4+ features).

## Before Commit & Push (mandatory, in this order)

1. Format: `swift-format format --in-place --recursive Boo/ BooApp/ Tests/`
2. Lint: `make lint` must be clean (same as the CI Lint job).
3. Test: `make test` must report 0 failures (same as the CI Build & Test job).
4. Only then commit (conventional style, no attribution) and `git push`.
5. After pushing, check CI: `gh run list --limit 3`. If it fails, read
   `gh run view <id> --log-failed`, fix the cause, and repeat steps 1-4.

Local passes don't guarantee CI passes. CI runs with default `AppSettings`,
but local tests read your real settings (e.g. `sidebarGlobalState`). A test
that depends on a setting must pin it and restore it in a `defer`.
