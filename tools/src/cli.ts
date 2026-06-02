#!/usr/bin/env node
import { api, StackBarNotRunning } from "./client.js";
import { resolveService, readLogTail, searchLog, LOGS_DIR } from "./store.js";
import { createReadStream, existsSync, watch, statSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const cmd = args[0];

function flag(name: string, short?: string): string | undefined {
  const i = args.findIndex((a) => a === `--${name}` || (short && a === `-${short}`));
  return i >= 0 ? args[i + 1] : undefined;
}
/** All values of a flag that may be repeated (e.g. multiple --cmd). */
function flagAll(name: string, short?: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === `--${name}` || (short && args[i] === `-${short}`)) {
      if (args[i + 1] !== undefined) out.push(args[i + 1]);
    }
  }
  return out;
}
function hasFlag(name: string, short?: string): boolean {
  return args.includes(`--${name}`) || (short ? args.includes(`-${short}`) : false);
}

async function main() {
  switch (cmd) {
    case "list":
    case "ls":
      return cmdList();
    case "rescan":
    case "refresh":
      return cmdRescan();
    case "workspaces":
      return cmdWorkspaces();
    case "add-workspace":
      return cmdAddWorkspace();
    case "start":
      return cmdAction("start");
    case "stop":
      return cmdAction("stop");
    case "restart":
      return cmdAction("restart");
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

const DOT: Record<string, string> = {
  running: "🟢",
  starting: "🟡",
  stopping: "🟡",
  idle: "⚪️",
};

async function cmdList() {
  const services = await api.list();
  if (services.length === 0) {
    console.log("No services configured. Add one: stackbar add <name> --dir <path> --cmd <command>");
    return;
  }
  for (const s of services) {
    const dot = DOT[s.status] ?? "🔴";
    const port = s.port ? ` :${s.port}` : "";
    console.log(`${dot} ${s.name}${port}  (${s.status})`);
    const cmds = s.commands ?? [s.command];
    for (const c of cmds) console.log(`     $ ${c}`);
    for (const c of s.stopCommands ?? []) console.log(`     ⏹ ${c}`);
    console.log(`     [${s.directory}]`);
  }
}

async function cmdRescan() {
  await api.rescan();
  const services = await api.list();
  console.log(`Rescanned — ${services.length} service(s) discovered.`);
}

async function cmdWorkspaces() {
  const ws = await api.workspaces();
  if (ws.length === 0) {
    console.log("No workspaces. Add one: stackbar add-workspace <folder>");
    return;
  }
  for (const w of ws) console.log(w);
}

async function cmdAddWorkspace() {
  const path = args[1];
  if (!path) {
    console.error("usage: stackbar add-workspace <folder>");
    process.exit(1);
  }
  await api.addWorkspace(path);
  const services = await api.list();
  console.log(`Added workspace. ${services.length} service(s) now discovered.`);
}

async function cmdAction(action: "start" | "stop" | "restart") {
  const target = args[1];
  if (!target) {
    console.error(`usage: stackbar ${action} <service|all>`);
    process.exit(1);
  }
  if (target === "all") {
    if (action === "start") await api.startAll();
    else if (action === "stop") await api.stopAll();
    else {
      await api.stopAll();
      await api.startAll();
    }
    console.log(`${action} all`);
    return;
  }
  if (action === "start") await api.start(target);
  else if (action === "stop") await api.stop(target);
  else await api.restart(target);
  console.log(`${action} "${target}"`);
}

async function cmdLogs() {
  const name = args[1];
  if (!name) {
    console.error("usage: stackbar logs <service> [-n LINES] [-f] [--cmd N]");
    process.exit(1);
  }
  const svc = await resolveService(name);
  if (!svc) {
    console.error(`No service matching "${name}". Try: stackbar list`);
    process.exit(1);
  }
  const lines = parseInt(flag("lines", "n") ?? "200", 10);
  const cmdFlag = flag("cmd");
  const cmdIndex = cmdFlag ? parseInt(cmdFlag, 10) - 1 : undefined;
  const tail = await readLogTail(svc, lines, cmdIndex);
  process.stdout.write(tail.endsWith("\n") ? tail : tail + "\n");

  if (hasFlag("follow", "f")) {
    const suffix = cmdIndex === undefined ? "" : `.${cmdIndex}`;
    const logPath = join(LOGS_DIR, `${svc.id}${suffix}.log`);
    if (!existsSync(logPath)) return;
    let pos = statSync(logPath).size;
    watch(logPath, () => {
      const size = statSync(logPath).size;
      if (size > pos) {
        createReadStream(logPath, { start: pos, end: size }).pipe(process.stdout);
        pos = size;
      } else if (size < pos) {
        pos = 0; // rotated/reset
      }
    });
    await new Promise(() => {});
  }
}

async function cmdSearch() {
  const name = args[1];
  const pattern = args[2];
  if (!name || !pattern) {
    console.error("usage: stackbar search <service> <pattern> [--regex] [--ignore-case]");
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
  console.log(hits.length === 0 ? "(no matches)" : hits.join("\n"));
}

function usage() {
  console.log(`stackbar — control and inspect StackBar services

Services come from .stackbar.json files in your workspace folders.

Services:
  stackbar list                                    List services + live status
  stackbar rescan                                  Re-scan workspaces for .stackbar.json
  stackbar workspaces                              List workspace folders
  stackbar add-workspace <folder>                  Track a folder (scanned for services)

Actions:
  stackbar start   <service|all>                   Start
  stackbar stop    <service|all>                   Stop
  stackbar restart <service|all>                   Restart

Logs:
  stackbar logs <service> [-n N] [-f]              Last N lines (default 200); -f follows
  stackbar search <service> <pattern> [--regex] [--ignore-case]

<service> matches by exact id, exact name, or partial name (case-insensitive).
Service/action commands need the StackBar app running; log reads work from files.`);
}

main().catch((err) => {
  if (err instanceof StackBarNotRunning) {
    console.error(err.message);
    process.exit(2);
  }
  console.error(err.message ?? err);
  process.exit(1);
});
