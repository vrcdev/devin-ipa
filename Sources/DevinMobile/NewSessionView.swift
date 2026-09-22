import SwiftUI

struct NewSessionView: View {
    var onCreated: () async -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var title = ""
    @State private var creating = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What should Devin do?") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 140)
                }
                Section("Title (optional)") {
                    TextField("Session title", text: $title)
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
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
        creating = true
        do {
            _ = try await appState.client.createSession(
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title
            )
            await onCreated()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
        creating = false
    }
}
