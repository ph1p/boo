# Claude Code Configuration

See [AGENTS.md](../AGENTS.md) for full project architecture, conventions, and guidelines.
See [README.md](../README.md) for build instructions and feature overview.

## Quick Reference

### Build
```bash
make setup    # First time: clone Ghostty + build GhosttyKit + build Exterm
make run      # Build and launch
make test     # Run 142 tests
swift build   # Build only (requires GhosttyKit already built)
```

### GhosttyKit rebuild (after updating Vendor/ghostty)
```bash
make clean-ghostty
make ghostty
```

### Rules
- Zero warnings policy
- All UI on main thread (PTY reads are background GCD)
- Use `TerminalColor.cgColor`/`.nsColor` extensions, not inline conversions
- Settings via `AppSettings.shared` with auto-notification
- Don't add co-authored-by to commits
- Safe screen access via `screenRead`/`screenWrite` helpers in VT100Terminal
