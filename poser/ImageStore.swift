import Foundation
import ImageIO
import UniformTypeIdentifiers

actor ImageStore {
    static let shared = ImageStore()

    enum StoreError: LocalizedError {
        case invalidImage
        case cannotCreateJPEG
        case missingGhost

        var errorDescription: String? {
            switch self {
            case .invalidImage: "POSER couldn't read that image."
            case .cannotCreateJPEG: "POSER couldn't prepare a display copy."
            case .missingGhost: "That pose copy is no longer available."
            }
        }
    }

    private let fileManager = FileManager.default

    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func prepareDirectories() throws {
        for path in ["shots", "shots/display", "shots/decorated", "shots/ghosts", "overlays", "stickers"] {
            try fileManager.createDirectory(
                at: documentsURL.appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    func persistCapture(
        _ data: Data,
        facing: CameraFacing,
        ghostOverlay: OverlaySnapshot?
    ) throws -> PersistedShot {
        try prepareDirectories()
        let prepared = try prepareThreeByFourCapture(data)
        let dimensions = prepared.dimensions
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).jpg"
        let originalURL = documentsURL.appending(path: "shots/\(fileName)")
        try prepared.data.write(to: originalURL, options: .atomic)

        if let displayData = downsampleJPEG(prepared.data, maxPixel: 1600, quality: 0.85) {
            try displayData.write(
                to: documentsURL.appending(path: "shots/display/\(fileName)"),
                options: .atomic
            )
        }

        var ghost: ShotGhostReference?
        if let ghostOverlay {
            let source = documentsURL.appending(path: "overlays/\(ghostOverlay.fileName)")
            let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
            let ghostName = "\(id)-ghost.\(ext)"
            let destination = documentsURL.appending(path: "shots/ghosts/\(ghostName)")
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.copyItem(at: source, to: destination)
            }
            ghost = ShotGhostReference(
                overlayId: ghostOverlay.id,
                fileName: ghostName,
                width: ghostOverlay.width,
                height: ghostOverlay.height
            )
        }

        return PersistedShot(
            id: id,
            fileName: fileName,
            width: dimensions.width,
            height: dimensions.height,
            ghost: ghost
        )
    }

    func persistOverlay(data: Data, order: Int) throws -> PersistedOverlay {
        try prepareDirectories()
        guard let dimensions = imageDimensions(data) else { throw StoreError.invalidImage }
        let id = UUID().uuidString.lowercased()
        let fileName = "\(id).jpg"
        let addedAt = Date().addingTimeInterval(Double(-order) * 0.001)
        let jpeg = transcodeJPEG(data, quality: 0.94) ?? data
        try jpeg.write(to: documentsURL.appending(path: "overlays/\(fileName)"), options: .atomic)
        return PersistedOverlay(id: id, fileName: fileName, width: dimensions.width, height: dimensions.height, addedAt: addedAt)
    }

    func restoreOverlay(from ghost: ShotGhostReference) throws -> PersistedOverlay {
        try prepareDirectories()
        let source = documentsURL.appending(path: "shots/ghosts/\(ghost.fileName)")
        guard fileManager.fileExists(atPath: source.path) else { throw StoreError.missingGhost }
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let fileName = "\(ghost.overlayId)-restored.\(ext)"
        let destination = documentsURL.appending(path: "overlays/\(fileName)")
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
        return PersistedOverlay(
            id: ghost.overlayId,
            fileName: fileName,
            width: ghost.width,
            height: ghost.height,
            addedAt: .now
        )
    }

    func persistDecoratedJPEG(_ data: Data, shotID: String) throws -> String {
        try prepareDirectories()
        let fileName = "\(shotID)-decorated-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        try data.write(
            to: documentsURL.appending(path: "shots/decorated/\(fileName)"),
            options: .atomic
        )
        return fileName
    }

    func removeDecoratedJPEG(named fileName: String) {
        try? fileManager.removeItem(at: documentsURL.appending(path: "shots/decorated/\(fileName)"))
    }

    func deleteShot(_ record: ShotRecord) {
        let paths = [
            "shots/\(record.fileName)",
            "shots/display/\(record.fileName)",
            record.decoratedFileName.map { "shots/decorated/\($0)" }
        ].compactMap { $0 }
        for path in paths { try? fileManager.removeItem(at: documentsURL.appending(path: path)) }
        if let ghost = record.ghost {
            try? fileManager.removeItem(at: documentsURL.appending(path: "shots/ghosts/\(ghost.fileName)"))
        }
    }

    func deleteOverlay(_ record: OverlayRecord) {
        try? fileManager.removeItem(at: documentsURL.appending(path: "overlays/\(record.fileName)"))
    }

    nonisolated func shotOriginalURL(_ record: ShotRecord) -> URL {
        documentURL.appending(path: "shots/\(record.fileName)")
    }

    nonisolated func shotDisplayURL(_ record: ShotRecord) -> URL {
        if let decorated = record.decoratedFileName {
            let url = documentURL.appending(path: "shots/decorated/\(decorated)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let display = documentURL.appending(path: "shots/display/\(record.fileName)")
        return FileManager.default.fileExists(atPath: display.path) ? display : shotOriginalURL(record)
    }

    nonisolated func overlayURL(_ record: OverlayRecord) -> URL {
        documentURL.appending(path: "overlays/\(record.fileName)")
    }

    nonisolated func customStickerURL(_ record: CustomStickerRecord) -> URL {
        documentURL.appending(path: "stickers/\(record.fileName)")
    }

    private nonisolated var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private func prepareThreeByFourCapture(
        _ data: Data
    ) throws -> (data: Data, dimensions: (width: Int, height: Int)) {
        let captureAspect = 3.0 / 4.0
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw StoreError.invalidImage }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        let orientedWidth = swapsAxes ? rawHeight : rawWidth
        let orientedHeight = swapsAxes ? rawWidth : rawHeight
        let ratio = Double(orientedWidth) / Double(max(1, orientedHeight))

        // Native iPhone stills are normally already 3:4. Keep their original
        // bytes and metadata when possible; only center-crop unusual formats.
        if abs(ratio - captureAspect) < 0.002 {
            return (data, (orientedWidth, orientedHeight))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw StoreError.invalidImage
        }

        let width = orientedImage.width
        let height = orientedImage.height
        let currentRatio = Double(width) / Double(max(1, height))
        let cropRect: CGRect
        if currentRatio > captureAspect {
            let targetWidth = Int((Double(height) * captureAspect).rounded(.down))
            cropRect = CGRect(
                x: CGFloat(width - targetWidth) / 2,
                y: 0,
                width: CGFloat(targetWidth),
                height: CGFloat(height)
            )
        } else {
            let targetHeight = Int((Double(width) / captureAspect).rounded(.down))
            cropRect = CGRect(
                x: 0,
                y: CGFloat(height - targetHeight) / 2,
                width: CGFloat(width),
                height: CGFloat(targetHeight)
            )
        }

        guard
            let cropped = orientedImage.cropping(to: cropRect),
            let jpeg = encodeJPEG(cropped, quality: 0.97)
        else { throw StoreError.cannotCreateJPEG }
        return (jpeg, (cropped.width, cropped.height))
    }

    private func downsampleJPEG(_ data: Data, maxPixel: Int, quality: Double) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    private func transcodeJPEG(_ data: Data, quality: Double) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    private func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
