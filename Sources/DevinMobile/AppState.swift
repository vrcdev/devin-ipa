import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var token: String
    @Published var orgID: String
    @Published var bridges: [BridgeConfig]

    private static let tokenAccount = "devin_api_token"
    private static let orgIDKey = "devin_org_id"
    private static let bridgesKey = "devin_bridges"
    private static let bridgeTokenPrefix = "devin_bridge_token_"

    init() {
        token = Keychain.get(Self.tokenAccount) ?? ""
        orgID = UserDefaults.standard.string(forKey: Self.orgIDKey) ?? ""

        var loaded = (try? JSONDecoder().decode(
            [BridgeConfig].self,
            from: UserDefaults.standard.data(forKey: Self.bridgesKey) ?? Data()
        )) ?? []

        // Migrate the legacy single-bridge config into the list.
        let legacyURL = UserDefaults.standard.string(forKey: "devin_bridge_url") ?? ""
        let legacyToken = Keychain.get("devin_bridge_token") ?? ""
        if !legacyURL.isEmpty || !legacyToken.isEmpty {
            let bridge = BridgeConfig(name: "Local PC", url: legacyURL)
            loaded.append(bridge)
            Keychain.set(legacyToken, for: Self.bridgeTokenPrefix + bridge.id)
            UserDefaults.standard.removeObject(forKey: "devin_bridge_url")
            Keychain.delete("devin_bridge_token")
            UserDefaults.standard.set(try? JSONEncoder().encode(loaded), forKey: Self.bridgesKey)
        }
        bridges = loaded
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

    // ------------------------------------------------------------- bridges

    func bridgeToken(for bridge: BridgeConfig) -> String {
        Keychain.get(Self.bridgeTokenPrefix + bridge.id) ?? ""
    }

    func client(for bridge: BridgeConfig) -> LocalBridgeClient? {
        LocalBridgeClient(base: bridge.url, token: bridgeToken(for: bridge))
    }

    func upsertBridge(_ bridge: BridgeConfig, token: String) {
        if let i = bridges.firstIndex(where: { $0.id == bridge.id }) {
            bridges[i] = bridge
        } else {
            bridges.append(bridge)
        }
        persistBridges()
        let account = Self.bridgeTokenPrefix + bridge.id
        if token.isEmpty {
            Keychain.delete(account)
        } else {
            Keychain.set(token, for: account)
        }
    }

    func deleteBridge(_ bridge: BridgeConfig) {
        bridges.removeAll { $0.id == bridge.id }
        Keychain.delete(Self.bridgeTokenPrefix + bridge.id)
        persistBridges()
    }

    private func persistBridges() {
        UserDefaults.standard.set(try? JSONEncoder().encode(bridges), forKey: Self.bridgesKey)
    }

    // ------------------------------------------------------------- sessions

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
