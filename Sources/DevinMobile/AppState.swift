import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var token: String
    @Published var orgID: String

    private static let tokenAccount = "devin_api_token"
    private static let orgIDKey = "devin_org_id"

    init() {
        token = Keychain.get(Self.tokenAccount) ?? ""
        orgID = UserDefaults.standard.string(forKey: Self.orgIDKey) ?? ""
    }

    var client: DevinAPIClient {
        DevinAPIClient(token: token, orgID: orgID)
    }

    var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func saveCredentials(token: String, orgID: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.orgID = orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(self.token, for: Self.tokenAccount)
        UserDefaults.standard.set(self.orgID, forKey: Self.orgIDKey)
    }

    func refresh() async {
        guard hasToken else { return }
        isLoading = sessions.isEmpty
        do {
            sessions = try await client.listSessions()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
