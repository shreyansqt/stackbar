import Foundation

/// One shell command in a service's start or stop list. `background` controls
/// whether the runner WAITS for it to exit before launching the next command:
///   - background == true  → launch and immediately move on (long-lived: watchers,
///     `docker compose up`, dev servers that never exit).
///   - background == false → run to completion before the next command starts
///     (short-lived prerequisites: `orb start`, a migration, `docker compose down`).
///
/// In JSON a command may be written two ways:
///   - a plain string  "yarn dev"                            → background (don't wait)
///   - an object       { "run": "...", "background": false } → wait for it
struct Command: Codable, Equatable {
    var run: String
    var background: Bool

    init(run: String, background: Bool = true) {
        self.run = run
        self.background = background
    }

    enum CodingKeys: String, CodingKey { case run, background }

    init(from decoder: Decoder) throws {
        // String shorthand → background command.
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            run = single
            background = true
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run = try c.decode(String.self, forKey: .run)
        background = try c.decodeIfPresent(Bool.self, forKey: .background) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(run, forKey: .run)
        try c.encode(background, forKey: .background)
    }
}

/// A configured service the user wants to run locally.
struct Service: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Working directory the commands run in. Absolute path.
    var directory: String
    /// One or more shell commands run via `/bin/zsh -lc`, in order. The runner
    /// waits for each non-background command to exit before starting the next;
    /// background commands (watchers, docker up) are launched and left running.
    var commands: [Command]
    /// Shell commands run on stop, in order, AFTER the start processes are
    /// SIGTERM'd — e.g. `docker compose down`. Same background semantics, though
    /// stop steps are normally short-lived (background: false).
    var stopCommands: [Command]
    /// TCP port to probe for "is it actually up". nil = process-alive only.
    var port: Int?

    init(id: UUID = UUID(), name: String, directory: String, commands: [Command],
         stopCommands: [Command] = [], port: Int? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.commands = commands
        self.stopCommands = stopCommands
        self.port = port
    }

    /// The shell text of each start command, for display/logging/menu titles.
    var commandStrings: [String] { commands.map(\.run) }
    /// The shell text of each stop command, for display/logging/menu titles.
    var stopCommandStrings: [String] { stopCommands.map(\.run) }

    /// Display string joining all commands.
    var displayCommand: String { commandStrings.joined(separator: "  ·  ") }

    enum CodingKeys: String, CodingKey { case id, name, directory, commands, stopCommands, port }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        directory = try c.decode(String.self, forKey: .directory)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        stopCommands = try c.decodeIfPresent([Command].self, forKey: .stopCommands) ?? []
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

    /// Compact hint shown at rest in the menu row (no exit code noise).
    var shortLabel: String {
        switch self {
        case .idle: return ""
        case .starting: return "starting…"
        case .running: return "running"
        case .stopping: return "stopping…"
        case .crashed: return "crashed"
        }
    }
}

enum StatusColor {
    case gray, yellow, green, red
}
