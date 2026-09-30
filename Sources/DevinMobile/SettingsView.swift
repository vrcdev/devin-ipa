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
    @State private var safariPage: SignInPage?
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
                    Text("Must be YOUR org — shown at the top of Settings → Devin API in the Devin web app.")
                }

                Section {
                } header: {
                    Text("Local Bridges")
                } footer: {
                    Text("PCs running devin_local_bridge.py are managed on the Local tab — tap + there to add each computer's URL and token.")
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
            .sheet(item: $safariPage) { page in
                SafariView(url: page.url)
                    .ignoresSafeArea()
            }
            .onAppear {
                token = appState.token
                orgID = appState.orgID
            }
        }
    }

    private func startSignIn() {
        let pkce = PKCE.make()
        verifier = pkce.verifier
        authURL = DevinAuth.signInURL(state: pkce.state, codeChallenge: pkce.challenge)
        safariPage = authURL.map(SignInPage.init)
        codeInput = ""
        signInStatus = nil
    }

    private func showSafari() {
        guard let url = authURL else { return }
        safariPage = nil
        DispatchQueue.main.async { safariPage = SignInPage(url: url) }
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
            var status = "Signed in"
            do {
                let me = try await probe.getSelf()
                status = "Signed in as \(me.userName ?? me.principalType)"
                if let discoveredOrg = me.orgId, !discoveredOrg.isEmpty {
                    orgID = discoveredOrg
                }
            } catch {
                status = "Signed in — profile lookup failed: \(error.localizedDescription)"
            }
            if orgID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let discovered = try? await DevinAuth.listOrgs(token: newToken), !discovered.isEmpty {
                    orgID = discovered
                } else if let discovered = try? await DevinAuth.discoverOrg(token: newToken), !discovered.isEmpty {
                    orgID = discovered
                }
            }
            signInStatus = status + (orgID.isEmpty ? " — enter org ID, tap Save" : " — tap Save")
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
            if !enteredOrg.isEmpty {
                _ = try await client.listSessions(first: 1)
                detail += ", sessions OK"
            } else if let discovered = try? await DevinAuth.listOrgs(token: token.trimmingCharacters(in: .whitespacesAndNewlines)), !discovered.isEmpty {
                detail += " — your org is \(discovered)"
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
