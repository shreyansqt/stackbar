# StackBar

A lightweight native macOS menu bar app for running and monitoring your local dev
services — start/stop each process, see at a glance how healthy your stack is, and
read each command's logs. Built in Swift with AppKit (`NSStatusItem` + `NSMenu`)
and SwiftUI; menu-bar-only, no Dock icon (`LSUIElement`).

Services are configured by `.stackbar.json` files that live **in your repos**, not
in the app — point StackBar at a workspace folder and it discovers them. Ships with
a `stackbar` CLI and an MCP server so any terminal or Claude Code session can drive
services and read their logs.

By [Shreyans Jain](https://shreyans.co) · hi@shreyans.co

## How it works

1. Each service has a **`.stackbar.json`** in its own folder (the folder is the
   service's working directory).
2. You add one or more **workspace folders** to StackBar (e.g. `~/work`).
3. StackBar **recursively scans** each workspace for `.stackbar.json` files
   (pruning `node_modules`, `.git`, `dist`, … and depth-capped) and lists those
   services. "Refresh Services" re-scans on demand.

### `.stackbar.json` format (JSONC — comments + trailing commas allowed)

```jsonc
{
  // Name shown in the StackBar menu.
  "name": "smarta-accounts",
  // Command(s) to start the service, run in order, each as its own process.
  "commands": ["pnpm dev"],
  // Optional: command(s) run on Stop, after the start processes are terminated
  // (e.g. a docker teardown). Run only after the start processes have exited.
  "stopCommands": ["docker compose down"],
  // Optional: TCP port to health-check (green when it accepts connections).
  "port": 8790
}
```

One file = one service. A repo with several apps has one `.stackbar.json` per app
folder. Keep these out of a shared repo with `.git/info/exclude` if the tool is
personal.

## The menu

- **Menu bar glyph** reflects overall state: a stacked-layers icon whose brightness
  scales with the fraction of services running (40%→100%), a **spinner** while
  anything is starting/stopping, a **checkmark** flash when everything comes up, and
  an **exclamation triangle** if something crashed.
- **Each service** opens a submenu: a Start/Stop toggle, a **Status** section
  (`Running on port 8791 · 4m`, plus Open in Browser), and **Start/Stop commands**
  sections — each command opens its own isolated log (enabled once it has output).
- Footer: **Start All / Stop All / Refresh Services / Workspaces… / Quit**.

Logs render in a native `NSTextView` console with ANSI color (servers are launched
with `FORCE_COLOR`), a line-number gutter, and ⌘F find.

## Data location

Everything lives under `~/Library/Application Support/StackBar/`:

- `workspaces.json` — the workspace folders you track
- `logs/<id>.log` — combined per-service log (id is derived from the folder path)
- `logs/<id>.<n>.log`, `logs/<id>.stop.<n>.log` — per start/stop-command logs
- `stackbar.log` — StackBar's own diagnostic log (spawns, stop commands, errors)
- `control.port` / `control.token` — the local control server's address + auth

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
cd tools && npm install && npm run build
```

The app runs a localhost-only HTTP control server (token-authed); the CLI and MCP
are thin clients of it. Service **actions** need the app running; **log reads** work
straight from the log files regardless.

### CLI (`stackbar`)

```sh
stackbar list                          # services + live status
stackbar start|stop|restart <svc|all>  # control a service (or all)
stackbar rescan                        # re-scan workspaces for .stackbar.json
stackbar workspaces                    # list workspace folders
stackbar add-workspace <folder>        # track a folder
stackbar logs <svc> [-n N] [-f] [--cmd N]   # tail logs (--cmd N = one command's log)
stackbar search <svc> <pattern> [--regex] [--ignore-case]
```

`<svc>` matches by exact id, exact name, or partial name (case-insensitive).
`npm link` in `tools/` to put `stackbar` on your PATH.

### MCP server

Register once at user scope so every Claude Code session can use it:

```sh
claude mcp add stackbar --scope user -- node /absolute/path/to/tools/dist/mcp.js
```

Tools: `list_services`, `start_service`, `stop_service`, `restart_service`,
`rescan_services`, `list_workspaces`, `add_workspace`, `get_logs`, `search_logs`.

> Note: `tools/dist/` is gitignored. After cloning, run `npm install && npm run build`
> in `tools/` before the CLI or MCP server will work.

## Notable behaviors

- **Process cleanup**: each spawned command runs in its own process group and is
  tagged `STACKBAR_MANAGED`. On quit, all services are terminated; on launch, any
  orphans left by a previous instance (which reparent to launchd) are swept, so
  dev-server processes don't accumulate across relaunches.
- **Container-safe**: the port-based kill backstop refuses to kill container
  runtimes (OrbStack/Docker/containerd), so stopping a docker-backed service can't
  wedge the daemon.
- **Health**: a service is green when its process is alive and (if a port is set)
  the port accepts connections — checked over both IPv4 and IPv6 (some dev servers
  bind IPv6-only).

## Status

Config lives in repo `.stackbar.json` files, discovered via workspace scanning.
No dependency ordering between services yet.

## Author

[Shreyans Jain](https://shreyans.co) — hi@shreyans.co

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Shreyans Jain.
