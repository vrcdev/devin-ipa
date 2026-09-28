import Foundation

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

private struct BridgeSessionsResponse: Decodable {
    let workspaces: [BridgeWorkspace]
}

private struct BridgeNewSessionResponse: Decodable {
    let sessionId: String
}

/// Talks to `bridge/devin_local_bridge.py` running on the user's PC.
final class LocalBridgeClient {
    private let base: URL
    private let token: String

    init?(base: String, token: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        self.base = url
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func newSession(ws: Int, prompt: String) async throws -> String {
        let data = try await request("POST", "/session", body: ["ws": ws, "prompt": prompt])
        return try JSONDecoder().decode(BridgeNewSessionResponse.self, from: data).sessionId
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        try await request(method, base.appendingPathComponent(path), body: body)
    }

    private func request(_ method: String, _ url: URL, body: [String: Any]? = nil) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.timeoutInterval = 120
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
