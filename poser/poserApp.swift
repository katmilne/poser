import SwiftData
import SwiftUI

@main
struct PoserApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .preferredColorScheme(.light)
        }
        .modelContainer(for: [ShotRecord.self, OverlayRecord.self, CustomStickerRecord.self])
    }
}
