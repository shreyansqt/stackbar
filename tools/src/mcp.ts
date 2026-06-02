#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { api, StackBarNotRunning } from "./client.js";
import { resolveService, readLogTail, searchLog } from "./store.js";

const server = new McpServer({ name: "stackbar", version: "1.0.0" });

type ToolResult = { content: { type: "text"; text: string }[]; isError?: boolean };

function text(t: string, isError = false): ToolResult {
  return { content: [{ type: "text", text: t }], ...(isError ? { isError: true } : {}) };
}

/** Wrap a control-API handler so a stopped app yields a clear message. */
async function withApp(fn: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await fn();
  } catch (e) {
    if (e instanceof StackBarNotRunning) return text(e.message, true);
    return text((e as Error).message ?? String(e), true);
  }
}

// ---- Discovery / status ----

server.tool(
  "list_services",
  "List all StackBar services with their live status (running/starting/idle/crashed), command, directory, and port. Call this first to discover service names.",
  {},
  () => withApp(async () => text(JSON.stringify(await api.list(), null, 2)))
);

// ---- Actions ----

server.tool(
  "start_service",
  "Start a StackBar service (or 'all'). The app spawns the service's command in its directory.",
  { service: z.string().describe("Service name/id, or 'all'") },
  ({ service }) =>
    withApp(async () => {
      if (service === "all") { await api.startAll(); return text("Started all services."); }
      const r = await api.start(service);
      return text(`Started "${service}" — status: ${r.status}`);
    })
);

server.tool(
  "stop_service",
  "Stop a running StackBar service (or 'all'). SIGTERMs the start processes, then runs the service's stop commands (e.g. docker compose down) if configured.",
  { service: z.string().describe("Service name/id, or 'all'") },
  ({ service }) =>
    withApp(async () => {
      if (service === "all") { await api.stopAll(); return text("Stopped all services."); }
      const r = await api.stop(service);
      return text(`Stopped "${service}" — status: ${r.status}`);
    })
);

server.tool(
  "restart_service",
  "Restart a StackBar service (or 'all').",
  { service: z.string().describe("Service name/id, or 'all'") },
  ({ service }) =>
    withApp(async () => {
      if (service === "all") { await api.stopAll(); await api.startAll(); return text("Restarted all services."); }
      await api.restart(service);
      return text(`Restarting "${service}".`);
    })
);

// ---- Workspaces & discovery ----
// Services aren't added here — they come from .stackbar.json files in the user's
// workspace folders. These tools manage workspaces and re-scan.

server.tool(
  "rescan_services",
  "Re-scan the configured workspace folders for .stackbar.json files and reconcile the service list. Use after adding/editing a .stackbar.json.",
  {},
  () => withApp(async () => {
    await api.rescan();
    const services = await api.list();
    return text(`Rescanned — ${services.length} service(s) discovered.`);
  })
);

server.tool(
  "list_workspaces",
  "List the workspace folders StackBar scans for .stackbar.json service files.",
  {},
  () => withApp(async () => text(JSON.stringify(await api.workspaces(), null, 2)))
);

server.tool(
  "add_workspace",
  "Track a folder as a workspace; StackBar recursively scans it for .stackbar.json files and lists those services.",
  { path: z.string().describe("Absolute path to a folder to scan") },
  ({ path }) => withApp(async () => {
    await api.addWorkspace(path);
    const services = await api.list();
    return text(`Added workspace ${path}. ${services.length} service(s) now discovered.`);
  })
);

// ---- Logs (read directly from files; work even if the app is stopped) ----

server.tool(
  "get_logs",
  "Get the most recent log lines for a StackBar service. Use this to see what a locally-running dev server is currently outputting.",
  {
    service: z.string().describe("Service name (exact or partial, case-insensitive) or id"),
    lines: z.number().int().positive().max(5000).default(200),
    command: z.number().int().min(1).optional()
      .describe("For multi-command services, which command's log (1-based). Omit for the combined log."),
  },
  async ({ service, lines, command }) => {
    const svc = await resolveService(service);
    if (!svc) return text(`No service matching "${service}". Call list_services first.`, true);
    const idx = command === undefined ? undefined : command - 1;
    const tail = await readLogTail(svc, lines, idx);
    const label = command === undefined ? svc.name : `${svc.name} (command ${command})`;
    return text(
      tail.trim().length === 0
        ? `(${label}: log is empty — service may not have been started)`
        : `# ${label} — last ${lines} lines\n\n${tail}`
    );
  }
);

server.tool(
  "search_logs",
  "Search a StackBar service's log for lines matching a substring or regex. Use to find errors or a specific request without pulling the whole log.",
  {
    service: z.string(),
    pattern: z.string(),
    regex: z.boolean().default(false),
    ignoreCase: z.boolean().default(true),
    max: z.number().int().positive().max(1000).default(200),
  },
  async ({ service, pattern, regex, ignoreCase, max }) => {
    const svc = await resolveService(service);
    if (!svc) return text(`No service matching "${service}". Call list_services first.`, true);
    const hits = await searchLog(svc, pattern, { regex, ignoreCase, max });
    return text(
      hits.length === 0
        ? `(${svc.name}: no lines match ${JSON.stringify(pattern)})`
        : `# ${svc.name} — ${hits.length} match(es)\n\n${hits.join("\n")}`
    );
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
