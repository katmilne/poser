import AVFoundation
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
    @State private var ghostOffset: CGSize = .zero
    @State private var ghostScale: CGFloat = 1
    @State private var normalizedCaptureCrop = NormalizedCrop.full
    @State private var errorMessage: String?

    private var favoriteOverlays: [OverlayRecord] {
        overlays.filter(\.isFavorite)
    }

    var body: some View {
        GeometryReader { proxy in
            let previewWidth = proxy.size.width
                + proxy.safeAreaInsets.leading
                + proxy.safeAreaInsets.trailing
            let previewHeight = proxy.size.height
                + proxy.safeAreaInsets.top
                + proxy.safeAreaInsets.bottom
            let previewCenter = CGPoint(
                x: previewWidth / 2,
                y: previewHeight / 2
            )
            let guideTop = max(68, proxy.safeAreaInsets.top + 9)
            let guideBottom = proxy.size.height - 220
            let availableGuideHeight = max(240, guideBottom - guideTop)
            let guideWidth = min(
                max(0, proxy.size.width - 56),
                availableGuideHeight * Theme.viewportAspect
            )
            let guideHeight = guideWidth / Theme.viewportAspect
            let guideRect = CGRect(
                x: (proxy.size.width - guideWidth) / 2,
                y: guideTop,
                width: guideWidth,
                height: guideHeight
            )
            let normalizedGuideRect = CGRect(
                x: (guideRect.minX + proxy.safeAreaInsets.leading) / max(1, previewWidth),
                y: (guideRect.minY + proxy.safeAreaInsets.top) / max(1, previewHeight),
                width: guideRect.width / max(1, previewWidth),
                height: guideRect.height / max(1, previewHeight)
            )

            ZStack {
                Theme.Colors.black.ignoresSafeArea()
                CameraViewport(
                    camera: camera,
                    normalizedGuideRect: normalizedGuideRect,
                    normalizedPhotoCrop: $normalizedCaptureCrop
                )
                .frame(width: previewWidth, height: previewHeight)
                .position(previewCenter)
                .clipped()
                .ignoresSafeArea()

                if camera.authorizationStatus == .authorized {
                    if let ghost = appState.selectedGhost {
                        GhostCaptureOverlay(
                            ghost: ghost,
                            flipped: appState.ghostFlipped,
                            opacity: ghostHidden ? 0 : appState.ghostOpacity,
                            offset: $ghostOffset,
                            scale: $ghostScale
                        )
                        .frame(width: guideWidth, height: guideHeight)
                        .position(x: guideRect.midX, y: guideRect.midY)
                    }

                    CaptureAreaGuide()
                        .frame(width: guideWidth, height: guideHeight)
                        .position(x: guideRect.midX, y: guideRect.midY)
                }

                VStack(spacing: 0) {
                    cameraTopBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
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
        }
        .task { await camera.requestAccessAndStart() }
        .onChange(of: appState.selectedGhost?.id, initial: true) {
            ghostOffset = .zero
            ghostScale = 1
        }
        .onDisappear { camera.stop() }
        .alert("Camera hiccup", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var cameraTopBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                GlassSurface(cornerRadius: Theme.Radius.pill) {
                    Text("POSER")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(Theme.Colors.ink)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                }
                Spacer()
                GlassIconButton(
                    symbol: camera.flash.symbol,
                    accessibilityLabel: "Flash \(camera.flash.rawValue)",
                    selected: camera.flash != .off
                ) {
                    camera.flash = camera.flash.next
                }
                ZStack(alignment: .bottomTrailing) {
                    GlassIconButton(symbol: "timer", accessibilityLabel: "Timer \(timerSeconds) seconds", selected: timerSeconds > 0) {
                        timerSeconds = timerSeconds == 0 ? 3 : timerSeconds == 3 ? 10 : 0
                    }
                    if timerSeconds > 0 {
                        Text("\(timerSeconds)")
                            .font(.system(size: 9, weight: .black, design: .monospaced))
                            .foregroundStyle(Theme.Colors.ink)
                            .padding(4)
                    }
                }
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

    private var referenceStrip: some View {
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
                                        if appState.selectedGhost?.id == overlay.id { appState.selectedGhost = nil }
                                        modelContext.delete(overlay)
                                        Task { await ImageStore.shared.deleteOverlay(overlay) }
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                GhostOpacityBar(opacity: Bindable(appState).ghostOpacity)
                    .disabled(appState.selectedGhost == nil)
                    .opacity(appState.selectedGhost == nil ? 0.4 : 1)
            }
            .padding(10)
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
            modelContext.insert(record)
            try modelContext.save()
            appState.presentedShot = record

            let url = ImageStore.shared.shotOriginalURL(record)
            Task {
                do { try await PhotoLibraryService.saveImage(at: url) }
                catch { errorMessage = error.localizedDescription }
            }
        } catch {
            errorMessage = "Capturing or saving the clean photo failed. \(error.localizedDescription)"
        }
    }
}

private struct CaptureAreaGuide: View {
    var body: some View {
        ZStack {
            CaptureCornerBubble(rotation: .zero)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CaptureCornerBubble(rotation: .degrees(90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            CaptureCornerBubble(rotation: .degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            CaptureCornerBubble(rotation: .degrees(270))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CaptureCornerBubble: View {
    let rotation: Angle

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                cornerBody
                    .glassEffect(
                        .clear.tint(.white.opacity(0.08)),
                        in: CaptureCornerShape()
                    )
            } else {
                cornerBody
                    .background(.ultraThinMaterial, in: CaptureCornerShape())
            }
        }
        .rotationEffect(rotation)
    }

    private var cornerBody: some View {
        CaptureCornerShape()
            .fill(.white.opacity(0.05))
            .overlay {
                CaptureCornerShape()
                    .stroke(.white.opacity(0.70), lineWidth: 0.45)
            }
            .overlay {
                CaptureCornerLine()
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.76), .white.opacity(0.22)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 0.65, lineCap: .round, lineJoin: .round)
                    )
                    .padding(1.75)
            }
            .frame(width: 26, height: 26)
            .shadow(color: .white.opacity(0.12), radius: 1.5)
            .shadow(color: .black.opacity(0.13), radius: 3, y: 1)
    }
}

private struct CaptureCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        CaptureCornerLine()
            .path(in: rect.insetBy(dx: 1.75, dy: 1.75))
            .strokedPath(
                StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)
            )
    }
}

private struct CaptureCornerLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

private struct CameraViewport: View {
    let camera: CameraController
    let normalizedGuideRect: CGRect
    @Binding var normalizedPhotoCrop: NormalizedCrop

    var body: some View {
        CameraPreview(
            session: camera.session,
            normalizedGuideRect: normalizedGuideRect,
            normalizedPhotoCrop: $normalizedPhotoCrop
        )
    }
}

private struct GhostCaptureOverlay: View {
    let ghost: OverlayRecord
    let flipped: Bool
    let opacity: Double
    @Binding var offset: CGSize
    @Binding var scale: CGFloat

    @State private var dragStart: CGSize = .zero
    @State private var scaleStart: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            LocalFileImage(url: ImageStore.shared.overlayURL(ghost), maxPixel: 1800)
                .id(ghost.cropData)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(x: flipped ? -scale : scale, y: scale)
                .offset(offset)
                .opacity(opacity)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(.rect)
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            let maxX = proxy.size.width * 0.6
                            let maxY = proxy.size.height * 0.6
                            offset = CGSize(
                                width: min(maxX, max(-maxX, dragStart.width + value.translation.width)),
                                height: min(maxY, max(-maxY, dragStart.height + value.translation.height))
                            )
                        }
                        .onEnded { _ in dragStart = offset }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in scale = min(2.5, max(0.4, scaleStart * value.magnification)) }
                        .onEnded { _ in scaleStart = scale }
                )
                .onTapGesture(count: 2) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.poserSettle) { resetGhostTransform() }
                }
                .onChange(of: ghost.id) {
                    withAnimation(.poserSettle) { resetGhostTransform() }
                }
        }
    }

    private func resetGhostTransform() {
        offset = .zero
        scale = 1
        dragStart = .zero
        scaleStart = 1
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
        Button(action: action) {
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
        .buttonStyle(PressScaleButtonStyle())
        .contextMenu {
            Button("Delete pose", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete this pose from POSER?", isPresented: $confirmsDelete) {
            Button("Delete pose", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        }
        .accessibilityLabel(selected ? "Selected pose" : "Pose")
        .accessibilityHint("Tap to select, flip, then remove")
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
