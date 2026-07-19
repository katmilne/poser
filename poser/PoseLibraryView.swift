import PhotosUI
import SwiftData
import SwiftUI

struct PoseLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(PremiumStore.self) private var premium
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OverlayRecord.addedAt, order: .reverse) private var overlays: [OverlayRecord]

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var selectedTags: Set<String> = []
    @State private var tagging: [OverlayRecord] = []
    @State private var framingRequest: PoseFramingRequest?
    @State private var importError: String?
    @State private var isImporting = false
    @State private var showsPaywall = false

    private var customPoseCount: Int { overlays.count { !$0.isBuiltIn } }

    /// How many more poses a free user may import; premium is uncapped.
    /// PhotosPicker treats 0 as "no limit", hence the explicit branch below.
    private var remainingFreePoses: Int {
        max(0, PremiumStore.freePoseLimit - customPoseCount)
    }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var filteredOverlays: [OverlayRecord] {
        guard !selectedTags.isEmpty else { return overlays }
        return overlays.filter { overlay in
            PoseTags.groups.allSatisfy { group in
                let active = selectedTags.intersection(group.options.map(\.id))
                return active.isEmpty || !active.isDisjoint(with: overlay.tags)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SkyBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        tagRail
                        LazyVGrid(columns: columns, spacing: 12) {
                            addPoseTile
                            ForEach(filteredOverlays) { overlay in
                                PoseLibraryTile(overlay: overlay) {
                                    appState.selectGhost(overlay)
                                    try? modelContext.save()
                                    dismiss()
                                } onTag: {
                                    tagging = [overlay]
                                } onReframe: {
                                    framingRequest = PoseFramingRequest(overlays: [overlay], tagsAfter: false)
                                } onFavorite: {
                                    overlay.isFavorite.toggle()
                                    if !overlay.isFavorite, appState.selectedGhost?.id == overlay.id {
                                        appState.selectedGhost = nil
                                    }
                                    try? modelContext.save()
                                } onDelete: {
                                    guard !overlay.isBuiltIn else { return }
                                    if appState.selectedGhost?.id == overlay.id { appState.selectedGhost = nil }
                                    if appState.libraryPose?.id == overlay.id { appState.libraryPose = nil }
                                    modelContext.delete(overlay)
                                    Task { await ImageStore.shared.deleteOverlay(overlay) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)

                if isImporting {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    GlassSurface(cornerRadius: Theme.Radius.md) {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("PREPARING POSES…")
                                .font(.system(size: 12, weight: .black, design: .monospaced))
                        }
                        .padding(18)
                    }
                }
            }
            .navigationTitle("POSES")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .onChange(of: pickedItems) {
            guard !pickedItems.isEmpty else { return }
            Task { await importPickedItems() }
        }
        .fullScreenCover(item: $framingRequest) { request in
            PoseFramingFlow(overlays: request.overlays) {
                framingRequest = nil
                guard request.tagsAfter else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    tagging = request.overlays
                }
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !tagging.isEmpty },
            set: { if !$0 { tagging = [] } }
        )) {
            PoseTaggingFlow(overlays: tagging) { tagging = [] }
        }
        .alert("Couldn't add that pose", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importError ?? "Please try another photo.")
        }
        .sheet(isPresented: $showsPaywall) {
            PaywallView(context: .poseLimit)
        }
    }

    @ViewBuilder
    private var addPoseTile: some View {
        if premium.isUnlocked || remainingFreePoses > 0 {
            PhotosPicker(
                selection: $pickedItems,
                maxSelectionCount: premium.isUnlocked ? 0 : remainingFreePoses,
                selectionBehavior: .ordered,
                matching: .images
            ) {
                addPoseTileLabel
            }
            .buttonStyle(PressScaleButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Add pose from Photos")
        } else {
            Button { showsPaywall = true } label: {
                addPoseTileLabel
            }
            .buttonStyle(PressScaleButtonStyle())
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Add pose from Photos, premium required")
        }
    }

    private var addPoseTileLabel: some View {
        GlassSurface(cornerRadius: Theme.Radius.md, tint: Theme.Colors.sky.opacity(0.18), interactive: true) {
            VStack(spacing: 12) {
                Image(systemName: addPoseLocked ? "sparkles" : "photo.badge.plus")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(addPoseLocked ? Theme.Colors.lemon : Theme.Colors.ink)
                Text("Add pose")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                Text(addPoseSubtitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Colors.textDim)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.Colors.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
    }

    private var addPoseLocked: Bool {
        !premium.isUnlocked && remainingFreePoses == 0
    }

    private var addPoseSubtitle: String {
        if premium.isUnlocked { return "From Photos" }
        if addPoseLocked { return "Premium unlocks unlimited" }
        return "From Photos · \(remainingFreePoses) of \(PremiumStore.freePoseLimit) free left"
    }

    private var tagRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FILTER POSES")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(1.4)
                Spacer()
                GlassTextButton(title: "All", compact: true, selected: selectedTags.isEmpty) {
                    selectedTags.removeAll()
                }
            }
            ForEach(PoseTags.sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(PoseTags.choices(in: section)) { option in
                                GlassTextButton(
                                    title: option.label,
                                    compact: true,
                                    selected: selectedTags.contains(option.id)
                                ) {
                                    if selectedTags.contains(option.id) {
                                        selectedTags.remove(option.id)
                                    } else {
                                        selectedTags.insert(option.id)
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    @MainActor
    private func importPickedItems() async {
        // The picker is already capped for free users, but the cap is
        // re-checked here so a stale picker session can't import past it.
        var items = pickedItems
        if !premium.isUnlocked {
            items = Array(items.prefix(remainingFreePoses))
        }
        pickedItems = []
        isImporting = true
        defer { isImporting = false }
        var newRecords: [OverlayRecord] = []
        do {
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let stored = try await ImageStore.shared.persistOverlay(data: data, order: index)
                let record = OverlayRecord(
                    id: stored.id,
                    fileName: stored.fileName,
                    addedAt: stored.addedAt,
                    width: stored.width,
                    height: stored.height,
                    sourceFileName: stored.sourceFileName,
                    sourceWidth: stored.sourceWidth,
                    sourceHeight: stored.sourceHeight,
                    crop: stored.crop,
                    canvasAspect: stored.canvasAspect
                )
                modelContext.insert(record)
                newRecords.append(record)
            }
            try modelContext.save()
            if !newRecords.isEmpty {
                Analytics.track("poses_imported", ["count": newRecords.count])
                framingRequest = PoseFramingRequest(overlays: newRecords, tagsAfter: true)
            }
        } catch {
            importError = error.localizedDescription
            Analytics.captureError(error, area: "pose_import")
        }
    }
}

private struct PoseFramingRequest: Identifiable {
    let id = UUID()
    let overlays: [OverlayRecord]
    let tagsAfter: Bool
}

private struct PoseLibraryTile: View {
    let overlay: OverlayRecord
    let onSelect: () -> Void
    let onTag: () -> Void
    let onReframe: () -> Void
    let onFavorite: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onSelect) {
                LocalFileImage(url: ImageStore.shared.overlayURL(overlay), maxPixel: 700)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(Theme.viewportAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        if !overlay.tags.isEmpty {
                            Text(overlay.tags.map { $0.uppercased() }.joined(separator: " · "))
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundStyle(Theme.Colors.ink)
                                .padding(.horizontal, 8)
                                .frame(height: 25)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .stroke(Color.white.opacity(0.88), lineWidth: 1)
                    }
                    .shadow(color: Theme.stickerShadow, radius: 24, y: 8)
            }
            .buttonStyle(PressScaleButtonStyle())
            .contextMenu {
                Button(
                    overlay.isFavorite ? "Remove from favorites" : "Add to favorites",
                    systemImage: overlay.isFavorite ? "heart.slash" : "heart",
                    action: onFavorite
                )
                Button("Edit tags", systemImage: "tag", action: onTag)
                Button("Reframe pose", systemImage: "crop", action: onReframe)
                if !overlay.isBuiltIn {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                }
            }

            Button(action: onFavorite) {
                GlassSurface(
                    cornerRadius: 22,
                    tint: overlay.isFavorite ? Theme.Colors.glassSelected : Theme.Colors.black.opacity(0.14),
                    interactive: true
                ) {
                    Image(systemName: overlay.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(overlay.isFavorite ? Theme.Colors.recRed : Theme.Colors.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
            }
            .buttonStyle(PressScaleButtonStyle())
            .padding(8)
            .accessibilityLabel(overlay.isFavorite ? "Remove pose from favorites" : "Add pose to favorites")
            .accessibilityAddTraits(overlay.isFavorite ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: overlay.isFavorite)
        }
        .confirmationDialog("Delete this pose from POSER?", isPresented: $confirmsDelete) {
            Button("Delete pose", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct PoseFramingFlow: View {
    @Environment(\.modelContext) private var modelContext

    let overlays: [OverlayRecord]
    let onDone: () -> Void

    @State private var index = 0
    @State private var crop = NormalizedCrop.full
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var current: OverlayRecord? {
        overlays.indices.contains(index) ? overlays[index] : nil
    }

    var body: some View {
        ZStack {
            SkyBackground(quiet: true)

            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FRAME YOUR POSE")
                            .font(.system(size: 18, weight: .black, design: .rounded))
                        Text("3:4 CAMERA FRAME")
                            .font(.system(size: 10, weight: .black, design: .monospaced))
                            .tracking(1.3)
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                    Spacer()
                    if overlays.count > 1 {
                        Text("\(index + 1) / \(overlays.count)")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                    GlassIconButton(symbol: "xmark", accessibilityLabel: "Keep current pose frame", action: onDone)
                }
                .padding(.horizontal, 18)

                if let current {
                    PoseCropCanvas(overlay: current, crop: $crop)
                        .padding(.horizontal, 24)

                    Text("DRAG TO POSITION · PINCH TO ZOOM")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(Theme.Colors.textDim)

                    HStack(spacing: 12) {
                        GlassTextButton(title: "RESET", compact: true) {
                            withAnimation(.poserSettle) {
                                crop = PoseCropGeometry.maximumCrop(for: current)
                            }
                        }
                        GlassTextButton(
                            title: index == overlays.count - 1 ? "USE FRAME" : "NEXT POSE",
                            disabled: isSaving
                        ) {
                            Task { await saveAndAdvance(current) }
                        }
                    }
                }
            }
            .padding(.vertical, 18)

            if isSaving {
                Color.black.opacity(0.16).ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .onAppear { loadCrop() }
        .alert("Couldn't frame that pose", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private func loadCrop() {
        crop = current?.crop ?? .full
    }

    @MainActor
    private func saveAndAdvance(_ overlay: OverlayRecord) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let dimensions = try await ImageStore.shared.updateOverlayCrop(
                sourceFileName: overlay.sourceFileName,
                outputFileName: overlay.fileName,
                crop: crop
            )
            overlay.crop = crop
            overlay.canvasAspect = 3.0 / 4.0
            overlay.width = dimensions.width
            overlay.height = dimensions.height
            try modelContext.save()

            if index == overlays.count - 1 {
                onDone()
            } else {
                index += 1
                loadCrop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PoseCropCanvas: View {
    let overlay: OverlayRecord
    @Binding var crop: NormalizedCrop

    @State private var dragStart = NormalizedCrop.full
    @State private var magnifyStart = NormalizedCrop.full
    @State private var isDragging = false
    @State private var isMagnifying = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let drawing = PoseCropGeometry.drawing(for: crop, in: size)

            LocalFileImage(
                url: ImageStore.shared.overlaySourceURL(overlay),
                contentMode: .fill,
                maxPixel: 2200
            )
            .frame(width: drawing.size.width, height: drawing.size.height)
            .offset(drawing.offset)
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay {
                Rectangle()
                    .stroke(.white.opacity(0.92), lineWidth: 1)
                RuleOfThirdsGrid()
                    .stroke(.white.opacity(0.38), lineWidth: 0.5)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            dragStart = crop
                            isDragging = true
                        }
                        crop = PoseCropGeometry.dragged(
                            from: dragStart,
                            translation: value.translation,
                            canvasSize: size,
                            maximum: PoseCropGeometry.maximumCrop(for: overlay)
                        )
                    }
                    .onEnded { _ in
                        dragStart = crop
                        isDragging = false
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if !isMagnifying {
                            magnifyStart = crop
                            isMagnifying = true
                        }
                        crop = PoseCropGeometry.magnified(
                            from: magnifyStart,
                            magnification: value.magnification,
                            maximum: PoseCropGeometry.maximumCrop(for: overlay)
                        )
                    }
                    .onEnded { _ in
                        magnifyStart = crop
                        isMagnifying = false
                    }
            )
            .onChange(of: overlay.id, initial: true) {
                dragStart = crop
                magnifyStart = crop
            }
        }
        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Color.white, lineWidth: 1)
        }
        .shadow(color: Theme.stickerShadow, radius: 24, y: 9)
        .accessibilityLabel("Pose framing preview")
        .accessibilityHint("Drag to position the pose and pinch to zoom")
    }
}

private enum PoseCropGeometry {
    static func maximumCrop(for overlay: OverlayRecord) -> NormalizedCrop {
        let width = Double(overlay.sourceWidth ?? overlay.width)
        let height = Double(max(1, overlay.sourceHeight ?? overlay.height))
        let sourceAspect = width / height
        let targetAspect = overlay.canvasAspect
        if sourceAspect > targetAspect {
            let cropWidth = targetAspect / sourceAspect
            return NormalizedCrop(x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1)
        }
        let cropHeight = sourceAspect / targetAspect
        return NormalizedCrop(x: 0, y: (1 - cropHeight) / 2, width: 1, height: cropHeight)
    }

    static func drawing(for crop: NormalizedCrop, in canvas: CGSize) -> (size: CGSize, offset: CGSize) {
        let width = canvas.width / max(0.0001, crop.width)
        let height = canvas.height / max(0.0001, crop.height)
        let offsetX = ((0.5 - crop.x) / max(0.0001, crop.width) - 0.5) * canvas.width
        let offsetY = ((0.5 - crop.y) / max(0.0001, crop.height) - 0.5) * canvas.height
        return (CGSize(width: width, height: height), CGSize(width: offsetX, height: offsetY))
    }

    static func dragged(
        from start: NormalizedCrop,
        translation: CGSize,
        canvasSize: CGSize,
        maximum: NormalizedCrop
    ) -> NormalizedCrop {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return start }
        var next = start
        next.x = start.x - Double(translation.width / canvasSize.width) * start.width
        next.y = start.y - Double(translation.height / canvasSize.height) * start.height
        return clamped(next, maximum: maximum)
    }

    static func magnified(
        from start: NormalizedCrop,
        magnification: CGFloat,
        maximum: NormalizedCrop
    ) -> NormalizedCrop {
        let factor = max(0.25, min(4, Double(magnification)))
        let minimumWidth = maximum.width / 4
        let width = min(maximum.width, max(minimumWidth, start.width / factor))
        let height = width * maximum.height / max(0.0001, maximum.width)
        let centerX = start.x + start.width / 2
        let centerY = start.y + start.height / 2
        return clamped(
            NormalizedCrop(
                x: centerX - width / 2,
                y: centerY - height / 2,
                width: width,
                height: height
            ),
            maximum: maximum
        )
    }

    private static func clamped(_ crop: NormalizedCrop, maximum: NormalizedCrop) -> NormalizedCrop {
        let width = min(maximum.width, max(maximum.width / 4, crop.width))
        let height = min(maximum.height, max(maximum.height / 4, crop.height))
        return NormalizedCrop(
            x: min(1 - width, max(0, crop.x)),
            y: min(1 - height, max(0, crop.y)),
            width: width,
            height: height
        )
    }
}

private struct RuleOfThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            path.move(to: CGPoint(x: rect.width * fraction, y: 0))
            path.addLine(to: CGPoint(x: rect.width * fraction, y: rect.height))
            path.move(to: CGPoint(x: 0, y: rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height * fraction))
        }
        return path
    }
}

private struct PoseTaggingFlow: View {
    @Environment(\.modelContext) private var modelContext
    let overlays: [OverlayRecord]
    let onDone: () -> Void
    @State private var index = 0
    @State private var selections: [String: Set<String>] = [:]

    private var current: OverlayRecord? {
        overlays.indices.contains(index) ? overlays[index] : nil
    }

    private var canAdvance: Bool {
        PoseTags.groups.allSatisfy { !$0.isRequired || !(selections[$0.id]?.isEmpty ?? true) }
    }

    var body: some View {
        ZStack {
            SkyBackground()
            VStack(spacing: 16) {
                HStack {
                    Text("TAG YOUR POSE")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                    Spacer()
                    Button("Later") { onDone() }
                }
                .padding(.horizontal, 20)

                if let current {
                    LocalFileImage(url: ImageStore.shared.overlayURL(current), maxPixel: 1200)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(Theme.viewportAspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                        .padding(.horizontal, 34)

                    ForEach(PoseTags.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 14, weight: .bold))
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(PoseTags.choices(in: section)) { option in
                                        let isSelected = selections[option.groupID]?.contains(option.id) ?? false
                                        GlassTextButton(
                                            title: option.label,
                                            compact: true,
                                            selected: isSelected
                                        ) { toggle(option) }
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    GlassTextButton(
                        title: index == overlays.count - 1 ? "DONE" : "NEXT POSE",
                        disabled: !canAdvance
                    ) { advance(current) }
                    .padding(.top, 6)
                }
            }
            .padding(.vertical, 20)
        }
        .onAppear { loadSelections() }
    }

    private func loadSelections() {
        guard let current else { return }
        selections = [:]
        for group in PoseTags.groups {
            selections[group.id] = Set(group.options.lazy.map(\.id).filter(current.tags.contains))
        }
    }

    private func toggle(_ option: PoseTags.Choice) {
        guard let group = PoseTags.groups.first(where: { $0.id == option.groupID }) else { return }
        if group.allowsMultiple {
            var selected = selections[group.id] ?? []
            if selected.contains(option.id) {
                selected.remove(option.id)
            } else {
                selected.insert(option.id)
            }
            selections[group.id] = selected
        } else {
            selections[group.id] = [option.id]
        }
    }

    private func advance(_ current: OverlayRecord) {
        current.tags = PoseTags.groups.flatMap { group in
            let selected = selections[group.id] ?? []
            return group.options.compactMap { selected.contains($0.id) ? $0.id : nil }
        }
        try? modelContext.save()
        if index == overlays.count - 1 {
            onDone()
        } else {
            index += 1
            loadSelections()
        }
    }
}
