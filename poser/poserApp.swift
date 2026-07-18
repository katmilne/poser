import SwiftData
import SwiftUI

@main
struct PoserApp: App {
    @State private var appState = AppState()
    @State private var premium = PremiumStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(premium)
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [ShotRecord.self, OverlayRecord.self, CustomStickerRecord.self])
    }
}
