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
        for path in ["shots", "shots/display", "shots/decorated", "shots/ghosts", "overlays", "overlays/sources", "stickers"] {
            try fileManager.createDirectory(
                at: documentsURL.appending(path: path, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
    }

    func persistCapture(
        _ data: Data,
        facing: CameraFacing,
        ghostOverlay: OverlaySnapshot?,
        normalizedCrop: NormalizedCrop
    ) throws -> PersistedShot {
        try prepareDirectories()
        let prepared = try prepareThreeByFourCapture(data, normalizedCrop: normalizedCrop)
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
        try persistOverlay(data: data, id: UUID().uuidString.lowercased(), order: order)
    }

    func persistBundledOverlay(
        sourceURL: URL,
        preparedURL: URL,
        id: String,
        order: Int,
        cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) throws -> PersistedOverlay {
        try prepareDirectories()

        // Built-in poses are prepared at build time. First launch only copies
        // their display JPEG and original source instead of decoding and
        // re-encoding every large PNG on the user's phone.
        let sourceData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let preparedData = try Data(contentsOf: preparedURL, options: .mappedIfSafe)
        let sourceDimensions = try imageDimensions(sourceData)
        let preparedDimensions = try imageDimensions(preparedData)
        let crop = centeredThreeByFourCrop(
            width: sourceDimensions.width,
            height: sourceDimensions.height,
            center: cropCenter
        )
        let fileName = "\(id).jpg"
        let sourceFileName = "\(id)-source.png"
        let addedAt = Date().addingTimeInterval(Double(-order) * 0.001)

        try sourceData.write(
            to: documentsURL.appending(path: "overlays/sources/\(sourceFileName)"),
            options: .atomic
        )
        try preparedData.write(
            to: documentsURL.appending(path: "overlays/\(fileName)"),
            options: .atomic
        )

        return PersistedOverlay(
            id: id,
            fileName: fileName,
            width: preparedDimensions.width,
            height: preparedDimensions.height,
            sourceFileName: sourceFileName,
            sourceWidth: sourceDimensions.width,
            sourceHeight: sourceDimensions.height,
            crop: crop,
            canvasAspect: 3.0 / 4.0,
            addedAt: addedAt
        )
    }

    private func persistOverlay(
        data: Data,
        id: String,
        order: Int,
        cropCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) throws -> PersistedOverlay {
        try prepareDirectories()
        let source = try renderOrientedJPEG(data, maxPixel: 2560, quality: 0.94)
        let crop = centeredThreeByFourCrop(
            width: source.dimensions.width,
            height: source.dimensions.height,
            center: cropCenter
        )
        let prepared = try renderCroppedJPEG(source.data, crop: crop, maxPixel: 2048, quality: 0.94)
        let fileName = "\(id).jpg"
        let sourceFileName = "\(id)-source.jpg"
        let addedAt = Date().addingTimeInterval(Double(-order) * 0.001)
        try source.data.write(
            to: documentsURL.appending(path: "overlays/sources/\(sourceFileName)"),
            options: .atomic
        )
        try prepared.data.write(
            to: documentsURL.appending(path: "overlays/\(fileName)"),
            options: .atomic
        )
        return PersistedOverlay(
            id: id,
            fileName: fileName,
            width: prepared.dimensions.width,
            height: prepared.dimensions.height,
            sourceFileName: sourceFileName,
            sourceWidth: source.dimensions.width,
            sourceHeight: source.dimensions.height,
            crop: crop,
            canvasAspect: 3.0 / 4.0,
            addedAt: addedAt
        )
    }

    func updateOverlayCrop(
        sourceFileName: String?,
        outputFileName: String,
        crop: NormalizedCrop
    ) async throws -> (width: Int, height: Int) {
        let outputURL = documentsURL.appending(path: "overlays/\(outputFileName)")
        let sourceURL = sourceFileName.map {
            documentsURL.appending(path: "overlays/sources/\($0)")
        } ?? outputURL
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let prepared = try renderCroppedJPEG(data, crop: crop, maxPixel: 2048, quality: 0.94)
        try prepared.data.write(to: outputURL, options: .atomic)
        await LocalImageLoader.shared.invalidate(url: outputURL)
        return prepared.dimensions
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
            sourceFileName: nil,
            sourceWidth: nil,
            sourceHeight: nil,
            crop: .full,
            canvasAspect: 3.0 / 4.0,
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
        if let sourceFileName = record.sourceFileName {
            try? fileManager.removeItem(at: documentsURL.appending(path: "overlays/sources/\(sourceFileName)"))
        }
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

    nonisolated func overlayFileExists(named fileName: String) -> Bool {
        let url = documentURL.appending(path: "overlays/\(fileName)")
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    nonisolated func overlaySourceURL(_ record: OverlayRecord) -> URL {
        guard let sourceFileName = record.sourceFileName else { return overlayURL(record) }
        return documentURL.appending(path: "overlays/sources/\(sourceFileName)")
    }

    nonisolated func customStickerURL(_ record: CustomStickerRecord) -> URL {
        documentURL.appending(path: "stickers/\(record.fileName)")
    }

    private nonisolated var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func prepareThreeByFourCapture(
        _ data: Data,
        normalizedCrop: NormalizedCrop
    ) throws -> (data: Data, dimensions: (width: Int, height: Int)) {
        try renderCroppedJPEG(data, crop: normalizedCrop, maxPixel: nil, quality: 0.97)
    }

    private func renderOrientedJPEG(
        _ data: Data,
        maxPixel: Int?,
        quality: Double
    ) throws -> (data: Data, dimensions: (width: Int, height: Int)) {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw StoreError.invalidImage }

        let sourceMaxPixel = max(rawWidth, rawHeight)
        let outputMaxPixel = min(sourceMaxPixel, maxPixel ?? sourceMaxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw StoreError.invalidImage
        }

        guard let jpeg = encodeJPEG(orientedImage, quality: quality) else {
            throw StoreError.cannotCreateJPEG
        }
        return (jpeg, (orientedImage.width, orientedImage.height))
    }

    private func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw StoreError.invalidImage }
        return (width, height)
    }

    private func renderCroppedJPEG(
        _ data: Data,
        crop: NormalizedCrop,
        maxPixel: Int?,
        quality: Double
    ) throws -> (data: Data, dimensions: (width: Int, height: Int)) {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw StoreError.invalidImage }

        let orientationRawValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRawValue) ?? .up

        let sourceMaxPixel = max(rawWidth, rawHeight)
        let outputMaxPixel = min(sourceMaxPixel, maxPixel ?? sourceMaxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw StoreError.invalidImage
        }

        let width = orientedImage.width
        let height = orientedImage.height
        let displayedCrop = cropConvertedToDisplayedOrientation(crop, orientation: orientation)
        let requested = CGRect(
            x: displayedCrop.x * Double(width),
            y: displayedCrop.y * Double(height),
            width: displayedCrop.width * Double(width),
            height: displayedCrop.height * Double(height)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let cropRect = threeByFourPixelRect(inside: requested, imageWidth: width, imageHeight: height)

        guard
            let cropped = orientedImage.cropping(to: cropRect),
            let jpeg = encodeJPEG(cropped, quality: quality)
        else { throw StoreError.cannotCreateJPEG }
        return (jpeg, (cropped.width, cropped.height))
    }

    /// Preview-layer metadata coordinates describe the camera's unrotated
    /// picture. ImageIO applies the EXIF orientation while decoding, so the
    /// same crop must be rotated/mirrored before it is applied to those pixels.
    private func cropConvertedToDisplayedOrientation(
        _ crop: NormalizedCrop,
        orientation: CGImagePropertyOrientation
    ) -> NormalizedCrop {
        switch orientation {
        case .up:
            crop
        case .upMirrored:
            NormalizedCrop(x: 1 - crop.x - crop.width, y: crop.y, width: crop.width, height: crop.height)
        case .down:
            NormalizedCrop(
                x: 1 - crop.x - crop.width,
                y: 1 - crop.y - crop.height,
                width: crop.width,
                height: crop.height
            )
        case .downMirrored:
            NormalizedCrop(x: crop.x, y: 1 - crop.y - crop.height, width: crop.width, height: crop.height)
        case .leftMirrored:
            NormalizedCrop(x: crop.y, y: crop.x, width: crop.height, height: crop.width)
        case .right:
            NormalizedCrop(x: 1 - crop.y - crop.height, y: crop.x, width: crop.height, height: crop.width)
        case .rightMirrored:
            NormalizedCrop(
                x: 1 - crop.y - crop.height,
                y: 1 - crop.x - crop.width,
                width: crop.height,
                height: crop.width
            )
        case .left:
            NormalizedCrop(x: crop.y, y: 1 - crop.x - crop.width, width: crop.height, height: crop.width)
        }
    }

    private func centeredThreeByFourCrop(
        width: Int,
        height: Int,
        center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) -> NormalizedCrop {
        let sourceAspect = Double(width) / Double(max(1, height))
        let targetAspect = 3.0 / 4.0
        let cropWidth: Double
        let cropHeight: Double
        if sourceAspect > targetAspect {
            cropWidth = targetAspect / sourceAspect
            cropHeight = 1
        } else {
            cropWidth = 1
            cropHeight = sourceAspect / targetAspect
        }
        let x = min(1 - cropWidth, max(0, Double(center.x) - cropWidth / 2))
        let y = min(1 - cropHeight, max(0, Double(center.y) - cropHeight / 2))
        return NormalizedCrop(x: x, y: y, width: cropWidth, height: cropHeight)
    }

    private func threeByFourPixelRect(
        inside requested: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        var rect = requested.isNull || requested.isEmpty ? bounds : requested.intersection(bounds)
        let targetAspect = 3.0 / 4.0
        if rect.width / max(1, rect.height) > targetAspect {
            let targetWidth = rect.height * targetAspect
            rect.origin.x += (rect.width - targetWidth) / 2
            rect.size.width = targetWidth
        } else {
            let targetHeight = rect.width / targetAspect
            rect.origin.y += (rect.height - targetHeight) / 2
            rect.size.height = targetHeight
        }

        let targetWidth = max(3, Int(rect.width.rounded(.down)) / 3 * 3)
        let targetHeight = max(4, targetWidth / 3 * 4)
        let maxX = max(0, imageWidth - targetWidth)
        let maxY = max(0, imageHeight - targetHeight)
        let x = min(maxX, max(0, Int(rect.midX.rounded()) - targetWidth / 2))
        let y = min(maxY, max(0, Int(rect.midY.rounded()) - targetHeight / 2))
        return CGRect(x: x, y: y, width: targetWidth, height: targetHeight)
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

    private func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
