import Foundation

struct SessionSummary: Decodable, Identifiable, Hashable {
    let sessionId: String
    let title: String?
    let status: String
    let statusEnum: String?
    let createdAt: String
    let updatedAt: String
    let tags: [String]?
    let pullRequest: PullRequestInfo?
    let requestingUserEmail: String?

    var id: String { sessionId }
}

struct PullRequestInfo: Decodable, Hashable {
    let url: String
}

struct ListSessionsResponse: Decodable {
    let sessions: [SessionSummary]
}

struct SessionDetail: Decodable {
    let sessionId: String
    let title: String?
    let status: String
    let statusEnum: String?
    let createdAt: String
    let updatedAt: String
    let messages: [SessionMessage]?
    let pullRequest: PullRequestInfo?
    let tags: [String]?
}

struct SessionMessage: Decodable, Identifiable, Hashable {
    let eventId: String
    let message: String
    let timestamp: String
    let type: String
    let origin: String?
    let username: String?

    var id: String { eventId }

    var isFromUser: Bool {
        type.localizedCaseInsensitiveContains("user") && !type.localizedCaseInsensitiveContains("devin")
    }
}

struct CreateSessionRequest: Encodable {
    let prompt: String
    let title: String?
}

struct CreateSessionResponse: Decodable {
    let sessionId: String
    let url: String
}

struct SendMessageRequest: Encodable {
    let message: String
}

enum FormatHelper {
    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func relative(_ string: String) -> String {
        guard let date = date(string) else { return string }
        return date.formatted(.relative(presentation: .named))
    }
}
