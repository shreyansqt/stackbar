import Foundation
import Combine

/// One service's live runtime. A service may run several commands, each as its
/// own child process; they start and stop together. Logs from all commands are
/// merged (prefixed when there's more than one) into one buffer and one file.
@MainActor
final class RunningService: ObservableObject, Identifiable {
    nonisolated let config: Service
    nonisolated var id: UUID { config.id }

    @Published private(set) var status: ServiceStatus = .idle
    /// Ring buffer of recent log lines (all commands merged, time-ordered).
    @Published private(set) var logLines: [String] = []
    /// Per-command ring buffers, indexed to match `config.commands`. Lets the UI
    /// show one command's output in isolation (e.g. transpile-watch vs docker up).
    @Published private(set) var logLinesByCommand: [[String]] = []
    /// Per-command status, indexed to match `config.commands`, so the UI can show
    /// which specific command is running/crashed in a multi-command service.
    @Published private(set) var commandStates: [ServiceStatus] = []

    /// One child process per command in `config.commands`.
    private var processes: [Process] = []
    private var pipes: [Pipe] = []
    private let maxLines = 2000
    private let logWriter: LogFileWriter
    /// True between stop() and the resulting terminations, so we don't flag
    /// a user-requested stop as a crash.
    private var stopping = false
    /// Deterministic termination accounting (don't poll Process.isRunning,
    /// which lags and is racy when killing process groups).
    private var launchedCount = 0
    private var terminatedCount = 0

    init(config: Service) {
        self.config = config
        self.logWriter = LogFileWriter(id: config.id)
        logWriter.writeMeta(config)
    }

    var isLive: Bool {
        if case .idle = status { return false }
        if case .crashed = status { return false }
        return true
    }

    /// In a transitional state (starting up or running stop commands). The UI
    /// disables actions while busy so the user can't fire overlapping commands
    /// (e.g. start during a docker-compose-down teardown).
    var isBusy: Bool {
        if case .starting = status { return true }
        if case .stopping = status { return true }
        return false
    }

    private var anyRunning: Bool { processes.contains { $0.isRunning } }

    func start() {
        guard !isLive else { return }
        logLines.removeAll()
        logLinesByCommand = Array(repeating: [], count: config.commands.count)
        commandStates = Array(repeating: .starting, count: config.commands.count)
        logWriter.reset()
        status = .starting
        stopping = false
        processes.removeAll()
        pipes.removeAll()
        launchedCount = 0
        terminatedCount = 0

        let multi = config.commands.count > 1
        for (idx, command) in config.commands.enumerated() {
            let prefix = multi ? "[\(idx + 1)] " : ""
            spawn(command, index: idx, prefix: prefix)
        }
        if processes.isEmpty {
            status = .crashed(code: -1)
        }
    }

    private func spawn(_ command: String, index: Int, prefix: String) {
        let proc = Process()
        // Run the command in its OWN process group/session so we can later kill the
        // entire subtree (zsh → pnpm → turbo → workerd, etc.) with one group signal.
        // `perl setpgrp` makes the launched shell a group leader; without this, dev
        // servers' grandchildren get orphaned when StackBar stops or quits.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", "setpgrp; exec @ARGV", "/bin/zsh", "-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.directory)

        // Ask CLIs to emit ANSI color even though stdout is a pipe, not a TTY —
        // so the captured logs carry the same colors they'd show in a terminal.
        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "1"      // node ecosystem (vite, webpack, etc.)
        env["CLICOLOR_FORCE"] = "1"   // BSD/CLI tools
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text, index: index, prefix: prefix) }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(pipe: pipe, index: index, code: code, prefix: prefix) }
        }

        do {
            try proc.run()
            processes.append(proc)
            pipes.append(pipe)
            launchedCount += 1
            commandStates[index] = .running
            Log.info("[\(config.name)] spawned cmd[\(index)] pid \(proc.processIdentifier): \(command)")
            append("[stackbar] started: \(command)\n", index: index, prefix: prefix)
        } catch {
            commandStates[index] = .crashed(code: -1)
            Log.error("[\(config.name)] cmd[\(index)] failed to launch: \(command) — \(error.localizedDescription)")
            append("[stackbar] failed to start: \(error.localizedDescription)\n", index: index, prefix: prefix)
        }
    }

    /// Synchronous force-kill of the whole process group — used on app quit so no
    /// subtree is orphaned. SIGTERM the group, then SIGKILL as a backstop.
    func terminateNow() {
        for proc in processes where proc.isRunning {
            let pgid = proc.processIdentifier
            kill(-pgid, SIGTERM)
            kill(-pgid, SIGKILL)
        }
        // Backstop: tools like Turbo detach their workers (pnpm/workerd re-parent
        // to launchd), escaping the group signal. Kill whatever holds our port.
        Self.killProcessOnPort(config.port)
    }

    func stop() {
        Log.info("[\(config.name)] stop requested")
        stopping = true
        // Show the stopping state immediately (menu bar spinner, disabled buttons)
        // for the whole teardown — including the wait + stop commands below.
        if !config.stopCommands.isEmpty { status = .stopping }
        // 1. SIGTERM the start processes (the whole group; dev servers spawn children).
        for proc in processes where proc.isRunning {
            kill(-proc.processIdentifier, SIGTERM)
            proc.terminate()
        }
        // 1b. Backstop for detached workers (Turbo) that escaped the group signal.
        Self.killProcessOnPort(config.port)
        // 2. Run any stop commands (e.g. `docker compose down`) AFTER the start
        //    processes have fully exited. Critical for docker: SIGTERM-ing a
        //    `docker compose up` makes Compose tear the stack down itself, so
        //    firing `docker compose down` at the same time collides on the daemon
        //    and can wedge it. So wait for the up-process to finish first.
        if config.stopCommands.isEmpty {
            status = .idle
        } else {
            let procs = processes
            runStopCommands(afterExitOf: procs)
        }
    }

    /// Processes we must never kill via the port backstop. For docker-backed
    /// services the listening process on the port is the container runtime's own
    /// proxy (e.g. OrbStack / Docker / containerd) — killing it takes the whole
    /// daemon down. The backstop is only meant to catch detached dev-server workers.
    private static let protectedProcessNames = [
        "orbstack", "docker", "com.docker", "containerd", "vpnkit", "qemu",
    ]

    /// Kill whatever is listening on `port` (SIGTERM), EXCEPT container-runtime
    /// processes. Catches detached dev-server workers that re-parented away from us.
    static func killProcessOnPort(_ port: Int?) {
        guard let port else { return }
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        guard (try? lsof.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return }
        for line in out.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            let name = processName(pid: pid).lowercased()
            if protectedProcessNames.contains(where: { name.contains($0) }) {
                Log.warn("port \(port): refusing to kill protected process \(pid) (\(name))")
                continue
            }
            kill(pid, SIGTERM)
        }
    }

    /// Best-effort process command name for a pid (via `ps -o comm=`).
    private static func processName(pid: Int32) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "comm=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = Pipe()
        guard (try? ps.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Run stopCommands sequentially on a background queue (each may block, e.g.
    /// docker teardown), streaming output into the log. Status -> idle when done.
    private func runStopCommands(afterExitOf procs: [Process]) {
        status = .stopping
        let directory = config.directory
        let stopCommands = config.stopCommands
        let name = config.name
        append("[stackbar] stopping…\n", index: nil, prefix: "")
        Log.info("[\(name)] running \(stopCommands.count) stop command(s)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Wait for the start processes to fully exit first (up to ~10s) so
            // their own teardown can't collide with the stop commands.
            let deadline = Date().addingTimeInterval(10)
            for p in procs {
                while p.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            Log.info("[\(name)] start processes exited; running stop commands")

            for command in stopCommands {
                Log.info("[\(name)] stop cmd start: \(command)")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-lc", command]
                proc.currentDirectoryURL = URL(fileURLWithPath: directory)
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    Task { @MainActor in self?.append(text, index: nil, prefix: "[stop] ") }
                }
                Task { @MainActor in self?.append("[stackbar] stop: \(command)\n", index: nil, prefix: "") }
                do {
                    try proc.run()
                } catch {
                    Log.error("[\(name)] stop cmd FAILED to launch: \(command) — \(error.localizedDescription)")
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continue
                }
                proc.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                let code = proc.terminationStatus
                if code == 0 {
                    Log.info("[\(name)] stop cmd done (exit 0): \(command)")
                } else {
                    Log.warn("[\(name)] stop cmd exited \(code): \(command)")
                }
            }
            Log.info("[\(name)] all stop commands finished")
            Task { @MainActor in
                self?.status = .idle
                self?.stopping = false
                self?.append("[stackbar] stopped.\n", index: nil, prefix: "")
            }
        }
    }

    func restart() {
        stop()
        // Wait long enough for stop commands (e.g. docker down) to finish and
        // the port to be released before relaunching.
        let delay = config.stopCommands.isEmpty ? 0.6 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // If stop commands are still running, defer until idle.
            if case .stopping = self.status {
                self.restart()
            } else {
                self.start()
            }
        }
    }

    /// Called periodically by the manager to refresh port-based status.
    func refreshHealth() {
        guard anyRunning else { return }
        guard let port = config.port else {
            status = .running // no port configured: any process alive == running
            return
        }
        status = PortProbe.isOpen(port: port) ? .running : .starting
        // Reflect health onto still-live commands (leave crashed ones as crashed).
        for i in commandStates.indices {
            if case .crashed = commandStates[i] { continue }
            commandStates[i] = status
        }
    }

    /// Append output. `index` is the command it came from (nil for service-level
    /// lifecycle messages like stop). Writes to the combined buffer/file AND the
    /// per-command buffer/file.
    private func append(_ text: String, index: Int?, prefix: String) {
        let prefixed = prefix.isEmpty ? text : applyPrefix(prefix, to: text)
        logWriter.append(prefixed)
        let incoming = prefixed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Combined buffer (all commands, time-ordered).
        logLines.append(contentsOf: incoming)
        if logLines.count > maxLines { logLines.removeFirst(logLines.count - maxLines) }

        // Per-command buffer + file (unprefixed — it's already isolated).
        guard let index, index < logLinesByCommand.count else { return }
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        logLinesByCommand[index].append(contentsOf: raw)
        if logLinesByCommand[index].count > maxLines {
            logLinesByCommand[index].removeFirst(logLinesByCommand[index].count - maxLines)
        }
        logWriter.append(text, commandIndex: index)
    }

    /// Prefix each non-empty line so interleaved multi-command output stays readable.
    private func applyPrefix(_ prefix: String, to text: String) -> String {
        let hasTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = lines.enumerated().map { i, line in
            (line.isEmpty && i == lines.count - 1) ? line : prefix + line
        }.joined(separator: "\n")
        if hasTrailingNewline && !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private func handleTermination(pipe: Pipe, index: Int, code: Int32, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = nil
        terminatedCount += 1
        append("[stackbar] exited with code \(code)\n", index: index, prefix: prefix)

        // User-requested stop: SIGTERM gives a non-zero code (15), which is not
        // a crash. Stay idle, and ignore the codes entirely.
        if stopping {
            if index < commandStates.count { commandStates[index] = .idle }
            // If stop commands will run (or are running), keep the stopping state —
            // runStopCommands() owns the transition to idle when it finishes.
            if terminatedCount >= launchedCount && config.stopCommands.isEmpty {
                status = .idle
                stopping = false
            }
            return
        }
        // A command died on its own. Record which command, and mark the service
        // crashed on a non-zero exit; bring the rest down so state is consistent.
        if index < commandStates.count {
            commandStates[index] = code == 0 ? .idle : .crashed(code: code)
        }
        if code != 0 {
            status = .crashed(code: code)
            for proc in processes where proc.isRunning {
                kill(-proc.processIdentifier, SIGTERM)
            }
        } else if terminatedCount >= launchedCount {
            status = .idle
        }
    }
}
