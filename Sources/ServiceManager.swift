import Foundation
import Combine

/// Owns the configured services, their runtime objects, persistence, and the health timer.
@MainActor
final class ServiceManager: ObservableObject {
    @Published private(set) var runners: [RunningService] = [] {
        didSet { observeRunners() }
    }

    /// Workspace folders the user tracks. Services are discovered by scanning these
    /// for `.stackbar.json` files — the repos own their config, not the app.
    @Published private(set) var workspaces: [URL] = []

    private var healthTimer: Timer?
    private let workspacesURL: URL
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
        self.workspacesURL = support.appendingPathComponent("workspaces.json")

        loadWorkspaces()
        rescan()
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

    // MARK: - Workspaces & discovery

    func addWorkspace(_ url: URL) {
        let std = url.standardizedFileURL
        guard !workspaces.contains(std) else { return }
        workspaces.append(std)
        saveWorkspaces()
        rescan()
    }

    func removeWorkspace(_ url: URL) {
        workspaces.removeAll { $0 == url.standardizedFileURL }
        saveWorkspaces()
        rescan()
    }

    /// Re-discover services from all workspaces and reconcile with current runners,
    /// preserving the live state of services that are still present (matched by id).
    func rescan() {
        let discovered = WorkspaceScanner.scan(workspaces: workspaces)
        reconcile(with: discovered)
    }

    /// Reconcile freshly-discovered services with current runners, preserving the
    /// live state of services still present (matched by id). Main-actor only.
    private func reconcile(with discovered: [Service]) {
        let existing = Dictionary(uniqueKeysWithValues: runners.map { ($0.id, $0) })

        var next: [RunningService] = []
        var keptIDs = Set<UUID>()
        for service in discovered {
            keptIDs.insert(service.id)
            if let current = existing[service.id] {
                // Same service (same folder). If its config changed while idle, swap
                // in a fresh runner; if it's live, keep the running one as-is.
                if current.config == service || current.isLive {
                    next.append(current)
                } else {
                    next.append(RunningService(config: service))
                }
            } else {
                next.append(RunningService(config: service))
            }
        }
        // Stop + drop services that disappeared from the workspaces.
        for runner in runners where !keptIDs.contains(runner.id) {
            runner.stop()
        }
        runners = next.sorted { $0.config.name.localizedCompare($1.config.name) == .orderedAscending }
        Log.info("rescan: \(workspaces.count) workspace(s) → \(runners.count) service(s)")
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

    func startAll(in workspace: URL) { runners(in: workspace).forEach { $0.start() } }
    func stopAll(in workspace: URL) { runners(in: workspace).forEach { $0.stop() } }

    // MARK: - Workspace grouping

    /// The runners grouped by the workspace they belong to, in workspace order,
    /// with each group's runners kept in their existing (name-sorted) order. Every
    /// tracked workspace is included even with no services (so a freshly-added
    /// folder shows an empty state rather than vanishing). A trailing `nil`-keyed
    /// group holds any runner under no tracked workspace, and is omitted when empty.
    var runnersByWorkspace: [(workspace: URL?, runners: [RunningService])] {
        var groups: [(workspace: URL?, runners: [RunningService])] =
            workspaces.map { (workspace: Optional($0), runners: []) }
        var orphans: [RunningService] = []
        let indexByWorkspace = Dictionary(
            uniqueKeysWithValues: workspaces.enumerated().map { ($0.element, $0.offset) })

        for runner in runners {
            if let ws = workspace(for: runner), let i = indexByWorkspace[ws] {
                groups[i].runners.append(runner)
            } else {
                orphans.append(runner)
            }
        }
        if !orphans.isEmpty { groups.append((workspace: nil, runners: orphans)) }
        return groups
    }

    /// The tracked workspace a runner belongs to: the deepest (longest-path)
    /// workspace folder that is an ancestor of the service's directory. nil if
    /// none contains it.
    private func workspace(for runner: RunningService) -> URL? {
        let dir = URL(fileURLWithPath: runner.config.directory).standardizedFileURL.path
        return workspaces
            .filter { dir == $0.path || dir.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    private func runners(in workspace: URL) -> [RunningService] {
        let std = workspace.standardizedFileURL
        return runners.filter { self.workspace(for: $0) == std }
    }

    /// Total sampled resident memory (bytes) across a workspace's live services.
    /// nil when none have a sample yet (so the menu can omit the row).
    func totalMemoryBytes(in workspace: URL) -> Int? {
        let samples = runners(in: workspace).compactMap { $0.memoryBytes }
        return samples.isEmpty ? nil : samples.reduce(0, +)
    }

    // MARK: - Status snapshot (JSON-friendly)

    /// A serializable view of every service + live status, for the control API.
    func statusSnapshot() -> [[String: Any]] {
        runners.map { r in
            [
                "id": r.id.uuidString,
                "name": r.config.name,
                "directory": r.config.directory,
                "commands": r.config.commandStrings,
                "stopCommands": r.config.stopCommandStrings,
                "command": r.config.displayCommand,
                "port": r.config.port as Any,
                "status": r.status.label,
                "live": r.isLive,
                "memoryBytes": r.memoryBytes as Any,
            ]
        }
    }

    // MARK: - Health polling

    private func startHealthTimer() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.runners.forEach { $0.refreshHealth() }
                self.sampleMemory()
            }
        }
    }

    /// Sample resident memory for every live service in a single `ps` over all of
    /// their process groups, then distribute the per-group totals back. Runs off
    /// the main actor so the `ps` call never blocks the UI.
    private func sampleMemory() {
        // (runner, its live group ids) — captured on the main actor before hopping off.
        let work = runners.compactMap { r -> (RunningService, [Int32])? in
            let pgids = r.liveProcessGroupIDs
            return pgids.isEmpty ? nil : (r, pgids)
        }
        guard !work.isEmpty else { return }
        let allPGIDs = work.flatMap { $0.1 }
        Task.detached {
            let totals = RunningService.groupRSS(pgids: allPGIDs)
            await MainActor.run {
                for (runner, pgids) in work {
                    let bytes = pgids.reduce(0) { $0 + (totals[$1] ?? 0) }
                    runner.setMemoryBytes(bytes > 0 ? bytes : nil)
                }
            }
        }
    }

    // MARK: - Workspace persistence

    private func loadWorkspaces() {
        guard let data = try? Data(contentsOf: workspacesURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        workspaces = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func saveWorkspaces() {
        let paths = workspaces.map(\.path)
        guard let data = try? JSONEncoder().encode(paths) else { return }
        try? data.write(to: workspacesURL)
    }
}
