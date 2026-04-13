# Architecture

## Overview

PiScope is a read-only macOS menu bar app that parses pi coding agent session files and surfaces cost/usage analytics. It never writes to session files.

## Structure

Single file: `PiScopeApp.swift`. No Xcode project, no Package.swift, no dependencies. Build command:

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o PiScope PiScopeApp.swift
```

## Codemap

| Symbol | Role |
|---|---|
| `PiScopeApp` | `@main` entry point, wires `AppDelegate` via `@NSApplicationDelegateAdaptor` |
| `AppDelegate` | Owns `NSStatusItem`, `NSPopover`, `StatsModel`, and the 30s refresh `Timer` |
| `StatsModel` | `ObservableObject` with a single `@Published var stats: AppStats` |
| `loadAppStats()` | Pure function — scans `~/.pi/agent/sessions/**/*.jsonl`, returns `AppStats` |
| `AppStats` | Flat array of `SessionData`, plus helpers to filter by `TimeRange` |
| `SessionData` | One pi session: cost, tokens, model, cache stats, timestamps, file path |
| `RangeStats` | Named struct holding aggregated stats for the active time range |
| `ContentView` | Root SwiftUI view — top bar (time range, Reload, Quit) + two columns |
| `LeftColumnView` | Overview: Activity card, Cost card, sparkline, top projects, top models |
| `RightColumnView` | Session list with sort controls and `SessionRowView` rows |
| `SparklineView` | Bar chart bucketed by the active `TimeRange` (hours/days/weeks/months) |
| `buildSparklinePaths()` | Free function that computes Bezier path geometry (called from `SparklineView`) |
| `SectionCard` | Generic card chrome (title + rounded background) used across the left column |

## Data flow

```
~/.pi/agent/sessions/<project>/<timestamp>_<uuid>.jsonl
         │
         ▼
  loadAppStats()          ← background DispatchQueue, every 30s
         │ AppStats
         ▼
    StatsModel            ← published on main queue
         │ @ObservedObject
         ▼
  ContentView / subviews  ← SwiftUI re-render
         │
         ▼
  statusItem.button.title ← "π $X.XX"
```

## JSONL format

Each session file is newline-delimited JSON. Relevant entry types:

| Type | Fields used |
|---|---|
| `session` | `id`, `cwd`, `timestamp` — identifies the session |
| `session_info` | `name` — user-defined display name (preferred over first user message) |
| `message` (assistant) | `model`, `usage.totalTokens`, `usage.cost.total`, `usage.input`, `usage.cacheRead`, `usage.cacheWrite`, `usage.cost.cacheRead`, `stopReason`, `content[].type == "toolCall"` |
| `message` (user) | First user message text, used as fallback session name |

Project path is derived from `cwd` — the last path component (e.g. `/Users/x/projects/foo` → `"foo"`).

## Key design decisions

**Single file, no Xcode.** Keeps the app hackable and easy to understand. One file = one `swiftc` command.

**No caching, no FSEvents.** Re-parse all session files every 30 s. Files are small (< 100 KB each); 100–200 sessions parse in well under a second. Simpler than incremental cache invalidation.

**`StatsModel` is not `@MainActor`.** Annotating it `@MainActor` caused actor-isolation errors with `AppDelegate` property initialization. Instead, parsing is dispatched to `DispatchQueue.global` and results are pushed back to `DispatchQueue.main` before publishing.

**Model breakdown uses per-session primary model.** Global model stats aggregate `totalCost` per session's `primaryModel` (the model with highest cost weight in that session). True per-message global aggregation would require an extra pass and isn't worth the complexity for this view.

**Sparkline buckets are range-aware.** Today → hourly (24 bars), This Week → daily (7), Last 30 Days → daily (30), All Time → monthly (12). Same `SparklineView` component handles all cases.

**Sort state lives in `RightColumnView`.** Sorting is a pure display concern; it doesn't belong in the model. Sorting 50–200 sessions on every render is negligible.

**Delete via `NSWorkspace.recycle`.** Sessions are moved to Trash (not permanently deleted) so the user can recover them. The file path is stored in `SessionData` for this purpose.

**`buildSparklinePaths()` is a free function, not inline.** SwiftUI’s `@ViewBuilder` does not allow `for` loops that build local values (only `ForEach` views). The Bezier path construction requires imperative loops, so it lives in a plain function called from a `let` binding inside `GeometryReader`.

**`DateFormatter` instances are module-level constants.** `DateFormatter` is expensive to initialise (ICU/locale setup). `sparklineBuckets` is a computed property called on every render; its formatters (`weekdayFmt`, `dayMonthFmt`, `monthFmt`, `shortDateFmt`) are hoisted to module scope to avoid per-bucket allocation.

**Cache savings estimate uses `cacheReadCost × 9`.** Derived from Anthropic’s prompt-cache pricing: cache reads cost ≈10% of the normal input token price, so each dollar paid for a cache read replaces ≈10 dollars of full-price input — a net saving of ≈9× the cost paid. This is Anthropic-specific and approximate; other providers may differ.
