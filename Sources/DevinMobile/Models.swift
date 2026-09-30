import Foundation

struct Session: Decodable, Identifiable, Hashable {
    let sessionId: String
    let title: String?
    let status: String
    let statusDetail: String?
    let url: String?
    let createdAt: Int
    let updatedAt: Int
    let acusConsumed: Double?
    let tags: [String]?
    let pullRequests: [SessionPullRequest]?
    let isArchived: Bool?

    var id: String { sessionId }

    var displayStatus: String {
        (statusDetail ?? status).replacingOccurrences(of: "_", with: " ")
    }

    var webURL: URL? {
        if let url, let parsed = URL(string: url) { return parsed }
        return URL(string: "https://app.devin.ai/sessions/\(sessionId)")
    }
}

struct SessionPullRequest: Decodable, Hashable {
    let prUrl: String?
    let prState: String?
}

struct SessionMessage: Decodable, Identifiable, Hashable {
    let eventId: String
    let message: String
    let createdAt: Int
    let source: String
    let origin: String?
    let username: String?

    var id: String { eventId }
    var isFromUser: Bool { source == "user" }
}

struct PageResponse<Item: Decodable>: Decodable {
    let items: [Item]
    let endCursor: String?
    let hasNextPage: Bool?
}

struct CreateSessionRequest: Encodable {
    let prompt: String
    let title: String?
}

struct SendMessageRequest: Encodable {
    let message: String
}

struct SelfResponse: Decodable {
    let principalType: String
    let userId: String?
    let userName: String?
    let orgId: String?
    let apiKeyId: String?
    let apiKeyName: String?
}

enum FormatHelper {
    static func date(_ timestamp: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    static func relative(_ timestamp: Int) -> String {
        date(timestamp).formatted(.relative(presentation: .named))
    }
}
