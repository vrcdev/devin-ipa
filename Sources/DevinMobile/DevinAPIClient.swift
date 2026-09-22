import Foundation

enum APIError: LocalizedError {
    case missingToken
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add your Devin API token in Settings first."
        case .http(let status, let body):
            return "HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
        }
    }
}

private struct AnyEncodable: Encodable {
    let wrapped: Encodable
    func encode(to encoder: Encoder) throws { try wrapped.encode(to: encoder) }
}

final class DevinAPIClient {
    private static let baseURL = URL(string: "https://api.devin.ai")!

    private let token: String
    private let orgID: String

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    init(token: String, orgID: String) {
        self.token = token
        self.orgID = orgID
    }

    func listSessions(limit: Int = 100, offset: Int = 0) async throws -> [SessionSummary] {
        let data = try await request("GET", "/v1/sessions", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        return try decoder.decode(ListSessionsResponse.self, from: data).sessions
    }

    func getSession(_ sessionID: String) async throws -> SessionDetail {
        let data = try await request("GET", "/v1/sessions/\(sessionID)")
        return try decoder.decode(SessionDetail.self, from: data)
    }

    func createSession(prompt: String, title: String?) async throws -> CreateSessionResponse {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = CreateSessionRequest(
            prompt: prompt,
            title: trimmedTitle?.isEmpty == true ? nil : trimmedTitle
        )
        let data = try await request("POST", "/v1/sessions", body: body)
        return try decoder.decode(CreateSessionResponse.self, from: data)
    }

    func sendMessage(_ sessionID: String, _ message: String) async throws {
        _ = try await request(
            "POST",
            "/v1/sessions/\(sessionID)/message",
            body: SendMessageRequest(message: message)
        )
    }

    func terminateSession(_ sessionID: String) async throws {
        _ = try await request("DELETE", "/v1/sessions/\(sessionID)")
    }

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil
    ) async throws -> Data {
        guard !token.isEmpty else { throw APIError.missingToken }

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !orgID.isEmpty {
            urlRequest.setValue(orgID, forHTTPHeaderField: "X-Org-Id")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(AnyEncodable(wrapped: body))
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: "unexpected response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: String(text.prefix(500)))
        }
        return data
    }
}
