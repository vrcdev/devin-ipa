import SwiftUI

struct StatusDot: View {
    let status: String

    private var color: Color {
        switch status {
        case "working", "running", "resumed", "resuming", "resume_requested", "new", "claimed":
            return .green
        case "blocked", "suspend_requested", "suspended":
            return .orange
        case "finished", "exit":
            return .gray
        case "expired", "error":
            return .red
        default:
            return .blue
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: session.statusEnum ?? session.status)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title ?? session.sessionId)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(FormatHelper.relative(session.updatedAt))
                    if let tags = session.tags, !tags.isEmpty {
                        Text(tags.joined(separator: ", "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if session.pullRequest != nil {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var showNewSession = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !appState.hasToken {
                    missingTokenView
                } else if appState.sessions.isEmpty && appState.isLoading {
                    ProgressView("Loading sessions…")
                } else if appState.sessions.isEmpty {
                    emptyView
                } else {
                    sessionList
                }
            }
            .navigationTitle("Devin")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNewSession = true } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!appState.hasToken)
                }
            }
            .task { await appState.refresh() }
            .navigationDestination(for: SessionSummary.self) { session in
                SessionDetailView(sessionID: session.sessionId)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showNewSession) {
                NewSessionView {
                    await appState.refresh()
                }
                .environmentObject(appState)
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { appState.errorMessage != nil },
                    set: { if !$0 { appState.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { appState.errorMessage = nil }
            } message: {
                Text(appState.errorMessage ?? "")
            }
        }
    }

    private var sessionList: some View {
        List(appState.sessions) { session in
            NavigationLink(value: session) {
                SessionRow(session: session)
            }
        }
        .refreshable { await appState.refresh() }
    }

    private var missingTokenView: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No API token")
                .font(.title3.bold())
            Text("Add a Devin API token to see your sessions.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No sessions yet")
                .font(.title3.bold())
            if let errorMessage = appState.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("New Session") { showNewSession = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
