import Foundation
import Combine

/// Owns the configured services, their runtime objects, persistence, and the health timer.
@MainActor
final class ServiceManager: ObservableObject {
    @Published private(set) var runners: [RunningService] = [] {
        didSet { observeRunners() }
    }

    private var healthTimer: Timer?
    private let configURL: URL
    private var controlServer: ControlServer?
    /// Subscriptions forwarding each runner's status changes up to us, so the menu
    /// bar (which observes the manager) refreshes when a service's status changes —
    /// not only when the runners array itself changes.
    private var runnerObservations: [AnyCancellable] = []

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StackBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.configURL = support.appendingPathComponent("services.json")

        load()
        // Reclaim any processes a previous StackBar instance left orphaned (they
        // reparent to launchd, so a fresh instance can't reach them via process
        // groups). Without this they accumulate across relaunches/crashes.
        cleanupOrphansFromPreviousRun()
        startHealthTimer()

        // Local HTTP control channel for the CLI / MCP.
        let server = ControlServer(manager: self)
        self.controlServer = server
        server.start()
    }

    /// Kill leftover processes from a previous StackBar run. Two passes:
    ///  1. By env marker: any process whose environment carries STACKBAR_MANAGED
    ///     (covers port-less services like watchers, and detached subtrees).
    ///  2. By port: anything LISTENING on a configured service port (skips
    ///     container runtimes — see RunningService.killProcessOnPort).
    private func cleanupOrphansFromPreviousRun() {
        let ports = runners.compactMap(\.config.port)
        // Run off the main thread — process scanning forks `ps`, which must never
        // block app launch.
        DispatchQueue.global(qos: .utility).async {
            var killed = 0

            // Pass 1 — env marker. Narrow to likely dev processes first (pgrep by
            // command), then check only those few for the STACKBAR_MANAGED env var.
            // (macOS `ps` only exposes env when queried per-pid.)
            let candidates = Self.shellLines("/usr/bin/pgrep",
                ["-f", "pnpm|wrangler|workerd|webpack|vite|yarn|node|esbuild"])
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            for pid in candidates {
                let env = Self.shellLines("/bin/ps", ["-Eww", "-o", "command=", "-p", String(pid)]).joined()
                if env.contains("STACKBAR_MANAGED=") {
                    kill(pid, SIGTERM)
                    killed += 1
                }
            }
            if killed > 0 {
                Log.info("startup cleanup: signaled \(killed) leftover STACKBAR_MANAGED process(es)")
            }

            // Pass 2 — by port, for each configured service that declares one.
            for port in ports {
                RunningService.killProcessOnPort(port)
            }
        }
    }

    /// Run a command and return its stdout lines (small helper for process scans).
    nonisolated private static func shellLines(_ path: String, _ args: [String]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).map(String.init) ?? []
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

    /// Overall state that drives which menu bar glyph is shown.
    /// Precedence: crashed > booting > allRunning > idle.
    enum IconState {
        case idle         // nothing running — dim glyph
        case booting      // something starting/stopping — animated spinner
        case allRunning   // everything up — solid glyph
        case crashed      // something errored — exclamation triangle
    }

    /// Fraction of services fully running (0…1). Drives the glyph's brightness
    /// when nothing is crashing or transitioning. 0 if there are no services.
    var runningFraction: Double {
        guard !runners.isEmpty else { return 0 }
        let running = runners.filter { if case .running = $0.status { return true } else { return false } }.count
        return Double(running) / Double(runners.count)
    }

    var iconState: IconState {
        let statuses = runners.map(\.status)
        if statuses.contains(where: { if case .crashed = $0 { return true } else { return false } }) {
            return .crashed
        }
        if statuses.contains(.starting) || statuses.contains(.stopping) {
            return .booting
        }
        let running = statuses.filter { if case .running = $0 { return true } else { return false } }.count
        if !runners.isEmpty && running == runners.count {
            return .allRunning
        }
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

    /// Forward each runner's change notifications to the manager so observers
    /// (the menu bar controller) update on per-service status changes too.
    private func observeRunners() {
        runnerObservations = runners.map { runner in
            runner.objectWillChange.sink { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: - Lookup & per-id actions (used by the control server)

    func runner(id: UUID) -> RunningService? {
        runners.first { $0.id == id }
    }

    /// Force-kill every running service's process group immediately, synchronously.
    /// Called on app termination so no dev-server subtrees are left orphaned.
    func terminateAllNow() {
        runners.forEach { $0.terminateNow() }
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
