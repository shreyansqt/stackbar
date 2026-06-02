# StackBar

A lightweight native macOS menu bar app for running and monitoring your local dev
services — start/stop/restart each process, see at a glance whether it's healthy
(process alive + TCP port open), and read its logs. Built in Swift with SwiftUI's
`MenuBarExtra`, no Dock icon (`LSUIElement`).

Ships with a CLI and an MCP server so Claude Code sessions (or any terminal) can
read service logs on demand.

## Layout

```
StackBar/
  project.yml              XcodeGen spec — source of truth for the Xcode project
  Sources/                 Swift app
    StackBarApp.swift       @main, MenuBarExtra + windows
    Service.swift           service model + status enum
    ServiceManager.swift    owns runners, persistence, 2s health timer
    RunningService.swift    one process: spawn, log capture, status
    LogStore.swift          on-disk log layout + file writer
    PortProbe.swift         non-blocking TCP connect health check
    MenuBarView.swift       the dropdown
    SettingsView.swift      add/edit/delete services
    LogWindowView.swift     live in-app log tail
  tools/                   TypeScript CLI + MCP server (read-only log access)
    src/store.ts            shared reader (mirrors LogStore layout)
    src/cli.ts              `stackbar` CLI
    src/mcp.ts              `stackbar-mcp` MCP server
```

## Data location

Everything lives under `~/Library/Application Support/StackBar/`:

- `services.json` — the service registry (name, dir, command, port)
- `logs/<id>.log` — per-service log, keyed by service UUID (survives renames)
- `logs/<id>.meta.json` — name/command/dir, so the CLI/MCP work without the app running

## Build the app

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate          # project.yml -> StackBar.xcodeproj
open StackBar.xcodeproj     # then Cmd-R in Xcode
```

Or from the CLI:

```sh
xcodebuild -project StackBar.xcodeproj -scheme StackBar -configuration Debug \
  -derivedDataPath ./build build CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/StackBar.app
```

## CLI + MCP tools

```sh
cd tools
npm install
npm run build
```

### CLI

```sh
node dist/cli.js list                       # services + log status
node dist/cli.js logs <service> [-n N] [-f] # tail N lines (default 200), -f to follow
node dist/cli.js search <service> <pattern> # grep; --regex, --ignore-case
```

`<service>` matches by exact id, exact name, or partial name (case-insensitive).

### MCP server

Register once at user scope so every Claude Code session can read logs:

```sh
claude mcp add stackbar --scope user -- node /absolute/path/to/tools/dist/mcp.js
```

Tools exposed: `list_services`, `get_logs`, `search_logs`.

> Note: `tools/dist/` is gitignored. After cloning, run `npm install && npm run build`
> in `tools/` before the CLI or MCP server will work.

## Status

V1. Health = process alive + TCP port check. Logs are captured to disk and shown
live in-app. No dependency ordering between services yet (planned).

## License

MIT — see [LICENSE](LICENSE).
