import PhotosUI
import SwiftData
import SwiftUI
import UIKit

/// Shows through the transparent parts of a cutout so the user can judge the
/// mask edges rather than a flat square.
private struct CheckerboardBackground: View {
    var square: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Colors.cloud))
            let columns = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<rows {
                for column in 0..<columns where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(Theme.Colors.mist))
                }
            }
        }
    }
}

struct StickerMakerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let onCreated: (CustomStickerRecord) -> Void

    @State private var camera = CameraController()
    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceData: Data?
    @State private var previewImage: UIImage?
    @State private var cutoutDraft: CutoutDraft?
    @State private var cutoutImage: UIImage?
    @State private var isCutting = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var previewBoxSize: CGSize = .zero
    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var zoomGestureStart: CGFloat = 1
    @State private var panGestureStart: CGSize = .zero

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 16) {
                HStack {
                    Text("CUTOUT CAMERA")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    Spacer()
                    GlassIconButton(symbol: "xmark", accessibilityLabel: "Close sticker maker") { dismiss() }
                }
                .padding(.horizontal, 18)

                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(Theme.Colors.mist)
                    if let cutoutImage {
                        CheckerboardBackground()
                        Image(uiImage: cutoutImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(20)
                    } else if let previewImage {
                        GeometryReader { proxy in
                            Image(uiImage: previewImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .scaleEffect(zoomScale)
                                .offset(panOffset)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                                .contentShape(.rect)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let bounds = panBounds(boxSize: proxy.size, imageSize: previewImage.size)
                                            panOffset = CGSize(
                                                width: min(bounds.width, max(-bounds.width, panGestureStart.width + value.translation.width)),
                                                height: min(bounds.height, max(-bounds.height, panGestureStart.height + value.translation.height))
                                            )
                                        }
                                        .onEnded { _ in panGestureStart = panOffset }
                                )
                                .simultaneousGesture(
                                    MagnifyGesture()
                                        .onChanged { value in
                                            zoomScale = min(4, max(1, zoomGestureStart * value.magnification))
                                            let bounds = panBounds(boxSize: proxy.size, imageSize: previewImage.size)
                                            panOffset = CGSize(
                                                width: min(bounds.width, max(-bounds.width, panOffset.width)),
                                                height: min(bounds.height, max(-bounds.height, panOffset.height))
                                            )
                                        }
                                        .onEnded { _ in
                                            zoomGestureStart = zoomScale
                                            panGestureStart = panOffset
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.poserSettle) { resetImageTransform() }
                                }
                                .onAppear { previewBoxSize = proxy.size }
                                .onChange(of: proxy.size) { _, newValue in previewBoxSize = newValue }
                        }
                    } else if camera.authorizationStatus == .authorized,
                              camera.configurationErrorMessage == nil {
                        CameraPreview(session: camera.session, isReady: camera.isReady)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.rectangle")
                                .font(.system(size: 52, weight: .light))
                            Text("Pick a clear photo of your subject.")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Theme.Colors.textDim)
                    }
                }
                .aspectRatio(Theme.viewportAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .padding(.horizontal, 30)

                if cutoutDraft != nil {
                    Text("KEEP THIS STICKER?")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Theme.Colors.textDim)
                } else if previewImage != nil {
                    Text("DRAG TO POSITION · PINCH TO ZOOM")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Theme.Colors.textDim)
                }

                if cutoutDraft != nil {
                    HStack(spacing: 12) {
                        GlassTextButton(title: "BACK", disabled: isSaving) {
                            withAnimation(.poserGlide) { discardCutout() }
                        }
                        GlassTextButton(title: "ACCEPT", disabled: isSaving) {
                            Task { await acceptCutout() }
                        }
                    }
                    .padding(.horizontal, 18)
                } else {
                    HStack(spacing: 12) {
                        GlassTextButton(
                            title: sourceData == nil ? "TAKE PHOTO" : "RETAKE",
                            disabled: sourceData == nil && !camera.isReady
                        ) {
                            if sourceData == nil {
                                Task { await takePhoto() }
                            } else {
                                sourceData = nil
                                previewImage = nil
                                pickerItem = nil
                                resetImageTransform()
                            }
                        }

                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            GlassSurface(cornerRadius: Theme.Radius.pill, interactive: true) {
                                Text(sourceData == nil ? "FROM PHOTOS" : "PICK ANOTHER")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.Colors.ink)
                                    .padding(.horizontal, 18)
                                    .frame(height: 48)
                            }
                        }
                    }
                    .padding(.horizontal, 18)

                    GlassTextButton(title: "CUT IT OUT", disabled: sourceData == nil || isCutting) {
                        Task { await cutOut() }
                    }
                }
                Spacer()
            }
            .padding(.top, 10)

            if isCutting || isSaving {
                Color.black.opacity(0.28).ignoresSafeArea()
                GlassSurface(cornerRadius: Theme.Radius.lg) {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(isCutting ? "LIFTING THE SUBJECT…" : "SAVING STICKER…")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                    }
                    .padding(24)
                }
            }
        }
        .onChange(of: pickerItem) {
            Task {
                sourceData = try? await pickerItem?.loadTransferable(type: Data.self)
                if let sourceData { previewImage = UIImage(data: sourceData) }
                resetImageTransform()
            }
        }
        .task { await camera.requestAccessAndStart() }
        .onDisappear { camera.stop() }
        .alert("Cutout camera", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func takePhoto() async {
        do {
            let data = try await camera.capturePhoto()
            sourceData = data
            previewImage = UIImage(data: data)
            resetImageTransform()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            errorMessage = error.localizedDescription
            Analytics.captureError(error, area: "sticker_camera")
        }
    }

    private func resetImageTransform() {
        zoomScale = 1
        panOffset = .zero
        zoomGestureStart = 1
        panGestureStart = .zero
    }

    private func panBounds(boxSize: CGSize, imageSize: CGSize) -> CGSize {
        guard boxSize.width > 0, boxSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let fillScale = max(boxSize.width / imageSize.width, boxSize.height / imageSize.height) * zoomScale
        let displayed = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        return CGSize(
            width: max(0, (displayed.width - boxSize.width) / 2),
            height: max(0, (displayed.height - boxSize.height) / 2)
        )
    }

    /// Bakes the on-screen pan/zoom into the source pixels before cutout, since
    /// Vision segments whatever crop is handed to it.
    private func croppedSourceData() -> Data? {
        guard let sourceData, let previewImage else { return sourceData }
        guard zoomScale > 1.001 || panOffset != .zero else { return sourceData }
        let imageSize = previewImage.size
        let boxSize = previewBoxSize
        guard imageSize.width > 0, imageSize.height > 0, boxSize.width > 0, boxSize.height > 0 else { return sourceData }

        let fillScale = max(boxSize.width / imageSize.width, boxSize.height / imageSize.height) * zoomScale
        let displayedSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        let displayedOrigin = CGPoint(
            x: (boxSize.width - displayedSize.width) / 2 + panOffset.width,
            y: (boxSize.height - displayedSize.height) / 2 + panOffset.height
        )
        let cropRect = CGRect(
            x: -displayedOrigin.x / fillScale,
            y: -displayedOrigin.y / fillScale,
            width: boxSize.width / fillScale,
            height: boxSize.height / fillScale
        ).intersection(CGRect(origin: .zero, size: imageSize))
        guard !cropRect.isEmpty else { return sourceData }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: cropRect.size, format: format)
        let cropped = renderer.image { _ in
            previewImage.draw(at: CGPoint(x: -cropRect.origin.x, y: -cropRect.origin.y))
        }
        return cropped.jpegData(compressionQuality: 0.95) ?? sourceData
    }

    @MainActor
    private func cutOut() async {
        guard let sourceData else { return }
        let dataToCut = croppedSourceData() ?? sourceData
        isCutting = true
        defer { isCutting = false }
        do {
            let draft = try await SubjectCutoutService.shared.makeCutout(from: dataToCut)
            guard let image = UIImage(data: draft.pngData) else {
                errorMessage = SubjectCutoutService.CutoutError.invalidImage.localizedDescription
                return
            }
            withAnimation(.poserGlide) {
                cutoutDraft = draft
                cutoutImage = image
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            errorMessage = error.localizedDescription
            // Expected "no subject found" outcomes are filtered out centrally
            // in Analytics.configure()'s beforeSend — only genuine failures
            // (unreadable image, write failure) become a Sentry issue.
            Analytics.captureError(error, area: "cutout")
        }
    }

    private func discardCutout() {
        cutoutDraft = nil
        cutoutImage = nil
    }

    @MainActor
    private func acceptCutout() async {
        guard let cutoutDraft else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let stored = try await SubjectCutoutService.shared.persist(cutoutDraft)
            let record = CustomStickerRecord(
                id: stored.id,
                fileName: stored.fileName,
                width: stored.width,
                height: stored.height
            )
            modelContext.insert(record)
            try modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Analytics.track("sticker_created")
            onCreated(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            Analytics.captureError(error, area: "sticker_persist")
        }
    }
}
