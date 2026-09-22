import Foundation

enum APIError: LocalizedError {
    case missingToken
    case missingOrgID
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Add your Devin API token in Settings first."
        case .missingOrgID:
            return "Add your organization ID (org-…) in Settings first."
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
    private static let qsStyleKey = "devin_qs_style"

    // The list endpoint takes a `qs` object query param whose wire encoding
    // isn't documented; these are the candidate serializations, tried in order.
    private enum QSStyle: String, CaseIterable {
        case jsonObject, flattened, nested, emptyObject
    }

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

    func listSessions(first: Int = 100) async throws -> [Session] {
        let path = "\(Self.sessionsPath(orgID))"

        if let raw = UserDefaults.standard.string(forKey: Self.qsStyleKey),
           let cached = QSStyle(rawValue: raw) {
            return try await requestSessionList(path: path, first: first, style: cached)
        }

        var lastError: Error = APIError.http(status: 0, body: "no encoding worked")
        for style in QSStyle.allCases {
            do {
                let sessions = try await requestSessionList(path: path, first: first, style: style)
                UserDefaults.standard.set(style.rawValue, forKey: Self.qsStyleKey)
                return sessions
            } catch APIError.http(let status, _) where status == 401 || status == 403 {
                throw APIError.http(status: status, body: "check your token and org ID")
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Identifies what the token authenticates as (pat_user / service_user /
    /// windsurf_session) and, when bound to one org, returns org_id.
    func getSelf() async throws -> SelfResponse {
        let data = try await request("GET", "/v3/self", requiresOrg: false)
        return try decoder.decode(SelfResponse.self, from: data)
    }

    func getSession(_ sessionID: String) async throws -> Session {
        let data = try await request("GET", "\(Self.sessionsPath(orgID))/\(sessionID)")
        return try decoder.decode(Session.self, from: data)
    }

    func listMessages(_ sessionID: String, first: Int = 200, maxPages: Int = 5) async throws -> [SessionMessage] {
        var all: [SessionMessage] = []
        var after: String? = nil
        for _ in 0..<maxPages {
            var query = [URLQueryItem(name: "first", value: String(first))]
            if let after {
                query.append(URLQueryItem(name: "after", value: after))
            }
            let data = try await request(
                "GET",
                "\(Self.sessionsPath(orgID))/\(sessionID)/messages",
                query: query
            )
            let page = try decoder.decode(PageResponse<SessionMessage>.self, from: data)
            all.append(contentsOf: page.items)
            guard page.hasNextPage == true, let cursor = page.endCursor else { break }
            after = cursor
        }
        return all
    }

    func createSession(prompt: String, title: String?) async throws -> Session {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = CreateSessionRequest(
            prompt: prompt,
            title: trimmedTitle?.isEmpty == true ? nil : trimmedTitle
        )
        let data = try await request("POST", Self.sessionsPath(orgID), body: body)
        return try decoder.decode(Session.self, from: data)
    }

    func sendMessage(_ sessionID: String, _ message: String) async throws {
        _ = try await request(
            "POST",
            "\(Self.sessionsPath(orgID))/\(sessionID)/messages",
            body: SendMessageRequest(message: message)
        )
    }

    func terminateSession(_ sessionID: String) async throws {
        _ = try await request("DELETE", "\(Self.sessionsPath(orgID))/\(sessionID)")
    }

    private static func sessionsPath(_ orgID: String) -> String {
        "/v3/organizations/\(orgID)/sessions"
    }

    private func requestSessionList(path: String, first: Int, style: QSStyle) async throws -> [Session] {
        let query: [URLQueryItem]
        switch style {
        case .jsonObject:
            query = [URLQueryItem(name: "qs", value: #"{"first":\#(first)}"#)]
        case .flattened:
            query = [URLQueryItem(name: "first", value: String(first))]
        case .nested:
            query = [URLQueryItem(name: "qs[first]", value: String(first))]
        case .emptyObject:
            query = [URLQueryItem(name: "qs", value: "{}")]
        }
        let data = try await request("GET", path, query: query)
        return try decoder.decode(PageResponse<Session>.self, from: data).items
    }

    private func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Encodable? = nil,
        requiresOrg: Bool = true
    ) async throws -> Data {
        guard !token.isEmpty else { throw APIError.missingToken }
        if requiresOrg, orgID.isEmpty { throw APIError.missingOrgID }

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
