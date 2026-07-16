import Foundation
import CoreGraphics
import SwiftData

nonisolated enum CameraFacing: String, Codable, CaseIterable, Sendable {
    case front
    case back
}

nonisolated struct ShotGhostReference: Codable, Equatable, Sendable {
    var overlayId: String
    var fileName: String
    var width: Int
    var height: Int
}

nonisolated struct NormalizedCrop: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = NormalizedCrop(x: 0, y: 0, width: 1, height: 1)

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

nonisolated struct ShotSticker: Codable, Identifiable, Equatable, Sendable {
    var key: String
    var stickerId: String
    var customStickerId: String?
    var imageAspectRatio: Double?
    var flipped = false
    var text: String?
    var cx: Double
    var cy: Double
    var offsetX: Double?
    var offsetY: Double?
    var scale: Double?
    var rotation: Double?

    var id: String { key }
}

nonisolated struct ShotEdits: Codable, Equatable, Sendable {
    var frameId: String?
    var stickers: [ShotSticker]
    var updatedAt: Date
}

@Model
final class ShotRecord {
    @Attribute(.unique) var id: String
    var fileName: String
    var decoratedFileName: String?
    var facingRawValue: String
    var takenAt: Date
    var width: Int
    var height: Int
    var ghostData: Data?
    var editsData: Data?

    init(
        id: String,
        fileName: String,
        decoratedFileName: String? = nil,
        facing: CameraFacing,
        takenAt: Date = .now,
        width: Int,
        height: Int,
        ghost: ShotGhostReference? = nil,
        edits: ShotEdits? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.decoratedFileName = decoratedFileName
        self.facingRawValue = facing.rawValue
        self.takenAt = takenAt
        self.width = width
        self.height = height
        self.ghostData = ghost.flatMap { try? JSONEncoder().encode($0) }
        self.editsData = edits.flatMap { try? JSONEncoder().encode($0) }
    }

    var facing: CameraFacing {
        get { CameraFacing(rawValue: facingRawValue) ?? .back }
        set { facingRawValue = newValue.rawValue }
    }

    var ghost: ShotGhostReference? {
        get { ghostData.flatMap { try? JSONDecoder().decode(ShotGhostReference.self, from: $0) } }
        set { ghostData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var edits: ShotEdits? {
        get { editsData.flatMap { try? JSONDecoder().decode(ShotEdits.self, from: $0) } }
        set { editsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

@Model
final class OverlayRecord {
    @Attribute(.unique) var id: String
    var fileName: String
    var addedAt: Date
    var width: Int
    var height: Int
    var sourceFileName: String?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var cropData: Data?
    var canvasAspectValue: Double?
    var tags: [String]
    var lastUsedAt: Date?
    var isFavorite: Bool = false

    init(
        id: String,
        fileName: String,
        addedAt: Date = .now,
        width: Int,
        height: Int,
        sourceFileName: String? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        crop: NormalizedCrop? = nil,
        canvasAspect: Double = 3.0 / 4.0,
        tags: [String] = [],
        lastUsedAt: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.addedAt = addedAt
        self.width = width
        self.height = height
        self.sourceFileName = sourceFileName
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.cropData = crop.flatMap { try? JSONEncoder().encode($0) }
        self.canvasAspectValue = canvasAspect
        self.tags = tags
        self.lastUsedAt = lastUsedAt
        self.isFavorite = isFavorite
    }

    var crop: NormalizedCrop {
        get { cropData.flatMap { try? JSONDecoder().decode(NormalizedCrop.self, from: $0) } ?? .full }
        set { cropData = try? JSONEncoder().encode(newValue) }
    }

    var canvasAspect: Double {
        get { canvasAspectValue ?? 3.0 / 4.0 }
        set { canvasAspectValue = newValue }
    }

    /// Sample poses shipped with the app use `builtin-` prefixed ids
    /// (see `BundledPoseCatalog`). Only user-added poses may be deleted.
    var isBuiltIn: Bool { id.hasPrefix("builtin-") }
}

@Model
final class CustomStickerRecord {
    @Attribute(.unique) var id: String
    var fileName: String
    var createdAt: Date
    var width: Int
    var height: Int
    /// Set when the sticker is taken out of the picker. The record and its file
    /// stay put: photos store a placement by id and draw nothing when the image
    /// is gone, so retiring one has to leave the artwork behind for the shots
    /// already wearing it.
    var hiddenAt: Date?

    init(id: String, fileName: String, createdAt: Date = .now, width: Int, height: Int) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.width = width
        self.height = height
    }
}

nonisolated struct PersistedShot: Sendable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
    let ghost: ShotGhostReference?
}

nonisolated struct PersistedOverlay: Sendable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
    let sourceFileName: String?
    let sourceWidth: Int?
    let sourceHeight: Int?
    let crop: NormalizedCrop
    let canvasAspect: Double
    let addedAt: Date
}

nonisolated struct PersistedCustomSticker: Sendable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
}

/// A finished cutout held in memory while the user decides whether to keep it.
nonisolated struct CutoutDraft: Sendable {
    let pngData: Data
    let width: Int
    let height: Int
}

nonisolated struct OverlaySnapshot: Sendable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
}

enum PoseTags {
    struct Group: Identifiable {
        let id: String
        let title: String
        let options: [(id: String, label: String)]
    }

    static let groups = [
        Group(id: "people", title: "Who is posing?", options: [("solo", "Solo"), ("duo", "Duo"), ("group", "Group")]),
        Group(id: "vibe", title: "What is the vibe?", options: [("cute", "Cute"), ("cool", "Cool"), ("silly", "Silly")])
    ]
}
