#!/bin/bash
# Bundle the MCP server into a single self-contained JS file and copy it into the
# app bundle at Contents/Resources/mcp/mcp.js. Runs as an Xcode build phase so the
# DMG ships with the MCP server inside — colleagues just point `claude mcp add` at
# the in-app path (no clone / npm install / build needed). See README.
set -euo pipefail

# When run by Xcode, SRCROOT points at the project dir; fall back for manual runs.
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TOOLS="$ROOT/tools"

# Where the built .app is. Xcode sets these; provide a sane default for CLI runs.
APP_RESOURCES="${BUILT_PRODUCTS_DIR:-}/${CONTENTS_FOLDER_PATH:-StackBar.app/Contents}/Resources"

if [ ! -d "$TOOLS/node_modules" ]; then
  echo "warning: tools/node_modules missing — running npm install"
  ( cd "$TOOLS" && npm install )
fi

# Build the self-contained bundle (esbuild inlines the deps; no node_modules at runtime).
( cd "$TOOLS" && npm run bundle:mcp )

mkdir -p "$APP_RESOURCES/mcp"
cp "$TOOLS/dist/mcp.bundle.js" "$APP_RESOURCES/mcp/mcp.js"
chmod +x "$APP_RESOURCES/mcp/mcp.js"
echo "Bundled MCP server -> $APP_RESOURCES/mcp/mcp.js"
