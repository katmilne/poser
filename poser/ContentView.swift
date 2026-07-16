import Foundation
import OSLog
import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage("onboarded") private var onboarded = false
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var camera = CameraController()

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
            appState.showsGallery || appState.showsPoseLibrary || appState.presentedShot != nil
        )
        .fullScreenCover(isPresented: $appState.showsGallery) {
            GalleryView()
        }
        .sheet(isPresented: $appState.showsPoseLibrary) {
            PoseLibraryView()
        }
        .fullScreenCover(item: $appState.presentedShot) { shot in
            PreviewEditorView(shot: shot)
        }
        .task {
            try? await ImageStore.shared.prepareDirectories()
            await BundledPoseCatalog.seedIfNeeded(in: modelContext)
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
        let vibe: String
        let cropCenter: CGPoint

        var tags: [String] { ["solo", vibe] }

        init(
            id: String,
            name: String,
            vibe: String,
            cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
        ) {
            self.id = id
            self.name = name
            self.vibe = vibe
            self.cropCenter = cropCenter
        }
    }

    /// Bumped to 4 when built-in poses stopped copying their full-resolution PNG
    /// into Documents and started reading it from the bundle. Re-seeding
    /// repoints the records and reclaims the old copies.
    private static let catalogVersion = 4
    private static let catalogVersionKey = "bundledPoseCatalogVersion"

    private static let poses = [
        Pose(id: "builtin-cool-sidewalk-sit", name: "sidewalk-sit", vibe: "cool"),
        Pose(id: "builtin-cool-record-shop-crouch", name: "record-shop-crouch", vibe: "cool"),
        Pose(id: "builtin-cool-doorway-knee-up", name: "doorway-knee-up", vibe: "cool"),
        Pose(id: "builtin-cool-pavement-recline", name: "pavement-recline", vibe: "cool"),
        Pose(id: "builtin-cool-night-lookback", name: "night-lookback", vibe: "cool"),
        Pose(id: "builtin-cool-vending-machine", name: "vending-machine", vibe: "cool"),
        Pose(id: "builtin-cool-scooter-lean", name: "scooter-lean", vibe: "cool"),
        Pose(id: "builtin-cute-railing-leg-pop", name: "railing-leg-pop", vibe: "cute"),
        Pose(id: "builtin-cute-steps-chin-rest", name: "steps-chin-rest", vibe: "cute"),
        Pose(id: "builtin-cute-rainy-umbrella-crouch", name: "rainy-umbrella-crouch", vibe: "cute"),
        Pose(id: "builtin-cute-sidewalk-hand-on-hip", name: "sidewalk-hand-on-hip", vibe: "cute"),
        Pose(id: "builtin-cute-doorstep-sit", name: "doorstep-sit", vibe: "cute"),
        Pose(id: "builtin-silly-cat-claw", name: "cat-claw", vibe: "silly"),
        Pose(id: "builtin-silly-reach-for-camera", name: "reach-for-camera", vibe: "silly")
    ]

    @MainActor
    static func seedIfNeeded(in modelContext: ModelContext) async {
        let defaults = UserDefaults.standard

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
                    forResource: pose.name,
                    withExtension: "png"
                ) else {
                    throw CatalogError.missingResource("\(pose.name).png")
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
                        tags: pose.tags
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
