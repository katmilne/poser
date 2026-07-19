import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var selectedGhost: OverlayRecord?
    /// The pose most recently chosen from the pose library. It owns the strip's
    /// reserved first slot and only changes when a new pose is picked from that
    /// page — tapping strip favorites swaps the active `selectedGhost` but leaves
    /// this untouched.
    var libraryPose: OverlayRecord?
    var ghostFlipped = false
    var ghostOpacity = 0.40
    var presentedShot: ShotRecord?
    var showsGallery = false
    var showsPoseLibrary = false
    var showsSettings = false

    func selectGhost(_ overlay: OverlayRecord) {
        selectedGhost = overlay
        libraryPose = overlay
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
