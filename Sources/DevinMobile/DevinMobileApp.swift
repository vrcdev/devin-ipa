import SwiftUI

@main
struct DevinMobileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            TabView {
                SessionsListView()
                    .tabItem { Label("Cloud", systemImage: "cloud") }
                LocalSessionsView()
                    .tabItem { Label("Local", systemImage: "desktopcomputer") }
            }
            .environmentObject(appState)
        }
    }
}
