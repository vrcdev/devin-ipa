import SwiftUI

@main
struct DevinMobileApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            SessionsListView()
                .environmentObject(appState)
        }
    }
}
