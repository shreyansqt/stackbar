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

        // Services are read-only here now (config lives in .stackbar.json files).
        if parts == ["services"], m == "GET" {
            return .json(["services": manager.statusSnapshot()])
        }
        if m == "POST" && parts == ["start-all"] { manager.startAll(); return .json(["ok": true]) }
        if m == "POST" && parts == ["stop-all"] { manager.stopAll(); return .json(["ok": true]) }
        if m == "POST" && parts == ["rescan"] { manager.rescan(); return .json(["ok": true, "services": manager.statusSnapshot()]) }

        // Workspace management.
        if parts == ["workspaces"] {
            if m == "GET" { return .json(["workspaces": manager.workspaces.map(\.path)]) }
            if m == "POST" {
                guard let body = req.jsonBody, let path = body["path"] as? String else {
                    return .json(["error": "path required"], status: 400)
                }
                manager.addWorkspace(URL(fileURLWithPath: path))
                return .json(["ok": true, "services": manager.statusSnapshot()])
            }
            if m == "DELETE" {
                guard let body = req.jsonBody, let path = body["path"] as? String else {
                    return .json(["error": "path required"], status: 400)
                }
                manager.removeWorkspace(URL(fileURLWithPath: path))
                return .json(["ok": true, "services": manager.statusSnapshot()])
            }
        }

        // Service actions: /services/<idOrName>/<action>
        if parts.count >= 3, parts[0] == "services" {
            let idOrName = parts[1]
            let action = parts[2]
            guard let r = manager.resolve(idOrName) else { return notFound(idOrName) }
            switch (m, action) {
            case ("POST", "start"): r.start(); return .json(["ok": true, "status": r.status.label])
            case ("POST", "stop"): r.stop(); return .json(["ok": true, "status": r.status.label])
            case ("POST", "restart"): r.restart(); return .json(["ok": true])
            default: break
            }
        }

        return .json(["error": "not found", "path": req.path], status: 404)
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
