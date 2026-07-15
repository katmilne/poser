import PhotosUI
import SwiftData
import SwiftUI

struct PoseLibraryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \OverlayRecord.addedAt, order: .reverse) private var overlays: [OverlayRecord]

    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var imported: [OverlayRecord] = []
    @State private var selectedTags: Set<String> = []
    @State private var tagging: [OverlayRecord] = []
    @State private var importError: String?

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
                                } onDelete: {
                                    if appState.selectedGhost?.id == overlay.id { appState.selectedGhost = nil }
                                    modelContext.delete(overlay)
                                    Task { await ImageStore.shared.deleteOverlay(overlay) }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
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
    }

    private var addPoseTile: some View {
        PhotosPicker(
            selection: $pickedItems,
            maxSelectionCount: 0,
            selectionBehavior: .ordered,
            matching: .images
        ) {
            GlassSurface(cornerRadius: Theme.Radius.md, tint: Theme.Colors.sky.opacity(0.18), interactive: true) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 32, weight: .semibold))
                    Text("Add pose")
                        .font(.system(size: 16, weight: .black, design: .rounded))
                    Text("From Photos")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .foregroundStyle(Theme.Colors.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(Theme.viewportAspect, contentMode: .fit)
        }
        .buttonStyle(PressScaleButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Add pose from Photos")
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
            ForEach(PoseTags.groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(group.options, id: \.id) { option in
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
        let items = pickedItems
        pickedItems = []
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
                    height: stored.height
                )
                modelContext.insert(record)
                newRecords.append(record)
            }
            try modelContext.save()
            imported = newRecords
            tagging = newRecords
        } catch {
            importError = error.localizedDescription
        }
    }
}

private struct PoseLibraryTile: View {
    let overlay: OverlayRecord
    let onSelect: () -> Void
    let onTag: () -> Void
    let onDelete: () -> Void
    @State private var confirmsDelete = false

    var body: some View {
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
            Button("Edit tags", systemImage: "tag", action: onTag)
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete this pose from POSER?", isPresented: $confirmsDelete) {
            Button("Delete pose", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The original stays in Photos.")
        }
    }
}

private struct PoseTaggingFlow: View {
    @Environment(\.modelContext) private var modelContext
    let overlays: [OverlayRecord]
    let onDone: () -> Void
    @State private var index = 0
    @State private var selections: [String: String] = [:]

    private var current: OverlayRecord? {
        overlays.indices.contains(index) ? overlays[index] : nil
    }

    private var canAdvance: Bool {
        PoseTags.groups.allSatisfy { selections[$0.id] != nil }
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

                    ForEach(PoseTags.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.system(size: 14, weight: .bold))
                            HStack(spacing: 8) {
                                ForEach(group.options, id: \.id) { option in
                                    GlassTextButton(
                                        title: option.label,
                                        compact: true,
                                        selected: selections[group.id] == option.id
                                    ) { selections[group.id] = option.id }
                                }
                            }
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
            selections[group.id] = group.options.first { current.tags.contains($0.id) }?.id
        }
    }

    private func advance(_ current: OverlayRecord) {
        current.tags = PoseTags.groups.compactMap { selections[$0.id] }
        try? modelContext.save()
        if index == overlays.count - 1 {
            onDone()
        } else {
            index += 1
            loadSelections()
        }
    }
}
