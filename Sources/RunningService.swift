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
    /// Ring buffer of recent log lines (all commands merged).
    @Published private(set) var logLines: [String] = []

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

    private var anyRunning: Bool { processes.contains { $0.isRunning } }

    func start() {
        guard !isLive else { return }
        logLines.removeAll()
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
            spawn(command, prefix: prefix)
        }
        if processes.isEmpty {
            status = .crashed(code: -1)
        }
    }

    private func spawn(_ command: String, prefix: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.directory)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text, prefix: prefix) }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(pipe: pipe, code: code, prefix: prefix) }
        }

        do {
            try proc.run()
            processes.append(proc)
            pipes.append(pipe)
            launchedCount += 1
            append("[stackbar] started: \(command)\n", prefix: prefix)
        } catch {
            append("[stackbar] failed to start: \(error.localizedDescription)\n", prefix: prefix)
        }
    }

    func stop() {
        guard anyRunning else {
            status = .idle
            return
        }
        stopping = true
        for proc in processes where proc.isRunning {
            // SIGTERM the whole process group; dev servers spawn children.
            kill(-proc.processIdentifier, SIGTERM)
            proc.terminate()
        }
        status = .idle
    }

    func restart() {
        stop()
        // Give the OS a beat to release the port before relaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.start()
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
    }

    private func append(_ text: String, prefix: String) {
        let prefixed = prefix.isEmpty ? text : applyPrefix(prefix, to: text)
        logWriter.append(prefixed)
        let incoming = prefixed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        logLines.append(contentsOf: incoming)
        if logLines.count > maxLines {
            logLines.removeFirst(logLines.count - maxLines)
        }
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

    private func handleTermination(pipe: Pipe, code: Int32, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = nil
        terminatedCount += 1
        append("[stackbar] exited with code \(code)\n", prefix: prefix)

        // User-requested stop: SIGTERM gives a non-zero code (15), which is not
        // a crash. Stay idle, and ignore the codes entirely.
        if stopping {
            if terminatedCount >= launchedCount { status = .idle; stopping = false }
            return
        }
        // A command died on its own. Non-zero exit => crash; bring the rest down
        // so the service's state is consistent. A clean exit of one command in a
        // multi-command service is unusual but treated as the service stopping
        // once all have exited.
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
