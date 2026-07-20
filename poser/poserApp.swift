import SwiftData
import SwiftUI

@main
struct PoserApp: App {
    @State private var appState: AppState
    @State private var premium: PremiumStore

    init() {
        Analytics.configure()
        // The store is built first so the pose lock is wired before any view
        // exists. AppState refuses locked poses from this point on, so there is
        // no window during launch where a premium pose could be selected.
        let store = PremiumStore()
        let state = AppState()
        state.isPoseLocked = { [store] overlay in store.isLocked(overlay) }
        _premium = State(initialValue: store)
        _appState = State(initialValue: state)
    }

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
