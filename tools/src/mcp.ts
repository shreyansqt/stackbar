#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  listServiceMeta,
  resolveService,
  readLogTail,
  searchLog,
} from "./store.js";

const server = new McpServer({
  name: "stackbar",
  version: "1.0.0",
});

server.tool(
  "list_services",
  "List all services configured in StackBar, with the size and last-modified time of each service's log file. Call this first to discover service names.",
  {},
  async () => {
    const meta = await listServiceMeta();
    if (meta.length === 0) {
      return { content: [{ type: "text", text: "No services configured in StackBar." }] };
    }
    return { content: [{ type: "text", text: JSON.stringify(meta, null, 2) }] };
  }
);

server.tool(
  "get_logs",
  "Get the most recent log lines for a StackBar service. Use this to see what a locally-running dev server is currently outputting.",
  {
    service: z.string().describe("Service name (exact or partial, case-insensitive) or id"),
    lines: z.number().int().positive().max(5000).default(200)
      .describe("How many trailing lines to return"),
  },
  async ({ service, lines }) => {
    const svc = await resolveService(service);
    if (!svc) {
      return {
        content: [{ type: "text", text: `No service matching "${service}". Call list_services first.` }],
        isError: true,
      };
    }
    const tail = await readLogTail(svc, lines);
    return {
      content: [{
        type: "text",
        text: tail.trim().length === 0
          ? `(${svc.name}: log is empty — service may not have been started)`
          : `# ${svc.name} — last ${lines} lines\n\n${tail}`,
      }],
    };
  }
);

server.tool(
  "search_logs",
  "Search a StackBar service's log for lines matching a substring or regex. Use this to find errors, a specific request, or a stack trace without pulling the whole log.",
  {
    service: z.string().describe("Service name (exact or partial, case-insensitive) or id"),
    pattern: z.string().describe("Substring, or a regex if regex=true"),
    regex: z.boolean().default(false).describe("Treat pattern as a regular expression"),
    ignoreCase: z.boolean().default(true).describe("Case-insensitive match"),
    max: z.number().int().positive().max(1000).default(200).describe("Max matching lines to return"),
  },
  async ({ service, pattern, regex, ignoreCase, max }) => {
    const svc = await resolveService(service);
    if (!svc) {
      return {
        content: [{ type: "text", text: `No service matching "${service}". Call list_services first.` }],
        isError: true,
      };
    }
    const hits = await searchLog(svc, pattern, { regex, ignoreCase, max });
    return {
      content: [{
        type: "text",
        text: hits.length === 0
          ? `(${svc.name}: no lines match ${JSON.stringify(pattern)})`
          : `# ${svc.name} — ${hits.length} match(es) for ${JSON.stringify(pattern)}\n\n${hits.join("\n")}`,
      }],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
