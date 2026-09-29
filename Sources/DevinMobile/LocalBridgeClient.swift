import Foundation

/// One PC running `devin_local_bridge.py`. Persisted in UserDefaults;
/// the bearer token lives in the Keychain under `devin_bridge_token_<id>`.
struct BridgeConfig: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var url: String

    init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    var displayName: String {
        name.isEmpty ? (URL(string: url)?.host ?? url) : name
    }
}

struct BridgeHealth: Decodable {
    let ok: Bool
    let version: String?
    let hostname: String?
    let shell: Bool?
    let workspaces: [String]?
}

struct BridgeSession: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let status: String?
    let updatedAt: String?
}

struct BridgeWorkspace: Decodable, Hashable {
    let index: Int
    let dir: String
    let sessions: [BridgeSession]
}

struct BridgeMessage: Decodable, Identifiable, Hashable {
    let id: String
    let role: String
    let text: String
    let status: String?

    var isFromUser: Bool { role == "user" }
}

struct BridgeTranscript: Decodable {
    let running: Bool
    let messages: [BridgeMessage]
}

struct BridgeShellResult: Decodable {
    let stdout: String
    let stderr: String
    let exitCode: Int
    let cwd: String
}

private struct BridgeSessionsResponse: Decodable {
    let workspaces: [BridgeWorkspace]
}

private struct BridgeNewSessionResponse: Decodable {
    let sessionId: String
    let ws: Int?
}

/// Talks to `bridge/devin_local_bridge.py` running on one PC.
final class LocalBridgeClient {
    private let base: URL
    private let token: String

    init?(base: String, token: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        self.base = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func health() async throws -> BridgeHealth {
        let data = try await request("GET", "/health", timeout: 15)
        return try JSONDecoder().decode(BridgeHealth.self, from: data)
    }

    func listWorkspaces() async throws -> [BridgeWorkspace] {
        let data = try await request("GET", "/sessions")
        return try JSONDecoder().decode(BridgeSessionsResponse.self, from: data).workspaces
    }

    func transcript(ws: Int, sessionID: String) async throws -> BridgeTranscript {
        var components = URLComponents(url: base.appendingPathComponent("/transcript"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ws", value: String(ws)),
            URLQueryItem(name: "id", value: sessionID),
        ]
        let data = try await request("GET", components.url!)
        return try JSONDecoder().decode(BridgeTranscript.self, from: data)
    }

    func sendMessage(ws: Int, sessionID: String, text: String) async throws {
        _ = try await request("POST", "/message", body: ["ws": ws, "id": sessionID, "text": text])
    }

    /// Creates a session; pass a workspace index OR a raw directory path.
    /// Returns (sessionId, wsIndex) — custom dirs join the bridge's workspace list.
    func newSession(ws: Int? = nil, dir: String? = nil, prompt: String) async throws -> (sessionId: String, ws: Int) {
        var body: [String: Any] = ["prompt": prompt]
        if let ws { body["ws"] = ws }
        if let dir { body["dir"] = dir }
        let data = try await request("POST", "/session", body: body)
        let res = try JSONDecoder().decode(BridgeNewSessionResponse.self, from: data)
        return (res.sessionId, res.ws ?? ws ?? 0)
    }

    func runShell(key: String, command: String) async throws -> BridgeShellResult {
        let data = try await request("POST", "/shell", body: ["key": key, "command": command])
        return try JSONDecoder().decode(BridgeShellResult.self, from: data)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 120) async throws -> Data {
        try await request(method, base.appendingPathComponent(path), body: body, timeout: timeout)
    }

    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil, timeout: TimeInterval = 120) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = timeout
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: "unexpected response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: String(text.prefix(300)))
        }
        return data
    }
}
