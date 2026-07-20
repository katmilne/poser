import ImageIO
import SwiftUI
import UIKit

/// An async semaphore. `DispatchSemaphore` cannot be used from async code -
/// blocking a cooperative-pool thread risks deadlocking the pool - so waiters
/// suspend on a continuation and are resumed in FIFO order as slots free up.
private actor DecodeGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// Runs `work` with a slot held.
    ///
    /// `nonisolated` on purpose. An actor-isolated version would run `work` on
    /// this actor's executor, which would serialize every decode behind every
    /// other one and block the gate's own bookkeeping while it ran - a limit of
    /// four that behaves like a limit of one. Nonisolated, only `acquire` and
    /// `release` touch the actor, and the decode stays on the pool thread the
    /// caller was already running on.
    ///
    /// `work` is synchronous and non-throwing, so the slot has exactly one
    /// release path and needs no `defer` to guarantee it.
    nonisolated func withSlot<T: Sendable>(_ work: @Sendable () -> T) async -> T {
        await acquire()
        let value = work()
        await release()
        return value
    }

    private func acquire() async {
        guard active >= limit else {
            active += 1
            return
        }
        // Resuming this continuation *is* the slot being handed over, so
        // nothing is incremented on the way out - `release` never gave the
        // slot up. Counting it again here would let a caller arriving in the
        // gap between resume and wake-up claim a slot that is already spoken
        // for, and the limit would drift upward under exactly the load it
        // exists to cap.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Decodes and caches downsampled copies of images stored on disk.
///
/// Deliberately *not* an actor. The work here is CPU-bound decoding, and an
/// actor has one executor: every thumbnail would queue behind every other one,
/// so the pose strip filled in a frame at a time and a single full-size pose
/// guide held up all the little ones behind it. `NSCache` is already
/// thread-safe, so requests run concurrently and only the cache is shared.
/// Concurrency is bounded by `DecodeGate` rather than by an executor, so the
/// ceiling is a number that can be tuned instead of an accident of isolation.
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

    /// Caps how many decodes may run at once. Overlays are stored at up to
    /// 2048px, so a single downsample is tens of milliseconds of CPU - enough
    /// that letting one land on every core starves the main thread and the
    /// scroll stutters. Leaving two cores free keeps the decodes off the
    /// critical path instead of racing it.
    private static let gate = DecodeGate(
        limit: max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    )

    func image(at url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let cached = cachedImage(at: url, maxPixel: maxPixel) { return cached }
        // Detached because `SWIFT_APPROACHABLE_CONCURRENCY` makes a plain
        // `nonisolated async` function run on the caller's executor - which is
        // the main actor here, exactly where this work must not go.
        //
        // Priority is `.utility`, not `.userInitiated`: a thumbnail that is
        // still a placeholder for one more frame is invisible next to a scroll
        // that drops frames, so this must lose to the main thread, not tie
        // with it.
        // Captures `self`, not `cache`: the loader is `@unchecked Sendable` on
        // the strength of `NSCache` being thread-safe, whereas `NSCache` itself
        // is not marked `Sendable` and capturing it directly warns today and
        // fails to compile under the Swift 6 language mode. The singleton
        // outlives every task here, so the capture costs nothing.
        let work = Task.detached(priority: .utility) { [self] () -> UIImage? in
            // Cancellation is checked on both sides of the gate. A tile can
            // scroll away while queued, and that is the common case during a
            // fast flick - the whole point is to not decode it.
            guard !Task.isCancelled else { return nil }
            return await Self.gate.withSlot {
                guard !Task.isCancelled else { return nil }
                guard let image = Self.decode(url: url, maxPixel: maxPixel) else { return nil }
                self.cache.setObject(
                    image,
                    forKey: Self.key(url: url, maxPixel: maxPixel),
                    cost: image.decodedByteCount
                )
                return image
            }
        }
        // `Task.detached` deliberately inherits nothing, cancellation included,
        // so without this bridge a tile scrolled past keeps decoding an image
        // nobody will see. Those orphans are what made the scroll drop frames
        // as it slowed: a flick queued dozens of them, and the backlog was
        // still burning CPU once the grid settled.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
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
