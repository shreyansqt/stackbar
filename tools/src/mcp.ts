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

// ---- CRUD ----

server.tool(
  "add_service",
  "Add a new service to StackBar. The directory must be an absolute path. Pass one or more commands; each runs via zsh in that directory as its own child process, all started/stopped together (e.g. a transpile watcher + a docker compose up).",
  {
    name: z.string(),
    directory: z.string().describe("Absolute path the commands run in"),
    commands: z.array(z.string()).min(1).describe("Shell commands, e.g. ['yarn transpile-watch', 'yarn up']"),
    stopCommands: z.array(z.string()).optional()
      .describe("Optional commands run on stop, after the start processes are SIGTERM'd, e.g. ['docker compose down']"),
    port: z.number().int().positive().optional().describe("TCP port to probe for health"),
  },
  (args) => withApp(async () => {
    const r = await api.add(args);
    return text(`Added "${args.name}" (id ${r.id}) with ${args.commands.length} command(s).`);
  })
);

server.tool(
  "edit_service",
  "Edit an existing service. Only the fields you pass are changed. Passing `commands` replaces the full command list.",
  {
    service: z.string().describe("Service name/id to edit"),
    name: z.string().optional(),
    directory: z.string().optional(),
    commands: z.array(z.string()).min(1).optional().describe("Replacement command list"),
    stopCommands: z.array(z.string()).optional().describe("Replacement stop-command list (e.g. ['docker compose down'])"),
    port: z.number().int().positive().nullable().optional().describe("New port, or null to clear"),
  },
  ({ service, ...patch }) => withApp(async () => {
    const clean = Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined));
    await api.edit(service, clean);
    return text(`Updated "${service}".`);
  })
);

server.tool(
  "remove_service",
  "Remove a service from StackBar (stops it first and deletes its logs).",
  { service: z.string().describe("Service name/id to remove") },
  ({ service }) => withApp(async () => {
    await api.remove(service);
    return text(`Removed "${service}".`);
  })
);

// ---- Logs (read directly from files; work even if the app is stopped) ----

server.tool(
  "get_logs",
  "Get the most recent log lines for a StackBar service. Use this to see what a locally-running dev server is currently outputting.",
  {
    service: z.string().describe("Service name (exact or partial, case-insensitive) or id"),
    lines: z.number().int().positive().max(5000).default(200),
  },
  async ({ service, lines }) => {
    const svc = await resolveService(service);
    if (!svc) return text(`No service matching "${service}". Call list_services first.`, true);
    const tail = await readLogTail(svc, lines);
    return text(
      tail.trim().length === 0
        ? `(${svc.name}: log is empty — service may not have been started)`
        : `# ${svc.name} — last ${lines} lines\n\n${tail}`
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
