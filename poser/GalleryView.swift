import SwiftData
import SwiftUI
import UIKit

private struct PocketFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct GalleryView: View {
    @AppStorage(ExportPreferences.includesPolaroidFrameKey) private var includesPolaroidFrame = false
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ShotRecord.takenAt, order: .reverse) private var shots: [ShotRecord]
    @State private var page = 0
    @State private var lightboxShot: ShotRecord?
    @State private var pocketFrames: [String: CGRect] = [:]
    @State private var progress: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var saveMessage: String?
    @State private var confirmsDelete: ShotRecord?
    @State private var sharePayload: SharePayload?
    @State private var editingShot: ShotRecord?

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
                                    activeLightboxID: lightboxShot?.id,
                                    animateIn: page == pageIndex,
                                    onOpen: { open($0, from: $1) },
                                    onDelete: { confirmsDelete = $0 }
                                )
                                .padding(.horizontal, 20)
                                .tag(pageIndex)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .sensoryFeedback(.impact(weight: .heavy), trigger: page)
                    }

                    HStack(spacing: 12) {
                        GlassIconButton(
                            symbol: "chevron.left",
                            accessibilityLabel: "Previous page",
                            size: 34,
                            disabled: page <= 0
                        ) { turnPage(by: -1) }

                        Text(String(format: "%02d / %02d", min(page + 1, max(1, pages.count)), max(1, pages.count)))
                            .font(.system(size: 12, weight: .black, design: .monospaced))
                            .tracking(1.8)
                            .foregroundStyle(Theme.Colors.denim)
                            // Fixed width so the buttons hold still as the digits change.
                            .frame(minWidth: 68)

                        GlassIconButton(
                            symbol: "chevron.right",
                            accessibilityLabel: "Next page",
                            size: 34,
                            disabled: page >= pages.count - 1
                        ) { turnPage(by: 1) }
                    }
                    .padding(.bottom, 14)
                }

                if let shot = lightboxShot {
                    LightboxLayer(
                        shot: shot,
                        seated: pocketFrames[shot.id],
                        screen: proxy.size,
                        progress: $progress,
                        dragOffset: $dragOffset,
                        onClosed: { lightboxShot = nil },
                        // The lightbox stays standing behind the editor, so closing the
                        // editor drops straight back onto the photo it just decorated.
                        onEdit: { editingShot = shot },
                        onShare: { Task { await share(shot) } },
                        onSave: { Task { await save(shot) } },
                        onDelete: { confirmsDelete = shot },
                        onUseGhost: { useGhost(from: shot) }
                    )
                    .zIndex(10)
                }
            }
            .coordinateSpace(name: "gallery")
            .onPreferenceChange(PocketFrameKey.self) { pocketFrames = $0 }
            .confirmationDialog("Delete this photo from POSER?", isPresented: Binding(
                get: { confirmsDelete != nil },
                set: { if !$0 { confirmsDelete = nil } }
            )) {
                Button("Delete from POSER", role: .destructive) {
                    if let shot = confirmsDelete { delete(shot) }
                }
                Button("Cancel", role: .cancel) { }
            }
            .fullScreenCover(item: $editingShot) { shot in
                PreviewEditorView(shot: shot, isDraft: false)
            }
            .shareSheet(payload: $sharePayload)
            .alert("Album", isPresented: Binding(
                get: { saveMessage != nil },
                set: { if !$0 { saveMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(saveMessage ?? "")
            }
            .task { seedTempTestShotsIfNeeded() }
        }
    }

    private func seedTempTestShotsIfNeeded() {
        guard shots.isEmpty else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let shotsDir = docs.appending(path: "shots")
        let displayDir = shotsDir.appending(path: "display")
        try? FileManager.default.createDirectory(at: displayDir, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple]
        for color in colors {
            let id = UUID().uuidString.lowercased()
            let fileName = "\(id).jpg"
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
            let image = renderer.image { ctx in
                color.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            }
            if let data = image.jpegData(compressionQuality: 0.9) {
                try? data.write(to: shotsDir.appending(path: fileName))
                try? data.write(to: displayDir.appending(path: fileName))
            }
            let record = ShotRecord(id: id, fileName: fileName, facing: .back, width: 600, height: 800)
            modelContext.insert(record)
        }
        try? modelContext.save()
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

    // The TabView's own .sensoryFeedback on `page` covers the haptic for both
    // these buttons and the swipe between pages.
    private func turnPage(by delta: Int) {
        let next = page + delta
        guard pages.indices.contains(next) else { return }
        withAnimation(.poserGlide) { page = next }
    }

    private func open(_ shot: ShotRecord, from initialProgress: CGFloat) {
        progress = min(0.5, max(0, initialProgress))
        dragOffset = 0
        lightboxShot = shot
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // Mirror of closeToPocket: first ride up out of the sleeve until the card's
        // bottom edge clears the pocket's top opening, then expand to fullscreen.
        // Phase A resumes from wherever the pull left the card, and is shortened by
        // the distance already covered so the rise keeps a steady speed.
        let rise = 0.26 * Double((0.5 - progress) / 0.5)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: rise)) { progress = 0.5 }
            DispatchQueue.main.asyncAfter(deadline: .now() + rise) {
                withAnimation(.easeInOut(duration: 0.4)) { progress = 1 }
            }
        }
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

    /// An undecorated shot has no developed copy, so its clean source remains
    /// the full-quality export base.
    private func currentURL(for shot: ShotRecord) -> URL {
        shot.decoratedFileName == nil
            ? ImageStore.shared.shotOriginalURL(shot)
            : ImageStore.shared.shotDisplayURL(shot)
    }

    private func exportURL(for shot: ShotRecord) async throws -> URL {
        let sourceURL = currentURL(for: shot)
        guard includesPolaroidFrame else { return sourceURL }
        return try await ImageStore.shared.polaroidExportURL(for: sourceURL)
    }

    private func share(_ shot: ShotRecord) async {
        do {
            sharePayload = SharePayload(url: try await exportURL(for: shot))
        } catch {
            saveMessage = error.localizedDescription
        }
    }

    private func save(_ shot: ShotRecord) async {
        do {
            let url = try await exportURL(for: shot)
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
    let activeLightboxID: String?
    let animateIn: Bool
    let onOpen: (ShotRecord, CGFloat) -> Void
    let onDelete: (ShotRecord) -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    private struct Slot: Identifiable {
        let id: String
        let shot: ShotRecord?
    }

    // Photos read backwards through the grid — bottom-right, bottom-left,
    // top-right, top-left — so the newest of the page sits in the bottom-right
    // pocket, like slotting the latest print into an album from the back. Empty
    // pockets fill the top-left, keeping every page anchored to the lower right.
    private var slots: [Slot] {
        let filled = shots.reversed().map { Slot(id: $0.id, shot: $0) }
        let emptyCount = max(0, 4 - filled.count)
        let empties = (0..<emptyCount).map { Slot(id: "empty-\($0)", shot: nil) }
        return empties + filled
    }

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
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    if let shot = slot.shot {
                        PhotoPocket(
                            shot: shot,
                            hiddenForLightbox: activeLightboxID == shot.id,
                            onOpen: { onOpen(shot, $0) },
                            onDelete: { onDelete(shot) }
                        )
                        .transition(.scale(scale: 0.82).combined(with: .offset(y: 24)))
                        .animation(
                            .spring(response: 0.40, dampingFraction: 0.72).delay(Double(index) * 0.055),
                            value: animateIn
                        )
                    } else {
                        EmptyPocket()
                    }
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
    let hiddenForLightbox: Bool
    // Carries the progress the pull already covered, so the lightbox can pick up
    // the card exactly where the finger left it instead of snapping back to seated.
    let onOpen: (CGFloat) -> Void
    let onDelete: () -> Void
    @State private var pullY: CGFloat = 0
    @State private var crossedThreshold = false
    @State private var confirmsDelete = false

    var body: some View {
        GeometryReader { geo in
            let polaroidW = geo.size.width * 0.82
            ZStack {
                SleeveBackground()
                PolaroidCard(shot: shot, width: polaroidW)
                    .offset(y: pullY)
                    .opacity(hiddenForLightbox ? 0 : 1)
                    .simultaneousGesture(
                        pullGesture(cell: geo.size, cardH: polaroidW / PolaroidStyle.cardAspect)
                    )
                    // A tap runs the same rise-then-expand animation, just from seated.
                    .onTapGesture { onOpen(0) }
                SleeveFront()
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: PocketFrameKey.self,
                        value: [shot.id: g.frame(in: .global)]
                    )
                }
            )
        }
        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
        .contentShape(.rect)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete this photo from POSER?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        }
    }

    private func pullGesture(cell: CGSize, cardH: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                pullY = min(0, value.translation.height)
                let crossed = pullY < -60
                if crossed != crossedThreshold {
                    UISelectionFeedbackGenerator().selectionChanged()
                    crossedThreshold = crossed
                }
            }
            .onEnded { value in
                let openIt = pullY < -60 || value.predictedEndTranslation.height < -110
                crossedThreshold = false
                if openIt {
                    // Phase A of the lightbox runs from the pocket's centre to cardH/2
                    // above its top opening; map how far the pull got along that span.
                    let span = cell.height / 2 + cardH / 2
                    let covered = min(1, max(0, -pullY / span))
                    // No animation: the seated card is hidden the instant the lightbox
                    // takes over, and the lightbox resumes from this exact offset.
                    pullY = 0
                    onOpen(0.5 * covered)
                } else {
                    withAnimation(.poserGlide) { pullY = 0 }
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
            }
    }
}

// The translucent, stitched clear sleeve that the polaroid slips into.
private struct SleeveBackground: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.10))
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .inset(by: 5)
                .stroke(
                    Theme.Colors.denim.opacity(0.34),
                    style: StrokeStyle(lineWidth: 1.3, dash: [4.5, 3.5])
                )
            VStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.6))
                    .frame(height: 3)
                    .padding(.horizontal, 20)
                    .padding(.top, 9)
                Spacer()
            }
        }
    }
}

// A soft plastic sheen drawn over the seated photo.
private struct SleeveFront: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.20), .clear, Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

// A polaroid: white frame, photo inset, thick bottom lip. Used both seated and full-screen.
private struct PolaroidCard: View {
    let shot: ShotRecord
    let width: CGFloat
    var maxPixel: CGFloat = 800

    var body: some View {
        let side = width * PolaroidStyle.sideInsetFraction
        let photoW = width - side * 2
        let photoH = photoW / PolaroidStyle.photoAspect
        let cardH = width / PolaroidStyle.cardAspect
        let radius = max(3, width * PolaroidStyle.outerCornerRadiusFraction)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white)
            LocalFileImage(url: ImageStore.shared.shotDisplayURL(shot), maxPixel: maxPixel)
                .frame(width: photoW, height: photoH)
                .clipShape(RoundedRectangle(cornerRadius: radius * 0.6, style: .continuous))
                .padding(.top, side)
        }
        .frame(width: width, height: cardH)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: Theme.stickerShadow, radius: width * 0.03, y: width * 0.012)
    }
}

private struct EmptyPocket: View {
    var body: some View {
        SleeveBackground()
            .aspectRatio(Theme.viewportAspect, contentMode: .fit)
    }
}

// Full-screen photo layer with a custom "slide out of / back into the pocket" transition.
private struct LightboxLayer: View {
    let shot: ShotRecord
    let seated: CGRect?
    let screen: CGSize
    @Binding var progress: CGFloat
    @Binding var dragOffset: CGFloat
    let onClosed: () -> Void
    let onEdit: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void
    let onUseGhost: () -> Void

    // The reported frame is the whole pocket cell (sleeve bounds), in global space.
    private var cellRectGlobal: CGRect {
        seated ?? CGRect(
            x: screen.width / 2 - 70,
            y: screen.height * 0.42 - 93,
            width: 140,
            height: 186
        )
    }

    private var fullWidth: CGFloat {
        min(screen.width * 0.86, (screen.height * 0.7) * PolaroidStyle.cardAspect)
    }

    private var fullCenter: CGPoint {
        CGPoint(x: screen.width / 2, y: screen.height * 0.44)
    }

    // `cell` must already be in the card layer's local space.
    private func morph(cell: CGRect) -> (center: CGPoint, width: CGFloat) {
        let photoW = cell.width * 0.82
        let photoH = photoW / PolaroidStyle.cardAspect
        // Seated: photo centered in the pocket. Above: photo bottom edge aligned to the pocket's top opening.
        let seatedC = CGPoint(x: cell.midX, y: cell.midY)
        let aboveC = CGPoint(x: cell.midX, y: cell.minY - photoH / 2)
        let p = max(0, min(1, progress))
        if p <= 0.5 {
            let t = p / 0.5
            return (lerp(seatedC, aboveC, t), photoW)
        } else {
            let t = (p - 0.5) / 0.5
            return (lerp(aboveC, fullCenter, t), photoW + (fullWidth - photoW) * t)
        }
    }

    private var controlsOpacity: Double {
        max(0, Double(progress) - Double(abs(dragOffset)) / 220)
    }

    var body: some View {
        let bgOpacity = max(0, 0.9 * Double(progress) - Double(abs(dragOffset)) / 700)
        ZStack {
            Color.black.opacity(bgOpacity)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(dismissGesture)

            // Rendered once at full size and scaled as a single transform so the
            // white frame and the photo never drift apart. The pocket reports in global
            // space; it is rebased into this reader's local space once here, so every
            // coordinate below shares one origin regardless of safe-area insets.
            GeometryReader { geo in
                let f = geo.frame(in: .global)
                let cell = cellRectGlobal.offsetBy(dx: -f.minX, dy: -f.minY)
                let m = morph(cell: cell)
                PolaroidCard(shot: shot, width: fullWidth, maxPixel: 1600)
                    .scaleEffect(m.width / fullWidth, anchor: .center)
                    .position(x: m.center.x, y: m.center.y + dragOffset)
            }
            .allowsHitTesting(false)

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
                        GlassIconButton(symbol: "xmark", accessibilityLabel: "Close photo", selected: true, action: closeToPocket)
                        GlassIconButton(symbol: "wand.and.sparkles", accessibilityLabel: "Edit photo", action: onEdit)
                        GlassIconButton(symbol: "square.and.arrow.up", accessibilityLabel: "Share photo", action: onShare)
                        GlassIconButton(symbol: "square.and.arrow.down", accessibilityLabel: "Save to Camera Roll", action: onSave)
                        GlassIconButton(symbol: "trash", accessibilityLabel: "Delete photo", action: onDelete)
                    }
                    .padding(8)
                }
                .padding(.bottom, 14)
            }
            .opacity(controlsOpacity)
            .allowsHitTesting(controlsOpacity > 0.85)
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in dragOffset = value.translation.height }
            .onEnded { value in
                if abs(dragOffset) > 110 || abs(value.predictedEndTranslation.height) > 320 {
                    closeToPocket()
                } else {
                    withAnimation(.poserSettle) { dragOffset = 0 }
                }
            }
    }

    private func closeToPocket() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        // Two beats: first settle to just above the pocket, then feed straight down into it.
        withAnimation(.easeInOut(duration: 0.4)) {
            progress = 0.5
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.26)) { progress = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: onClosed)
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
