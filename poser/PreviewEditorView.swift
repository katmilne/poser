import SwiftData
import SwiftUI
import UIKit

struct PreviewEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CustomStickerRecord.createdAt, order: .reverse) private var customStickers: [CustomStickerRecord]

    let shot: ShotRecord
    @State private var sourceImage: UIImage?
    @State private var frameID: String?
    @State private var stickers: [ShotSticker]
    @State private var selectedStickerID: String?
    @State private var showsTools = false
    @State private var noteText = ""
    @State private var showsNoteEntry = false
    @State private var showsStickerMaker = false
    @State private var sharePayload: SharePayload?
    @State private var alertMessage: String?
    @State private var isRendering = false

    init(shot: ShotRecord) {
        self.shot = shot
        let edits = shot.edits
        _frameID = State(initialValue: edits?.frameId)
        _stickers = State(initialValue: edits?.stickers ?? [])
    }

    private var isDecorated: Bool { frameID != nil || !stickers.isEmpty }

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

                if let selectedStickerID {
                    stickerSelectionBar(selectedStickerID)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if showsTools {
                    toolsTray
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                actionRow
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
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
        .sheet(item: $sharePayload) { payload in ShareSheet(items: [payload.url]) }
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
            HStack {
                GlassIconButton(symbol: "wand.and.sparkles", accessibilityLabel: "Toggle editing tools", selected: showsTools) {
                    withAnimation(.poserGlide) {
                        selectedStickerID = nil
                        showsTools.toggle()
                    }
                }
                Spacer()
                GlassIconButton(symbol: "square.and.arrow.up", accessibilityLabel: "Share photo") {
                    Task { await share() }
                }
                Spacer()
                GlassIconButton(
                    symbol: "square.and.arrow.down",
                    accessibilityLabel: "Save decorated photo",
                    selected: isDecorated,
                    disabled: !isDecorated
                ) {
                    Task { await saveDecoratedToPhotos() }
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
                            GlassTextButton(title: frame.title, compact: true, selected: frameID == frame.id) {
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
                        Button { showsNoteEntry = true } label: {
                            StickerGlyph(id: "note", text: "Aa")
                                .frame(width: 54, height: 54)
                        }
                        .buttonStyle(PressScaleButtonStyle())
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
                        ForEach(customStickers) { custom in
                            Button { addCustomSticker(custom) } label: {
                                StickerGlyph(id: "custom", customURL: ImageStore.shared.customStickerURL(custom))
                                    .frame(width: 54, height: 54)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                        }
                        ForEach(StickerCatalog.all, id: \.id) { item in
                            Button { addSticker(item.id) } label: {
                                StickerGlyph(id: item.id)
                                    .frame(width: 54, height: 54)
                            }
                            .buttonStyle(PressScaleButtonStyle())
                            .accessibilityLabel("Add \(item.title) sticker")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(14)
        }
        .padding(.horizontal, 14)
    }

    private func stickerSelectionBar(_ id: String) -> some View {
        GlassSurface(cornerRadius: Theme.Radius.pill) {
            HStack(spacing: 16) {
                Button("FLIP") {
                    guard let index = stickers.firstIndex(where: { $0.key == id }) else { return }
                    stickers[index].flipped.toggle()
                }
                Button("DELETE", role: .destructive) {
                    stickers.removeAll { $0.key == id }
                    selectedStickerID = nil
                }
                Text("PINCH TO RESIZE · TWIST TO ROTATE")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .font(.system(size: 12, weight: .black))
            .padding(.horizontal, 16)
            .frame(height: 46)
        }
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

    private var customStickerURLs: [String: URL] {
        Dictionary(uniqueKeysWithValues: customStickers.map { ($0.id, ImageStore.shared.customStickerURL($0)) })
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
        let exportSize = CGSize(width: 1536, height: 2048)
        let renderer = ImageRenderer(content: CompositeCanvas(
            image: sourceImage,
            frameID: frameID,
            stickers: stickers,
            selectedStickerID: nil,
            editable: false,
            customStickerURLs: customStickerURLs,
            onSelect: { _ in },
            onChange: { _ in }
        ).frame(width: exportSize.width, height: exportSize.height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(exportSize)
        return renderer.uiImage?.jpegData(compressionQuality: 0.92)
    }

    @MainActor
    private func persistDecoratedPreview() async -> URL? {
        guard isDecorated, let data = await renderedJPEG() else { return nil }
        do {
            let oldName = shot.decoratedFileName
            let fileName = try await ImageStore.shared.persistDecoratedJPEG(data, shotID: shot.id)
            shot.decoratedFileName = fileName
            try modelContext.save()
            if let oldName, oldName != fileName { await ImageStore.shared.removeDecoratedJPEG(named: oldName) }
            return ImageStore.shared.shotDisplayURL(shot)
        } catch {
            alertMessage = "The edit recipe is safe, but POSER couldn't develop its album preview."
            return nil
        }
    }

    @MainActor
    private func closeEditor() async {
        isRendering = true
        saveRecipe()
        if isDecorated { _ = await persistDecoratedPreview() }
        isRendering = false
        dismiss()
    }

    @MainActor
    private func share() async {
        isRendering = true
        defer { isRendering = false }
        if isDecorated {
            if let url = await persistDecoratedPreview() { sharePayload = SharePayload(url: url) }
        } else {
            sharePayload = SharePayload(url: ImageStore.shared.shotOriginalURL(shot))
        }
    }

    @MainActor
    private func saveDecoratedToPhotos() async {
        isRendering = true
        defer { isRendering = false }
        guard let url = await persistDecoratedPreview() else { return }
        do {
            try await PhotoLibraryService.saveImage(at: url)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            alertMessage = "Decorated copy saved to Camera Roll."
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            alertMessage = error.localizedDescription
        }
    }
}

private struct CompositeCanvas: View {
    let image: UIImage
    let frameID: String?
    let stickers: [ShotSticker]
    let selectedStickerID: String?
    let editable: Bool
    let customStickerURLs: [String: URL]
    let onSelect: (String) -> Void
    let onChange: (ShotSticker) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                if let frameID { DecorativeFrame(id: frameID) }

                ForEach(stickers) { sticker in
                    PlacedStickerView(
                        sticker: sticker,
                        canvasSize: proxy.size,
                        selected: selectedStickerID == sticker.key,
                        editable: editable,
                        customURL: sticker.customStickerId.flatMap { customStickerURLs[$0] },
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
    let onSelect: () -> Void
    let onChange: (ShotSticker) -> Void
    @State private var dragStart: CGPoint?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?

    var body: some View {
        let base = canvasSize.width * 0.22
        StickerGlyph(id: sticker.stickerId, text: sticker.text, customURL: customURL)
            .frame(width: base, height: base)
            .scaleEffect(x: sticker.flipped ? -(sticker.scale ?? 1) : (sticker.scale ?? 1), y: sticker.scale ?? 1)
            .rotationEffect(.degrees(sticker.rotation ?? 0))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.Colors.ink, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                }
            }
            .position(x: sticker.cx * canvasSize.width, y: sticker.cy * canvasSize.height)
            .contentShape(.rect)
            .onTapGesture { if editable { onSelect() } }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard editable else { return }
                        let start = dragStart ?? CGPoint(x: sticker.cx, y: sticker.cy)
                        if dragStart == nil { dragStart = start }
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

private struct StickerGlyph: View {
    let id: String
    var text: String?
    var customURL: URL?

    var body: some View {
        ZStack {
            switch id {
            case "custom":
                if let customURL {
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
        let count = 16
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                Image(systemName: symbol)
                    .font(.system(size: size.width * 0.075, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.Colors.ink.opacity(0.35), radius: 2, y: 1)
                    .position(borderPoint(index: index, count: count, size: size))
            }
        }
    }

    private func borderPoint(index: Int, count: Int, size: CGSize) -> CGPoint {
        let inset: CGFloat = 20
        let w = max(1, size.width - inset * 2)
        let h = max(1, size.height - inset * 2)
        let perimeter = 2 * (w + h)
        var distance = perimeter * CGFloat(index) / CGFloat(count)

        if distance < w {
            return CGPoint(x: inset + distance, y: inset)
        }
        distance -= w
        if distance < h {
            return CGPoint(x: size.width - inset, y: inset + distance)
        }
        distance -= h
        if distance < w {
            return CGPoint(x: size.width - inset - distance, y: size.height - inset)
        }
        distance -= w
        return CGPoint(x: inset, y: size.height - inset - distance)
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
