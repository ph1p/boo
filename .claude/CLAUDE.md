# Claude Code Configuration

See [AGENTS.md](../AGENTS.md) for full project architecture, conventions, and guidelines.

## Quick Reference
- Build: `swift build` or `make run`
- Zero warnings policy
- All UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
- Settings via `AppSettings.shared` with auto-notification
- Don't add co-authored-by to commits
