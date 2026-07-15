import ImageIO
import SwiftUI
import UIKit

actor LocalImageLoader {
    static let shared = LocalImageLoader()
    private let cache = NSCache<NSString, UIImage>()

    func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.path)-\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct LocalFileImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var maxPixel: CGFloat = 1600
    @State private var image: UIImage?

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
