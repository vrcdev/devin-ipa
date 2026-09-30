import SwiftUI

private struct ShellEntry: Identifiable {
    let id = UUID()
    let command: String
    var stdout: String = ""
    var stderr: String = ""
    var exitCode: Int = 0
    var running = true
}

/// Stateless-feeling terminal: the bridge tracks cwd per key (this bridge's id)
/// so `cd` persists across commands.
struct ShellView: View {
    let bridge: BridgeConfig

    @EnvironmentObject var appState: AppState

    @State private var entries: [ShellEntry] = []
    @State private var draft = ""
    @State private var cwd: String?
    @State private var running = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            terminalOutput
            Divider()
            composer
        }
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { entries.removeAll() } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
            }
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

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { entry in
                        entryView(entry)
                            .id(entry.id)
                    }
                    if entries.isEmpty {
                        Text("Run commands on \(bridge.displayName).\ncd persists; output is captured, not streamed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .onChange(of: entries.count) { _ in
                if let last = entries.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func entryView(_ entry: ShellEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("$")
                    .foregroundStyle(.green)
                Text(entry.command)
                    .fontWeight(.semibold)
                if entry.running {
                    ProgressView().scaleEffect(0.6)
                } else if entry.exitCode != 0 {
                    Text("exit \(entry.exitCode)")
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            if !entry.stdout.isEmpty {
                Text(entry.stdout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            if !entry.stderr.isEmpty {
                Text(entry.stderr)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(spacing: 4) {
            if let cwd {
                Text(cwd)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            HStack(spacing: 10) {
                TextField("command", text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await run() } }
                Button {
                    Task { await run() }
                } label: {
                    Image(systemName: "return")
                        .font(.title3)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
            }
        }
        .padding()
    }

    private func run() async {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let client = appState.client(for: bridge) else { return }
        draft = ""
        running = true
        let entry = ShellEntry(command: command)
        entries.append(entry)
        let entryID = entry.id
        do {
            let result = try await client.runShell(key: bridge.id, command: command)
            if let i = entries.firstIndex(where: { $0.id == entryID }) {
                entries[i].stdout = result.stdout
                entries[i].stderr = result.stderr
                entries[i].exitCode = result.exitCode
                entries[i].running = false
            }
            cwd = result.cwd
        } catch {
            if let i = entries.firstIndex(where: { $0.id == entryID }) {
                entries[i].stderr = error.localizedDescription
                entries[i].exitCode = -1
                entries[i].running = false
            }
        }
        running = false
    }
}
