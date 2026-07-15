import Foundation
import Photos

enum PhotoLibraryService {
    enum SaveError: LocalizedError {
        case denied
        case failed

        var errorDescription: String? {
            switch self {
            case .denied: "Camera Roll access is off. Your photo is safe inside POSER."
            case .failed: "Your photo is safe inside POSER, but it couldn't be copied to Camera Roll."
            }
        }
    }

    static func saveImage(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
