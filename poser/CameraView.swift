import AVFoundation
import AVKit
import SwiftData
import SwiftUI
import UIKit

struct CameraView: View {
    @AppStorage("hasSeenCameraHints") private var hasSeenCameraHints = false
    @Environment(AppState.self) private var appState
    @Environment(PremiumStore.self) private var premium
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \OverlayRecord.addedAt, order: .reverse) private var overlays: [OverlayRecord]

    let camera: CameraController
    @State private var hintAnchors: [String: Anchor<CGRect>] = [:]
    @State private var showsHints = false
    @State private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var captureBusy = false
    @State private var ghostHidden = false
    /// Nil until the preview has measured the capture frame. Deliberately not
    /// defaulted to `.full`: that default is what silently saved the whole
    /// sensor when the crop failed to arrive, and a wrongly-framed photo looks
    /// perfectly normal on its own. Better to know than to guess.
    @State private var normalizedCaptureCrop: NormalizedCrop?
    @State private var captureFrameInWindow = CGRect.zero
    @State private var errorMessage: String?
    @State private var referenceStripCollapsed = false
    @State private var paywallContext: PaywallContext?
    @State private var pinchStartZoom: CGFloat?
    @State private var pinchStartZoomOut: CGFloat?
    /// 0 = the feed fills the whole screen (1×); 1 = it has shrunk to the 3:4
    /// capture rect, with the cloud backdrop showing in the exposed area.
    @State private var viewfinderZoomOut: CGFloat = 0
    /// Favourite pose ids in the order the user last dragged them into, newline
    /// separated because `@AppStorage` has no array form and pose ids never
    /// contain a newline. Ids that are no longer favourites are dropped on the
    /// next reorder rather than pruned eagerly - an unknown id ranks nothing.
    @AppStorage("stripFavoriteOrder") private var stripFavoriteOrderRaw = ""
    @State private var draggingPoseID: String?
    @State private var dragTranslation: CGFloat = 0
    /// Favourite ids in their live order while a hold-and-drag is in progress,
    /// empty at rest. Kept separate from the saved order so an interrupted drag
    /// costs nothing and the strip re-derives itself from storage.
    @State private var dragOrder: [String] = []
    @State private var dragStartIndex = 0

    /// The strip's first slot is reserved for the pose most recently chosen from
    /// the pose library, even when it isn't a favorite, so it stays reachable
    /// while tapping strip favorites only swaps the active overlay. If that pose
    /// is already a favorite in the strip it keeps its existing place rather than
    /// being pulled to the front.
    ///
    /// Locked poses are filtered out rather than shown disabled. The library is
    /// where premium poses are advertised; the strip is a working tool, and a
    /// pose only reaches it by being favourited or picked, both of which are
    /// already gated. This filter is the lapse case: a subscription that ends
    /// leaves premium poses favourited, and they have to leave the strip
    /// without being unfavourited, so they come back if the user resubscribes.
    private var stripOverlays: [OverlayRecord] {
        let favorites = liveFavorites
        guard let pinned = appState.libraryPose, !premium.isLocked(pinned) else { return favorites }
        if favorites.contains(where: { $0.id == pinned.id }) { return favorites }
        return [pinned] + favorites
    }

    private var savedFavoriteOrder: [String] {
        stripFavoriteOrderRaw.isEmpty ? [] : stripFavoriteOrderRaw.components(separatedBy: "\n")
    }

    /// Favourites in the order the strip shows them: the arrangement the user
    /// dragged them into, with anything favourited since that drag kept at the
    /// front, which is where a new favourite has always appeared. Before the
    /// first ever reorder nothing is ranked, so this is exactly the query's
    /// newest-first order.
    private var orderedFavorites: [OverlayRecord] {
        let favorites = overlays.filter { $0.isFavorite && !premium.isLocked($0) }
        var rank: [String: Int] = [:]
        for (index, id) in savedFavoriteOrder.enumerated() { rank[id] = index }
        let ranked = favorites
            .filter { rank[$0.id] != nil }
            .sorted { rank[$0.id, default: 0] < rank[$1.id, default: 0] }
        return favorites.filter { rank[$0.id] == nil } + ranked
    }

    /// `orderedFavorites`, overridden by the in-flight drag arrangement so the
    /// strip shifts under the finger. Falls back to the stored order if the two
    /// ever disagree on membership - a pose deleted mid-drag, say.
    private var liveFavorites: [OverlayRecord] {
        let favorites = orderedFavorites
        guard !dragOrder.isEmpty else { return favorites }
        let byID = Dictionary(favorites.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = dragOrder.compactMap { byID[$0] }
        return live.count == favorites.count ? live : favorites
    }

    private static let hintSteps: [HintStep] = [
        HintStep(
            id: "poseLibrary",
            title: "PICK A POSE",
            message: "Tap here to browse reference poses and float one over your camera."
        ),
        HintStep(
            id: "shutter",
            title: "LINE UP & SHOOT",
            message: "Match the ghost, then tap the shutter for a clean, full-resolution photo."
        ),
        HintStep(
            id: "album",
            title: "YOUR ALBUM",
            message: "Every photo you take lands here - edit, save, or share it anytime."
        ),
        HintStep(
            id: "settings",
            title: "SETTINGS",
            message: "Manage exports, Premium, and more from here."
        )
    ]

    var body: some View {
        ZStack {
            // The same cloud backdrop the album uses. It sits behind the feed
            // and shows through wherever the feed does not reach, so the zoomed-
            // out letterbox reads as that backdrop instead of a flat colour.
            //
            // Rendered inside a flexible Color and clipped so `scaledToFill`
            // fills the screen without reporting an oversized layout - that
            // oversize would stretch the ZStack past the screen and push the
            // controls' edges (the top bar) off both sides.
            Color.clear
                .overlay {
                    Image(.cloudBackground)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .overlay(Theme.Colors.bg.opacity(0.16))
                .ignoresSafeArea()
                .accessibilityHidden(true)

            // The camera *is* the background of this screen and fills it edge to
            // edge at 1× (the hero, immersive view). It is never boxed into a
            // sensor-shaped rect that would strand it inside bars.
            //
            // Zooming out does not crop the lens - it shrinks the feed toward the
            // 3:4 capture rect so the whole sensor becomes visible, and the space
            // that opens up around it reveals the cloud backdrop behind (the
            // preview view is transparent outside the feed - see
            // `CameraPreview.feedRect`). At 1× (`zoomOut == 0`) the feed still
            // covers the screen, so this path is identical to before and
            // `normalizedPhotoCrop` reports exactly the bracketed frame.
            CameraViewport(
                camera: camera,
                captureFrameInWindow: captureFrameInWindow,
                zoomOut: viewfinderZoomOut,
                normalizedPhotoCrop: $normalizedCaptureCrop
            )
            .ignoresSafeArea()
            .simultaneousGesture(cameraZoomGesture)

            // The capture frame and the pose guide are one and the same rect:
            // full width, 3:4 tall, anchored below the top bar - which is exactly
            // what ImageStore's `threeByFourPixelRect` keeps of the feed. The
            // brackets tell the user which part of the viewfinder survives the
            // crop, so this layer must stay in lockstep with that trim.
            //
            // This boxes the *guide*, never the preview: the feed stays edge-to-
            // edge at 1× and only shrinks toward this rect when the user zooms
            // out. The preview re-bases this same measured rect for its own
            // full-screen coordinates.
            CaptureFrame(
                ghost: camera.authorizationStatus == .authorized ? appState.usableGhost : nil,
                ghostFlipped: appState.ghostFlipped,
                ghostOpacity: ghostHidden ? 0 : appState.ghostOpacity
            )
            .allowsHitTesting(false)
            .onPreferenceChange(CaptureFrameRectKey.self) { captureFrameInWindow = $0 }

            VStack(spacing: 0) {
                cameraTopBar
                    .padding(.horizontal, 16)
                    .padding(.top, CaptureFrameMetrics.topBarPadding)
                Spacer()

                if camera.authorizationStatus == .denied || camera.authorizationStatus == .restricted {
                    cameraPermissionCard
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                } else if let message = camera.configurationErrorMessage {
                    cameraUnavailableCard(message)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }

                if !referenceStripCollapsed && camera.supportsZoom && camera.authorizationStatus == .authorized {
                    CameraZoomControl(camera: camera, viewfinderZoomOut: $viewfinderZoomOut)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                referenceStrip
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                cameraBottomBar
                    .padding(.horizontal, 30)
                    .padding(.bottom, 20)
            }

            if let countdown {
                Color.black.opacity(0.16).ignoresSafeArea()
                VStack(spacing: 14) {
                    GlassSurface(cornerRadius: 64) {
                        Text("\(countdown)")
                            .font(.system(size: 72, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 128, height: 128)
                    }
                    Text("HOLD THAT POSE")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
            }

            if showsHints {
                FeatureHintsOverlay(steps: Self.hintSteps, anchors: hintAnchors) {
                    hasSeenCameraHints = true
                    withAnimation(.poserGlide) { showsHints = false }
                }
                .zIndex(20)
            }
        }
        .collectHintAnchors(into: $hintAnchors)
        .modifier(HardwareCameraCaptureModifier(
            isEnabled: camera.isReady
                && !captureBusy
                && !appState.showsSettings
                && !appState.showsPoseLibrary
                && !appState.showsGallery
                && appState.presentedShot == nil
        ) {
            Task { await capture() }
        })
        .task { await camera.requestAccessAndStart() }
        .task { await presentHintsIfNeeded() }
        // A subscription can lapse while a premium pose is the active ghost, so
        // the viewfinder re-checks rather than trusting what selection left
        // behind. `initial: true` covers the lapse having happened off-screen.
        // The render and capture paths read `usableGhost`, which re-tests the
        // lock anyway, so this is about releasing the slot rather than about
        // keeping a locked pose off screen.
        .onChange(of: premium.isUnlocked, initial: true) { appState.enforcePoseLock() }
        .onDisappear { camera.stop() }
        .sheet(item: $paywallContext) { context in
            PaywallView(context: context)
        }
        .alert("Camera hiccup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    /// Shown once, the first time a new user reaches the live camera screen -
    /// after onboarding's permission prompt has already settled, and only if
    /// nothing else (a sheet, the shutter countdown) is already on screen.
    @MainActor
    private func presentHintsIfNeeded() async {
        guard !hasSeenCameraHints else { return }
        try? await Task.sleep(for: .seconds(0.8))
        guard
            camera.authorizationStatus == .authorized,
            !appState.showsSettings,
            !appState.showsPoseLibrary,
            !appState.showsGallery,
            appState.presentedShot == nil
        else { return }
        withAnimation(.poserGlide) { showsHints = true }
    }

    private var cameraZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let mag = value.magnification
                if pinchStartZoom == nil { pinchStartZoom = camera.zoomFactor }
                if pinchStartZoomOut == nil { pinchStartZoomOut = viewfinderZoomOut }
                let startZoom = pinchStartZoom ?? camera.zoomFactor
                let startOut = pinchStartZoomOut ?? viewfinderZoomOut

                // Below the lens's own minimum there is nothing left to zoom out
                // optically, so pinching in there digitally shrinks the feed
                // (the cloud backdrop fills the gap) instead of doing nothing. Pinching
                // back out unwinds that before the lens takes over again.
                if startOut > 0 || (mag < 1 && startZoom <= camera.minimumZoomFactor + 0.001) {
                    // Gain of 2.5 so a comfortable pinch spans the whole 0…1
                    // range in one gesture - without it, spreading the fingers
                    // back out could never fully return to the full-screen camera.
                    // (Optical zoom-in from here takes a fresh pinch once this
                    // one has settled back to the full screen.)
                    viewfinderZoomOut = max(0, min(1, startOut + (1 - mag) * 2.5))
                } else if camera.supportsZoom {
                    camera.setZoom(startZoom * mag)
                }
            }
            .onEnded { _ in
                // Snap away any sliver of letterbox so the camera always settles
                // back to a clean full screen.
                if viewfinderZoomOut < 0.02 { viewfinderZoomOut = 0 }
                pinchStartZoom = nil
                pinchStartZoomOut = nil
            }
    }

    private var cameraTopBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { appState.showsSettings = true } label: {
                    GlassSurface(cornerRadius: Theme.Radius.pill, interactive: false) {
                        Text("POSER")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(Theme.Colors.ink)
                            .padding(.horizontal, 18)
                            .frame(height: CaptureFrameMetrics.topBarHeight)
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("POSER settings")
                .hintAnchor("settings")
                Spacer()
                GlassIconButton(
                    symbol: camera.flash.symbol,
                    accessibilityLabel: "Flash \(camera.flash.rawValue)",
                    selected: camera.flash != .off
                ) {
                    camera.flash = camera.flash.next
                }
                GlassIconButton(
                    symbol: timerSeconds == 0 ? "timer" : "timer.circle.fill",
                    accessibilityLabel: timerSeconds == 0 ? "Timer off" : "Timer \(timerSeconds) seconds",
                    selected: timerSeconds > 0
                ) {
                    timerSeconds = timerSeconds == 0 ? 3 : timerSeconds == 3 ? 10 : 0
                }
            }
        }
        // Rendered outside GlassEffectContainer: content overlapping a glass
        // shape's own bounds can get covered by its live backdrop even via
        // .overlay, so the badge is anchored here instead, above the whole bar.
        .overlay(alignment: .topTrailing) {
            if timerSeconds > 0 {
                Text("\(timerSeconds)")
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Theme.Colors.ink))
                    .offset(x: 4, y: -4)
                    .allowsHitTesting(false)
            }
        }
    }

    private var cameraBottomBar: some View {
        GlassGroup(spacing: 32) {
            HStack {
                GlassIconButton(symbol: "photo.on.rectangle", accessibilityLabel: "Open album") {
                    appState.showsGallery = true
                }
                .hintAnchor("album")
                Spacer()
                ShutterButton(enabled: camera.isReady && !captureBusy) {
                    Task { await capture() }
                }
                .hintAnchor("shutter")
                Spacer()
                GlassIconButton(
                    symbol: "arrow.triangle.2.circlepath",
                    accessibilityLabel: "Flip camera",
                    disabled: captureBusy || camera.isSwitching
                ) {
                    withAnimation(.poserGlide) { viewfinderZoomOut = 0 }
                    Task {
                        do { try await camera.switchCamera() }
                        catch {
                            errorMessage = "Switching cameras failed. \(error.localizedDescription)"
                            Analytics.captureError(error, area: "camera_switch")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var referenceStrip: some View {
        if referenceStripCollapsed {
            HStack {
                Spacer()
                GlassIconButton(symbol: "chevron.up", accessibilityLabel: "Show poses", size: 40) {
                    withAnimation(.poserGlide) { referenceStripCollapsed = false }
                }
                Spacer()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            GlassSurface(cornerRadius: Theme.Radius.lg) {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        GlassIconButton(symbol: "square.grid.2x2", accessibilityLabel: "Open pose library", size: 40) {
                            appState.showsPoseLibrary = true
                        }
                        .hintAnchor("poseLibrary")
                        if stripOverlays.isEmpty {
                            Button("FAVORITE A POSE") { appState.showsPoseLibrary = true }
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Theme.Colors.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: PoseStripMetrics.spacing) {
                                    ForEach(stripOverlays) { overlay in
                                        PoseThumbnail(
                                            overlay: overlay,
                                            selected: appState.usableGhost?.id == overlay.id,
                                            flipped: appState.usableGhost?.id == overlay.id && appState.ghostFlipped,
                                            // Only favourites reorder. The
                                            // reserved most-recent slot is
                                            // positional by definition, so its
                                            // pose has nowhere to be dragged to.
                                            reorder: overlay.isFavorite ? reorder(for: overlay) : nil
                                        ) {
                                            // The strip already filters locked
                                            // poses out, so this is the backstop
                                            // for one that slipped in: refuse the
                                            // selection and sell the upgrade
                                            // rather than doing nothing.
                                            guard appState.cycleGhost(overlay) else {
                                                Analytics.track("premium_pose_tapped", ["pose": overlay.id])
                                                paywallContext = .premiumPose
                                                return
                                            }
                                            try? modelContext.save()
                                        }
                                        .zIndex(draggingPoseID == overlay.id ? 1 : 0)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            // A lifted pose owns the horizontal axis; without
                            // this the strip scrolls out from under the drag.
                            .scrollDisabled(draggingPoseID != nil)
                        }
                        GlassIconButton(symbol: "chevron.down", accessibilityLabel: "Hide poses", size: 40) {
                            withAnimation(.poserGlide) { referenceStripCollapsed = true }
                        }
                    }
                    GhostOpacitySlider(opacity: Bindable(appState).ghostOpacity)
                        .disabled(appState.usableGhost == nil)
                        .opacity(appState.usableGhost == nil ? 0 : 1)
                }
                .padding(10)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func reorder(for overlay: OverlayRecord) -> PoseReorder {
        PoseReorder(
            dragging: draggingPoseID == overlay.id,
            offset: dragOffset(for: overlay),
            onBegin: { beginReorder(overlay) },
            onChange: { updateReorder(overlay, translation: $0) },
            onEnd: { endReorder() },
            onNudge: { nudgeFavorite(overlay, by: $0) }
        )
    }

    /// How far the lifted pose sits from the slot it currently occupies. The
    /// slot moves out from under it every time the arrangement changes, so the
    /// slots it has already travelled past are subtracted back out and the
    /// thumbnail stays pinned to the finger.
    private func dragOffset(for overlay: OverlayRecord) -> CGFloat {
        guard draggingPoseID == overlay.id,
              let current = dragOrder.firstIndex(of: overlay.id) else { return 0 }
        return dragTranslation - CGFloat(current - dragStartIndex) * PoseStripMetrics.stride
    }

    private func beginReorder(_ overlay: OverlayRecord) {
        dragOrder = orderedFavorites.map(\.id)
        dragStartIndex = dragOrder.firstIndex(of: overlay.id) ?? 0
        dragTranslation = 0
        draggingPoseID = overlay.id
    }

    private func updateReorder(_ overlay: OverlayRecord, translation: CGFloat) {
        guard draggingPoseID == overlay.id,
              let current = dragOrder.firstIndex(of: overlay.id) else { return }
        dragTranslation = translation
        let slots = Int((translation / PoseStripMetrics.stride).rounded())
        let target = min(max(dragStartIndex + slots, 0), dragOrder.count - 1)
        guard target != current else { return }
        withAnimation(.poserGlide) {
            dragOrder.remove(at: current)
            dragOrder.insert(overlay.id, at: target)
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    /// Commits the arrangement, storing only the ids that are favourites right
    /// now. A pose that leaves the strip loses its rank and returns to the front
    /// if it is favourited again, which is where new favourites go anyway.
    private func endReorder() {
        if !dragOrder.isEmpty, dragOrder != savedFavoriteOrder {
            stripFavoriteOrderRaw = dragOrder.joined(separator: "\n")
        }
        draggingPoseID = nil
        withAnimation(.poserGlide) {
            dragTranslation = 0
            dragOrder = []
        }
    }

    /// The VoiceOver route to the same rearrangement, since a drag is not
    /// reachable by anyone navigating the strip by rotor.
    @discardableResult
    private func nudgeFavorite(_ overlay: OverlayRecord, by delta: Int) -> Bool {
        var order = orderedFavorites.map(\.id)
        guard let current = order.firstIndex(of: overlay.id) else { return false }
        let target = current + delta
        guard order.indices.contains(target) else { return false }
        order.remove(at: current)
        order.insert(overlay.id, at: target)
        withAnimation(.poserGlide) { stripFavoriteOrderRaw = order.joined(separator: "\n") }
        return true
    }

    private var cameraPermissionCard: some View {
        GlassSurface(cornerRadius: Theme.Radius.lg, tint: Theme.Colors.cream.opacity(0.26)) {
            VStack(spacing: 12) {
                Text("CAMERA TIME")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                Text("POSER needs the camera to float your pose guide over the viewfinder.")
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.textDim)
                GlassTextButton(title: "OPEN SETTINGS") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            .padding(20)
        }
    }

    private func cameraUnavailableCard(_ message: String) -> some View {
        GlassSurface(cornerRadius: Theme.Radius.lg, tint: Theme.Colors.cream.opacity(0.26)) {
            VStack(spacing: 10) {
                Text("CAMERA UNAVAILABLE")
                    .font(.system(size: 17, weight: .black, design: .rounded))
                Text("The camera isn't available in this environment. POSER's album and pose tools still work here.")
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.Colors.textDim)
                Text(message)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.disabled)
                    .lineLimit(2)
            }
            .padding(18)
        }
    }

    @MainActor
    private func capture() async {
        guard !captureBusy, camera.isReady else { return }
        captureBusy = true
        defer {
            captureBusy = false
            ghostHidden = false
        }

        if timerSeconds > 0 {
            for value in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.easeOut(duration: 0.15)) { countdown = value }
                UISelectionFeedbackGenerator().selectionChanged()
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = nil
        }

        guard let normalizedCaptureCrop else {
            errorMessage = "The viewfinder is still getting ready. Please try again."
            return
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        ghostHidden = true
        do {
            let data = try await camera.capturePhoto()
            // `usableGhost`, not `selectedGhost`: a shot stores its ghost so the
            // gallery can re-arm that pose later, and a locked one must not get
            // written into a photo that would hand it back after a lapse.
            let ghostSnapshot = appState.usableGhost.map {
                OverlaySnapshot(id: $0.id, fileName: $0.fileName, width: $0.width, height: $0.height)
            }
            let stored = try await ImageStore.shared.persistCapture(
                data,
                facing: camera.facing,
                ghostOverlay: ghostSnapshot,
                normalizedCrop: normalizedCaptureCrop
            )
            let record = ShotRecord(
                id: stored.id,
                fileName: stored.fileName,
                facing: camera.facing,
                width: stored.width,
                height: stored.height,
                ghost: stored.ghost
            )
            // The shot lands in the context so the editor has something to
            // decorate, but it is a draft until the editor's Done keeps it:
            // closing with X deletes it again. Nothing reaches the Camera Roll
            // from here - that is the album lightbox's job, on request.
            modelContext.insert(record)
            try modelContext.save()
            appState.presentedShot = record
            Analytics.track("photo_captured", ["has_ghost": ghostSnapshot != nil])
        } catch {
            errorMessage = "Capturing the photo failed. \(error.localizedDescription)"
            Analytics.captureError(error, area: "camera_capture")
        }
    }
}

private struct HardwareCameraCaptureModifier: ViewModifier {
    let isEnabled: Bool
    let capture: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: isEnabled) { event in
                guard event.phase == .ended else { return }
                capture()
            }
        } else {
            content
        }
    }
}

private struct CameraZoomControl: View {
    let camera: CameraController
    /// Any explicit zoom choice means "full-screen camera at this optical zoom",
    /// so selecting one clears the digital zoom-out (and its backdrop letterbox).
    @Binding var viewfinderZoomOut: CGFloat
    @State private var showsRange = false

    var body: some View {
        GlassGroup(spacing: 8) {
            GlassSurface(cornerRadius: Theme.Radius.pill) {
                if showsRange {
                    HStack(spacing: 10) {
                        Text(Self.label(for: camera.zoomFactor))
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 42)

                        Slider(value: zoomProgress, in: 0...1)
                            .tint(Theme.Colors.sky)
                            .frame(width: 170)
                            .accessibilityLabel("Zoom")
                            .accessibilityValue(Self.accessibilityLabel(for: camera.zoomFactor))

                        Button { showsRange = false } label: {
                            Text("Done")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Theme.Colors.ink)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(.rect)
                        }
                        .buttonStyle(PressScaleButtonStyle())
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .transition(.opacity)
                } else {
                    HStack(spacing: 4) {
                        ForEach(zoomStops) { stop in
                            Button {
                                withAnimation(.poserGlide) { viewfinderZoomOut = stop.zoomOut }
                                camera.setZoom(stop.lens, smoothly: true)
                            } label: {
                                Text(stop.label)
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Colors.ink)
                                    .frame(width: 42, height: 42)
                                    .background {
                                        if isSelected(stop) {
                                            Circle().fill(Theme.Colors.sky)
                                        }
                                    }
                                    .contentShape(.circle)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityLabel("Zoom \(stop.label)")
                            .accessibilityAddTraits(isSelected(stop) ? .isSelected : [])
                        }

                        Button { showsRange = true } label: {
                            Image(systemName: "dial.medium")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Theme.Colors.ink)
                                .frame(width: 42, height: 42)
                                .contentShape(.circle)
                        }
                        .buttonStyle(PressScaleButtonStyle())
                        .accessibilityLabel("Choose any zoom from \(Self.accessibilityLabel(for: camera.minimumZoomFactor)) to \(Self.accessibilityLabel(for: camera.maximumZoomFactor))")
                    }
                    .padding(.horizontal, 5)
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsRange)
        .onChange(of: camera.facing) { showsRange = false }
        .accessibilityElement(children: .contain)
    }

    /// On an ultra-wide device the widest lens can be pulled back digitally to
    /// reveal the full sensor with the cloud backdrop around it - the true 0.5×
    /// the preset row exposes. Matches the `widest < 0.9` test the preset stops
    /// use so the two controls agree on which devices have that mode.
    private var hasBackdropSegment: Bool { camera.minimumZoomFactor < 0.9 }

    /// Fraction of the slider track reserved, at the very bottom, for that
    /// pull-back to the full sensor. Zero on devices without an ultra-wide.
    private var backdropFraction: Double { hasBackdropSegment ? 0.16 : 0 }

    /// The slider is a continuous version of the preset row. Its bottom
    /// `backdropFraction` of travel holds the widest lens and pulls the feed back
    /// to the full sensor (`viewfinderZoomOut` 0→1), so the slider's 0.5× lands on
    /// the *same* framing as the 0.5× preset instead of the screen-filling crop of
    /// the widest lens. The remaining travel is the optical range, filling the
    /// screen. The two segments meet at the widest lens with no jump.
    private var zoomProgress: Binding<Double> {
        Binding(
            get: {
                let minimum = max(Double(camera.minimumZoomFactor), 0.01)
                let maximum = max(Double(camera.maximumZoomFactor), minimum)
                let backdrop = backdropFraction
                if backdrop > 0 && viewfinderZoomOut > 0 {
                    return (1 - Double(viewfinderZoomOut)) * backdrop
                }
                guard maximum > minimum else { return backdrop }
                let optical = log(Double(camera.zoomFactor) / minimum) / log(maximum / minimum)
                return backdrop + optical * (1 - backdrop)
            },
            set: { progress in
                let minimum = max(Double(camera.minimumZoomFactor), 0.01)
                let maximum = max(Double(camera.maximumZoomFactor), minimum)
                let backdrop = backdropFraction
                if backdrop > 0 && progress < backdrop {
                    let t = progress / backdrop
                    viewfinderZoomOut = CGFloat(1 - t)
                    camera.setZoom(camera.minimumZoomFactor)
                    return
                }
                if viewfinderZoomOut != 0 { viewfinderZoomOut = 0 }
                guard maximum > minimum else { return }
                let optical = (progress - backdrop) / (1 - backdrop)
                let factor = minimum * pow(maximum / minimum, optical)
                camera.setZoom(CGFloat(factor))
            }
        )
    }

    /// One tappable zoom pill. Beyond an optical `lens` it also carries a
    /// `zoomOut`, so a single lens can appear twice: once pulled all the way
    /// back to the full sensor (cloud backdrop around it) and once filling the
    /// screen.
    private struct ZoomStop: Identifiable {
        let id: Int
        let label: String
        let lens: CGFloat
        let zoomOut: CGFloat
    }

    /// Left → right, widest to narrowest:
    ///   • widest lens, full sensor (cloud backdrop around it) - most zoomed out
    ///   • widest lens, filling the screen - the widest view with no bars
    ///   • each remaining optical preset, filling the screen
    /// The middle stop only exists when the widest lens is an ultra-wide (< 1×);
    /// otherwise it would just duplicate 1×.
    private var zoomStops: [ZoomStop] {
        let presets = camera.zoomPresetFactors
        guard let widest = presets.first else { return [] }
        var stops: [ZoomStop] = []
        if widest < 0.9 {
            stops.append(ZoomStop(id: 0, label: Self.label(for: widest), lens: widest, zoomOut: 1))
            stops.append(ZoomStop(id: 1, label: Self.label(for: 0.7), lens: widest, zoomOut: 0))
        } else {
            stops.append(ZoomStop(id: 0, label: Self.label(for: widest), lens: widest, zoomOut: 0))
        }
        for (index, factor) in presets.enumerated() where factor != widest {
            stops.append(ZoomStop(id: 100 + index, label: Self.label(for: factor), lens: factor, zoomOut: 0))
        }
        return stops
    }

    private func isSelected(_ stop: ZoomStop) -> Bool {
        // The pulled-back (backdrop) stop owns the zoomed-out state; fill stops
        // light up only while the feed is filling the screen at their lens.
        if stop.zoomOut > 0.5 {
            return viewfinderZoomOut > 0.5
        }
        return viewfinderZoomOut < 0.5 && abs(camera.zoomFactor - stop.lens) < 0.05
    }

    private static func label(for factor: CGFloat) -> String {
        "\(formatted(factor))×"
    }

    private static func accessibilityLabel(for factor: CGFloat) -> String {
        "\(formatted(factor)) times"
    }

    private static func formatted(_ factor: CGFloat) -> String {
        let value = Double(factor)
        let isWhole = abs(value.rounded() - value) < 0.01
        return value.formatted(.number.precision(.fractionLength(isWhole ? 0 : 1)))
    }
}

private struct CameraViewport: View {
    let camera: CameraController
    let captureFrameInWindow: CGRect
    let zoomOut: CGFloat
    @Binding var normalizedPhotoCrop: NormalizedCrop?

    var body: some View {
        CameraPreview(
            session: camera.session,
            captureFrameInWindow: captureFrameInWindow,
            zoomOut: zoomOut,
            isReady: camera.isReady,
            normalizedPhotoCrop: $normalizedPhotoCrop
        )
    }
}

/// The one definition of the capture frame: the region of the viewfinder that
/// survives the 3:4 crop.
///
/// Everything that needs this rect derives it from here - the brackets, the pose
/// guide, and the crop the photo is actually rendered with (via `PreviewView`).
/// Keep it that way: if the on-screen frame and the crop are computed
/// separately they will drift, and the brackets will quietly start lying about
/// what ends up in the photo.
enum CaptureFrameMetrics {
    /// Top bar geometry. `cameraTopBar` is laid out from these same constants,
    /// so the frame tracks the bar automatically instead of restating its size.
    static let topBarPadding: CGFloat = 8
    static let topBarHeight: CGFloat = 46
    /// Breathing room between the bar and the frame.
    static let gapBelowTopBar: CGFloat = 8

    /// The frame hangs just below the top bar rather than a fixed distance from
    /// centre: the bar is a constant height on every device, but the space
    /// around it is not, so this is the one anchor that means the same thing on
    /// every screen.
    static let dropBelowSafeAreaTop = topBarPadding + topBarHeight + gapBelowTopBar

    /// Left/right breathing room so the corner brackets read as a frame inside
    /// the screen instead of tucking under the rounded corners at the very edge.
    /// Matches the top bar's horizontal padding so the frame lines up with it.
    static let sideInset: CGFloat = 16

    /// In safe-area coordinates - what the SwiftUI overlay is laid out in. This
    /// is the *only* place the frame is defined. The preview does not recompute
    /// it in its own coordinate space; it is handed the measured rect, so the
    /// brackets and the crop cannot disagree no matter what the layout does.
    static func rect(inSafeArea size: CGSize) -> CGRect {
        let width = max(0, size.width - sideInset * 2)
        let height = min(width * 4 / 3, size.height)
        // Never let the frame hang off the bottom on a short screen; it gives up
        // the gap under the bar before it gives up being fully visible.
        let y = min(max(0, dropBelowSafeAreaTop), size.height - height)
        return CGRect(x: sideInset, y: y, width: width, height: height)
    }

    /// The capture frame as a fraction of the *photo* rather than the screen.
    ///
    /// Pure geometry, and deliberately so. The preview aspect-fills a 3:4 photo
    /// into `viewSize`, which fixes exactly where the photo's (overflowing)
    /// rendered rect sits; the frame's place inside it is then just division.
    ///
    /// This used to go through `metadataOutputRectConverted`, which needs a live
    /// preview connection and returns nothing before one exists. The crop then
    /// stayed at its `.full` default - silently saving the whole sensor instead
    /// of the bracketed area. Geometry cannot arrive late or fail, so the crop
    /// is always right by the first layout pass.
    ///
    /// Returned in *displayed* image space (the photo as the user saw it, after
    /// rotation and any front-camera mirroring), which is what
    /// `ImageStore.renderCroppedJPEG` applies its crops in.
    static func photoCrop(
        for frame: CGRect,
        in viewSize: CGSize,
        photoAspect: CGFloat = 3.0 / 4.0
    ) -> NormalizedCrop? {
        guard viewSize.width > 0, viewSize.height > 0, photoAspect > 0,
              !frame.isEmpty, !frame.isNull else { return nil }

        // Aspect-fill: scale the photo until it covers both axes, then centre it.
        // Whichever axis overflows hangs off the view symmetrically.
        let scale = max(viewSize.width / photoAspect, viewSize.height)
        let rendered = CGSize(width: photoAspect * scale, height: scale)
        let origin = CGPoint(
            x: (viewSize.width - rendered.width) / 2,
            y: (viewSize.height - rendered.height) / 2
        )

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let crop = CGRect(
            x: (frame.minX - origin.x) / rendered.width,
            y: (frame.minY - origin.y) / rendered.height,
            width: frame.width / rendered.width,
            height: frame.height / rendered.height
        ).intersection(unit)
        guard !crop.isNull, !crop.isEmpty else { return nil }

        return NormalizedCrop(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)
    }
}

/// Carries the capture frame, measured in window coordinates, from the overlay
/// that draws it to the preview that crops to it.
struct CaptureFrameRectKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Marks the region of the viewfinder that survives the 3:4 crop, and holds the
/// pose guide inside it.
///
/// The frame is marked with corner brackets only. The area outside it is left
/// completely untouched - never dim, tint, or otherwise darken it: the feed is
/// edge-to-edge and stays that way.
///
/// The pose is fixed to this rect and cannot be dragged or pinched: its position
/// *is* the promise about where the crop lands, so letting it move would break
/// the only signal the user has. Poses are stored on a 3:4 canvas, so a `.fit`
/// here fills the frame exactly and the guide lines up with the capture area by
/// construction. Users who want a different capture area re-crop the pose itself
/// via "Reframe pose" in the pose library.
private struct CaptureFrame: View {
    let ghost: OverlayRecord?
    let ghostFlipped: Bool
    let ghostOpacity: Double

    var body: some View {
        GeometryReader { proxy in
            let frame = CaptureFrameMetrics.rect(inSafeArea: proxy.size)

            ZStack {
                if let ghost {
                    LocalFileImage(url: ImageStore.shared.overlayURL(ghost), contentMode: .fit, maxPixel: 1800)
                        .id(ghost.cropData)
                        .scaleEffect(x: ghostFlipped ? -1 : 1, y: 1)
                        .opacity(ghostOpacity)
                        .frame(width: frame.width, height: frame.height)
                        .clipped()
                        .position(x: frame.midX, y: frame.midY)
                }

                // Two-layer stroke - a dark halo under a white line - so the
                // capture corners read on any scene (bright, dark, or the cloud
                // backdrop) without relying on a blur/shadow filter.
                CaptureFrameBrackets(arm: 26)
                    .stroke(.black.opacity(0.5), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                CaptureFrameBrackets(arm: 26)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
            // Hand the preview the rect that was actually drawn, in window
            // coordinates so it survives the trip across coordinate spaces.
            .preference(
                key: CaptureFrameRectKey.self,
                value: frame.offsetBy(
                    dx: proxy.frame(in: .global).minX,
                    dy: proxy.frame(in: .global).minY
                )
            )
        }
    }
}

/// Corner brackets, inset so the strokes sit just inside the capture frame.
/// Bright white with a soft shadow so the capture area stays readable over both
/// a light scene (or the cloud backdrop) and a dark one, short enough not to
/// box the subject in.
private struct CaptureFrameBrackets: Shape {
    var arm: CGFloat = 16
    var inset: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        for corner in [
            (CGPoint(x: box.minX, y: box.minY), CGFloat(1), CGFloat(1)),
            (CGPoint(x: box.maxX, y: box.minY), CGFloat(-1), CGFloat(1)),
            (CGPoint(x: box.minX, y: box.maxY), CGFloat(1), CGFloat(-1)),
            (CGPoint(x: box.maxX, y: box.maxY), CGFloat(-1), CGFloat(-1))
        ] {
            let (origin, dx, dy) = corner
            path.move(to: CGPoint(x: origin.x + arm * dx, y: origin.y))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + arm * dy))
        }
        return path
    }
}

/// Layout the strip and its thumbnails have to agree on: a drag is turned into
/// a slot count by dividing the finger's travel by one thumbnail plus one gap,
/// so the two numbers cannot drift apart.
enum PoseStripMetrics {
    static let thumbWidth: CGFloat = 54
    static let thumbHeight: CGFloat = 72
    static let spacing: CGFloat = 8
    static var stride: CGFloat { thumbWidth + spacing }
}

/// Everything a strip thumbnail needs to be held and dragged into a new
/// position. Nil for the reserved most-recent slot, which never moves.
struct PoseReorder {
    let dragging: Bool
    let offset: CGFloat
    let onBegin: () -> Void
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void
    /// VoiceOver's equivalent of the drag: -1 moves left, +1 right.
    let onNudge: (Int) -> Bool
}

private struct PoseThumbnail: View {
    let overlay: OverlayRecord
    let selected: Bool
    let flipped: Bool
    let reorder: PoseReorder?
    let action: () -> Void

    private var dragging: Bool { reorder?.dragging == true }

    var body: some View {
        Button(action: action) {
            LocalFileImage(
                url: ImageStore.shared.overlayURL(overlay),
                contentMode: .fit,
                maxPixel: 220
            )
            .scaleEffect(x: flipped ? -1 : 1, y: 1)
            .frame(width: PoseStripMetrics.thumbWidth, height: PoseStripMetrics.thumbHeight)
            .background(Theme.Colors.black.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        selected ? Color.white : Theme.Colors.glassEdge,
                        lineWidth: selected ? 2 : 1
                    )
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        // The lift: the held pose grows out of the row and casts a shadow so it
        // reads as picked up off the strip rather than sliding along it.
        .scaleEffect(dragging ? 1.12 : 1)
        .shadow(color: Theme.Colors.black.opacity(dragging ? 0.34 : 0), radius: 12, y: 6)
        .offset(x: reorder?.offset ?? 0)
        .animation(.poserGlide, value: dragging)
        .gesture(holdGesture)
        .accessibilityLabel(selected ? "Selected pose" : "Pose")
        .accessibilityHint(reorder == nil ? "Tap to select, then flip" : "Tap to select, then flip. Hold and drag to rearrange")
        .accessibilityActions {
            if let reorder {
                Button("Move left") { _ = reorder.onNudge(-1) }
                Button("Move right") { _ = reorder.onNudge(1) }
            }
        }
    }

    /// Hold to lift, then drag. `minimumDistance: 0` so the drag is already
    /// live the instant the press succeeds - otherwise the first few points of
    /// travel are swallowed and the thumbnail lags the finger out of the gate.
    ///
    /// The reserved most-recent slot has no `reorder`, so holding it does
    /// nothing at all rather than lifting a pose that cannot go anywhere.
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    guard let reorder, !dragging else { return }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    reorder.onBegin()
                case .second(true, let drag):
                    guard let drag else { return }
                    reorder?.onChange(drag.translation.width)
                default:
                    break
                }
            }
            .onEnded { _ in reorder?.onEnd() }
    }
}

private struct ShutterButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassSurface(cornerRadius: 46, interactive: true) {
                ZStack {
                    Circle().stroke(.white.opacity(0.74), lineWidth: 2).padding(9)
                    Circle().fill(.white.opacity(enabled ? 0.52 : 0.20)).padding(17)
                    Circle().fill(.white.opacity(enabled ? 0.86 : 0.30)).frame(width: 18, height: 18)
                }
                .frame(width: 92, height: 92)
            }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel("Take photo")
        .accessibilityHint(enabled ? "Captures a clean full-resolution photo" : "Camera is getting ready")
    }
}
