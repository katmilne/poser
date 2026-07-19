import SwiftData
import SwiftUI
import UIKit

/// The first thing shown after the shutter: the full frame the user just
/// captured, before any decorating. The shot is already in the album as a
/// draft, so Done simply keeps it and X throws it away again. Edit opens the
/// decorating surface on top, which saves back onto this same shot.
struct CaptureReviewView: View {
    @AppStorage(ExportPreferences.includesPolaroidFrameKey) private var includesPolaroidFrame = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let shot: ShotRecord
    @State private var editingShot: ShotRecord?
    @State private var sharePayload: SharePayload?
    @State private var alertMessage: String?
    @State private var isExporting = false

    var body: some View {
        ZStack {
            SkyBackground(quiet: true)
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                LocalFileImage(
                    url: ImageStore.shared.shotDisplayURL(shot),
                    contentMode: .fit,
                    maxPixel: 2200
                )
                .aspectRatio(Theme.viewportAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.Colors.glassEdge, lineWidth: 1)
                }
                .shadow(color: Theme.charmShadow, radius: 18, y: 6)
                .padding(.horizontal, 20)
                Spacer(minLength: 0)
                actionBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            if isExporting {
                Color.black.opacity(0.24).ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.Colors.ink)
            }
        }
        .fullScreenCover(item: $editingShot) { shot in
            // Already-kept semantics: the review owns discard/keep, so the editor
            // is a pure decorating surface that saves back and returns here.
            PreviewEditorView(shot: shot, isDraft: false)
        }
        .shareSheet(payload: $sharePayload)
        .alert("POSER", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var actionBar: some View {
        GlassGroup(spacing: 18) {
            HStack(spacing: 18) {
                GlassIconButton(symbol: "xmark", accessibilityLabel: "Delete photo", action: discard)
                Spacer()
                GlassIconButton(symbol: "wand.and.sparkles", accessibilityLabel: "Edit photo") {
                    editingShot = shot
                }
                GlassIconButton(symbol: "square.and.arrow.up", accessibilityLabel: "Share photo") {
                    Task { await share() }
                }
                GlassIconButton(symbol: "square.and.arrow.down", accessibilityLabel: "Save to Camera Roll") {
                    Task { await saveToCameraRoll() }
                }
                GlassTextButton(title: "DONE", selected: true, action: keep)
            }
        }
    }

    /// The record is already in the context, so keeping it is just letting the
    /// review dismiss — nothing else has to reach disk for an undecorated shot.
    private func keep() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    private func discard() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        modelContext.delete(shot)
        try? modelContext.save()
        Task { await ImageStore.shared.deleteShot(shot) }
        dismiss()
    }

    @MainActor
    private func share() async {
        isExporting = true
        defer { isExporting = false }
        do {
            sharePayload = SharePayload(url: try await exportURL())
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveToCameraRoll() async {
        isExporting = true
        defer { isExporting = false }
        do {
            try await PhotoLibraryService.saveImage(at: try await exportURL())
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            alertMessage = "Saved to Camera Roll."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertMessage = error.localizedDescription
        }
    }

    /// A fresh capture is undecorated, so its clean original is the full-quality
    /// export base — the polaroid frame is only wrapped on when the user asked
    /// for it in settings.
    private func exportURL() async throws -> URL {
        let sourceURL = ImageStore.shared.shotOriginalURL(shot)
        guard includesPolaroidFrame else { return sourceURL }
        return try await ImageStore.shared.polaroidExportURL(for: sourceURL)
    }
}
