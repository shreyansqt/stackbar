import Foundation
import Combine

/// One service's live runtime: the spawned process, its log buffer, and status.
@MainActor
final class RunningService: ObservableObject, Identifiable {
    nonisolated let config: Service
    nonisolated var id: UUID { config.id }

    @Published private(set) var status: ServiceStatus = .idle
    /// Ring buffer of recent log lines (stdout+stderr merged).
    @Published private(set) var logLines: [String] = []

    private var process: Process?
    private var outPipe: Pipe?
    private let maxLines = 2000
    private let logWriter: LogFileWriter

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

    func start() {
        guard !isLive else { return }
        logLines.removeAll()
        logWriter.reset()
        status = .starting

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", config.command]
        proc.currentDirectoryURL = URL(fileURLWithPath: config.directory)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        self.outPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.append(text) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in self?.handleTermination(code: p.terminationStatus) }
        }

        do {
            try proc.run()
            self.process = proc
            append("[stackbar] started: \(config.command)\n")
        } catch {
            append("[stackbar] failed to start: \(error.localizedDescription)\n")
            status = .crashed(code: -1)
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            status = .idle
            return
        }
        // SIGTERM the whole process group; dev servers spawn children.
        let pgid = proc.processIdentifier
        kill(-pgid, SIGTERM)
        proc.terminate()
        status = .idle
    }

    func restart() {
        stop()
        // Give the OS a beat to release the port before relaunching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.start()
        }
    }

    /// Called periodically by the manager to refresh port-based status.
    func refreshHealth() {
        guard let proc = process, proc.isRunning else { return }
        guard let port = config.port else {
            status = .running // no port configured: process-alive == running
            return
        }
        let open = PortProbe.isOpen(port: port)
        status = open ? .running : .starting
    }

    private func append(_ text: String) {
        logWriter.append(text)
        let incoming = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        logLines.append(contentsOf: incoming)
        if logLines.count > maxLines {
            logLines.removeFirst(logLines.count - maxLines)
        }
    }

    private func handleTermination(code: Int32) {
        outPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        switch status {
        case .idle:
            break // user-initiated stop
        default:
            status = code == 0 ? .idle : .crashed(code: code)
            append("[stackbar] exited with code \(code)\n")
        }
    }
}
