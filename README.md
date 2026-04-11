# PiScope

A lightweight macOS menu bar app to monitor your [pi coding agent](https://pi.dev) sessions — costs, tokens, models, and projects at a glance.

## Inspirations

- [Bandwidther](https://github.com/simonw/bandwidther) — single-file SwiftUI app built with plain `swiftc`, no Xcode
- [Claudoscope](https://github.com/cordwainersmith/Claudoscope) — session analytics for Claude Code

## What it shows

**Menu bar:** `π $0.42` — today's total spend, updated every 30 seconds.

**Click to open a popover with two panels:**

- **Left — Overview:** activity stats (sessions, messages, tool calls, cache hit rate), cost summary with cache savings, cost-over-time sparkline, top projects by spend, top models by spend. All scoped to a time range you pick: Today / This Week / Last 30 Days / All Time.

- **Right — Sessions:** full session list for the selected range, sortable by recency, cost, duration, or project. Each row shows status (green/red), name, project, model, timestamps, cost, tokens, message counts, tool calls, and duration. Hover a row to see cache details and a delete button.

## Build & run

Requires macOS 14+ (Sonoma) and Swift 5.9+. No Xcode, no package manager.

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o PiScope PiScopeApp.swift
./PiScope
```

PiScope reads pi session files from `~/.pi/agent/sessions/` and never writes to them.
