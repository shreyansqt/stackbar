import Foundation

/// Owns the on-disk layout StackBar writes and the CLI/MCP read.
///
/// Layout (under Application Support/StackBar):
///   services.json          — the service registry (written by ServiceManager)
///   logs/<id>.log          — one append-only log file per service, keyed by UUID
///   logs/<id>.meta.json    — { name, command, directory } so readers can map id -> name
///
/// Keying files by UUID (not name) keeps them stable across renames.
enum LogStore {
    static var root: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StackBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var logsDir: URL {
        let dir = root.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func logFile(for id: UUID) -> URL {
        logsDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// Per-command log file, e.g. `<id>.0.log`, for multi-command services.
    static func logFile(for id: UUID, command index: Int) -> URL {
        logsDir.appendingPathComponent("\(id.uuidString).\(index).log")
    }

    /// Per-stop-command log file, e.g. `<id>.stop.0.log`.
    static func stopLogFile(for id: UUID, command index: Int) -> URL {
        logsDir.appendingPathComponent("\(id.uuidString).stop.\(index).log")
    }

    static func metaFile(for id: UUID) -> URL {
        logsDir.appendingPathComponent("\(id.uuidString).meta.json")
    }
}

/// Append-only writer for one service's log file, with size-based rotation.
/// Lives on a serial queue so the readability handler never blocks the main actor.
final class LogFileWriter {
    private let id: UUID
    private let url: URL
    private let queue: DispatchQueue
    private var handle: FileHandle?
    /// Per-command file handles, keyed by command index.
    /// Per-command file handles, keyed "start.<i>" / "stop.<i>".
    private var namedHandles: [String: FileHandle] = [:]
    private let maxBytes: UInt64 = 5 * 1024 * 1024 // 5 MB, then rotate to .1

    init(id: UUID) {
        self.id = id
        self.url = LogStore.logFile(for: id)
        self.queue = DispatchQueue(label: "stackbar.log.\(id.uuidString)")
    }

    /// Record service metadata so readers can resolve id -> name without the app.
    func writeMeta(_ service: Service) {
        let meta: [String: String] = [
            "id": service.id.uuidString,
            "name": service.name,
            "command": service.displayCommand,
            "directory": service.directory,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) else { return }
        try? data.write(to: LogStore.metaFile(for: service.id))
    }

    /// Truncate the combined log + all per-command logs at (re)start.
    func reset() {
        queue.async {
            self.handle?.closeFile()
            self.handle = nil
            try? Data().write(to: self.url)
            self.handle = try? FileHandle(forWritingTo: self.url)
            // Clear any per-command files from the previous run.
            for (_, h) in self.namedHandles { h.closeFile() }
            self.namedHandles.removeAll()
            let dir = LogStore.logsDir
            let prefix = "\(self.id.uuidString)."
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in files where f.hasPrefix(prefix) && f.hasSuffix(".log") && f != "\(self.id.uuidString).log" {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
        }
    }

    func append(_ text: String) {
        queue.async {
            self.ensureHandle()
            guard let h = self.handle, let data = text.data(using: .utf8) else { return }
            h.write(data)
            self.rotateIfNeeded()
        }
    }

    /// Append to a specific start-command's log file.
    func append(_ text: String, commandIndex: Int) {
        appendToHandle(text, key: "start.\(commandIndex)",
                       url: LogStore.logFile(for: id, command: commandIndex))
    }

    /// Append to a specific stop-command's log file.
    func appendStop(_ text: String, commandIndex: Int) {
        appendToHandle(text, key: "stop.\(commandIndex)",
                       url: LogStore.stopLogFile(for: id, command: commandIndex))
    }

    private func appendToHandle(_ text: String, key: String, url: URL) {
        queue.async {
            let h: FileHandle
            if let existing = self.namedHandles[key] {
                h = existing
            } else {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                guard let newHandle = try? FileHandle(forWritingTo: url) else { return }
                newHandle.seekToEndOfFile()
                self.namedHandles[key] = newHandle
                h = newHandle
            }
            if let data = text.data(using: .utf8) { h.write(data) }
        }
    }

    private func ensureHandle() {
        guard handle == nil else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        guard let size = try? handle?.offset(), size > maxBytes else { return }
        handle?.closeFile()
        handle = nil
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
        ensureHandle()
    }
}
