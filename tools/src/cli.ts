#!/usr/bin/env node
import {
  listServiceMeta,
  resolveService,
  readLogTail,
  searchLog,
  LOGS_DIR,
} from "./store.js";
import { createReadStream, existsSync, watch } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const cmd = args[0];

function flag(name: string, short?: string): string | undefined {
  const i = args.findIndex((a) => a === `--${name}` || (short && a === `-${short}`));
  return i >= 0 ? args[i + 1] : undefined;
}
function hasFlag(name: string, short?: string): boolean {
  return args.includes(`--${name}`) || (short ? args.includes(`-${short}`) : false);
}

async function main() {
  switch (cmd) {
    case "list":
    case "ls":
      return cmdList();
    case "logs":
    case "log":
      return cmdLogs();
    case "search":
    case "grep":
      return cmdSearch();
    case "help":
    case undefined:
    case "--help":
    case "-h":
      return usage();
    default:
      console.error(`Unknown command: ${cmd}\n`);
      usage();
      process.exit(1);
  }
}

async function cmdList() {
  const meta = await listServiceMeta();
  if (meta.length === 0) {
    console.log("No services configured. Add some in the StackBar app.");
    return;
  }
  for (const m of meta) {
    const kb = (m.logSize / 1024).toFixed(1);
    const when = m.lastModified ? new Date(m.lastModified).toLocaleString() : "never";
    console.log(`${m.name}`);
    console.log(`  cmd:  ${m.command}`);
    console.log(`  dir:  ${m.directory}`);
    console.log(`  log:  ${m.logExists ? `${kb} KB, updated ${when}` : "no log yet"}`);
  }
}

async function cmdLogs() {
  const name = args[1];
  if (!name) {
    console.error("usage: stackbar logs <service> [-n LINES] [-f]");
    process.exit(1);
  }
  const svc = await resolveService(name);
  if (!svc) {
    console.error(`No service matching "${name}". Try: stackbar list`);
    process.exit(1);
  }
  const lines = parseInt(flag("lines", "n") ?? "200", 10);
  const tail = await readLogTail(svc, lines);
  process.stdout.write(tail.endsWith("\n") ? tail : tail + "\n");

  if (hasFlag("follow", "f")) {
    const logPath = join(LOGS_DIR, `${svc.id}.log`);
    if (!existsSync(logPath)) return;
    let pos = Buffer.byteLength(tail, "utf8");
    const { statSync } = await import("node:fs");
    pos = statSync(logPath).size;
    watch(logPath, () => {
      const size = statSync(logPath).size;
      if (size > pos) {
        createReadStream(logPath, { start: pos, end: size }).pipe(process.stdout);
        pos = size;
      } else if (size < pos) {
        pos = 0; // file was rotated/reset
      }
    });
    // keep process alive
    await new Promise(() => {});
  }
}

async function cmdSearch() {
  const name = args[1];
  const pattern = args[2];
  if (!name || !pattern) {
    console.error('usage: stackbar search <service> <pattern> [--regex] [--ignore-case]');
    process.exit(1);
  }
  const svc = await resolveService(name);
  if (!svc) {
    console.error(`No service matching "${name}". Try: stackbar list`);
    process.exit(1);
  }
  const hits = await searchLog(svc, pattern, {
    regex: hasFlag("regex"),
    ignoreCase: hasFlag("ignore-case", "i"),
  });
  if (hits.length === 0) {
    console.log("(no matches)");
    return;
  }
  console.log(hits.join("\n"));
}

function usage() {
  console.log(`stackbar — read StackBar service logs

Usage:
  stackbar list                          List services and log status
  stackbar logs <service> [-n N] [-f]    Show last N lines (default 200); -f to follow
  stackbar search <service> <pattern>    Search log lines
                 [--regex] [--ignore-case]

<service> matches by exact id, exact name, or partial name (case-insensitive).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
