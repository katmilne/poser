import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

actor SubjectCutoutService {
    static let shared = SubjectCutoutService()

    enum CutoutError: LocalizedError {
        case invalidImage
        case noSubject
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The source photo could not be read."
            case .noSubject: "Apple Vision couldn't find a foreground subject in this photo."
            case .writeFailed: "POSER couldn't save the finished sticker."
            }
        }
    }

    func createSticker(from sourceData: Data) throws -> PersistedCustomSticker {
        try autoreleasepool {
            let preparedData = downsampleJPEG(sourceData, maxPixel: 2048) ?? sourceData
            let temporaryURL = FileManager.default.temporaryDirectory
                .appending(path: "poser-cutout-\(UUID().uuidString).jpg")
            try preparedData.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            guard let inputImage = CIImage(
                contentsOf: temporaryURL,
                options: [.applyOrientationProperty: true]
            ) else { throw CutoutError.invalidImage }

            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(ciImage: inputImage)
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw CutoutError.noSubject
            }

            let maskedBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let id = UUID().uuidString.lowercased()
            let fileName = "\(id).png"
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appending(path: "stickers", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: fileName)

            let context = CIContext(options: [.cacheIntermediates: false])
            defer { context.clearCaches() }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw CutoutError.writeFailed }
            try context.writePNGRepresentation(
                of: CIImage(cvPixelBuffer: maskedBuffer),
                to: destination,
                format: .RGBA8,
                colorSpace: colorSpace
            )
            return PersistedCustomSticker(
                id: id,
                fileName: fileName,
                width: CVPixelBufferGetWidth(maskedBuffer),
                height: CVPixelBufferGetHeight(maskedBuffer)
            )
        }
    }

    private func downsampleJPEG(_ data: Data, maxPixel: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
