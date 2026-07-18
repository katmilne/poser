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
            PreviewEditorView(shot: shot)
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
            cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
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
        }
    }

    private static func optimizedPose(
        _ name: String,
        people: String = "solo",
        genders: [String] = ["f"],
        vibe: String,
        framing: [String] = [],
        extras: [String] = [],
        cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
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
            cropCenter: cropCenter
        )
    }

    /// Version 10 adds female, male, and pet subject tags across the bundled catalog.
    private static let catalogVersion = 10
    private static let catalogVersionKey = "bundledPoseCatalogVersion"

    /// Fresh installs start with one selfie, one solo, and one group pose
    /// favourited so the camera's pose strip is never empty on first open.
    private static let starterFavoriteIDs: Set<String> = [
        "builtin-mirror-phone-selfie",
        "builtin-sunny-curb-sit",
        "builtin-friends-cheer"
    ]

    private static let poses = [
        Pose(id: "builtin-cool-sidewalk-sit", name: "sidewalk-sit", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cool-record-shop-crouch", name: "record-shop-crouch", vibe: "cool"),
        Pose(id: "builtin-cool-doorway-knee-up", name: "doorway-knee-up", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cool-pavement-recline", name: "pavement-recline", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cool-night-lookback", name: "night-lookback", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-cool-vending-machine", name: "vending-machine", vibe: "cool"),
        Pose(id: "builtin-cool-scooter-lean", name: "scooter-lean", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-cute-railing-leg-pop", name: "railing-leg-pop", vibe: "cute"),
        Pose(id: "builtin-cute-steps-chin-rest", name: "steps-chin-rest", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cute-rainy-umbrella-crouch", name: "rainy-umbrella-crouch", vibe: "cute"),
        Pose(id: "builtin-cute-sidewalk-hand-on-hip", name: "sidewalk-hand-on-hip", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        Pose(id: "builtin-cute-doorstep-sit", name: "doorstep-sit", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        Pose(id: "builtin-silly-cat-claw", name: "cat-claw", vibe: "silly"),
        Pose(id: "builtin-silly-reach-for-camera", name: "reach-for-camera", vibe: "silly", cropCenter: CGPoint(x: 0.5, y: 0.58)),

        // Solo poses
        optimizedPose("camera-recline", genders: ["m"], vibe: "cool"),
        optimizedPose("cross-legged-park", genders: ["m"], vibe: "cool"),
        optimizedPose("waterside-lookback", genders: ["m"], vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("city-bench", genders: ["m"], vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("shaded-curb-sit", genders: ["m"], vibe: "cool"),
        optimizedPose("cafe-crate-sit", vibe: "cute"),
        optimizedPose("overhead-crouch", vibe: "cute", framing: ["overhead"]),
        optimizedPose("crosswalk-lean", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.58)),
        optimizedPose("sunny-curb-sit", vibe: "cute"),
        optimizedPose("railing-stretch", vibe: "cool", cropCenter: CGPoint(x: 0.5, y: 0.60)),
        optimizedPose("cafe-wall-leg-up", vibe: "cool"),
        optimizedPose("cafe-chair-lean", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("grass-leg-kick", vibe: "cute"),
        optimizedPose("night-overhead-recline", vibe: "dramatic", framing: ["overhead"]),
        optimizedPose("sunglasses-adjust", vibe: "cool"),
        optimizedPose("street-heart-hands", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.55)),
        optimizedPose("game-over-stairs", vibe: "dramatic"),
        optimizedPose("drink-lookdown", vibe: "cool", framing: ["overhead"]),
        optimizedPose("stone-ledge-sit", vibe: "cool"),
        optimizedPose("wall-portrait", vibe: "cute"),
        optimizedPose("grass-face-cover", vibe: "dramatic", framing: ["overhead"]),
        optimizedPose("wall-leg-cross", vibe: "cute"),
        optimizedPose("hands-point-down", vibe: "cute", framing: ["overhead"], cropCenter: CGPoint(x: 0.5, y: 0.42)),
        optimizedPose("finger-frame-perspective", vibe: "silly", framing: ["illusion"]),
        optimizedPose("giant-drink-pour-solo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("sunglasses-selfie", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("phone-show-selfie", vibe: "silly", framing: ["selfie"]),
        optimizedPose("mirror-phone-selfie", vibe: "cool", framing: ["selfie"]),
        optimizedPose("crouch-selfie", vibe: "cute", framing: ["selfie", "overhead"]),
        optimizedPose("drink-selfie", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("outfit-selfie", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("dress-selfie", vibe: "cute", framing: ["selfie", "overhead"]),
        optimizedPose("seated-street-selfie", vibe: "cool", framing: ["selfie"]),

        // Duo poses
        optimizedPose("cafe-drinks-duo", people: "duo", genders: ["m"], vibe: "cool"),
        optimizedPose("overhead-toast-duo", people: "duo", genders: ["m"], vibe: "cool", framing: ["overhead"]),
        optimizedPose("street-steps-duo", people: "duo", genders: ["m"], vibe: "cool"),
        optimizedPose("record-store-duo", people: "duo", genders: ["m"], vibe: "cool"),
        optimizedPose("hooded-night-duo", people: "duo", vibe: "cool", framing: ["overhead"]),
        optimizedPose("cat-cafe-selfie", people: "duo", vibe: "cool", framing: ["selfie"]),
        optimizedPose("crosswalk-overhead-duo", people: "duo", vibe: "cool", framing: ["selfie", "overhead"]),
        optimizedPose("cafe-steps-duo", people: "duo", vibe: "cool"),
        optimizedPose("hand-heart-frame-duo", people: "duo", vibe: "cute"),
        optimizedPose("seated-heart-duo", people: "duo", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.45)),
        optimizedPose("table-heart-duo", people: "duo", vibe: "cute"),
        optimizedPose("giant-tiny-split", people: "duo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("giant-drink-pour-duo", people: "duo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("palm-sized-friend", people: "duo", vibe: "silly", framing: ["illusion"]),
        optimizedPose("peace-sign-duo-selfie", people: "duo", genders: ["f", "m"], vibe: "silly", framing: ["selfie", "overhead"]),
        optimizedPose(
            "sunset-hug-selfie",
            people: "duo",
            genders: ["f", "m"],
            vibe: "cute",
            framing: ["selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.30)
        ),
        optimizedPose("arm-over-shoulder-duo", people: "duo", genders: ["f", "m"], vibe: "cool"),
        optimizedPose("recline-selfie-duo", people: "duo", genders: ["f", "m"], vibe: "silly", framing: ["selfie", "overhead"]),
        optimizedPose(
            "puppy-recline-duo",
            people: "duo",
            vibe: "cute",
            framing: ["overhead"],
            extras: ["pet"]
        ),
        optimizedPose("matching-step-duo", people: "duo", genders: ["f", "m"], vibe: "cool"),
        optimizedPose(
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
            framing: ["selfie", "overhead"],
            cropCenter: CGPoint(x: 0.5, y: 0.45)
        ),

        // Group poses
        optimizedPose("friends-cheer", people: "group", vibe: "cute"),
        optimizedPose("trio-heart-selfie", people: "group", vibe: "cute", framing: ["selfie"]),
        optimizedPose("four-friends-table", people: "group", vibe: "cute", cropCenter: CGPoint(x: 0.5, y: 0.45)),
        optimizedPose("flower-heart-circle", people: "group", vibe: "cute"),
        optimizedPose("trio-heart-line", people: "group", vibe: "cute"),
        optimizedPose("trio-street-lean", people: "group", vibe: "cool"),
        optimizedPose("friendship-circle", people: "group", vibe: "cute", framing: ["overhead"]),
        optimizedPose(
            "party-photobomb",
            people: "group",
            genders: ["f", "m"],
            vibe: "dramatic",
            framing: ["selfie"],
            cropCenter: CGPoint(x: 0.5, y: 0.36)
        ),
        optimizedPose("four-friend-heart", people: "group", vibe: "cute")
    ]

    @MainActor
    static func seedIfNeeded(in modelContext: ModelContext) async {
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
                    if isFirstInstall && starterFavoriteIDs.contains(pose.id) {
                        record.isFavorite = true
                    }
                } else {
                    modelContext.insert(OverlayRecord(
                        id: stored.id,
                        fileName: stored.fileName,
                        addedAt: stored.addedAt,
                        width: stored.width,
                        height: stored.height,
                        sourceFileName: stored.sourceFileName,
                        sourceWidth: stored.sourceWidth,
                        sourceHeight: stored.sourceHeight,
                        crop: stored.crop,
                        canvasAspect: stored.canvasAspect,
                        tags: pose.tags,
                        isFavorite: isFirstInstall && starterFavoriteIDs.contains(pose.id)
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
