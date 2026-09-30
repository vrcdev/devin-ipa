import SwiftUI

/// Local tab root: list of PCs running devin_local_bridge.py.
/// Each entry has its own URL + token — different users point the same
/// app at their own bridges, so everyone's sessions stay private.
struct BridgeListView: View {
    @EnvironmentObject var appState: AppState
    @State private var health: [String: BridgeHealth] = [:]
    @State private var offline: Set<String> = []
    @State private var showAdd = false
    @State private var editing: BridgeConfig?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.bridges.isEmpty {
                    emptyView
                } else {
                    pcList
                }
            }
            .navigationTitle("Local")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await checkAll() }
            .navigationDestination(for: BridgeConfig.self) { bridge in
                LocalSessionsView(bridge: bridge)
                    .environmentObject(appState)
            }
            .navigationDestination(for: LocalRoute.self) { route in
                LocalSessionDetailView(bridge: route.bridge, ws: route.ws, sessionID: route.id, title: route.title)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showAdd) {
                BridgeEditView(bridge: nil).environmentObject(appState)
            }
            .sheet(item: $editing) { bridge in
                BridgeEditView(bridge: bridge).environmentObject(appState)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(appState)
            }
        }
    }

    private var pcList: some View {
        List {
            ForEach(appState.bridges) { bridge in
                NavigationLink(value: bridge) {
                    HStack(spacing: 12) {
                        statusDot(for: bridge)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName(for: bridge))
                                .font(.headline)
                            Text(bridge.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let h = health[bridge.id], h.shell == true {
                            Image(systemName: "terminal")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        appState.deleteBridge(bridge)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        editing = bridge
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }
        .refreshable { await checkAll() }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No PCs added")
                .font(.title3.bold())
            Text("Run devin_local_bridge.py on each computer that hosts your local Devin sessions, reachable over Tailscale. Tap + to add one.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add a PC") { showAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func statusDot(for bridge: BridgeConfig) -> some View {
        Circle()
            .fill(offline.contains(bridge.id) ? Color.red
                  : health[bridge.id] != nil ? Color.green : Color.gray)
            .frame(width: 10, height: 10)
    }

    private func displayName(for bridge: BridgeConfig) -> String {
        if let host = health[bridge.id]?.hostname, !host.isEmpty {
            return bridge.name.isEmpty ? host : "\(bridge.name) (\(host))"
        }
        return bridge.displayName
    }

    @MainActor
    private func checkAll() async {
        let list = appState.bridges
        await withTaskGroup(of: (String, BridgeHealth?).self) { group in
            for bridge in list {
                group.addTask {
                    guard let client = await appState.client(for: bridge) else {
                        return (bridge.id, nil)
                    }
                    return (bridge.id, try? await client.health())
                }
            }
            for await (id, h) in group {
                if let h {
                    health[id] = h
                    offline.remove(id)
                } else {
                    offline.insert(id)
                }
            }
        }
    }
}

struct BridgeEditView: View {
    let bridge: BridgeConfig?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Desktop)", text: $name)
                    TextField("http://100.x.y.z:8787", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("bridge token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("URL = the PC's bridge address on your tailnet. Token = its DEVIN_BRIDGE_TOKEN.")
                }

                if let testResult {
                    Section {
                        Text(testResult)
                            .foregroundStyle(testResult.hasPrefix("OK") ? .green : .red)
                    }
                }

                Section {
                    Button(testing ? "Testing…" : "Test Connection") {
                        Task { await test() }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                }
            }
            .navigationTitle(bridge == nil ? "Add PC" : "Edit PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let bridge {
                    name = bridge.name
                    url = bridge.url
                    token = appState.bridgeToken(for: bridge)
                }
            }
        }
    }

    private func save() {
        let config = BridgeConfig(
            id: bridge?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        appState.upsertBridge(config, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        dismiss()
    }

    private func test() async {
        testing = true
        testResult = nil
        guard let client = LocalBridgeClient(base: url, token: token) else {
            testResult = "Invalid URL"
            testing = false
            return
        }
        do {
            let h = try await client.health()
            testResult = "OK — \(h.hostname ?? "reachable")\(h.version.map { ", bridge v\($0)" } ?? "")\(h.shell == true ? ", shell on" : "")"
        } catch {
            testResult = error.localizedDescription
        }
        testing = false
    }
}
