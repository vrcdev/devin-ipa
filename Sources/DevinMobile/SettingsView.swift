import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var token = ""
    @State private var orgID = ""
    @State private var testResult: String?
    @State private var testing = false

    @State private var verifier: String?
    @State private var authURL: URL?
    @State private var safariURL: URL?
    @State private var codeInput = ""
    @State private var exchanging = false
    @State private var signInStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Sign in with Devin") { startSignIn() }

                    if verifier != nil {
                        TextField("Paste the code from the sign-in page", text: $codeInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button(exchanging ? "Signing in…" : "Complete sign-in") {
                            Task { await completeSignIn() }
                        }
                        .disabled(codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || exchanging)

                        Button("Reopen sign-in page") { showSafari() }
                            .disabled(authURL == nil)
                    }

                    if let signInStatus {
                        Text(signInStatus)
                            .foregroundStyle(signInStatus.hasPrefix("Signed in") ? .green : .red)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text("Signs in with your Devin account in a browser sheet, then paste the code it shows. The token it mints is stored in the iOS Keychain.")
                }

                Section {
                    SecureField("cog_…", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("API Token")
                } footer: {
                    Text("Or paste a Personal Access Token / service user key (starts with cog_) instead of signing in.")
                }

                Section {
                    TextField("org-…", text: $orgID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Organization ID")
                } footer: {
                    Text("Filled automatically after sign-in. Otherwise find it under Settings → Organizations in the Devin web app.")
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
            .sheet(item: $safariItem) { item in
                SafariView(url: item.url)
                    .ignoresSafeArea()
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

    private var safariItem: Binding<SignInPage?> {
        Binding(
            get: { safariURL.map(SignInPage.init) },
            set: { if $0 == nil { safariURL = nil } }
        )
    }

    private func startSignIn() {
        let pkce = PKCE.make()
        verifier = pkce.verifier
        authURL = DevinAuth.signInURL(state: pkce.state, codeChallenge: pkce.challenge)
        safariURL = authURL
        codeInput = ""
        signInStatus = nil
    }

    private func showSafari() {
        guard let url = authURL else { return }
        safariURL = nil
        DispatchQueue.main.async { safariURL = url }
    }

    private func completeSignIn() async {
        guard let verifier else { return }
        exchanging = true
        signInStatus = nil
        do {
            let newToken = try await DevinAuth.exchange(
                code: codeInput.trimmingCharacters(in: .whitespacesAndNewlines),
                verifier: verifier
            )
            token = newToken

            let probe = DevinAPIClient(token: newToken, orgID: "")
            if let me = try? await probe.getSelf() {
                if let discoveredOrg = me.orgId, !discoveredOrg.isEmpty {
                    orgID = discoveredOrg
                }
                signInStatus = "Signed in as \(me.userName ?? me.principalType) — tap Save"
            } else {
                signInStatus = "Signed in — tap Save"
            }
            self.verifier = nil
            authURL = nil
            codeInput = ""
        } catch {
            signInStatus = error.localizedDescription
        }
        exchanging = false
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        let client = DevinAPIClient(
            token: token.trimmingCharacters(in: .whitespacesAndNewlines),
            orgID: orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            let me = try await client.getSelf()
            var detail = "OK — token valid (\(me.principalType)\(me.userName.map { ", \($0)" } ?? ""))"
            let enteredOrg = orgID.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tokenOrg = me.orgId, !tokenOrg.isEmpty, !enteredOrg.isEmpty, tokenOrg != enteredOrg {
                detail += " — token org \(tokenOrg) differs from entered org"
            }
            if !orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await client.listSessions(first: 1)
                detail += ", sessions OK"
            }
            testResult = detail
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}

private struct SignInPage: Identifiable {
    let id = UUID()
    let url: URL
}
