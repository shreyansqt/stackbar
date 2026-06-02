import { homedir } from "node:os";
import { join } from "node:path";
import { readFile, readdir, stat } from "node:fs/promises";
import { existsSync } from "node:fs";

/**
 * Mirror of the Swift LogStore layout. Single source of truth for where
 * StackBar writes, so the CLI and MCP server stay in sync with the app.
 *
 *   <root>/services.json        registry written by the app
 *   <root>/logs/<id>.log        per-service log (keyed by service UUID)
 *   <root>/logs/<id>.meta.json  { id, name, command, directory }
 */
export const ROOT = join(
  homedir(),
  "Library",
  "Application Support",
  "StackBar"
);
export const LOGS_DIR = join(ROOT, "logs");
const REGISTRY = join(ROOT, "services.json");

export interface Service {
  id: string;
  name: string;
  directory: string;
  command: string;
  port?: number;
}

export interface ServiceMeta {
  id: string;
  name: string;
  command: string;
  directory: string;
  logPath: string;
  logExists: boolean;
  logSize: number;
  lastModified: string | null;
}

/** Read the service registry the app persists. Empty if the app never ran. */
export async function listServices(): Promise<Service[]> {
  if (!existsSync(REGISTRY)) return [];
  try {
    return JSON.parse(await readFile(REGISTRY, "utf8")) as Service[];
  } catch {
    return [];
  }
}

/** Enrich each service with the state of its log file on disk. */
export async function listServiceMeta(): Promise<ServiceMeta[]> {
  const services = await listServices();
  return Promise.all(
    services.map(async (s) => {
      const logPath = join(LOGS_DIR, `${s.id}.log`);
      let logSize = 0;
      let lastModified: string | null = null;
      const logExists = existsSync(logPath);
      if (logExists) {
        const st = await stat(logPath);
        logSize = st.size;
        lastModified = st.mtime.toISOString();
      }
      return {
        id: s.id,
        name: s.name,
        command: s.command,
        directory: s.directory,
        logPath,
        logExists,
        logSize,
        lastModified,
      };
    })
  );
}

/** Resolve a service by exact id, or case-insensitive name match. */
export async function resolveService(
  nameOrId: string
): Promise<Service | null> {
  const services = await listServices();
  const lower = nameOrId.toLowerCase();
  return (
    services.find((s) => s.id === nameOrId) ??
    services.find((s) => s.name.toLowerCase() === lower) ??
    services.find((s) => s.name.toLowerCase().includes(lower)) ??
    null
  );
}

/** Path to a service's combined log, or one command's log if commandIndex given. */
function logPathFor(service: Service, commandIndex?: number): string {
  return commandIndex === undefined
    ? join(LOGS_DIR, `${service.id}.log`)
    : join(LOGS_DIR, `${service.id}.${commandIndex}.log`);
}

/** Read the last `lines` lines of a service's log (or one command's log). */
export async function readLogTail(
  service: Service,
  lines = 200,
  commandIndex?: number
): Promise<string> {
  const logPath = logPathFor(service, commandIndex);
  if (!existsSync(logPath)) return "";
  const content = await readFile(logPath, "utf8");
  const all = content.split("\n");
  return all.slice(Math.max(0, all.length - lines)).join("\n");
}

/** Return log lines matching a substring or regex. */
export async function searchLog(
  service: Service,
  pattern: string,
  opts: { regex?: boolean; ignoreCase?: boolean; max?: number } = {}
): Promise<string[]> {
  const logPath = join(LOGS_DIR, `${service.id}.log`);
  if (!existsSync(logPath)) return [];
  const content = await readFile(logPath, "utf8");
  const lines = content.split("\n");
  const max = opts.max ?? 200;

  let test: (line: string) => boolean;
  if (opts.regex) {
    const re = new RegExp(pattern, opts.ignoreCase ? "i" : undefined);
    test = (l) => re.test(l);
  } else {
    const needle = opts.ignoreCase ? pattern.toLowerCase() : pattern;
    test = (l) =>
      (opts.ignoreCase ? l.toLowerCase() : l).includes(needle);
  }

  const hits: string[] = [];
  for (const line of lines) {
    if (test(line)) {
      hits.push(line);
      if (hits.length >= max) break;
    }
  }
  return hits;
}
