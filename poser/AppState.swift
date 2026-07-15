import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedGhost: OverlayRecord?
    var ghostFlipped = false
    var ghostOpacity = 0.40
    var presentedShot: ShotRecord?
    var editingShot: ShotRecord?
    var showsGallery = false
    var showsPoseLibrary = false

    func selectGhost(_ overlay: OverlayRecord) {
        selectedGhost = overlay
        ghostFlipped = false
        overlay.lastUsedAt = .now
    }

    func cycleGhost(_ overlay: OverlayRecord) {
        guard selectedGhost?.id == overlay.id else {
            selectGhost(overlay)
            return
        }
        if !ghostFlipped {
            ghostFlipped = true
        } else {
            selectedGhost = nil
            ghostFlipped = false
        }
    }
}
