---
name: setup-stackbar
description: Install and configure StackBar — a macOS menu-bar app for managing local dev services. StackBar discovers services from .stackbar.json files in your repos, shows live status in the menu bar, and exposes an MCP server so your AI agents can start/stop services and read logs. macOS only.
---

# setup-stackbar

Install StackBar and wire it into your agent tooling. StackBar is a native macOS
menu-bar app that:

- Discovers services from `.stackbar.json` files in your workspace repos
- Shows live status (running/stopped/crashed) in the menu bar
- Starts/stops services with one click
- Exposes an MCP server so your AI agents can manage services and read logs

**macOS only.** StackBar is a native Swift app (macOS 14.0+). On other platforms,
skip this skill.

## Configuration

- **StackBar DMG URL**: resolved dynamically from the latest GitHub release.
  The repo is public at `github.com/shreyansqt/stackbar` (MIT-licensed). No API
  token needed for public repos.

## Tools

- `bash` for running commands, `Read` for checking files, `Write` for writing config.
- The `stackbar` MCP tools (after installation) for verifying the setup.

## Steps

### 1. Check if StackBar is already installed

Look for the app bundle:

```bash
ls /Applications/StackBar.app/Contents/Resources/mcp/mcp.js 2>/dev/null
```

If it exists, StackBar is installed. Skip to step 3.

If the app exists but the MCP bundle is missing, it's an older version — prompt the
user to update.

### 2. Install StackBar

Download the latest DMG and open it:

```bash
DMG_URL=$(curl -s https://api.github.com/repos/shreyansqt/stackbar/releases/latest \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['assets'][0]['browser_download_url'])")
curl -L -o /tmp/StackBar.dmg "$DMG_URL"
open /tmp/StackBar.dmg
```

This opens the DMG in Finder. Tell the user:
> "Drag StackBar.app to the Applications folder, then launch it from there.
> The first launch may require right-click → Open to bypass Gatekeeper."

Wait for confirmation that the app is installed and running before continuing.

### 3. Add workspace folders

StackBar discovers services by scanning workspace folders for `.stackbar.json` files.
Ask the user which folders contain their project repos (e.g. `~/work`, `~/projects`).

If StackBar is running, use the MCP tools:

```
mcp__stackbar__add_workspace { "path": "<folder>" }
```

Repeat for each folder the user wants scanned. If the MCP is not yet available, use
the StackBar CLI instead:

```bash
stackbar add-workspace <folder>
```

If neither is available, tell the user to add folders through the menu bar app:
- Click the StackBar icon → Preferences → Workspaces → Add Folder

StackBar will scan these folders recursively for `.stackbar.json` files and discover
all services.

### 4. Register the MCP server

Register the StackBar MCP server in the user's agent tool. The MCP server is bundled
inside the app at `/Applications/StackBar.app/Contents/Resources/mcp/mcp.js`. No
`npm install` needed.

#### Claude Code

Add to `~/.claude.json` under `mcpServers`:

```json
"stackbar": {
  "args": ["/Applications/StackBar.app/Contents/Resources/mcp/mcp.js"],
  "command": "node",
  "type": "stdio"
}
```

Or use the CLI: `claude mcp add stackbar --scope user -- node /Applications/StackBar.app/Contents/Resources/mcp/mcp.js`

#### OpenCode

Add to the OpenCode MCP config:

```json
{
  "mcpServers": {
    "stackbar": {
      "command": "node",
      "args": ["/Applications/StackBar.app/Contents/Resources/mcp/mcp.js"]
    }
  }
}
```

#### Cursor / Codex

These use the same MCP JSON format. Add the same block to their respective MCP
config files (typically `~/.cursor/mcp.json` or `~/.codex/mcp.json`).

#### Strategy

Detect which agent tools the user has configured:
- Check `~/.claude.json` for Claude Code
- Check `~/.opencode/` for OpenCode
- Ask the user which tools they use if unsure

For each tool found, add the MCP server configuration. If the tool's config file
doesn't exist, create it with just the StackBar entry.

### 5. Wire instruction files

Add a StackBar section to the user's agent instructions so agents know to use it.
Add to the workspace `AGENTS.override.md` (or `CLAUDE.local.md`):

```markdown
## StackBar

Always run local services through StackBar, not raw dev commands.
Use the `stackbar` MCP tools to start, stop, and check service status.
```

If the user already has a StackBar section, skip this. If they have conflicting
instructions (e.g. "run `pnpm dev` directly"), update them.

### 6. Keep `.stackbar.json` out of git tracking

`.stackbar.json` files are personal config — they should not be committed to team
repos. Add them to git exclude so local changes are never tracked:

```bash
# For each repo that has a .stackbar.json:
echo ".stackbar.json" >> <repo>/.git/info/exclude
```

This is per-repo, per-machine. The exclude file is like `.gitignore` but local-only
(never committed).

### 7. Verify

1. Confirm StackBar is running: `stackbar list` or `mcp__stackbar__list_services`
2. Confirm services are discovered — the list should match the `.stackbar.json` files
   in the added workspace folders
3. If services are missing, run `mcp__stackbar__rescan_services`

Report:
- StackBar: installed and running
- MCP server: registered for [tool names]
- Services discovered: N services
- Instruction files: updated

### 8. Quick start

Show the user what they can do now:

- **Menu bar**: click the StackBar icon to see all services and start/stop them
- **MCP**: agents can now call `list_services`, `start_service`, `stop_service`,
  `get_logs`, `search_logs`
- **CLI**: `stackbar start <name>`, `stackbar logs <name>`, etc.

## Notes

- **StackBar is optional.** Your repos' dev commands work fine without it. StackBar
  is a convenience layer — one place to manage services instead of multiple terminal
  windows.
- **macOS only.** StackBar is a native Swift app. There is no Linux or Windows
  version.
- **The MCP server ships inside the app.** No separate install, no `npm install`.
  Updating StackBar updates the MCP server automatically.
- **Workspace folders are persisted** in `~/Library/Application Support/StackBar/workspaces.json`.
  They survive app restarts and machine reboots.
- **Logs live at** `~/Library/Application Support/StackBar/logs/<service-id>/`.
  The MCP `get_logs` and `search_logs` tools read these directly.