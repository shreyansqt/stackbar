import Foundation
import Network

/// A minimal localhost-only HTTP control server so the `stackbar` CLI and MCP
/// can drive the app: list/add/edit/remove services and start/stop/restart them.
///
/// Security: binds 127.0.0.1 only, on an OS-assigned port. The port and a random
/// bearer token are written to files under Application Support (token chmod 600).
/// Every request must carry `Authorization: Bearer <token>`. So only a process
/// that can read the user's home directory can issue commands — same trust
/// boundary as the config and logs themselves.
@MainActor
final class ControlServer {
    private let manager: ServiceManager
    private var listener: NWListener?
    private let token: String

    init(manager: ServiceManager) {
        self.manager = manager
        self.token = Self.loadOrCreateToken()
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            self.listener = listener

            listener.stateUpdateHandler = { state in
                guard case .ready = state, let port = listener.port else { return }
                MainActor.assumeIsolated { Self.writePortFile(port.rawValue) }
            }
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.handle(conn) }
            }
            listener.start(queue: .main)
        } catch {
            NSLog("StackBar ControlServer failed to start: \(error)")
        }
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }

                // Wait until we have headers; then, if there's a body, until it's complete.
                if let request = HTTPRequest(buffer), request.isComplete {
                    let response = self.route(request)
                    conn.send(content: response.encoded(), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                    return
                }
                if error != nil || isComplete {
                    conn.cancel()
                    return
                }
                self.receive(conn, buffer: buffer)
            }
        }
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        guard req.bearerToken == token else {
            return .json(["error": "unauthorized"], status: 401)
        }
        // Percent-decode each path component so service names with spaces or
        // punctuation (e.g. "smarta%20banking") resolve correctly.
        let parts = req.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let m = req.method

        // Collection routes.
        if parts == ["services"] {
            if m == "GET" { return .json(["services": manager.statusSnapshot()]) }
            if m == "POST" { return addService(req) }
        }
        if m == "POST" && parts == ["start-all"] { manager.startAll(); return .json(["ok": true]) }
        if m == "POST" && parts == ["stop-all"] { manager.stopAll(); return .json(["ok": true]) }

        // Item routes: /services/<idOrName>[/action]
        if parts.count >= 2, parts[0] == "services" {
            let idOrName = parts[1]
            let action = parts.count >= 3 ? parts[2] : nil

            switch (m, action) {
            case ("PATCH", nil):
                return editService(idOrName, req)
            case ("DELETE", nil):
                guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
                manager.deleteService(id: r.id)
                return .json(["ok": true])
            case ("POST", "start"):
                guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
                r.start()
                return .json(["ok": true, "status": r.status.label])
            case ("POST", "stop"):
                guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
                r.stop()
                return .json(["ok": true, "status": r.status.label])
            case ("POST", "restart"):
                guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
                r.restart()
                return .json(["ok": true])
            default:
                break
            }
        }

        return .json(["error": "not found", "path": req.path], status: 404)
    }

    /// Accept either `commands: [String]` or a single `command: String`.
    private func extractCommands(_ body: [String: Any]) -> [String]? {
        if let cmds = body["commands"] as? [String], !cmds.isEmpty { return cmds }
        if let single = body["command"] as? String { return [single] }
        return nil
    }

    private func addService(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = req.jsonBody,
              let name = body["name"] as? String,
              let directory = body["directory"] as? String,
              let commands = extractCommands(body) else {
            return .json(["error": "name, directory, and command(s) required"], status: 400)
        }
        let port = body["port"] as? Int
        let stopCommands = (body["stopCommands"] as? [String]) ?? []
        let service = Service(name: name, directory: directory, commands: commands,
                              stopCommands: stopCommands, port: port)
        manager.addService(service)
        return .json(["ok": true, "id": service.id.uuidString])
    }

    private func editService(_ idOrName: String, _ req: HTTPRequest) -> HTTPResponse {
        guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
        guard let body = req.jsonBody else { return .json(["error": "invalid body"], status: 400) }
        let old = r.config
        let updated = Service(
            id: old.id,
            name: body["name"] as? String ?? old.name,
            directory: body["directory"] as? String ?? old.directory,
            commands: extractCommands(body) ?? old.commands,
            stopCommands: (body["stopCommands"] as? [String]) ?? old.stopCommands,
            port: body.keys.contains("port") ? (body["port"] as? Int) : old.port
        )
        manager.updateService(updated)
        return .json(["ok": true, "id": updated.id.uuidString])
    }

    private func notFound(_ idOrName: String) -> HTTPResponse {
        .json(["error": "no service matching '\(idOrName)'"], status: 404)
    }

    // MARK: - Token & port files

    private static func loadOrCreateToken() -> String {
        let url = LogStore.root.appendingPathComponent("control.token")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = UUID().uuidString + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }

    private static func writePortFile(_ port: UInt16) {
        let url = LogStore.root.appendingPathComponent("control.port")
        try? String(port).write(to: url, atomically: true, encoding: .utf8)
    }
}
