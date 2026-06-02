import Foundation

/// Bare-minimum HTTP/1.1 request parser for the localhost control server.
/// Handles exactly what our CLI/MCP send: a request line, headers, optional
/// JSON body delimited by Content-Length. Not a general-purpose HTTP parser.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    /// True once we've received the full body indicated by Content-Length.
    let isComplete: Bool

    init?(_ data: Data) {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil // headers not fully received yet
        }
        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        self.method = String(requestParts[0])
        // Strip any query string; our routes don't use it.
        self.path = String(requestParts[1].split(separator: "?").first ?? "")

        lines.removeFirst()
        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                headers[kv[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                    kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        self.headers = headers

        let bodyStart = headerEndRange.upperBound
        let received = data.subdata(in: bodyStart..<data.count)
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        self.body = received
        self.isComplete = received.count >= expected
    }

    var bearerToken: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst(7))
    }

    var jsonBody: [String: Any]? {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj
    }
}

struct HTTPResponse {
    let status: Int
    let body: Data

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data()
        return HTTPResponse(status: status, body: data)
    }

    func encoded() -> Data {
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : (status == 401 ? "Unauthorized" : "Error"))
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
