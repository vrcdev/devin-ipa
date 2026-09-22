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
                    Text("Organization ID")
                } footer: {
                    Text("Required — the app calls /v3/organizations/{org-id}/…, so this is in every request URL. Find it in the Devin web app under Settings → Organizations.")
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
                    .disabled(canSave)

                    Button(testing ? "Testing…" : "Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(canSave || testing)
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

    private var canSave: Bool {
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let client = DevinAPIClient(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            orgID: orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            _ = try await client.listSessions(first: 1)
            testResult = "OK — connected"
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}
