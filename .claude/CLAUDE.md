# Claude Code Configuration

See [AGENTS.md](../AGENTS.md) for project architecture and conventions.
Full docs: https://ph1p.github.io/boo/

## Build

```bash
make setup    # First time: clone Ghostty + build GhosttyKit + build Boo
make run      # Build and launch
make test     # Run tests
make lint     # Check code style
make format   # Format code in-place
```

## Rules

- Zero warnings policy
- All UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
- Settings via `AppSettings.shared` with auto-notification
- Don't add co-authored-by to commits
- Use `RemoteExplorer.shellEscPath()` (not `shellEscape()`) for remote paths
