import SwiftData
import SwiftUI
import UIKit

struct GalleryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ShotRecord.takenAt, order: .reverse) private var shots: [ShotRecord]
    @Namespace private var albumNamespace
    @State private var page = 0
    @State private var lightboxShot: ShotRecord?
    @State private var openedShotID: String?
    @State private var saveMessage: String?
    @State private var confirmsDelete: ShotRecord?

    private var pages: [[ShotRecord]] {
        stride(from: 0, to: shots.count, by: 4).map { start in
            Array(shots[start..<min(start + 4, shots.count)])
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                albumBackground
                    .frame(width: proxy.size.width, height: proxy.size.height)
                VStack(spacing: 14) {
                    header
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    if pages.isEmpty {
                        emptyAlbum
                    } else {
                        TabView(selection: $page) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageShots in
                                AlbumPage(
                                    shots: pageShots,
                                    namespace: albumNamespace,
                                    activeLightboxID: lightboxShot?.id,
                                    animateIn: page == pageIndex
                                ) { shot in
                                    openedShotID = shot.id
                                    withAnimation(.poserGlide) { lightboxShot = shot }
                                } onDelete: { shot in
                                    confirmsDelete = shot
                                }
                                .padding(.horizontal, 20)
                                .tag(pageIndex)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .sensoryFeedback(.impact(weight: .heavy), trigger: page)
                    }

                    Text(String(format: "%02d / %02d", min(page + 1, max(1, pages.count)), max(1, pages.count)))
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(Theme.Colors.denim)
                        .padding(.bottom, 14)
                }

                if let shot = lightboxShot {
                    AlbumLightbox(
                        shots: shots,
                        shot: shot,
                        namespace: albumNamespace,
                        returnsToPocket: openedShotID == shot.id,
                        onChange: { lightboxShot = $0 },
                        onClose: { closeLightbox() },
                        onEdit: {
                            lightboxShot = nil
                            appState.showsGallery = false
                            appState.editingShot = shot
                        },
                        onSave: { Task { await save(shot) } },
                        onDelete: { confirmsDelete = shot },
                        onUseGhost: { useGhost(from: shot) }
                    )
                    .zIndex(10)
                }
            }
            .confirmationDialog("Delete this photo from POSER?", isPresented: Binding(
                get: { confirmsDelete != nil },
                set: { if !$0 { confirmsDelete = nil } }
            )) {
                Button("Delete from POSER", role: .destructive) {
                    if let shot = confirmsDelete { delete(shot) }
                }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Album", isPresented: Binding(
                get: { saveMessage != nil },
                set: { if !$0 { saveMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveMessage ?? "")
            }
        }
    }

    private var albumBackground: some View {
        Image(.cloudBackground)
            .resizable()
            .scaledToFill()
            .ignoresSafeArea()
            .overlay(Theme.Colors.bg.opacity(0.16))
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack {
            GlassSurface(cornerRadius: Theme.Radius.pill, tint: Theme.Colors.electricBlue.opacity(0.18)) {
                HStack(spacing: 9) {
                    Text("ALBUM")
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(1.5)
                    Text("\(shots.count)")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Theme.Colors.denim.opacity(0.16), in: Capsule())
                }
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, 17)
                .frame(height: 46)
            }
            Spacer()
            GlassIconButton(symbol: "xmark", accessibilityLabel: "Close album", selected: true) {
                appState.showsGallery = false
            }
        }
    }

    private var emptyAlbum: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54, weight: .light))
            Text("YOUR ALBUM IS WAITING")
                .font(.system(size: 16, weight: .black, design: .rounded))
            Text("Take a photo and it will slip into a sleeve here.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.textDim)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(40)
    }

    private func closeLightbox() {
        withAnimation(.poserGlide) { lightboxShot = nil }
    }

    private func delete(_ shot: ShotRecord) {
        if lightboxShot?.id == shot.id { lightboxShot = nil }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        modelContext.delete(shot)
        try? modelContext.save()
        Task { await ImageStore.shared.deleteShot(shot) }
        confirmsDelete = nil
        page = min(page, max(0, pages.count - 1))
    }

    private func save(_ shot: ShotRecord) async {
        let url = shot.decoratedFileName == nil
            ? ImageStore.shared.shotOriginalURL(shot)
            : ImageStore.shared.shotDisplayURL(shot)
        do {
            try await PhotoLibraryService.saveImage(at: url)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            saveMessage = "Saved to Camera Roll."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            saveMessage = error.localizedDescription
        }
    }

    private func useGhost(from shot: ShotRecord) {
        guard let ghost = shot.ghost else { return }
        let descriptor = FetchDescriptor<OverlayRecord>(predicate: #Predicate { $0.id == ghost.overlayId })
        if let overlay = try? modelContext.fetch(descriptor).first {
            appState.selectGhost(overlay)
            lightboxShot = nil
            appState.showsGallery = false
            return
        }

        Task { @MainActor in
            do {
                let restored = try await ImageStore.shared.restoreOverlay(from: ghost)
                let overlay = OverlayRecord(
                    id: restored.id,
                    fileName: restored.fileName,
                    addedAt: restored.addedAt,
                    width: restored.width,
                    height: restored.height,
                    sourceFileName: restored.sourceFileName,
                    sourceWidth: restored.sourceWidth,
                    sourceHeight: restored.sourceHeight,
                    crop: restored.crop,
                    canvasAspect: restored.canvasAspect,
                    lastUsedAt: .now
                )
                modelContext.insert(overlay)
                try modelContext.save()
                appState.selectGhost(overlay)
                lightboxShot = nil
                appState.showsGallery = false
            } catch {
                saveMessage = error.localizedDescription
            }
        }
    }
}

private struct AlbumPage: View {
    let shots: [ShotRecord]
    let namespace: Namespace.ID
    let activeLightboxID: String?
    let animateIn: Bool
    let onOpen: (ShotRecord) -> Void
    let onDelete: (ShotRecord) -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Theme.Colors.cream.opacity(0.94))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.88), lineWidth: 1)
                }
                .shadow(color: Theme.stickerShadow, radius: 24, y: 8)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                    PhotoPocket(
                        shot: shot,
                        namespace: namespace,
                        hiddenForLightbox: activeLightboxID == shot.id,
                        onOpen: { onOpen(shot) },
                        onDelete: { onDelete(shot) }
                    )
                    .transition(.scale(scale: 0.82).combined(with: .offset(y: 24)))
                    .animation(
                        .spring(response: 0.40, dampingFraction: 0.72).delay(Double(index) * 0.055),
                        value: animateIn
                    )
                }
                ForEach(shots.count..<4, id: \.self) { _ in
                    EmptyPocket()
                }
            }
            .padding(18)
        }
        .aspectRatio(0.75, contentMode: .fit)
        .frame(maxWidth: 640)
    }
}

private struct PhotoPocket: View {
    let shot: ShotRecord
    let namespace: Namespace.ID
    let hiddenForLightbox: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var pullY: CGFloat = 0
    @State private var crossedThreshold = false
    @State private var confirmsDelete = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.Colors.linen)
            LocalFileImage(url: ImageStore.shared.shotDisplayURL(shot), maxPixel: 800)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .matchedGeometryEffect(id: shot.id, in: namespace, isSource: !hiddenForLightbox)
                .offset(y: pullY)
                .opacity(hiddenForLightbox ? 0 : 1)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            pullY = min(0, value.translation.height)
                            let crossed = pullY < -90
                            if crossed != crossedThreshold {
                                UISelectionFeedbackGenerator().selectionChanged()
                                crossedThreshold = crossed
                            }
                        }
                        .onEnded { value in
                            let isTap = abs(value.translation.width) < 10 && abs(value.translation.height) < 10
                            if isTap || pullY < -90 || value.predictedEndTranslation.height < -140 {
                                withAnimation(.poserGlide) { pullY = 0 }
                                onOpen()
                            } else {
                                withAnimation(.poserGlide) { pullY = 0 }
                                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                            }
                            crossedThreshold = false
                        }
                )
        }
        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.88), lineWidth: 1)
        }
        .contentShape(.rect)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete this photo from POSER?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct EmptyPocket: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Theme.Colors.linen.opacity(0.82))
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.Colors.outline)
            }
            .aspectRatio(Theme.viewportAspect, contentMode: .fit)
    }
}

private struct AlbumLightbox: View {
    let shots: [ShotRecord]
    let shot: ShotRecord
    let namespace: Namespace.ID
    let returnsToPocket: Bool
    let onChange: (ShotRecord) -> Void
    let onClose: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    let onUseGhost: () -> Void
    @State private var dismissOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.88 - min(0.5, abs(dismissOffset) / 900)).ignoresSafeArea()
            TabView(selection: Binding(
                get: { shot.id },
                set: { id in if let next = shots.first(where: { $0.id == id }) { onChange(next) } }
            )) {
                ForEach(shots) { item in
                    LocalFileImage(url: ImageStore.shared.shotDisplayURL(item), maxPixel: 1800)
                        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
                        .matchedGeometryEffect(id: item.id, in: namespace, isSource: item.id == shot.id)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in if value.translation.height > 0 { dismissOffset = value.translation.height } }
                    .onEnded { value in
                        if dismissOffset > 150 || value.predictedEndTranslation.height > 420 {
                            withAnimation(.easeOut(duration: 0.24)) { dismissOffset = 640 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: onClose)
                        } else {
                            withAnimation(.poserSettle) { dismissOffset = 0 }
                        }
                    }
            )

            VStack {
                HStack {
                    Spacer()
                    if shot.ghost != nil {
                        GlassTextButton(title: "USE GHOST", compact: true, action: onUseGhost)
                    }
                }
                .padding(.horizontal, 18)
                Spacer()
                GlassSurface(cornerRadius: Theme.Radius.lg, tint: Theme.Colors.black.opacity(0.14)) {
                    HStack(spacing: 14) {
                        GlassIconButton(symbol: "xmark", accessibilityLabel: "Close photo", selected: returnsToPocket, action: onClose)
                        GlassIconButton(symbol: "wand.and.sparkles", accessibilityLabel: "Edit photo", action: onEdit)
                        GlassIconButton(symbol: "square.and.arrow.down", accessibilityLabel: "Save to Camera Roll", action: onSave)
                        Text("\((shots.firstIndex { $0.id == shot.id } ?? 0) + 1) / \(shots.count)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)
                        GlassIconButton(symbol: "trash", accessibilityLabel: "Delete photo", action: onDelete)
                    }
                    .padding(8)
                }
                .padding(.bottom, 14)
            }
        }
        .transition(.opacity)
    }
}
