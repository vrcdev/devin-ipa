import SwiftUI

struct LocalSessionsView: View {
    let bridge: BridgeConfig

    @EnvironmentObject var appState: AppState
    @State private var workspaces: [BridgeWorkspace] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var showNewSession = false

    var body: some View {
        Group {
            if workspaces.isEmpty && loading {
                ProgressView("Loading local sessions…")
            } else if workspaces.isEmpty {
                emptyView
            } else {
                sessionList
            }
        }
        .navigationTitle(bridge.displayName)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    NavigationLink {
                        ShellView(bridge: bridge).environmentObject(appState)
                    } label: {
                        Image(systemName: "terminal")
                    }
                    Button { showNewSession = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showNewSession) {
            NewLocalSessionView(bridge: bridge, workspaces: workspaces) {
                await refresh()
            }
            .environmentObject(appState)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var sessionList: some View {
        List {
            ForEach(workspaces, id: \.index) { ws in
                Section(header: Text(ws.dir).font(.caption)) {
                    ForEach(ws.sessions) { session in
                        NavigationLink(value: LocalRoute(bridge: bridge, ws: ws.index, id: session.id, title: session.title)) {
                            HStack(spacing: 12) {
                                StatusDot(status: session.status ?? "")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.title ?? session.id)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if let status = session.status {
                                        Text(status.replacingOccurrences(of: "_", with: " "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .refreshable { await refresh() }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No local sessions found")
                .font(.title3.bold())
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("New Local Session") { showNewSession = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func refresh() async {
        guard let client = appState.client(for: bridge) else { return }
        loading = workspaces.isEmpty
        do {
            workspaces = try await client.listWorkspaces()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}

struct LocalRoute: Hashable {
    let bridge: BridgeConfig
    let ws: Int
    let id: String
    let title: String?
}

struct LocalSessionDetailView: View {
    let bridge: BridgeConfig
    let ws: Int
    let sessionID: String
    let title: String?

    @EnvironmentObject var appState: AppState

    @State private var transcript: BridgeTranscript?
    @State private var draft = ""
    @State private var sending = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if transcript?.running == true {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Devin is working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Divider()
            }
            messageList
            Divider()
            composer
        }
        .navigationTitle(title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if transcript == nil {
                    ProgressView("Loading…")
                        .padding(.top, 40)
                } else if transcript?.messages.isEmpty == true {
                    Text("No messages yet")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(transcript?.messages ?? []) { message in
                            LocalMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: transcript?.messages.count) { _ in
                if let last = transcript?.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Devin…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
        .padding()
    }

    private func load() async {
        guard let client = appState.client(for: bridge) else { return }
        do {
            transcript = try await client.transcript(ws: ws, sessionID: sessionID)
        } catch {
            if transcript == nil { errorText = error.localizedDescription }
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                let interval: UInt64 = transcript?.running == true ? 3_000_000_000 : 10_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = appState.client(for: bridge) else { return }
        sending = true
        do {
            try await client.sendMessage(ws: ws, sessionID: sessionID, text: text, apiKey: appState.token)
            draft = ""
            await load()
        } catch {
            errorText = error.localizedDescription
        }
        sending = false
    }
}

struct LocalMessageRow: View {
    let message: BridgeMessage

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        case "agent":
            HStack {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 40)
            }
        case "tool":
            HStack(spacing: 8) {
                Image(systemName: "wrench")
                    .font(.caption2)
                Text(message.text)
                    .font(.caption)
                    .lineLimit(2)
                if let status = message.status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
        default: // thought, plan
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NewLocalSessionView: View {
    let bridge: BridgeConfig
    let workspaces: [BridgeWorkspace]
    var onCreated: () async -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var wsIndex = 0
    @State private var customDir = ""
    @State private var creating = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What should Devin do?") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                }
                Section {
                    Picker("Directory", selection: $wsIndex) {
                        ForEach(workspaces, id: \.index) { ws in
                            Text(ws.dir).tag(ws.index)
                        }
                    }
                    .disabled(!customDir.isEmpty)
                    TextField("Or a custom path on that PC…", text: $customDir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Workspace")
                } footer: {
                    Text("A custom path is added to the bridge's workspace list for next time.")
                }
            }
            .navigationTitle("New Local Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating)
                }
            }
            .overlay {
                if creating {
                    ProgressView("Starting session…")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert(
                "Couldn't create session",
                isPresented: Binding(
                    get: { errorText != nil },
                    set: { if !$0 { errorText = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func create() async {
        guard let client = appState.client(for: bridge) else { return }
        creating = true
        do {
            let dir = customDir.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await client.newSession(
                ws: dir.isEmpty ? wsIndex : nil,
                dir: dir.isEmpty ? nil : dir,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: appState.token
            )
            await onCreated()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        creating = false
    }
}
