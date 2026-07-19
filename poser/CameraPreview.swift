import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// The capture frame as measured by the overlay that draws it. The preview
    /// crops to this rather than recomputing the frame from its own bounds, so
    /// the photo is guaranteed to be what the brackets showed.
    let captureFrameInWindow: CGRect
    /// How far the viewfinder is zoomed out, 0…1. At 0 the feed fills the whole
    /// screen (the 1× hero); at 1 it shrinks to the 3:4 capture rect, revealing
    /// the full sensor with the cloud backdrop behind showing in the exposed area.
    let zoomOut: CGFloat
    /// Whether the camera is producing frames. The moment this turns true after a
    /// flip, the on-screen feed *is* the new camera, so it's the safe cue to
    /// adopt the new camera's rotation — doing it earlier would rotate the
    /// outgoing feed still visible during the swap.
    let isReady: Bool
    @Binding var normalizedPhotoCrop: NormalizedCrop?

    init(
        session: AVCaptureSession,
        captureFrameInWindow: CGRect = .zero,
        zoomOut: CGFloat = 0,
        isReady: Bool = false,
        normalizedPhotoCrop: Binding<NormalizedCrop?> = .constant(nil)
    ) {
        self.session = session
        self.captureFrameInWindow = captureFrameInWindow
        self.zoomOut = zoomOut
        self.isReady = isReady
        _normalizedPhotoCrop = normalizedPhotoCrop
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(normalizedPhotoCrop: $normalizedPhotoCrop)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.configure(session: session)
        view.onCropChange = context.coordinator.updateCrop
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.configure(session: session)
        uiView.onCropChange = context.coordinator.updateCrop
        uiView.captureFrameInWindow = captureFrameInWindow
        uiView.zoomOut = zoomOut
        uiView.updateReadiness(isReady)
        uiView.setNeedsLayout()
        uiView.updatePhotoCrop()
    }

    final class Coordinator {
        private var normalizedPhotoCrop: Binding<NormalizedCrop?>

        init(normalizedPhotoCrop: Binding<NormalizedCrop?>) {
            self.normalizedPhotoCrop = normalizedPhotoCrop
        }

        func updateCrop(_ crop: NormalizedCrop) {
            guard crop != normalizedPhotoCrop.wrappedValue else { return }
            DispatchQueue.main.async { [normalizedPhotoCrop] in
                normalizedPhotoCrop.wrappedValue = crop
            }
        }
    }
}

final class PreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var captureFrameInWindow = CGRect.zero
    var zoomOut: CGFloat = 0
    var onCropChange: ((NormalizedCrop) -> Void)?

    // Portrait orientation is per-camera: the front sensor's correct angle is
    // not the back's, so hard-coding 90° flipped the front feed every time it
    // was re-asserted (e.g. on a zoom change). The coordinator reports the right
    // angle for whichever device is live.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var rotationDevice: AVCaptureDevice?
    /// Latest readiness from the controller. Rotation is only ever touched while
    /// this is true: during a flip the outgoing feed is still on screen with the
    /// preview connection mid-swap, and re-aiming rotation then would turn it.
    private var cameraIsReady = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        installPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installPreviewLayer()
    }

    private func installPreviewLayer() {
        clipsToBounds = true
        // Transparent so the cloud backdrop placed behind this view shows through
        // the letterbox that opens up when the feed is zoomed out.
        backgroundColor = .clear
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.masksToBounds = true
        layer.addSublayer(previewLayer)
    }

    func configure(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        // Attaching or reconfiguring an AVCaptureSession can update the preview
        // connection after this view is created. Reassert aspect-fill so the
        // feed always covers its rendering rect (`feedRect`), whatever the zoom.
        previewLayer.videoGravity = .resizeAspectFill
        // Match rotation to the live camera. This no-ops until the camera is
        // ready, so it never re-aims the outgoing feed mid-flip; once ready it
        // runs on every reconfigure/layout and so reliably catches the new lens
        // however late the preview connection re-points at it.
        ensureRotation()
    }

    /// Rebuilds the rotation coordinator for whichever camera the preview
    /// connection now carries, then applies its angle. Only called once the
    /// camera is confirmed ready, so it never swaps the angle out from under the
    /// outgoing feed during a flip.
    private func refreshRotationCoordinator() {
        guard let device = videoInputDevice() else { return }
        guard device !== rotationDevice else {
            applyRotation()
            return
        }
        rotationDevice = device
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            self?.applyRotation()
        }
    }

    private func videoInputDevice() -> AVCaptureDevice? {
        let port = previewLayer.connection?.inputPorts.first { $0.mediaType == .video }
        return (port?.input as? AVCaptureDeviceInput)?.device
    }

    /// Called on every update with the camera's readiness. The false→true edge is
    /// the moment a (possibly just-flipped) camera starts producing frames, so
    /// the feed on screen is now this camera — the point at which adopting its
    /// rotation becomes safe. The follow-ups nudge the re-check in case the
    /// preview connection hasn't re-pointed at the new device yet; `ensureRotation`
    /// running from every later layout is what ultimately guarantees it lands.
    func updateReadiness(_ isReady: Bool) {
        let becameReady = isReady && !cameraIsReady
        cameraIsReady = isReady
        guard becameReady else { return }
        ensureRotation()
        for delay in [0.12, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.ensureRotation()
            }
        }
    }

    /// Matches the rotation coordinator to whichever camera is live and applies
    /// its angle — but only while ready, so the outgoing feed is never re-aimed
    /// during a flip. Because it also runs from `configure` and `layoutSubviews`,
    /// it re-checks repeatedly after a flip and reliably lands the new lens's
    /// angle even if the preview connection re-pointed later than the ready edge.
    private func ensureRotation() {
        guard cameraIsReady else { return }
        refreshRotationCoordinator()
    }

    /// Sets the preview to the coordinator's device-correct portrait angle. Safe
    /// to call repeatedly: it only writes when the angle actually differs, and
    /// the coordinator's angle is stable across zooms, so re-asserting it during
    /// a zoom no longer flips the feed.
    func applyRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        if connection.videoRotationAngle != angle {
            connection.videoRotationAngle = angle
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The window rect handed in by the overlay only means something once
        // this view is in a window to convert it against.
        ensureRotation()
        updatePhotoCrop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The feed rect tracks a live pinch, so update it without Core Animation's
        // implicit ~0.25s move — otherwise the feed lags behind the gesture.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = feedRect()
        previewLayer.videoGravity = .resizeAspectFill
        CATransaction.commit()
        ensureRotation()
        updatePhotoCrop()
    }

    /// The rect the live feed is drawn into. At `zoomOut == 0` this is the full
    /// view (the 1× full-screen camera); at `zoomOut == 1` it is the 3:4 capture
    /// rect, so the feed shrinks to show the whole sensor while the exposed area
    /// around it falls back to the cloud backdrop behind. Interpolating between the
    /// two keeps the 1× path pixel-identical to before.
    private func feedRect() -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let capture = captureFrameInWindow == .zero ? bounds : convert(captureFrameInWindow, from: nil)
        let t = max(0, min(1, zoomOut))
        return CGRect(
            x: bounds.minX + (capture.minX - bounds.minX) * t,
            y: bounds.minY + (capture.minY - bounds.minY) * t,
            width: bounds.width + (capture.width - bounds.width) * t,
            height: bounds.height + (capture.height - bounds.height) * t
        )
    }

    /// Reports the region of the photo behind the capture frame, so the saved
    /// image is exactly the rect the brackets drew.
    ///
    /// The frame is converted from the overlay's window coordinates and measured
    /// against the feed's actual rendering rect, so it stays correct as the feed
    /// shrinks on zoom-out: one measured rect, no second definition to drift.
    func updatePhotoCrop() {
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        let feed = feedRect()
        guard feed.width > 0, feed.height > 0 else { return }
        let capture = convert(captureFrameInWindow, from: nil)
        let frameInFeed = capture.offsetBy(dx: -feed.minX, dy: -feed.minY)
        guard let crop = CaptureFrameMetrics.photoCrop(for: frameInFeed, in: feed.size) else { return }
        onCropChange?(crop)
    }
}
