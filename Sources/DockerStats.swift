import Foundation

/// Samples per-compose-project memory from the container runtime so StackBar can
/// attribute a docker-backed service's real footprint (which lives in the
/// OrbStack/Docker VM, not in our `docker compose up` client process).
///
/// Two cheap shell calls, joined by container name:
///   1. `docker stats --no-stream` → name → memory bytes
///   2. `docker ps` → name → the compose project's working_dir label
/// summed into `[workingDir: bytes]`. A service matches by its `directory`.
enum DockerStats {
    /// Total container memory (bytes) keyed by the compose project's working dir.
    /// Empty if docker isn't installed/running or nothing is up. `docker stats
    /// --no-stream` samples a short window (~1–2s), so call this OFF the main
    /// actor on a relaxed cadence — not synchronously on the fast health timer.
    static func memoryByWorkingDir() -> [String: Int] {
        // name → working_dir (only running containers carry live stats).
        let dirByName = run(#"docker ps --format '{{.Names}}\t{{.Label "com.docker.compose.project.working_dir"}}'"#)
            .reduce(into: [String: String]()) { acc, line in
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 2, !cols[1].isEmpty else { return }
                acc[cols[0]] = cols[1]
            }
        guard !dirByName.isEmpty else { return [:] }

        // name → "<used> / <limit>"; we only want the used side.
        var totals: [String: Int] = [:]
        for line in run(#"docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}'"#) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2, let dir = dirByName[cols[0]] else { continue }
            let used = cols[1].components(separatedBy: "/").first ?? cols[1]
            guard let bytes = parseBytes(used.trimmingCharacters(in: .whitespaces)) else { continue }
            totals[dir, default: 0] += bytes
        }
        return totals
    }

    /// Parse a docker-formatted size like "1.069GiB", "488.7MiB", "13.24MiB",
    /// "0B" into bytes. Handles both binary (GiB/MiB) and decimal (GB/MB) units.
    static func parseBytes(_ s: String) -> Int? {
        let units: [(suffix: String, factor: Double)] = [
            ("GiB", 1_073_741_824), ("MiB", 1_048_576), ("KiB", 1_024),
            ("GB", 1_000_000_000), ("MB", 1_000_000), ("kB", 1_000),
            ("B", 1),
        ]
        for (suffix, factor) in units where s.hasSuffix(suffix) {
            let num = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            guard let value = Double(num) else { return nil }
            return Int(value * factor)
        }
        return nil
    }

    /// Run a command through a login shell (so `docker` is on PATH) and return its
    /// stdout lines. Empty on any failure — docker being absent is not an error.
    private static func run(_ command: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(whereSeparator: \.isNewline).map(String.init)
    }
}
