import SwiftData
import SwiftUI
import UIKit

struct PreviewEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomStickerRecord.createdAt, order: .reverse) private var customStickers: [CustomStickerRecord]

    let shot: ShotRecord
    /// The capture route opens straight from the shutter on a shot nobody has
    /// agreed to keep yet: Done is what puts it in the album, and X throws it
    /// away. From the album the shot is already kept and the lightbox carries
    /// its own share/save, so the editor stays a pure decorating surface.
    var isDraft = true
    @State private var sourceImage: UIImage?
    @State private var frameID: String?
    @State private var stickers: [ShotSticker]
    @State private var selectedStickerID: String?
    @State private var selectedPack = StickerPack.own
    @State private var noteText = ""
    @State private var showsNoteEntry = false
    @State private var showsStickerMaker = false
    @State private var stickerPendingRemoval: CustomStickerRecord?
    @State private var sharePayload: SharePayload?
    @State private var alertMessage: String?
    @State private var isRendering = false
    @State private var confirmsDiscard = false
    @State private var renderedComposite: RenderedComposite?

    /// The recipe the decorated file on disk was developed from. Comparing the
    /// live recipe against it is what tells a re-render from a re-read.
    private struct RenderedComposite: Equatable {
        var frameID: String?
        var stickers: [ShotSticker]
    }

    init(shot: ShotRecord, isDraft: Bool = true) {
        self.shot = shot
        self.isDraft = isDraft
        let edits = shot.edits
        _frameID = State(initialValue: edits?.frameId)
        _stickers = State(initialValue: edits?.stickers ?? [])
        // An album shot arrives with its composite already developed, so the
        // first share is a read unless the user actually changes something.
        _renderedComposite = State(initialValue: shot.decoratedFileName == nil ? nil : edits.map {
            RenderedComposite(frameID: $0.frameId, stickers: $0.stickers)
        })
    }

    private var isDecorated: Bool { frameID != nil || !stickers.isEmpty }

    /// The composite is laid out in points at roughly the size the editor shows
    /// it, and only then scaled up to the 1536×2048 export. Handing the renderer
    /// the pixel size directly would keep every fixed-point detail inside the
    /// canvas — the frame's 20pt border inset, the digicam trim, sticker
    /// shadows — at its literal size against a canvas four times wider, which
    /// pushes the frame marks so close to the edge that half of each is clipped
    /// away and the photo reads as cropped in.
    private static let exportCanvas = CGSize(width: 384, height: 384 / Theme.viewportAspect)
    private static let exportScale: CGFloat = 4

    var body: some View {
        ZStack {
            SkyBackground(quiet: true)
            VStack(spacing: 14) {
                editorHeader
                    .padding(.horizontal, 16)

                GeometryReader { proxy in
                    let canvasSize = fittedCanvas(in: proxy.size)
                    ZStack {
                        if let sourceImage {
                            CompositeCanvas(
                                image: sourceImage,
                                frameID: frameID,
                                stickers: stickers,
                                selectedStickerID: selectedStickerID,
                                editable: true,
                                customStickerURLs: customStickerURLs,
                                onSelect: { selectedStickerID = $0 },
                                onDeselect: { selectedStickerID = nil },
                                onChange: updateSticker
                            )
                            .frame(width: canvasSize.width, height: canvasSize.height)
                        } else {
                            ProgressView("Preparing photo…")
                                .frame(width: canvasSize.width, height: canvasSize.height)
                                .background(Theme.Colors.mist)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 10) {
                    if let selectedStickerID {
                        stickerSelectionBar(selectedStickerID)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    toolsTray
                }
                .animation(.poserGlide, value: selectedStickerID)
                // Without the action row beneath it the tray is the last thing in the
                // stack, so it needs the bottom breathing room the row used to give.
                .padding(.bottom, isDraft ? 0 : 12)

                if isDraft {
                    actionRow
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }

            if isRendering {
                Color.black.opacity(0.24).ignoresSafeArea()
                GlassSurface(cornerRadius: Theme.Radius.md) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("DEVELOPING…")
                            .font(.system(size: 13, weight: .black, design: .monospaced))
                    }
                    .padding(18)
                }
            }
        }
        .task {
            sourceImage = await LocalImageLoader.shared.image(
                at: ImageStore.shared.shotOriginalURL(shot),
                maxPixel: 2200
            )
        }
        .onChange(of: frameID) { saveRecipe() }
        .onChange(of: stickers) { saveRecipe() }
        .sheet(isPresented: $showsNoteEntry) { noteEntrySheet }
        .fullScreenCover(isPresented: $showsStickerMaker) {
            StickerMakerView { custom in addCustomSticker(custom) }
        }
        .shareSheet(payload: $sharePayload)
        .confirmationDialog(
            "Remove this sticker from your pack?",
            isPresented: Binding(
                get: { stickerPendingRemoval != nil },
                set: { if !$0 { stickerPendingRemoval = nil } }
            ),
            presenting: stickerPendingRemoval
        ) { custom in
            Button("Remove sticker", role: .destructive) { removeCustomStickerFromPack(custom) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Photos you've already put it on will keep it.")
        }
        .confirmationDialog(
            "Discard this photo?",
            isPresented: $confirmsDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard photo", role: .destructive) { discardDraft() }
            Button("Keep editing", role: .cancel) { }
        } message: {
            Text("It hasn't been saved to your album yet, so it will be gone for good.")
        }
        .alert("POSER", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var editorHeader: some View {
        HStack {
            GlassSurface(cornerRadius: Theme.Radius.pill, tint: Theme.Colors.hotPink.opacity(0.13)) {
                Text("EDIT")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .tracking(1.6)
                    .padding(.horizontal, 18)
                    .frame(height: 46)
            }
            Spacer()
            GlassIconButton(symbol: "xmark", accessibilityLabel: "Close editor") {
                Task { await closeEditor() }
            }
        }
    }

    private var actionRow: some View {
        GlassGroup(spacing: 18) {
            HStack(spacing: 18) {
                GlassIconButton(symbol: "square.and.arrow.up", accessibilityLabel: "Share photo") {
                    Task { await share() }
                }
                GlassIconButton(
                    symbol: "square.and.arrow.down",
                    accessibilityLabel: "Save to Camera Roll"
                ) {
                    Task { await saveToCameraRoll() }
                }
                GlassTextButton(title: "DONE", selected: true) {
                    Task { await finishDraft() }
                }
            }
        }
    }

    private var toolsTray: some View {
        GlassSurface(cornerRadius: Theme.Radius.lg) {
            VStack(alignment: .leading, spacing: 12) {
                Text("FRAMES")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.5)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(FrameCatalog.all, id: \.id) { frame in
                            GlassTextButton(
                                title: frame.title,
                                compact: true,
                                selected: frameID == frame.id,
                                minWidth: FrameCatalog.pillWidth
                            ) {
                                frameID = frame.id
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                Text("STICKERS")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(1.5)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(StickerPack.allCases) { pack in
                            GlassTextButton(title: pack.title, compact: true, selected: selectedPack == pack) {
                                withAnimation(.poserGlide) { selectedPack = pack }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        switch selectedPack {
                        case .own: ownPackItems
                        case .sample: packItems(StickerCatalog.all)
                        case .doodle: packItems(DoodleCatalog.all)
                        case .pixel: packItems(PixelCatalog.pickerItems)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 58)
            }
            .padding(14)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private var ownPackItems: some View {
        Button { showsNoteEntry = true } label: {
            StickerGlyph(id: "note", text: "Aa")
                .frame(width: 54, height: 54)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("Add a note sticker")

        Button { showsStickerMaker = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "person.crop.rectangle.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                Text("MAKE")
                    .font(.system(size: 8, weight: .black))
            }
            .foregroundStyle(Theme.Colors.ink)
            .frame(width: 54, height: 54)
            .background(Theme.Colors.cyan, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("Make a sticker from a photo")

        ForEach(pickerStickers) { custom in
            Button { addCustomSticker(custom) } label: {
                StickerGlyph(id: "custom", customURL: ImageStore.shared.customStickerURL(custom))
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("Add your sticker")
            .contextMenu {
                Button("Remove sticker", systemImage: "trash", role: .destructive) {
                    stickerPendingRemoval = custom
                }
            }
        }
    }

    /// The query deliberately keeps every record, hidden ones included, so
    /// `customStickerURLs` can still resolve art for stickers already placed on
    /// this shot. Only the picker narrows to what's still on offer.
    private var pickerStickers: [CustomStickerRecord] {
        customStickers.filter { $0.hiddenAt == nil }
    }

    private func packItems(_ items: [(id: String, title: String)]) -> some View {
        ForEach(items, id: \.id) { item in
            Button { addSticker(item.id) } label: {
                StickerGlyph(id: item.id)
                    .frame(width: 54, height: 54)
            }
            .buttonStyle(PressScaleButtonStyle())
            .accessibilityLabel("Add \(item.title) sticker")
        }
    }

    private func stickerSelectionBar(_ id: String) -> some View {
        GlassSurface(cornerRadius: Theme.Radius.pill) {
            HStack(spacing: 14) {
                Button("FLIP") {
                    guard let index = stickers.firstIndex(where: { $0.key == id }) else { return }
                    stickers[index].flipped.toggle()
                }
                Button("COPY") { duplicateSticker(id) }
                Button("DELETE", role: .destructive) {
                    stickers.removeAll { $0.key == id }
                    selectedStickerID = nil
                }
                Spacer(minLength: 4)
                Button("DONE") { selectedStickerID = nil }
            }
            .font(.system(size: 12, weight: .black))
            .padding(.horizontal, 18)
            .frame(height: 46)
        }
        .padding(.horizontal, 14)
    }

    private var noteEntrySheet: some View {
        NavigationStack {
            Form {
                TextField("NO BAD ANGLES", text: $noteText, axis: .vertical)
                    .lineLimit(2...3)
                    .onChange(of: noteText) { if noteText.count > 48 { noteText = String(noteText.prefix(48)) } }
                Text("\(noteText.count) / 48")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Add a note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showsNoteEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addTextSticker(noteText)
                        noteText = ""
                        showsNoteEntry = false
                    }
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func fittedCanvas(in available: CGSize) -> CGSize {
        let width = min(available.width, available.height * Theme.viewportAspect)
        return CGSize(width: width, height: width / Theme.viewportAspect)
    }

    private func addSticker(_ id: String) {
        let count = stickers.count
        let sticker = ShotSticker(
            key: UUID().uuidString,
            stickerId: id,
            cx: 0.5 + Double((count % 4) - 2) * 0.035,
            cy: 0.48 + Double((count % 3) - 1) * 0.035,
            scale: 1,
            rotation: Double((count % 5) * 4 - 8)
        )
        stickers.append(sticker)
        selectedStickerID = sticker.key
    }

    private func addTextSticker(_ text: String) {
        var sticker = ShotSticker(key: UUID().uuidString, stickerId: "note", text: text, cx: 0.5, cy: 0.48)
        sticker.scale = 1
        stickers.append(sticker)
        selectedStickerID = sticker.key
    }

    private func addCustomSticker(_ custom: CustomStickerRecord) {
        let sticker = ShotSticker(
            key: UUID().uuidString,
            stickerId: "custom",
            customStickerId: custom.id,
            imageAspectRatio: Double(custom.width) / Double(max(1, custom.height)),
            cx: 0.5,
            cy: 0.48,
            scale: 1
        )
        stickers.append(sticker)
        selectedStickerID = sticker.key
    }

    /// Retires a sticker from the picker without touching the photos wearing it.
    /// The record and its file survive so those placements keep drawing — only
    /// `ownPackItems` filters on `hiddenAt`.
    private func removeCustomStickerFromPack(_ custom: CustomStickerRecord) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        custom.hiddenAt = .now
        try? modelContext.save()
        stickerPendingRemoval = nil
    }

    private var customStickerURLs: [String: URL] {
        Dictionary(uniqueKeysWithValues: customStickers.map { ($0.id, ImageStore.shared.customStickerURL($0)) })
    }

    private func duplicateSticker(_ id: String) {
        guard let original = stickers.first(where: { $0.key == id }) else { return }
        var copy = original
        copy.key = UUID().uuidString
        copy.cx = min(1, original.cx + 0.06)
        copy.cy = min(1, original.cy + 0.06)
        stickers.append(copy)
        selectedStickerID = copy.key
    }

    private func updateSticker(_ sticker: ShotSticker) {
        guard let index = stickers.firstIndex(where: { $0.key == sticker.key }) else { return }
        stickers[index] = sticker
    }

    private func saveRecipe() {
        shot.edits = ShotEdits(frameId: frameID, stickers: stickers, updatedAt: .now)
        try? modelContext.save()
    }

    @MainActor
    private func renderedJPEG() async -> Data? {
        guard let sourceImage else { return nil }
        selectedStickerID = nil
        await Task.yield()
        var customStickerImages: [String: UIImage] = [:]
        for id in Set(stickers.compactMap(\.customStickerId)) {
            guard let url = customStickerURLs[id] else { continue }
            if let image = await LocalImageLoader.shared.image(at: url, maxPixel: 600) {
                customStickerImages[id] = image
            }
        }
        let renderer = ImageRenderer(content: CompositeCanvas(
            image: sourceImage,
            frameID: frameID,
            stickers: stickers,
            selectedStickerID: nil,
            editable: false,
            customStickerURLs: customStickerURLs,
            customStickerImages: customStickerImages,
            onSelect: { _ in },
            onChange: { _ in }
        ).frame(width: Self.exportCanvas.width, height: Self.exportCanvas.height))
        renderer.scale = Self.exportScale
        renderer.proposedSize = ProposedViewSize(Self.exportCanvas)
        guard let image = renderer.uiImage else { return nil }
        // The renderer has to rasterise on the main actor, but encoding what it
        // produced does not, and at 1536×2048 the encode is long enough to be
        // felt as a tap that hangs the app.
        return await Task.detached(priority: .userInitiated) {
            image.jpegData(compressionQuality: 0.92)
        }.value
    }

    @MainActor
    private func persistDecoratedPreview() async -> URL? {
        guard isDecorated else { return nil }
        let composite = RenderedComposite(frameID: frameID, stickers: stickers)
        // Sharing twice, or sharing what Done has already developed, asks for a
        // composite the file on disk is holding: rendering it again would only
        // block the main thread to reproduce bytes we have.
        if composite == renderedComposite, shot.decoratedFileName != nil {
            return ImageStore.shared.shotDisplayURL(shot)
        }
        guard let data = await renderedJPEG() else { return nil }
        do {
            let oldName = shot.decoratedFileName
            let fileName = try await ImageStore.shared.persistDecoratedJPEG(data, shotID: shot.id)
            shot.decoratedFileName = fileName
            try modelContext.save()
            if let oldName, oldName != fileName { await ImageStore.shared.removeDecoratedJPEG(named: oldName) }
            renderedComposite = composite
            return ImageStore.shared.shotDisplayURL(shot)
        } catch {
            alertMessage = "The edit recipe is safe, but POSER couldn't develop its album preview."
            return nil
        }
    }

    /// A draft has nothing behind it, so leaving is leaving it behind: ask, then
    /// throw the shot away. From the album the photo is already the user's, and
    /// closing is just putting it down — the edits go with it.
    @MainActor
    private func closeEditor() async {
        if isDraft {
            confirmsDiscard = true
            return
        }
        isRendering = true
        saveRecipe()
        if isDecorated { _ = await persistDecoratedPreview() }
        isRendering = false
        dismiss()
    }

    private func discardDraft() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        modelContext.delete(shot)
        try? modelContext.save()
        Task { await ImageStore.shared.deleteShot(shot) }
        dismiss()
    }

    /// Keeping the draft: the record is already in the context, so this only has
    /// to fix the edits in place and develop the album's preview of them.
    @MainActor
    private func finishDraft() async {
        isRendering = true
        saveRecipe()
        if isDecorated { _ = await persistDecoratedPreview() }
        isRendering = false
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }

    @MainActor
    private func share() async {
        isRendering = true
        defer { isRendering = false }
        if let url = await currentExportURL() {
            sharePayload = SharePayload(url: url)
        }
    }

    @MainActor
    private func saveToCameraRoll() async {
        isRendering = true
        defer { isRendering = false }
        guard let url = await currentExportURL() else { return }
        do {
            try await PhotoLibraryService.saveImage(at: url)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            alertMessage = "Saved to Camera Roll."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func currentExportURL() async -> URL? {
        if isDecorated { return await persistDecoratedPreview() }
        return ImageStore.shared.shotOriginalURL(shot)
    }
}

private struct CompositeCanvas: View {
    let image: UIImage
    let frameID: String?
    let stickers: [ShotSticker]
    let selectedStickerID: String?
    let editable: Bool
    let customStickerURLs: [String: URL]
    var customStickerImages: [String: UIImage] = [:]
    let onSelect: (String) -> Void
    var onDeselect: () -> Void = { }
    let onChange: (ShotSticker) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if editable {
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { onDeselect() }
                }

                if let frameID { DecorativeFrame(id: frameID) }

                ForEach(stickers) { sticker in
                    PlacedStickerView(
                        sticker: sticker,
                        canvasSize: proxy.size,
                        selected: selectedStickerID == sticker.key,
                        editable: editable,
                        customURL: sticker.customStickerId.flatMap { customStickerURLs[$0] },
                        customImage: sticker.customStickerId.flatMap { customStickerImages[$0] },
                        onSelect: { onSelect(sticker.key) },
                        onChange: onChange
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(.rect)
        }
        .clipped()
    }
}

private struct PlacedStickerView: View {
    let sticker: ShotSticker
    let canvasSize: CGSize
    let selected: Bool
    let editable: Bool
    let customURL: URL?
    var customImage: UIImage?
    let onSelect: () -> Void
    let onChange: (ShotSticker) -> Void
    @State private var dragStart: CGPoint?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?

    var body: some View {
        let base = canvasSize.width * 0.22
        let scale = sticker.scale ?? 1
        StickerGlyph(id: sticker.stickerId, text: sticker.text, customURL: customURL, customImage: customImage)
            .frame(width: base, height: base)
            .overlay {
                if selected {
                    // Drawn inside the transform so the box hugs the rotated
                    // sticker; the stroke is divided back out to keep a
                    // constant on-screen weight at any zoom.
                    RoundedRectangle(cornerRadius: 8 / scale, style: .continuous)
                        .stroke(
                            Theme.Colors.ink,
                            style: StrokeStyle(lineWidth: 2 / scale, dash: [7 / scale, 5 / scale])
                        )
                }
            }
            // Hit area must be established while the view is still sticker-sized:
            // `.position` below expands it to fill the canvas, which would make
            // every sticker swallow gestures meant for the ones beneath it.
            .contentShape(.rect)
            .scaleEffect(x: sticker.flipped ? -scale : scale, y: scale)
            .rotationEffect(.degrees(sticker.rotation ?? 0))
            .position(x: sticker.cx * canvasSize.width, y: sticker.cy * canvasSize.height)
            .allowsHitTesting(editable)
            .onTapGesture { if editable { onSelect() } }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard editable else { return }
                        let start = dragStart ?? CGPoint(x: sticker.cx, y: sticker.cy)
                        if dragStart == nil {
                            dragStart = start
                            if !selected { onSelect() }
                        }
                        var next = sticker
                        next.cx = min(1, max(0, start.x + value.translation.width / canvasSize.width))
                        next.cy = min(1, max(0, start.y + value.translation.height / canvasSize.height))
                        onChange(next)
                    }
                    .onEnded { _ in
                        dragStart = nil
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .simultaneously(with: RotateGesture())
                    .onChanged { value in
                        guard editable else { return }
                        var next = sticker
                        if let magnify = value.first {
                            let start = scaleStart ?? (sticker.scale ?? 1)
                            if scaleStart == nil { scaleStart = start }
                            next.scale = min(4, max(0.3, start * magnify.magnification))
                        }
                        if let rotate = value.second {
                            let start = rotationStart ?? (sticker.rotation ?? 0)
                            if rotationStart == nil { rotationStart = start }
                            next.rotation = start + rotate.rotation.degrees
                        }
                        onChange(next)
                    }
                    .onEnded { _ in
                        scaleStart = nil
                        rotationStart = nil
                    }
            )
    }
}

private enum FrameCatalog {
    static let all: [(id: String?, title: String)] = [
        (nil, "None"), ("hearts", "Hearts"), ("stars", "Stars"),
        ("digicam", "Digicam"), ("sparkle", "Sparkle")
    ]

    /// One width for every frame pill, so the row reads as a set of equal
    /// choices rather than pills sized to their own labels. Comfortably clears
    /// the longest title at the compact button's fixed 13pt font, and acts as a
    /// floor — a longer title would grow its pill rather than clip.
    static let pillWidth: CGFloat = 92
}

private enum StickerPack: String, CaseIterable, Identifiable {
    case own
    case sample
    case doodle
    case pixel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .own: "OWN"
        case .sample: "SAMPLE"
        case .doodle: "DOODLE"
        case .pixel: "PIXEL"
        }
    }
}

private enum StickerCatalog {
    static let all = [
        ("star", "Star"), ("sparkle", "Sparkle"), ("heart", "Heart"),
        ("smiley", "Smiley"), ("butterfly", "Butterfly"), ("flame", "Flame"),
        ("bolt", "Bolt"), ("cd", "CD"), ("2000", "2000"), ("xoxo", "xoxo"),
        ("flower", "Flower"), ("scribble", "Scribble"), ("bubble", "No Bad Angles"),
        ("pin", "Safety Pin"), ("iconic", "Status Iconic")
    ].map { (id: $0.0, title: $0.1) }
}

/// Hand-drawn ink marks — the whole pack is stroked vector art on a clear
/// background, so it reads the same over light and dark photos.
private enum DoodleCatalog {
    static let all = [
        ("doodle-heart", "Doodle Heart"), ("doodle-sparkle", "Doodle Sparkle"),
        ("doodle-sparkle-solid", "Solid Sparkle"), ("doodle-moon", "Doodle Moon"),
        ("doodle-circle", "Doodle Circle"), ("doodle-dot", "Doodle Dot")
    ].map { (id: $0.0, title: $0.1) }

    static let ids = Set(all.map(\.id))
}

/// Pixel-art takes on the same marks the doodle pack draws, each offered in ink
/// and in white so there is a legible choice over both a dark and a pale photo.
private enum PixelCatalog {
    enum Tone: String, CaseIterable {
        case black
        case white

        var color: Color {
            switch self {
            case .black: Theme.Colors.ink
            case .white: Theme.Colors.cloud
            }
        }

        /// A white mark disappears against a pale photo and against the picker's
        /// own light surface, so it carries an edge shadow that ink doesn't need.
        var edgeShadow: Color {
            switch self {
            case .black: .clear
            case .white: Theme.Colors.ink.opacity(0.35)
            }
        }
    }

    struct Item {
        let id: String
        let title: String
        let sprite: PixelSprite
        let tone: Tone
    }

    private static let shapes: [(slug: String, title: String, sprite: PixelSprite)] = [
        ("heart", "Heart", .heart), ("sparkle", "Sparkle", .sparkle),
        ("sparkle-solid", "Solid Sparkle", .sparkleSolid), ("moon", "Moon", .moon),
        ("circle", "Circle", .circle), ("dot", "Dot", .dot)
    ]

    /// Tones sit next to each other within a shape so the row reads as pairs.
    static let all: [Item] = shapes.flatMap { shape in
        Tone.allCases.map { tone in
            Item(
                id: "pixel-\(shape.slug)-\(tone.rawValue)",
                title: "Pixel \(tone == .white ? "White " : "")\(shape.title)",
                sprite: shape.sprite,
                tone: tone
            )
        }
    }

    static let ids = Set(all.map(\.id))

    static let pickerItems = all.map { (id: $0.id, title: $0.title) }

    static func item(_ id: String) -> Item? { all.first { $0.id == id } }
}

private struct StickerGlyph: View {
    let id: String
    var text: String?
    var customURL: URL?
    var customImage: UIImage?

    var body: some View {
        ZStack {
            switch id {
            case "custom":
                if let customImage {
                    Image(uiImage: customImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if let customURL {
                    LocalFileImage(url: customURL, contentMode: .fit, maxPixel: 600)
                }
            case "heart": symbol("heart.fill", Theme.Colors.hotPink)
            case "star": symbol("star.fill", Theme.Colors.lemon)
            case "sparkle": symbol("sparkles", Theme.Colors.cyan)
            case "smiley": symbol("face.smiling.inverse", Theme.Colors.lemon)
            case "butterfly": symbol("camera.macro", Theme.Colors.grape)
            case "flame": symbol("flame.fill", Theme.Colors.tangerine)
            case "bolt": symbol("bolt.fill", Theme.Colors.sky)
            case "cd": symbol("opticaldisc.fill", Theme.Colors.grape)
            case "flower": symbol("camera.macro.circle.fill", Theme.Colors.hotPink)
            case "pin": symbol("paperclip", Theme.Colors.cyan)
            case "2000", "xoxo": stickerText(id.uppercased(), Theme.Colors.grape)
            case "bubble": stickerText("NO BAD\nANGLES", Theme.Colors.sky)
            case "iconic": stickerText("STATUS:\nICONIC", Theme.Colors.lemon)
            case "note": stickerText(text ?? "Aa", Theme.Colors.cream)
            case "scribble": ScribbleShape().stroke(Theme.Colors.hotPink, lineWidth: 7)
            case _ where DoodleCatalog.ids.contains(id): DoodleGlyph(id: id)
            case _ where PixelCatalog.ids.contains(id): PixelGlyph(id: id)
            default: symbol("sparkles", Theme.Colors.cyan)
            }
        }
        .padding(5)
        .shadow(color: Theme.stickerShadow, radius: 6, y: 3)
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .shadow(color: Theme.Colors.ink.opacity(0.35), radius: 2, y: 1)
            .padding(8)
    }

    private func stickerText(_ value: String, _ color: Color) -> some View {
        Text(value)
            .font(.system(size: 15, weight: .black, design: .rounded))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.35)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white, lineWidth: 3) }
    }
}

private struct DoodleGlyph: View {
    let id: String

    var body: some View {
        switch id {
        case "doodle-heart": DoodleMark(shape: DoodleHeartShape())
        case "doodle-sparkle": DoodleMark(shape: DoodleSparkleShape())
        case "doodle-sparkle-solid": DoodleMark(shape: DoodleSparkleShape(), filled: true, inset: 0.34)
        case "doodle-moon": DoodleMark(shape: DoodleMoonShape())
        case "doodle-circle": DoodleMark(shape: Circle(), inset: 0.28)
        case "doodle-dot": DoodleMark(shape: Circle(), filled: true, inset: 0.40)
        default: EmptyView()
        }
    }
}

/// Draws a doodle shape at a stroke weight proportional to its rendered size,
/// so one glyph serves both the 54pt picker and a full-size canvas sticker.
private struct DoodleMark<S: Shape>: View {
    let shape: S
    var filled = false
    /// Fraction of the frame trimmed off each edge — lets small marks such as
    /// the dot stay small relative to the shared sticker frame.
    var inset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(1.2, side * 0.055)
            ZStack {
                if filled {
                    shape.fill(Theme.Colors.ink)
                } else {
                    shape.stroke(
                        Theme.Colors.ink,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .padding(side * inset + lineWidth / 2)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct PixelGlyph: View {
    let id: String

    var body: some View {
        if let item = PixelCatalog.item(id) {
            PixelMark(sprite: item.sprite, color: item.tone.color)
                .shadow(color: item.tone.edgeShadow, radius: 2, y: 1)
        }
    }
}

/// A pixel-art mark held as its own ASCII art: `#` is an on pixel, `.` is off.
private struct PixelSprite {
    /// Every sprite is centred in a grid this many pixels square, which fixes one
    /// pixel size for the whole pack: a small mark such as the dot then stays
    /// small beside the heart instead of being blown up to the same frame.
    static let field = 16

    let rows: [String]

    var height: Int { rows.count }
    var width: Int { rows.first?.count ?? 0 }
}

extension PixelSprite {
    static let heart = PixelSprite(rows: [
        "..####...####..",
        ".#....#.#....#.",
        "#......#......#",
        "#.............#",
        "#.............#",
        ".#...........#.",
        "..#.........#..",
        "...#.......#...",
        "....#.....#....",
        ".....#...#.....",
        "......#.#......",
        ".......#......."
    ])

    static let sparkle = PixelSprite(rows: [
        "......#......",
        "......#......",
        "......#......",
        ".....#.#.....",
        ".....#.#.....",
        "..###...###..",
        "##.........##",
        "..###...###..",
        ".....#.#.....",
        ".....#.#.....",
        "......#......",
        "......#......",
        "......#......"
    ])

    static let sparkleSolid = PixelSprite(rows: [
        "....#....",
        "....#....",
        "....#....",
        "...###...",
        "#########",
        "...###...",
        "....#....",
        "....#....",
        "....#...."
    ])

    static let moon = PixelSprite(rows: [
        ".....###.....",
        "...##..#.....",
        "..#...#......",
        ".#...#.......",
        ".#..#........",
        "#...#........",
        "#...#........",
        "#...#........",
        ".#..#........",
        ".#...#.......",
        "..#...#......",
        "...##..#.....",
        ".....###....."
    ])

    static let circle = PixelSprite(rows: [
        "...###...",
        "..#...#..",
        ".#.....#.",
        "#.......#",
        "#.......#",
        "#.......#",
        ".#.....#.",
        "..#...#..",
        "...###..."
    ])

    static let dot = PixelSprite(rows: [
        ".##.",
        "####",
        "####",
        ".##."
    ])
}

/// Stamps a sprite at whatever size it is handed, so one grid serves both the
/// 54pt picker tile and a full-size canvas sticker.
private struct PixelMark: View {
    let sprite: PixelSprite
    let color: Color

    var body: some View {
        Canvas { context, size in
            let cell = min(size.width, size.height) / CGFloat(PixelSprite.field)
            let origin = CGPoint(
                x: (size.width - cell * CGFloat(sprite.width)) / 2,
                y: (size.height - cell * CGFloat(sprite.height)) / 2
            )
            var path = Path()
            for (row, line) in sprite.rows.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    path.addRect(CGRect(
                        x: origin.x + CGFloat(column) * cell,
                        y: origin.y + CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    ))
                }
            }
            // Filled as one path so neighbouring pixels merge instead of showing
            // antialiased seams along every shared edge.
            context.fill(path, with: .color(color))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct DoodleHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + h * 0.28),
            control1: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.74),
            control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.50)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + h * 0.24),
            control1: CGPoint(x: rect.minX + w * 0.04, y: rect.minY),
            control2: CGPoint(x: rect.minX + w * 0.38, y: rect.minY - h * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.28),
            control1: CGPoint(x: rect.maxX - w * 0.38, y: rect.minY - h * 0.02),
            control2: CGPoint(x: rect.maxX - w * 0.04, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.50),
            control2: CGPoint(x: rect.maxX - w * 0.10, y: rect.minY + h * 0.74)
        )
        path.closeSubpath()
        return path
    }
}

/// Four-point star with concave sides — the sparkle repeated across the pattern.
private struct DoodleSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        // Pulls each side in toward the centre; smaller values sharpen the points.
        let waist: CGFloat = 0.14
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - ry))
        path.addQuadCurve(
            to: CGPoint(x: cx + rx, y: cy),
            control: CGPoint(x: cx + rx * waist, y: cy - ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy + ry),
            control: CGPoint(x: cx + rx * waist, y: cy + ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - rx, y: cy),
            control: CGPoint(x: cx - rx * waist, y: cy + ry * waist)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - ry),
            control: CGPoint(x: cx - rx * waist, y: cy - ry * waist)
        )
        path.closeSubpath()
        return path
    }
}

private struct DoodleMoonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let radius = side / 2
        let disc = Path(ellipseIn: CGRect(
            x: rect.midX - radius,
            y: rect.midY - radius,
            width: side,
            height: side
        ))
        let biteRadius = radius * 0.92
        let bite = Path(ellipseIn: CGRect(
            x: rect.midX - biteRadius + radius * 0.54,
            y: rect.midY - biteRadius,
            width: biteRadius * 2,
            height: biteRadius * 2
        ))
        return disc.subtracting(bite)
    }
}

private struct ScribbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.width * 0.25, y: rect.minY),
            control2: CGPoint(x: rect.width * 0.30, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control1: CGPoint(x: rect.width * 0.70, y: rect.minY),
            control2: CGPoint(x: rect.width * 0.75, y: rect.maxY)
        )
        return path
    }
}

private struct DecorativeFrame: View {
    let id: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch id {
                case "hearts":
                    frameSymbols("heart.fill", color: Theme.Colors.hotPink, size: proxy.size)
                case "stars":
                    frameSymbols("star.fill", color: Theme.Colors.lemon, size: proxy.size)
                case "sparkle":
                    frameSymbols("sparkles", color: Theme.Colors.cyan, size: proxy.size)
                case "digicam":
                    DigicamFrame()
                default:
                    EmptyView()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func frameSymbols(_ symbol: String, color: Color, size: CGSize) -> some View {
        ZStack {
            ForEach(Array(borderPoints(in: size).enumerated()), id: \.offset) { _, point in
                Image(systemName: symbol)
                    .font(.system(size: size.width * 0.075, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.Colors.ink.opacity(0.35), radius: 2, y: 1)
                    .position(point)
            }
        }
    }

    /// Walks the border clockwise from the top-left, stepping each edge on its
    /// own count rather than marching a single stride around the whole
    /// perimeter. A shared stride only lands on all four corners when the rect
    /// is square: on the 3:4 canvas the corners sit at distances the stride
    /// steps straight over, which leaves three of them bare.
    ///
    /// Each edge starts exactly on its corner, so all four are always marked,
    /// and the counts are picked to keep the horizontal and vertical steps as
    /// close to the same length as the rect allows.
    private func borderPoints(in size: CGSize) -> [CGPoint] {
        let inset: CGFloat = 20
        let minX = inset
        let minY = inset
        let maxX = max(minX + 1, size.width - inset)
        let maxY = max(minY + 1, size.height - inset)
        let w = maxX - minX
        let h = maxY - minY

        // Splits the border into roughly 14 marks on a 3:4 canvas (3 steps
        // across each horizontal edge, 4 down each vertical one).
        let unit = (w + h) / 7
        let columns = max(1, Int((w / unit).rounded()))
        let rows = max(1, Int((h / unit).rounded()))

        var points: [CGPoint] = []
        for i in 0..<columns {
            points.append(CGPoint(x: minX + w * CGFloat(i) / CGFloat(columns), y: minY))
        }
        for i in 0..<rows {
            points.append(CGPoint(x: maxX, y: minY + h * CGFloat(i) / CGFloat(rows)))
        }
        for i in 0..<columns {
            points.append(CGPoint(x: maxX - w * CGFloat(i) / CGFloat(columns), y: maxY))
        }
        for i in 0..<rows {
            points.append(CGPoint(x: minX, y: maxY - h * CGFloat(i) / CGFloat(rows)))
        }
        return points
    }
}

private struct DigicamFrame: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .stroke(.white.opacity(0.86), style: StrokeStyle(lineWidth: 3, dash: [26, 12]))
                .padding(18)
            VStack {
                HStack {
                    Text("● REC")
                        .foregroundStyle(Theme.Colors.recRed)
                        .opacity(pulse ? 0.42 : 1)
                    Spacer()
                    Image(systemName: "battery.75percent")
                }
                Spacer()
                HStack {
                    Spacer()
                    Text(Date.now.formatted(.dateTime.year(.twoDigits).month(.twoDigits).day(.twoDigits).hour().minute()))
                }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(28)
        }
        .task {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true }
        }
    }
}
