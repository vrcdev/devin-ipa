import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var token: String
    @Published var orgID: String
    @Published var bridgeURL: String
    @Published var bridgeToken: String

    private static let tokenAccount = "devin_api_token"
    private static let orgIDKey = "devin_org_id"
    private static let bridgeURLKey = "devin_bridge_url"
    private static let bridgeTokenAccount = "devin_bridge_token"

    init() {
        token = Keychain.get(Self.tokenAccount) ?? ""
        orgID = UserDefaults.standard.string(forKey: Self.orgIDKey) ?? ""
        bridgeURL = UserDefaults.standard.string(forKey: Self.bridgeURLKey) ?? ""
        bridgeToken = Keychain.get(Self.bridgeTokenAccount) ?? ""
    }

    var client: DevinAPIClient {
        DevinAPIClient(token: token, orgID: orgID)
    }

    var hasToken: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasBridge: Bool {
        !bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !bridgeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bridgeClient: LocalBridgeClient? {
        hasBridge ? LocalBridgeClient(base: bridgeURL, token: bridgeToken) : nil
    }

    func saveCredentials(token: String, orgID: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.orgID = orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(self.token, for: Self.tokenAccount)
        UserDefaults.standard.set(self.orgID, forKey: Self.orgIDKey)
    }

    func saveBridge(url: String, token: String) {
        bridgeURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        bridgeToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(bridgeURL, forKey: Self.bridgeURLKey)
        if bridgeToken.isEmpty {
            Keychain.delete(Self.bridgeTokenAccount)
        } else {
            Keychain.set(bridgeToken, for: Self.bridgeTokenAccount)
        }
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
