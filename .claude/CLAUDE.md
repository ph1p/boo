# Claude Code Configuration

See [AGENTS.md](../AGENTS.md) for full project architecture, conventions, and guidelines.
See [README.md](../README.md) for build instructions and feature overview.

## Quick Reference

### Build
```bash
make setup    # First time: clone Ghostty + build GhosttyKit + build Exterm
make run      # Build and launch
make test     # Run 702 tests
swift build   # Build only (requires GhosttyKit already built)
make lint     # Check code style (swift-format)
make format   # Format code in-place
make app      # Create .app bundle (after make release)
make dmg      # Create distributable DMG
make dist     # Full release: build + bundle + sign + notarize + DMG
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
- Use `RemoteExplorer.shellEscPath()` (not `shellEscape()`) for any path sent to a remote terminal — preserves tilde expansion
