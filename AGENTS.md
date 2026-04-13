# AGENTS.md

PiScope is a single-file macOS menu bar app (`PiScopeApp.swift`) that reads pi coding agent session files from `~/.pi/agent/sessions/` and displays cost/usage analytics. It never writes to those files.

For user-facing documentation (features, how it works, metrics, limitations) see [README.md](README.md).

## Build

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o PiScope PiScopeApp.swift
./PiScope
```

## Key constraints

- **One file only.** Do not split into multiple files or introduce a package manifest.
- **No Xcode project.** The build command above is the only build system.
- **Read-only.** PiScope must never write to session files under `~/.pi/agent/sessions/`. The only write operation allowed is `NSWorkspace.recycle` (move to Trash) on an explicit user action.
- **macOS 14+ APIs only.** Don't use deprecated AppKit/SwiftUI APIs.
- **No tests.** There is no XCTest target and no `swift test` setup. Do not attempt to add or run tests without first explicitly setting up a test harness.

## Key symbols (approximate line numbers may shift as code changes)

| Symbol | Kind | Role |
|--------|------|------|
| `PiScopeApp` | struct | `@main` entry point |
| `AppDelegate` | class | Owns `NSStatusItem`, `NSPopover`, 30 s refresh timer |
| `StatsModel` | class | `ObservableObject` wrapping `AppStats` |
| `loadAppStats()` | func | Pure parser — scans all JSONL files, returns `AppStats` |
| `AppStats` | struct | Flat `[SessionData]` + `filteredSessions(for:)` helper |
| `SessionData` | struct | One session: cost, tokens, model, cache stats, file path |
| `RangeStats` | struct | Aggregated stats for the selected time range (used by `LeftColumnView`) |
| `ContentView` | view | Root: top bar + two-column layout |
| `LeftColumnView` | view | Overview column: activity, cost, sparkline, top projects/models |
| `RightColumnView` | view | Session list with sort controls |
| `SparklineView` | view | Bezier-curve area chart; uses `buildSparklinePaths()` helper |
| `buildSparklinePaths()` | func | Computes `Path` geometry outside `@ViewBuilder` (for-loops not allowed inline) |
| `SectionCard` | view | Generic card chrome used in left column |
| `SessionRowView` | view | One row in the session list; delete on hover |
| `TimeRange` | enum | Today / This Week / Last 30 Days / All Time |

`MARK:` sections in the file: App Entry Point, AppDelegate, Observable Stats Model, Data Models, JSONL Parser, Time Range, Formatters, Root Content View, Left Column, Right Column.

## Known limitations & tech debt

- **`rangeStats` is a named struct (`RangeStats`) but started as a tuple** — if fields need adding, extend `RangeStats`.
- **Empty-state UI is minimal** — shows a simple message; not a full onboarding flow.

See [README.md § Known limitations](README.md#known-limitations) for user-facing limitations (no incremental parsing, Anthropic-specific cache savings formula, etc.).

## Where things are

See [ARCHITECTURE.md](ARCHITECTURE.md) for the codemap, data flow, JSONL format, and design decisions.
