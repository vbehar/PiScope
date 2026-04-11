# AGENTS.md

PiScope is a single-file macOS menu bar app (`PiScopeApp.swift`) that reads pi coding agent session files from `~/.pi/agent/sessions/` and displays cost/usage analytics. It never writes to those files.

## Build

```bash
swiftc -parse-as-library -framework SwiftUI -framework AppKit -o PiScope PiScopeApp.swift
./PiScope
```

Requires macOS 14+ and Swift 5.9+. No Xcode, no Package.swift, no dependencies.

## Key constraints

- **One file only.** Do not split into multiple files or introduce a package manifest.
- **No Xcode project.** The build command above is the only build system.
- **Read-only.** PiScope must never write to session files under `~/.pi/agent/sessions/`. The only write operation allowed is `NSWorkspace.recycle` (move to Trash) on an explicit user action.
- **macOS 14+ APIs only.** Don't use deprecated AppKit/SwiftUI APIs.

## Where things are

See [ARCHITECTURE.md](ARCHITECTURE.md) for the codemap, data flow, JSONL format, and design decisions.
