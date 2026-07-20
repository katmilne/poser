import Foundation
import OSLog
import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("sessionCount") private var sessionCount = 0
    @AppStorage("premiumNudgeShown") private var premiumNudgeShown = false
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var camera = CameraController()
    @State private var showsPremiumNudge = false

    var body: some View {
        @Bindable var appState = appState
        Group {
            if onboarded {
                CameraView(camera: camera)
            } else {
                OnboardingView {
                    onboarded = true
                    Analytics.track("onboarding_completed")
                }
            }
        }
        .accessibilityHidden(
            appState.showsGallery
                || appState.showsPoseLibrary
                || appState.showsSettings
                || appState.presentedShot != nil
        )
        .fullScreenCover(isPresented: $appState.showsGallery) {
            GalleryView()
        }
        .sheet(isPresented: $appState.showsPoseLibrary) {
            PoseLibraryView()
        }
        .sheet(isPresented: $appState.showsSettings) {
            SettingsSheet()
        }
        .fullScreenCover(item: $appState.presentedShot) { shot in
            CaptureReviewView(shot: shot)
        }
        .sheet(isPresented: $showsPremiumNudge) {
            PaywallView(context: .discover)
        }
        .task {
            try? await ImageStore.shared.prepareDirectories()
            await BundledPoseCatalog.seedIfNeeded(in: modelContext)
        }
        .task {
            // Poser's one-time "discover Premium" nudge: shown once, on
            // the user's 2nd app session, never during first-run onboarding.
            sessionCount += 1
            guard onboarded, sessionCount == 2, !premiumNudgeShown else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard
                !appState.showsGallery,
                !appState.showsPoseLibrary,
                !appState.showsSettings,
                appState.presentedShot == nil
            else { return }
            premiumNudgeShown = true
            showsPremiumNudge = true
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(PremiumStore())
        .modelContainer(for: [ShotRecord.self, OverlayRecord.self, CustomStickerRecord.self], inMemory: true)
}

enum BundledPoseCatalog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "space.concurrent.poser",
        category: "BundledPoseCatalog"
    )

    private struct Pose {
        let id: String
        let name: String
        let people: String
        let genders: [String]
        let vibe: String
        let framing: [String]
        let extras: [String]
        let sourceName: String
        let sourceExtension: String
        let cropCenter: CGPoint
        let isPremium: Bool

        var tags: [String] { [people] + genders + [vibe] + framing + extras }

        init(
            id: String,
            name: String,
            people: String = "solo",
            genders: [String] = ["f"],
            vibe: String,
            framing: [String] = [],
            extras: [String] = [],
            sourceName: String? = nil,
            sourceExtension: String = "png",
            cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
            isPremium: Bool = false
        ) {
            self.id = id
            self.name = name
            self.people = people
            self.genders = genders
            self.vibe = vibe
            self.framing = framing
            self.extras = extras
            self.sourceName = sourceName ?? name
            self.sourceExtension = sourceExtension
            self.cropCenter = cropCenter
            self.isPremium = isPremium
        }
    }

    /// The premium half of the collection. Every pose is still seeded and still
    /// browsable - see `PremiumStore.isLocked(_:)` for what locking means.
    /// Add a premium pose with `premiumPose(...)`, which is `optimizedPose(...)`
    /// with the flag set; moving one between the sets is a rename at the call
    /// site, since nothing about premium status is persisted.
    static let premiumPoseIDs: Set<String> = Set(poses.lazy.filter(\.isPremium).map(\.id))

    private static func premiumPose(
        _ name: String,
        people: String = "solo",
        genders: [String] = ["f"],
        vibe: String,
        framing: [String] = [],
        extras: [String] = [],
        cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> Pose {
        optimizedPose(
            name,
            people: people,
            genders: genders,
            vibe: vibe,
            framing: framing,
            extras: extras,
            cropCenter: cropCenter,
            isPremium: true
        )
    }

    private static func optimizedPose(
        _ name: String,
        people: String = "solo",
        genders: [String] = ["f"],
        vibe: String,
        framing: [String] = [],
        extras: [String] = [],
        cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5),
        isPremium: Bool = false
    ) -> Pose {
        Pose(
            id: "builtin-\(name)",
            name: name,
            people: people,
            genders: genders,
            vibe: vibe,
            framing: framing,
            extras: extras,
            sourceName: "\(name)-source",
            sourceExtension: "jpg",
            cropCenter: cropCenter,
            isPremium: isPremium
        )
    }

    /// Version 12 retags 18 poses (vibe and framing only - no pose added,
    /// removed, or moved between tiers), which reaches existing installs
    /// because the seed loop refreshes `record.tags` on every version bump.
    /// Existing records keep their favourites and framing - the seed loop only
    /// forces `isFavorite` for starter poses on a first install.
    private static let catalogVersion = 12
    private static let catalogVersionKey = "bundledPoseCatalogVersion"

    /// Fresh installs start with one solo, one duo, and one group pose
    /// favourited so the camera's pose strip is never empty on first open.
    /// Listed in the order they should appear in the strip: solo, then duo,
    /// then group.
    private static let starterFavoriteIDs: [String] = [
        "builtin-silly-cat-claw",   // solo · female · cute
        "builtin-table-heart-duo",  // duo · female · cute
        "builtin-trio-street-lean"  // group · female · cool
    ]

    /// The strip sorts favourites by `addedAt` descending, so the first
    /// starter (solo) needs the newest stamp. The bundled poses each get an
    /// `addedAt` taken while they are persisted one after another, and that
    /// sequential file I/O drifts the wall clock far enough that the
    /// last-seeded starter would otherwise sort newest - reversing the strip
    /// to group → duo → solo. Stamping the trio from one shared instant,
    /// spaced a second per rank, pins them to solo → duo → group regardless of
    /// how long seeding takes or where the poses sit in `poses`.
    private static func starterFavoriteAddedAt(seed: Date, rank: Int) -> Date {
        seed.addingTimeInterval(Double(-rank))
    }

    /// A starter favourite lands in the camera strip before anyone has paid, so
    /// promoting one to premium would open a fresh install on a locked pose.
    /// Moving a pose between the free and premium sets is a one-word edit at its
    /// call site, far from this list, so this catches the mismatch in debug
    /// rather than leaving it to be spotted in the running app.
    private static func assertStarterFavoritesAreFree() {
        assert(
            starterFavoriteIDs.allSatisfy { !premiumPoseIDs.contains($0) },
            "Starter favourites must be free: \(starterFavoriteIDs.filter(premiumPoseIDs.contains))"
        )
    }

    private static let poses = [
        Pose(id: "builtin-cool-sidewalk-sit", name: "sidewalk-sit", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cool-record-shop-crouch", name: "record-shop-crouch", vibe: "cool", framing: ["overhead"]),
        Pose(id: "builtin-cool-doorway-knee-up", name: "doorway-knee-up", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(
            id: "builtin-cool-pavement-recline",
            name: "pavement-recline",
            vibe: "cool",
            framing: ["hidden-face"],
            cropCenter: CGPoint(x: 0.5, y: 0.55),
            isPremium: true
        ),
        Pose(id: "builtin-cool-night-lookback", name: "night-lookback", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-cool-vending-machine", name: "vending-machine", vibe: "cool", isPremium: true),
        Pose(id: "builtin-cool-scooter-lean", name: "scooter-lean", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-cute-railing-leg-pop", name: "railing-leg-pop", vibe: "cute"),
        Pose(id: "builtin-cute-steps-chin-rest", name: "steps-chin-rest", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cute-rainy-umbrella-crouch", name: "rainy-umbrella-crouch", vibe: "cute", framing: ["overhead"], isPremium: true),
        Pose(id: "builtin-cute-sidewalk-hand-on-hip", name: "sidewalk-hand-on-hip", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cute-doorstep-sit", name: "doorstep-sit", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-silly-cat-claw", name: "cat-claw", vibe: "cute", framing: ["overhead"]),
        Pose(
            id: "builtin-silly-reach-for-camera",
            name: "reach-for-camera",
            vibe: "cute",
            cropCenter: CGPoint(x: 0.5, y: 0.58),
            isPremium: true
        ),

        // Solo poses
        optimizedPose("camera-recline", genders: ["m"], vibe: "cute"),
        optimizedPose("cross-legged-park", genders: ["m"], vibe: "cool"),
        optimizedPose("waterside-lookback", genders: ["m"], vibe: "cool", framing: ["hidden-face"], cropCenter: CGPoint(x: 0.5, y: 0.55)),
        premiumPose("city-bench", genders: ["m"], vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        premiumPose("shaded-curb-sit", genders: ["m"], vibe: "cool", framing: ["hidden-face", "overhead"]),
        optimizedPose("cafe-crate-sit", vibe: "cool", framing: ["overhead"]),
        optimizedPose("overhead-crouch", vibe: "cute", framing: ["overhead"]),
        premiumPose("crosswalk-lean", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        premiumPose("sunny-curb-sit", vibe: "cute"),
        premiumPose("railing-stretch", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.60)),
        optimizedPose("cafe-wall-leg-up", vibe: "cool"),
        optimizedPose("cafe-chair-lean", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        premiumPose("grass-leg-kick", vibe: "cute"),
        optimizedPose("night-overhead-recline", vibe: "cool", framing: ["overhead"]),
        optimizedPose("sunglasses-adjust", vibe: "cool"),
        optimizedPose("street-heart-hands", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("game-over-stairs", vibe: "silly", framing: ["hidden-face"]),
        premiumPose("drink-lookdown", vibe: "cool", framing: ["overhead"]),
        optimizedPose("stone-ledge-sit", vibe: "cool", framing: ["hidden-face"]),
        optimizedPose("wall-portrait", vibe: "cute"),
        optimizedPose("grass-face-cover", vibe: "cute", framing: ["hidden-face", "overhead"]),
        premiumPose("wall-leg-cross", vibe: "cute"),
        premiumPose("hands-point-down", vibe: "cute", framing: ["overhead"], cropCenter: CGPoint(x: 0.5, y: 0.42)),
        optimizedPose("finger-frame-perspective", vibe: "silly", framing: ["hidden-face", "illusion"]),
        premiumPose("giant-drink-pour-solo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("sunglasses-selfie", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("phone-show-selfie", vibe: "cute", framing: ["selfie"]),
        optimizedPose("mirror-phone-selfie", vibe: "cool", framing: ["selfie"]),
        optimizedPose("crouch-selfie", vibe: "cute"),
        premiumPose("drink-selfie", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("outfit-selfie", vibe: "cute", framing: ["hidden-face", "overhead", "selfie"]),
        premiumPose("dress-selfie", vibe: "cute", framing: ["overhead"]),
        optimizedPose("seated-street-selfie", vibe: "cute", framing: ["selfie"]),

        // Solo poses, second drop. Mostly premium: solo/cool and solo/cute are
        // the two buckets the free tier already covers most heavily, so new
        // work there deepens the paid collection rather than the free one.

        premiumPose(
            "night-street-crouch",
            genders: ["m"],
            vibe: "cool",
            framing: ["overhead"],
            cropCenter: CGPoint(x: 0.5, y: 0.54)
        ),
        optimizedPose("night-railing-city", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.52)),
        premiumPose("shop-window-selfie", vibe: "cute", framing: ["selfie"], cropCenter: CGPoint(x: 0.5, y: 0.52)),
        premiumPose("corner-walk-bag", vibe: "cool", framing: ["hidden-face"], cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("stairs-head-back", genders: ["m"], vibe: "cool", framing: ["overhead"], cropCenter: CGPoint(x: 0.5, y: 0.62)),
        premiumPose("lamppost-leg-up", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.53)),
        premiumPose("headphones-walk-away", vibe: "cool", framing: ["hidden-face"], cropCenter: CGPoint(x: 0.5, y: 0.52)),
        premiumPose("curb-hands-face", vibe: "cute", framing: ["hidden-face"], cropCenter: CGPoint(x: 0.5, y: 0.58)),
        premiumPose("wall-lean-lookback", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.49)),
        optimizedPose("pavement-sit-cap", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.60)),
        premiumPose(
            "arm-out-overhead-selfie",
            vibe: "cool",
            framing: ["selfie", "overhead"],
            cropCenter: CGPoint(x: 0.5, y: 0.44)
        ),
        optimizedPose("night-finger-frame", genders: ["m"], vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.48)),
        premiumPose("hand-to-lens-crouch", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.42)),
        premiumPose("peace-sign-selfie", vibe: "cute", framing: ["selfie"], cropCenter: CGPoint(x: 0.5, y: 0.40)),
        premiumPose("railing-lean-soft", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.62)),
        premiumPose(
            "hand-to-head-selfie",
            vibe: "cool",
            framing: ["selfie", "overhead"],
            cropCenter: CGPoint(x: 0.5, y: 0.45)
        ),
        optimizedPose("top-down-stand", genders: ["m"], vibe: "cool", framing: ["overhead"], cropCenter: CGPoint(x: 0.5, y: 0.55)),
        premiumPose("arms-up-peace", genders: ["m"], vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.52)),
        premiumPose("stoop-hair-touch", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.60)),
        optimizedPose("giant-hand-drink", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.48)),
        premiumPose("ledge-leg-lift", vibe: "cute"),
        premiumPose("wall-photo-back", vibe: "cute", framing: ["hidden-face"], cropCenter: CGPoint(x: 0.5, y: 0.60)),
        premiumPose("wall-lean-arm-up", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.49)),
        premiumPose("hand-reach-shades", vibe: "cool", framing: ["illusion"], cropCenter: CGPoint(x: 0.5, y: 0.48)),
        premiumPose(
            "glasses-overhead-selfie",
            vibe: "cute",
            framing: ["selfie", "overhead"],
            cropCenter: CGPoint(x: 0.5, y: 0.48)
        ),
        premiumPose("both-hands-lens", genders: ["m"], vibe: "cool", framing: ["illusion"]),

        // Duo poses
        optimizedPose("cafe-drinks-duo", people: "duo", genders: ["m"], vibe: "cool"),
        optimizedPose("overhead-toast-duo", people: "duo", genders: ["m"], vibe: "cute", framing: ["overhead"]),
        premiumPose("street-steps-duo", people: "duo", genders: ["m"], vibe: "cool"),
        premiumPose("record-store-duo", people: "duo", genders: ["m"], vibe: "cool"),
        optimizedPose("hooded-night-duo", people: "duo", vibe: "cute", framing: ["hidden-face", "overhead", "selfie"]),
        premiumPose("cat-cafe-selfie", people: "duo", vibe: "cute", framing: ["low", "selfie"]),
        premiumPose("crosswalk-overhead-duo", people: "duo", vibe: "cool", framing: ["hidden-face", "overhead", "selfie"]),
        premiumPose("cafe-steps-duo", people: "duo", vibe: "cool"),
        optimizedPose("hand-heart-frame-duo", people: "duo", vibe: "cute", framing: ["hidden-face"]),
        optimizedPose("seated-heart-duo", people: "duo", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.45)),
        optimizedPose("table-heart-duo", people: "duo", vibe: "cute", framing: ["hidden-face"]),
        optimizedPose("giant-tiny-split", people: "duo", vibe: "silly", framing: ["illusion"]),
        premiumPose("giant-drink-pour-duo", people: "duo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("palm-sized-friend", people: "duo", vibe: "cool", framing: ["illusion"]),
        optimizedPose("peace-sign-duo-selfie", people: "duo", genders: ["f", "m"], vibe: "silly", framing: ["selfie"]),
        optimizedPose(
            "sunset-hug-selfie",
            people: "duo",
            genders: ["f", "m"],
            vibe: "cute",
            framing: ["selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.30)
        ),
        premiumPose("arm-over-shoulder-duo", people: "duo", genders: ["f", "m"], vibe: "cool"),
        optimizedPose("recline-selfie-duo", people: "duo", genders: ["f", "m"], vibe: "silly", framing: ["selfie", "overhead"]),
        optimizedPose("puppy-recline-duo", people: "duo", vibe: "cute", extras: ["pet"]),
        optimizedPose("matching-step-duo", people: "duo", genders: ["f", "m"], vibe: "cool"),
        premiumPose(
            "peekaboo-duo-selfie",
            people: "duo",
            genders: ["f", "m"],
            vibe: "silly",
            framing: ["selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.64)
        ),
        optimizedPose(
            "grass-duo-selfie",
            people: "duo",
            genders: ["f", "m"],
            vibe: "cute",
            framing: ["overhead", "selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.45)
        ),

        // Duo poses, second drop. Free: duo trails solo badly in the free tier,
        // and the illusion pair below is the free tier's thinnest framing.

        optimizedPose(
            "night-duo-selfie",
            people: "duo",
            genders: ["m"],
            vibe: "cool",
            framing: ["hidden-face", "overhead", "selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.48)
        ),
        optimizedPose("duo-heart-hands-night", people: "duo", genders: ["m"], vibe: "cute"),
        optimizedPose("giant-hand-friend-down", people: "duo", genders: ["m"], vibe: "cool", framing: ["illusion"]),

        // Group poses
        premiumPose("friends-cheer", people: "group", vibe: "cute"),
        optimizedPose("trio-heart-selfie", people: "group", vibe: "cute", framing: ["selfie"]),
        optimizedPose("four-friends-table", people: "group", vibe: "silly", cropCenter: CGPoint(x: 0.5, y: 0.45)),
        premiumPose("flower-heart-circle", people: "group", vibe: "cute"),
        optimizedPose("trio-heart-line", people: "group", vibe: "cute"),
        optimizedPose("trio-street-lean", people: "group", vibe: "cool"),
        optimizedPose("friendship-circle", people: "group", vibe: "cute", framing: ["overhead", "selfie"]),
        optimizedPose(
            "party-photobomb",
            people: "group",
            genders: ["f", "m"],
            vibe: "silly",
            framing: ["selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.36)
        ),
        premiumPose("four-friend-heart", people: "group", vibe: "cute"),

        // Group poses, second drop. Both free: group is the smallest people
        // bucket in the free tier, and group/cool had exactly one free pose.
        optimizedPose(
            "friends-stairs-selfie",
            people: "group",
            genders: ["m"],
            vibe: "cool",
            framing: ["low", "selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.46)
        ),
        optimizedPose(
            "friends-lying-circle",
            people: "group",
            genders: ["m"],
            vibe: "cool",
            framing: ["overhead", "selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.42)
        )
    ]

    @MainActor
    static func seedIfNeeded(in modelContext: ModelContext) async {
        assertStarterFavoritesAreFree()
        let defaults = UserDefaults.standard

        // Version 0 means the catalog has never been seeded on this device,
        // i.e. a brand-new user rather than an upgrade or repair pass.
        let isFirstInstall = defaults.integer(forKey: catalogVersionKey) == 0

        do {
            let existing = try modelContext.fetch(FetchDescriptor<OverlayRecord>())
            let recordsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
            let catalogNeedsRepair = poses.contains { pose in
                guard let record = recordsByID[pose.id] else { return true }
                return !ImageStore.shared.overlayFileExists(named: record.fileName)
            }
            guard
                defaults.integer(forKey: catalogVersionKey) < catalogVersion || catalogNeedsRepair
            else { return }

            // One instant shared by every starter favourite so the trio's
            // relative order does not drift as the seed loop's file I/O elapses.
            let favoriteSeed = Date()

            for (index, pose) in poses.enumerated() {
                guard let sourceURL = Bundle.main.url(
                    forResource: pose.sourceName,
                    withExtension: pose.sourceExtension
                ) else {
                    throw CatalogError.missingResource("\(pose.sourceName).\(pose.sourceExtension)")
                }
                guard let preparedURL = Bundle.main.url(
                    forResource: pose.name,
                    withExtension: "jpg"
                ) else {
                    throw CatalogError.missingResource("\(pose.name).jpg")
                }

                let stored = try await ImageStore.shared.persistBundledOverlay(
                    sourceURL: sourceURL,
                    preparedURL: preparedURL,
                    id: pose.id,
                    order: index,
                    cropCenter: pose.cropCenter
                )
                let starterRank = isFirstInstall ? starterFavoriteIDs.firstIndex(of: pose.id) : nil
                let overlayAddedAt = starterRank
                    .map { starterFavoriteAddedAt(seed: favoriteSeed, rank: $0) } ?? stored.addedAt
                if let record = recordsByID[pose.id] {
                    record.fileName = stored.fileName
                    record.width = stored.width
                    record.height = stored.height
                    record.sourceFileName = stored.sourceFileName
                    record.sourceWidth = stored.sourceWidth
                    record.sourceHeight = stored.sourceHeight
                    record.crop = stored.crop
                    record.canvasAspect = stored.canvasAspect
                    record.tags = pose.tags
                    if starterRank != nil {
                        record.isFavorite = true
                        record.addedAt = overlayAddedAt
                    }
                } else {
                    modelContext.insert(OverlayRecord(
                        id: stored.id,
                        fileName: stored.fileName,
                        addedAt: overlayAddedAt,
                        width: stored.width,
                        height: stored.height,
                        sourceFileName: stored.sourceFileName,
                        sourceWidth: stored.sourceWidth,
                        sourceHeight: stored.sourceHeight,
                        crop: stored.crop,
                        canvasAspect: stored.canvasAspect,
                        tags: pose.tags,
                        isFavorite: starterRank != nil
                    ))
                }
            }

            try modelContext.save()
            defaults.set(catalogVersion, forKey: catalogVersionKey)
            await ImageStore.shared.removeLegacyBundledSources(ids: poses.map(\.id))
        } catch {
            modelContext.rollback()
            // Bundled poses are starter content, so a transient file-system or
            // Preview-container failure must not terminate the whole app. Since
            // the version is only saved after a successful import, this retries
            // automatically the next time the view starts.
            logger.error(
                "Could not seed bundled poses; will retry next launch: \(error.localizedDescription, privacy: .public)"
            )
#if DEBUG
            print("BundledPoseCatalog error: \(error)")
#endif
        }
    }

    private enum CatalogError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let fileName):
                "Bundled pose resource is missing: \(fileName)"
            }
        }
    }
}
