import Foundation
import CryptoKit

/// Discovers services from `.stackbar.json` files inside workspace folders.
///
/// Model: the user tracks one or more *workspace* folders. StackBar scans each
/// recursively for `.stackbar.json` files; every file describes ONE service and
/// the folder it lives in IS that service's working directory. Config lives in
/// the repos (version-controllable), not in the app.
enum WorkspaceScanner {
    static let fileName = ".stackbar.json"

    /// Directories never worth descending into — huge and never hold our config.
    private static let prunedDirs: Set<String> = [
        "node_modules", ".git", "dist", "build", ".next", ".turbo",
        "target", "vendor", ".venv", "venv", "Pods", ".build", "coverage",
    ]
    private static let maxDepth = 6

    /// Scan all workspaces and return the discovered services (deduped by id).
    static func scan(workspaces: [URL]) -> [Service] {
        var byId: [String: Service] = [:]
        for ws in workspaces {
            for fileURL in findConfigFiles(in: ws) {
                if let service = loadService(at: fileURL) {
                    byId[service.id.uuidString] = service   // later wins; ids are stable
                }
            }
        }
        return Array(byId.values).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - File discovery

    private static func findConfigFiles(in root: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey]),
              rootValues.isDirectory == true else { return [] }

        // Manual BFS so we can prune directories and cap depth.
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()

            let candidate = dir.appendingPathComponent(fileName)
            if fm.fileExists(atPath: candidate.path) {
                results.append(candidate)
            }
            guard depth < maxDepth else { continue }

            let entries = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries {
                guard let v = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
                      v.isDirectory == true else { continue }
                if prunedDirs.contains(entry.lastPathComponent) { continue }
                queue.append((entry, depth + 1))
            }
        }
        return results
    }

    // MARK: - Loading one service

    private static func loadService(at fileURL: URL) -> Service? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let stripped = JSONC.stripComments(raw)
        guard let data = stripped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let directory = fileURL.deletingLastPathComponent().path
        let name = (obj["name"] as? String) ?? fileURL.deletingLastPathComponent().lastPathComponent
        let commands: [String]
        if let cmds = obj["commands"] as? [String], !cmds.isEmpty {
            commands = cmds
        } else if let single = obj["command"] as? String {
            commands = [single]
        } else {
            return nil   // a service must have at least one command
        }
        let stopCommands = (obj["stopCommands"] as? [String]) ?? []
        let port = obj["port"] as? Int

        // Stable id derived from the absolute directory path, so logs/state survive
        // rescans and relaunches (same folder → same service).
        let id = stableID(forPath: directory)
        return Service(id: id, name: name, directory: directory,
                       commands: commands, stopCommands: stopCommands, port: port)
    }

    /// Deterministic UUID from a path: first 16 bytes of SHA-256("stackbar:" + path).
    /// Same folder → same id, so logs/state survive rescans and relaunches.
    private static func stableID(forPath path: String) -> UUID {
        let digest = SHA256.hash(data: Data(("stackbar:" + path).utf8))
        let b = Array(digest.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
