import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Answers "is this pose locked right now?", injected at app start so this
    /// type can refuse a locked pose without depending on the store.
    ///
    /// Ghost selection is funnelled through `AppState` on purpose. The lock has
    /// to be enforced where the state lives, not at each call site: call sites
    /// are easy to add and easy to forget - the gallery's "use this pose again"
    /// button was already a second way in, separate from the pose library - and
    /// a missed one silently hands a lapsed subscriber a premium pose.
    @ObservationIgnored
    var isPoseLocked: @MainActor (OverlayRecord) -> Bool = { _ in false }

    private(set) var selectedGhost: OverlayRecord?
    /// The pose most recently chosen from the pose library. It owns the strip's
    /// reserved first slot and only changes when a new pose is picked from that
    /// page - tapping strip favorites swaps the active `selectedGhost` but leaves
    /// this untouched.
    private(set) var libraryPose: OverlayRecord?
    var ghostFlipped = false
    var ghostOpacity = 0.40
    var presentedShot: ShotRecord?
    var showsGallery = false
    var showsPoseLibrary = false
    var showsSettings = false

    /// The only ghost the camera may draw or bake into a capture. The lock is
    /// re-tested on every read so an entitlement that lapses between
    /// enforcement passes still cannot put a premium pose in the viewfinder,
    /// however stale `selectedGhost` happens to be at that moment.
    var usableGhost: OverlayRecord? {
        guard let selectedGhost, !isPoseLocked(selectedGhost) else { return nil }
        return selectedGhost
    }

    /// Returns false when the pose is locked, so the caller can raise the
    /// paywall instead of silently doing nothing.
    @discardableResult
    func selectGhost(_ overlay: OverlayRecord) -> Bool {
        guard !isPoseLocked(overlay) else { return false }
        activateGhost(overlay)
        libraryPose = overlay
        return true
    }

    @discardableResult
    func cycleGhost(_ overlay: OverlayRecord) -> Bool {
        guard !isPoseLocked(overlay) else { return false }
        guard selectedGhost?.id == overlay.id else {
            activateGhost(overlay)
            return true
        }
        if !ghostFlipped {
            ghostFlipped = true
        } else {
            clearGhost()
        }
        return true
    }

    func clearGhost() {
        selectedGhost = nil
        ghostFlipped = false
    }

    /// Drops a pose from every slot it can occupy. Used when it is deleted or
    /// unfavorited, so no slot outlives the pose behind it.
    func forgetPose(id: String) {
        if selectedGhost?.id == id { clearGhost() }
        if libraryPose?.id == id { libraryPose = nil }
    }

    /// Releases anything the entitlement no longer covers. Idempotent and
    /// cheap, so it is safe to run on every appearance and every entitlement
    /// change rather than only where a lapse is expected.
    func enforcePoseLock() {
        if let selectedGhost, isPoseLocked(selectedGhost) { clearGhost() }
        if let libraryPose, isPoseLocked(libraryPose) { self.libraryPose = nil }
    }

    private func activateGhost(_ overlay: OverlayRecord) {
        selectedGhost = overlay
        ghostFlipped = false
        overlay.lastUsedAt = .now
        Analytics.track("ghost_selected")
    }
}
