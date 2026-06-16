import { homedir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";

/**
 * HTTP client for the StackBar app's local control server. Discovers the port
 * and token from files the app writes under Application Support. The app is the
 * single authority for services + actions, so the CLI/MCP just talk to it.
 */
const ROOT = join(homedir(), "Library", "Application Support", "StackBar");
const PORT_FILE = join(ROOT, "control.port");
const TOKEN_FILE = join(ROOT, "control.token");

export class StackBarNotRunning extends Error {
  constructor() {
    super(
      "StackBar isn't running (no control.port found). Open the StackBar app and try again."
    );
    this.name = "StackBarNotRunning";
  }
}

interface Conn {
  base: string;
  token: string;
}

async function conn(): Promise<Conn> {
  if (!existsSync(PORT_FILE) || !existsSync(TOKEN_FILE)) throw new StackBarNotRunning();
  const port = (await readFile(PORT_FILE, "utf8")).trim();
  const token = (await readFile(TOKEN_FILE, "utf8")).trim();
  if (!port) throw new StackBarNotRunning();
  return { base: `http://127.0.0.1:${port}`, token };
}

async function call(
  method: string,
  path: string,
  body?: unknown
): Promise<any> {
  const c = await conn();
  let res: Response;
  try {
    res = await fetch(c.base + path, {
      method,
      headers: {
        Authorization: `Bearer ${c.token}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    // Port file exists but nothing is listening — app was killed.
    throw new StackBarNotRunning();
  }
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    throw new Error(json.error ?? `HTTP ${res.status}`);
  }
  return json;
}

export interface ServiceStatus {
  id: string;
  name: string;
  directory: string;
  command: string;
  commands: string[];
  stopCommands: string[];
  port: number | null;
  status: string;
  live: boolean;
}

export const api = {
  list: (): Promise<ServiceStatus[]> =>
    call("GET", "/services").then((r) => r.services as ServiceStatus[]),
  start: (idOrName: string) =>
    call("POST", `/services/${encodeURIComponent(idOrName)}/start`),
  stop: (idOrName: string) =>
    call("POST", `/services/${encodeURIComponent(idOrName)}/stop`),
  restart: (idOrName: string) =>
    call("POST", `/services/${encodeURIComponent(idOrName)}/restart`),
  startAll: () => call("POST", "/start-all"),
  stopAll: () => call("POST", "/stop-all"),
  rescan: () => call("POST", "/rescan"),
  workspaces: (): Promise<string[]> =>
    call("GET", "/workspaces").then((r) => r.workspaces as string[]),
  addWorkspace: (path: string) => call("POST", "/workspaces", { path }),
  removeWorkspace: (path: string) => call("DELETE", "/workspaces", { path }),
};
