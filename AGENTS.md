# AGENTS.md

Tripwire is a macOS tool with one job: make doomscrolling hard. Read `README.md` first, then `docs/DECISIONS.md` before you change the design.

## Build and test
- Build: `swift build`
- Test: `swift run TripwireSelfTest` (an executable target, so no Xcode or XCTest is needed). Every check must print PASS.
- Install and run: `scripts/install.sh` (loads a LaunchAgent). Use `scripts/install.sh --test` for a 30 s window with no block.

## Layout
- `Sources/TripwireCore`: pure logic (rule, sites, keys, logs, SelfControl call). Put new logic here and add a check in `Sources/TripwireSelfTest/main.swift`.
- `Sources/tripwire`: the daemon and macOS glue (event tap, tab reader, gray screen, menu bar).
- `scripts/`: install, uninstall, and the signing certificate.

## Rules
- One job only. Do not add schedules, budgets, dashboards, or rule modes (D1).
- No browser extension (D4). Tripwire detects; SelfControl blocks. Do not build a blocker (D5).
- Privacy: never store characters, keycodes, page content, or full URLs. If you change what the logs record, update the Privacy section of `README.md`.
- A design change gets a new decision at the end of `docs/DECISIONS.md`. Do not delete old ones.
