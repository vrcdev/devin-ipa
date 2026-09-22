import SwiftUI

struct MessageBubble: View {
    let message: SessionMessage

    var body: some View {
        HStack {
            if message.isFromUser { Spacer(minLength: 40) }
            VStack(alignment: message.isFromUser ? .trailing : .leading, spacing: 4) {
                Text(message.message)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        message.isFromUser
                            ? Color.accentColor
                            : Color(.secondarySystemBackground)
                    )
                    .foregroundStyle(message.isFromUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(FormatHelper.relative(message.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !message.isFromUser { Spacer(minLength: 40) }
        }
    }
}

struct SessionDetailView: View {
    let sessionID: String

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var session: Session?
    @State private var messages: [SessionMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmTerminate = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            composer
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .confirmationDialog(
            "Terminate this session?",
            isPresented: $confirmTerminate,
            titleVisibility: .visible
        ) {
            Button("Terminate Session", role: .destructive) {
                Task { await terminate() }
            }
            Button("Cancel", role: .cancel) {}
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

    private var header: some View {
        HStack(spacing: 10) {
            StatusDot(status: session?.statusDetail ?? session?.status ?? "")
            Text(session?.displayStatus ?? "…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let updatedAt = session?.updatedAt {
                Text("· \(FormatHelper.relative(updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let prURL = session?.pullRequests?.first?.prUrl, let url = URL(string: prURL) {
                Link(destination: url) {
                    Image(systemName: "arrow.triangle.pull")
                }
            }
            if let webURL = session?.webURL ?? URL(string: "https://app.devin.ai/sessions/\(sessionID)") {
                Link(destination: webURL) {
                    Image(systemName: "safari")
                }
            }
            Button { confirmTerminate = true } label: {
                Image(systemName: "stop.circle")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session == nil {
                    ProgressView("Loading…")
                        .padding(.top, 40)
                } else if messages.isEmpty {
                    Text("No messages yet")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
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
        do {
            async let fetchedSession = appState.client.getSession(sessionID)
            async let fetchedMessages = appState.client.listMessages(sessionID)
            session = try await fetchedSession
            messages = try await fetchedMessages
        } catch {
            if session == nil { errorText = error.localizedDescription }
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        do {
            try await appState.client.sendMessage(sessionID, text)
            draft = ""
            await load()
        } catch {
            errorText = error.localizedDescription
        }
        sending = false
    }

    private func terminate() async {
        do {
            try await appState.client.terminateSession(sessionID)
            await appState.refresh()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
