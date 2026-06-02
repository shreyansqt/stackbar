import Foundation

/// A configured service the user wants to run locally.
struct Service: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Working directory the command runs in. Absolute path.
    var directory: String
    /// Shell command, run via `/bin/zsh -lc`.
    var command: String
    /// TCP port to probe for "is it actually up". nil = process-alive only.
    var port: Int?

    init(id: UUID = UUID(), name: String, directory: String, command: String, port: Int? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.command = command
        self.port = port
    }
}

/// Live status of a service, derived from the running process + port probe.
enum ServiceStatus: Equatable {
    /// Not started, or stopped cleanly by the user.
    case idle
    /// Process spawned, port not yet accepting connections.
    case starting
    /// Process alive and (if a port is configured) port is open.
    case running
    /// Process exited non-zero while we expected it up.
    case crashed(code: Int32)

    var dotColor: StatusColor {
        switch self {
        case .idle: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .crashed: return .red
        }
    }

    /// Stable string for the control API / CLI.
    var label: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "running"
        case .crashed(let code): return "crashed(\(code))"
        }
    }
}

enum StatusColor {
    case gray, yellow, green, red
}
