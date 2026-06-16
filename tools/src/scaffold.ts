import { existsSync, writeFileSync } from "node:fs";
import { join, resolve, basename } from "node:path";

/** Options for scaffolding a `.stackbar.json`. */
export interface InitOptions {
  dir?: string;
  name?: string;
  commands?: string[];
  stopCommands?: string[];
  port?: number;
  force?: boolean;
}

export interface InitResult {
  file: string;
  name: string;
  /** True when no commands were given and a placeholder was written. */
  placeholder: boolean;
}

/** Quote a string for embedding in a JSON array literal. */
function jstr(s: string): string {
  return JSON.stringify(s);
}

/**
 * Render the commented JSONC body for a `.stackbar.json`. Kept hand-editable and
 * matching the format the scanner parses (JSONC.swift): name, commands[],
 * optional stopCommands[], optional port.
 */
export function renderConfig(opts: {
  name: string;
  commands: string[];
  stopCommands: string[];
  port?: number;
}): string {
  const cmdLines = opts.commands.length
    ? opts.commands.map(jstr).join(", ")
    : jstr("echo 'replace me: your start command'");
  const stopLine =
    opts.stopCommands.length > 0
      ? `\n\n  // Optional: command(s) run when you Stop the service (e.g. docker teardown).\n  "stopCommands": [${opts.stopCommands.map(jstr).join(", ")}],`
      : "";
  const portLine =
    opts.port !== undefined
      ? `\n\n  // Optional: TCP port to health-check (green when it's accepting connections).\n  "port": ${opts.port},`
      : `\n\n  // Optional: TCP port to health-check (green when it's accepting connections).\n  // "port": 3000,`;

  return `{
  // StackBar service config. This file is read by the StackBar menu-bar app.
  // Lives in this folder; the folder IS the service's working directory.

  // Name shown in the StackBar menu.
  "name": ${jstr(opts.name)},

  // Command(s) to start the service, run in order, each in its own process.
  "commands": [${cmdLines}],${stopLine}${portLine}
}
`;
}

/**
 * Write a `.stackbar.json` into the target folder. Throws if a file already
 * exists and `force` is not set. Does NOT rescan — callers trigger that.
 */
export function writeConfig(opts: InitOptions): InitResult {
  const dir = resolve(opts.dir ?? ".");
  const file = join(dir, ".stackbar.json");
  if (existsSync(file) && !opts.force) {
    throw new Error(`${file} already exists. Use force to overwrite.`);
  }
  const name = opts.name ?? basename(dir);
  const commands = opts.commands ?? [];
  writeFileSync(
    file,
    renderConfig({
      name,
      commands,
      stopCommands: opts.stopCommands ?? [],
      port: opts.port,
    })
  );
  return { file, name, placeholder: commands.length === 0 };
}
