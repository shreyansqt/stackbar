import Foundation
import Combine

/// Owns the configured services, their runtime objects, persistence, and the health timer.
@MainActor
final class ServiceManager: ObservableObject {
    @Published private(set) var runners: [RunningService] = []

    private var healthTimer: Timer?
    private let configURL: URL
    private var controlServer: ControlServer?

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StackBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.configURL = support.appendingPathComponent("services.json")

        load()
        startHealthTimer()

        // Local HTTP control channel for the CLI / MCP.
        let server = ControlServer(manager: self)
        self.controlServer = server
        server.start()
    }

    // MARK: - Aggregate status for the menu bar glyph

    var overallStatus: ServiceStatus {
        let statuses = runners.map(\.status)
        if statuses.contains(where: { if case .crashed = $0 { return true } else { return false } }) {
            return .crashed(code: 1)
        }
        if statuses.contains(.starting) || statuses.contains(.stopping) { return .starting }
        if statuses.contains(.running) { return .running }
        return .idle
    }

    // MARK: - CRUD

    func addService(_ service: Service) {
        runners.append(RunningService(config: service))
        persist()
    }

    func updateService(_ service: Service) {
        guard let idx = runners.firstIndex(where: { $0.id == service.id }) else { return }
        let wasLive = runners[idx].isLive
        if wasLive { runners[idx].stop() }
        runners[idx] = RunningService(config: service)
        persist()
        if wasLive { runners[idx].start() }
    }

    func deleteService(id: UUID) {
        guard let idx = runners.firstIndex(where: { $0.id == id }) else { return }
        runners[idx].stop()
        runners.remove(at: idx)
        // Clean up the service's log + meta files.
        try? FileManager.default.removeItem(at: LogStore.logFile(for: id))
        try? FileManager.default.removeItem(at: LogStore.metaFile(for: id))
        persist()
    }

    // MARK: - Lookup & per-id actions (used by the control server)

    func runner(id: UUID) -> RunningService? {
        runners.first { $0.id == id }
    }

    /// Resolve by exact id string, exact name, or partial name (case-insensitive).
    func resolve(_ nameOrId: String) -> RunningService? {
        let lower = nameOrId.lowercased()
        return runners.first { $0.id.uuidString == nameOrId }
            ?? runners.first { $0.config.name.lowercased() == lower }
            ?? runners.first { $0.config.name.lowercased().contains(lower) }
    }

    // MARK: - Bulk controls

    func startAll() { runners.forEach { $0.start() } }
    func stopAll() { runners.forEach { $0.stop() } }

    // MARK: - Status snapshot (JSON-friendly)

    /// A serializable view of every service + live status, for the control API.
    func statusSnapshot() -> [[String: Any]] {
        runners.map { r in
            [
                "id": r.id.uuidString,
                "name": r.config.name,
                "directory": r.config.directory,
                "commands": r.config.commands,
                "stopCommands": r.config.stopCommands,
                "command": r.config.displayCommand,
                "port": r.config.port as Any,
                "status": r.status.label,
                "live": r.isLive,
            ]
        }
    }

    // MARK: - Health polling

    private func startHealthTimer() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runners.forEach { $0.refreshHealth() } }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: configURL),
              let services = try? JSONDecoder().decode([Service].self, from: data) else {
            return
        }
        runners = services.map { RunningService(config: $0) }
    }

    private func persist() {
        let services = runners.map(\.config)
        guard let data = try? JSONEncoder().encode(services) else { return }
        try? data.write(to: configURL)
    }
}
