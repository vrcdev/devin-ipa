import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var orgID = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("cog_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Token")
                } footer: {
                    Text("Create a Personal Access Token or service user API key in the Devin web app (Settings → API Keys). Tokens start with cog_. Stored in the iOS Keychain.")
                }

                Section {
                    TextField("org-…", text: $orgID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Organization ID (optional)")
                } footer: {
                    Text("Personal Access Tokens require your org ID (starts with org-); it's sent as the X-Org-Id header. Service-user keys resolve the org automatically.")
                }

                if let testResult {
                    Section {
                        Text(testResult)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                    }
                }

                Section {
                    Button("Save") {
                        appState.saveCredentials(token: token, orgID: orgID)
                        Task {
                            await appState.refresh()
                            dismiss()
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(testing ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                token = appState.token
                orgID = appState.orgID
            }
        }
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let client = DevinAPIClient(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            orgID: orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            _ = try await client.listSessions(limit: 1)
            testResult = "OK — connected"
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}
