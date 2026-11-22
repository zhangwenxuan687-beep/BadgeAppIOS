import SwiftUI

@main
@MainActor
struct BadgeApp: App {
    @StateObject private var ble = BleManager.shared
    @StateObject private var chat = ChatOrchestrator.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(chat)
        }
    }
}
