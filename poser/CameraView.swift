import AVFoundation
import AVKit
import SwiftData
import SwiftUI
import UIKit

struct CameraView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \OverlayRecord.addedAt, order: .reverse) private var overlays: [OverlayRecord]

    let camera: CameraController
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
    @State private var showsSettings = false
    @State private var pinchStartZoom: CGFloat?

    private var favoriteOverlays: [OverlayRecord] {
        overlays.filter(\.isFavorite)
    }

    var body: some View {
        ZStack {
            Theme.Colors.black.ignoresSafeArea()

            // INVARIANT: the viewfinder is edge-to-edge — it fills the whole
            // screen, safe areas included, and the controls float on top of it.
            // Never box it into a sensor-shaped rect (e.g. width * 4/3 pinned
            // below the top bar): that letterboxes the feed into black bars,
            // which is a regression this screen has repeatedly suffered.
            //
            // The preview layer is .resizeAspectFill, so the 3:4 sensor feed
            // scales until it covers the screen's height and its width spills
            // off the sides. `normalizedPhotoCrop` reports the sensor region
            // behind `CaptureFrameMetrics.rect` — already 3:4, so ImageStore's
            // trim is a no-op and the photo is exactly the bracketed frame.
            CameraViewport(
                camera: camera,
                captureFrameInWindow: captureFrameInWindow,
                normalizedPhotoCrop: $normalizedCaptureCrop
            )
            .ignoresSafeArea()
            .simultaneousGesture(cameraZoomGesture)

            // The capture frame and the pose guide are one and the same rect:
            // full width, 3:4 tall, centred — which is exactly what ImageStore's
            // `threeByFourPixelRect` keeps of the screen. The brackets are what
            // tell the user which part of the viewfinder survives the crop, so
            // this layer must stay in lockstep with that trim.
            //
            // Note this boxes the *guide*, never the preview: the feed stays
            // edge-to-edge and undimmed outside the frame.
            // Laid out in the safe area, unlike the preview beneath it: the
            // frame is anchored to the top bar, which lives in the safe area
            // too. `PreviewView` re-bases the same anchor for its own
            // full-screen coordinates.
            CaptureFrame(
                ghost: camera.authorizationStatus == .authorized ? appState.selectedGhost : nil,
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
                    CameraZoomControl(camera: camera)
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
        }
        .modifier(HardwareCameraCaptureModifier(
            isEnabled: camera.isReady
                && !captureBusy
                && !showsSettings
                && !appState.showsPoseLibrary
                && !appState.showsGallery
                && appState.presentedShot == nil
        ) {
            Task { await capture() }
        })
        .task { await camera.requestAccessAndStart() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
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

    private var cameraZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard camera.supportsZoom else { return }
                if pinchStartZoom == nil { pinchStartZoom = camera.zoomFactor }
                camera.setZoom((pinchStartZoom ?? camera.zoomFactor) * value.magnification)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private var cameraTopBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { showsSettings = true } label: {
                    GlassSurface(cornerRadius: Theme.Radius.pill, interactive: true) {
                        Text("POSER")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(Theme.Colors.ink)
                            .padding(.horizontal, 18)
                            .frame(height: CaptureFrameMetrics.topBarHeight)
                    }
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel("POSER settings")
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
                GlassIconButton(
                    symbol: "arrow.triangle.2.circlepath",
                    accessibilityLabel: "Flip camera",
                    disabled: captureBusy || camera.isSwitching
                ) {
                    Task {
                        do { try await camera.switchCamera() }
                        catch { errorMessage = "Switching cameras failed. \(error.localizedDescription)" }
                    }
                }
                Spacer()
                ShutterButton(enabled: camera.isReady && !captureBusy) {
                    Task { await capture() }
                }
                Spacer()
                GlassIconButton(symbol: "photo.on.rectangle", accessibilityLabel: "Open album") {
                    appState.showsGallery = true
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
                        if favoriteOverlays.isEmpty {
                            Button("FAVORITE A POSE") { appState.showsPoseLibrary = true }
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(Theme.Colors.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(favoriteOverlays) { overlay in
                                        PoseThumbnail(
                                            overlay: overlay,
                                            selected: appState.selectedGhost?.id == overlay.id,
                                            flipped: appState.selectedGhost?.id == overlay.id && appState.ghostFlipped
                                        ) {
                                            appState.cycleGhost(overlay)
                                            try? modelContext.save()
                                        } onDelete: {
                                            guard !overlay.isBuiltIn else { return }
                                            if appState.selectedGhost?.id == overlay.id { appState.selectedGhost = nil }
                                            modelContext.delete(overlay)
                                            Task { await ImageStore.shared.deleteOverlay(overlay) }
                                        }
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                        GlassIconButton(symbol: "chevron.down", accessibilityLabel: "Hide poses", size: 40) {
                            withAnimation(.poserGlide) { referenceStripCollapsed = true }
                        }
                    }
                    GhostOpacitySlider(opacity: Bindable(appState).ghostOpacity)
                        .disabled(appState.selectedGhost == nil)
                        .opacity(appState.selectedGhost == nil ? 0.4 : 1)
                }
                .padding(10)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
            let ghostSnapshot = appState.selectedGhost.map {
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
            // from here — that is the album lightbox's job, on request.
            modelContext.insert(record)
            try modelContext.save()
            appState.presentedShot = record
        } catch {
            errorMessage = "Capturing the photo failed. \(error.localizedDescription)"
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
                            .tint(Theme.Colors.ink)
                            .frame(width: 170)
                            .accessibilityLabel("Zoom")
                            .accessibilityValue(Self.accessibilityLabel(for: camera.zoomFactor))

                        Button("Done") { showsRange = false }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Colors.ink)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .transition(.opacity)
                } else {
                    HStack(spacing: 4) {
                        ForEach(camera.zoomPresetFactors, id: \.self) { factor in
                            Button {
                                camera.setZoom(factor, smoothly: true)
                            } label: {
                                Text(Self.label(for: factor))
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(isSelected(factor) ? Theme.Colors.cream : Theme.Colors.ink)
                                    .frame(width: 42, height: 42)
                                    .background {
                                        if isSelected(factor) {
                                            Circle().fill(Theme.Colors.ink.opacity(0.88))
                                        }
                                    }
                                    .contentShape(.circle)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityLabel("Zoom \(Self.accessibilityLabel(for: factor))")
                            .accessibilityAddTraits(isSelected(factor) ? .isSelected : [])
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

    private var zoomProgress: Binding<Double> {
        Binding(
            get: {
                let minimum = max(Double(camera.minimumZoomFactor), 0.01)
                let maximum = max(Double(camera.maximumZoomFactor), minimum)
                guard maximum > minimum else { return 0 }
                return log(Double(camera.zoomFactor) / minimum) / log(maximum / minimum)
            },
            set: { progress in
                let minimum = max(Double(camera.minimumZoomFactor), 0.01)
                let maximum = max(Double(camera.maximumZoomFactor), minimum)
                let factor = minimum * pow(maximum / minimum, progress)
                camera.setZoom(CGFloat(factor))
            }
        )
    }

    private func isSelected(_ factor: CGFloat) -> Bool {
        abs(camera.zoomFactor - factor) < 0.05
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
    @Binding var normalizedPhotoCrop: NormalizedCrop?

    var body: some View {
        CameraPreview(
            session: camera.session,
            captureFrameInWindow: captureFrameInWindow,
            normalizedPhotoCrop: $normalizedPhotoCrop
        )
    }
}

/// The one definition of the capture frame: the region of the viewfinder that
/// survives the 3:4 crop.
///
/// Everything that needs this rect derives it from here — the brackets, the pose
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

    /// In safe-area coordinates — what the SwiftUI overlay is laid out in. This
    /// is the *only* place the frame is defined. The preview does not recompute
    /// it in its own coordinate space; it is handed the measured rect, so the
    /// brackets and the crop cannot disagree no matter what the layout does.
    static func rect(inSafeArea size: CGSize) -> CGRect {
        let width = size.width
        let height = min(width * 4 / 3, size.height)
        // Never let the frame hang off the bottom on a short screen; it gives up
        // the gap under the bar before it gives up being fully visible.
        let y = min(max(0, dropBelowSafeAreaTop), size.height - height)
        return CGRect(x: 0, y: y, width: width, height: height)
    }

    /// The capture frame as a fraction of the *photo* rather than the screen.
    ///
    /// Pure geometry, and deliberately so. The preview aspect-fills a 3:4 photo
    /// into `viewSize`, which fixes exactly where the photo's (overflowing)
    /// rendered rect sits; the frame's place inside it is then just division.
    ///
    /// This used to go through `metadataOutputRectConverted`, which needs a live
    /// preview connection and returns nothing before one exists. The crop then
    /// stayed at its `.full` default — silently saving the whole sensor instead
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
/// completely untouched — never dim, tint, or otherwise darken it: the feed is
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

                CaptureFrameBrackets()
                    .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
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
/// Kept deliberately faint and short — enough to read the crop when looked for,
/// not enough to compete with the subject.
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

private struct PoseThumbnail: View {
    let overlay: OverlayRecord
    let selected: Bool
    let flipped: Bool
    let action: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        thumbnail
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel(selected ? "Selected pose" : "Pose")
            .accessibilityHint("Tap to select, flip, then remove")
    }

    @ViewBuilder
    private var thumbnail: some View {
        let button = Button(action: action) {
            LocalFileImage(
                url: ImageStore.shared.overlayURL(overlay),
                contentMode: .fit,
                maxPixel: 220
            )
            .scaleEffect(x: flipped ? -1 : 1, y: 1)
            .frame(width: 54, height: 72)
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

        // Sample poses can't be deleted, so they get no context menu at all.
        if overlay.isBuiltIn {
            button
        } else {
            button
                .contextMenu {
                    Button("Delete pose", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
                .confirmationDialog("Delete this pose from POSER?", isPresented: $confirmsDelete) {
                    Button("Delete pose", role: .destructive, action: onDelete)
                    Button("Cancel", role: .cancel) { }
                }
        }
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
