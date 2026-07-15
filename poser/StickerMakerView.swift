import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct StickerMakerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let onCreated: (CustomStickerRecord) -> Void

    @State private var camera = CameraController()
    @State private var pickerItem: PhotosPickerItem?
    @State private var sourceData: Data?
    @State private var previewImage: UIImage?
    @State private var isCutting = false
    @State private var errorMessage: String?

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
                    if let previewImage {
                        Image(uiImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else if camera.authorizationStatus == .authorized,
                              camera.configurationErrorMessage == nil {
                        CameraPreview(session: camera.session)
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
                Spacer()
            }
            .padding(.top, 10)

            if isCutting {
                Color.black.opacity(0.28).ignoresSafeArea()
                GlassSurface(cornerRadius: Theme.Radius.lg) {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("LIFTING THE SUBJECT…")
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
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func cutOut() async {
        guard let sourceData else { return }
        isCutting = true
        defer { isCutting = false }
        do {
            let stored = try await SubjectCutoutService.shared.createSticker(from: sourceData)
            let record = CustomStickerRecord(
                id: stored.id,
                fileName: stored.fileName,
                width: stored.width,
                height: stored.height
            )
            modelContext.insert(record)
            try modelContext.save()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCreated(record)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
