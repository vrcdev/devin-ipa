import SwiftUI

@main
struct DevinMobileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                SessionsListView()
                    .tabItem { Label("Cloud", systemImage: "cloud") }
                BridgeListView()
                    .tabItem { Label("Local", systemImage: "desktopcomputer") }
            }
            .environmentObject(appState)
        }
    }
}
