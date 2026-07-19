import ImageIO
import SwiftUI
import UIKit

/// Decodes and caches downsampled copies of images stored on disk.
///
/// Deliberately *not* an actor. The work here is CPU-bound decoding, and an
/// actor has one executor: every thumbnail would queue behind every other one,
/// so the pose strip filled in a frame at a time and a single full-size pose
/// guide held up all the little ones behind it. `NSCache` is already
/// thread-safe, so requests run concurrently and only the cache is shared.
nonisolated final class LocalImageLoader: @unchecked Sendable {
    static let shared = LocalImageLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Bounded by decoded bitmap bytes rather than image count: a pose guide
        // and a 54pt strip thumbnail differ by three orders of magnitude, so
        // counting entries would bound nothing that matters.
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// An already-decoded image, without suspending. Lets a view show a cached
    /// image on its first render rather than flashing a spinner and waiting a
    /// frame for an `await` that was never going to do any work.
    func cachedImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(url: url, maxPixel: maxPixel))
    }

    func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let cached = cachedImage(at: url, maxPixel: maxPixel) { return cached }
        return await Task.detached(priority: .userInitiated) { [cache] in
            guard let image = Self.decode(url: url, maxPixel: maxPixel) else { return nil }
            cache.setObject(
                image,
                forKey: Self.key(url: url, maxPixel: maxPixel),
                cost: image.decodedByteCount
            )
            return image
        }.value
    }

    func invalidate(url _: URL) {
        // NSCache intentionally does not expose its keys. The image URLs are
        // rewritten rarely, so clearing the bounded cache is both predictable
        // and cheap compared with serving a stale pose crop.
        cache.removeAllObjects()
    }

    private static func key(url: URL, maxPixel: CGFloat) -> NSString {
        "\(url.path)-\(Int(maxPixel))" as NSString
    }

    private static func decode(url: URL, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

private extension UIImage {
    /// The decoded bitmap's footprint - the number that actually costs memory,
    /// as opposed to the compressed file's size.
    nonisolated var decodedByteCount: Int {
        guard let cgImage else { return 0 }
        return max(1, cgImage.bytesPerRow * cgImage.height)
    }
}

struct LocalFileImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var maxPixel: CGFloat = 1600
    @State private var image: UIImage?

    init(url: URL, contentMode: ContentMode = .fill, maxPixel: CGFloat = 1600) {
        self.url = url
        self.contentMode = contentMode
        self.maxPixel = maxPixel
        // Seeded rather than left nil so a cached image renders immediately.
        // `.task` cannot run before the first frame, so without this an image
        // the loader already holds still costs a frame of placeholder.
        _image = State(initialValue: LocalImageLoader.shared.cachedImage(at: url, maxPixel: maxPixel))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    Theme.Colors.mist
                    ProgressView().tint(Theme.Colors.denim)
                }
            }
        }
        .task(id: url) {
            image = await LocalImageLoader.shared.image(at: url, maxPixel: maxPixel)
        }
    }
}
