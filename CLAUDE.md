# Boo — notes for Claude Code

[AGENTS.md](AGENTS.md) covers architecture, build commands, project structure
and conventions. Read it first. This file adds working rules.

## Working rules

- Ask about scope before implementing: a pointer, or the full change? Library
  author or consumer view? When the user only wants validation, give that.
- New state: ask whether it is global (`AppSettings`) or per tab (`TabState`)
  before writing it.
- Bug fixes: check the surrounding behavior for regressions. After 3 failed
  attempts at one approach, stop and propose another.
- Use pnpm, never npm or npx.
- Shell scripts must run on bash 3.2: no associative arrays, no bash 4+ features.
- Before removing a Swift memberwise initializer, grep the whole project for
  its signature. swift-format hooks can silently revert manual edits.

## Running a dev build

`make build` produces `.build/debug/Boo.app`. It shares the bundle ID,
settings, `~/.boo/session.json` and `~/.boo/run/` with an installed Boo; only
the socket differs (`~/.boo/boo-dev.sock`).

- Never `pkill Boo` or `killall Boo`: it also kills the installed app. Stop
  the dev build by PID.
- Quitting the dev build saves its session over the real one. Back up
  `~/.boo/session.json` first when that matters.

## Before commit and push (in this order)

1. Format: `swift-format format --in-place --recursive Boo/ BooApp/ Tests/`
2. Lint: `make lint` must be clean (the CI Lint job).
3. Test: `make test` must report 0 failures (the CI Build & Test job).
4. Commit in conventional style (`type(scope): subject`), with no attribution.
   Then `git push`.
5. Check CI with `gh run list --limit 3`. On failure, read
   `gh run view <id> --log-failed`, fix the cause, and repeat steps 1-4.

CI skips every job, release included, when the newest pushed commit starts
with `chore` or `docs`. Push a `feat`/`fix` commit last if it should release.

A local pass does not guarantee a CI pass. CI runs with default
`AppSettings`, but local tests read your real settings (for example
`sidebarGlobalState`). A test that depends on a setting must pin it and
restore it in a `defer`.
