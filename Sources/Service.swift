import Foundation

/// A configured service the user wants to run locally.
struct Service: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Working directory the commands run in. Absolute path.
    var directory: String
    /// One or more shell commands, each run via `/bin/zsh -lc` as its own
    /// child process. A service with two commands (e.g. a transpile watcher +
    /// a docker compose up) starts/stops them together.
    var commands: [String]
    /// Optional shell commands run on stop, in order, AFTER the start processes
    /// are SIGTERM'd — e.g. `docker compose down` to tear down containers that a
    /// `docker compose up` start command left running. Empty = SIGTERM only.
    var stopCommands: [String]
    /// TCP port to probe for "is it actually up". nil = process-alive only.
    var port: Int?

    init(id: UUID = UUID(), name: String, directory: String, commands: [String],
         stopCommands: [String] = [], port: Int? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.commands = commands
        self.stopCommands = stopCommands
        self.port = port
    }

    init(id: UUID = UUID(), name: String, directory: String, command: String, port: Int? = nil) {
        self.init(id: id, name: name, directory: directory, commands: [command], port: port)
    }

    /// Display string joining all commands.
    var displayCommand: String { commands.joined(separator: "  &&  ") }

    // Backward/forward compatible coding: accept either `commands: [...]`
    // (new) or `command: "..."` (old single-command configs).
    enum CodingKeys: String, CodingKey { case id, name, directory, commands, command, stopCommands, port }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(String.self, forKey: .directory)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        stopCommands = try c.decodeIfPresent([String].self, forKey: .stopCommands) ?? []
        if let cmds = try c.decodeIfPresent([String].self, forKey: .commands) {
            commands = cmds
        } else if let single = try c.decodeIfPresent(String.self, forKey: .command) {
            commands = [single]
        } else {
            commands = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(directory, forKey: .directory)
        try c.encode(commands, forKey: .commands)
        if !stopCommands.isEmpty { try c.encode(stopCommands, forKey: .stopCommands) }
        try c.encodeIfPresent(port, forKey: .port)
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
    /// Running the service's stop commands (e.g. docker compose down).
    case stopping
    /// Process exited non-zero while we expected it up.
    case crashed(code: Int32)

    var dotColor: StatusColor {
        switch self {
        case .idle: return .gray
        case .starting, .stopping: return .yellow
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
        case .stopping: return "stopping"
        case .crashed(let code): return "crashed(\(code))"
        }
    }
}

enum StatusColor {
    case gray, yellow, green, red
}
