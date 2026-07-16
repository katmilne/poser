import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// The capture frame as measured by the overlay that draws it. The preview
    /// crops to this rather than recomputing the frame from its own bounds, so
    /// the photo is guaranteed to be what the brackets showed.
    let captureFrameInWindow: CGRect
    @Binding var normalizedPhotoCrop: NormalizedCrop?

    init(
        session: AVCaptureSession,
        captureFrameInWindow: CGRect = .zero,
        normalizedPhotoCrop: Binding<NormalizedCrop?> = .constant(nil)
    ) {
        self.session = session
        self.captureFrameInWindow = captureFrameInWindow
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
    var onCropChange: ((NormalizedCrop) -> Void)?

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
        backgroundColor = .clear
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    func configure(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        // Attaching or reconfiguring an AVCaptureSession can update the
        // preview connection after this view is created. Reassert aspect-fill
        // so the 4:3 sensor feed always crops to the full phone screen.
        previewLayer.videoGravity = .resizeAspectFill
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The window rect handed in by the overlay only means something once
        // this view is in a window to convert it against.
        updatePhotoCrop()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        updatePhotoCrop()
    }

    /// Reports the region of the photo behind the capture frame, so the saved
    /// image is exactly the rect the brackets drew.
    ///
    /// The frame is converted from the overlay's window coordinates rather than
    /// recomputed here: one measured rect, no second definition to drift from
    /// the first.
    func updatePhotoCrop() {
        guard bounds.width > 0, bounds.height > 0, window != nil else { return }
        let layerRect = convert(captureFrameInWindow, from: nil)
        guard let crop = CaptureFrameMetrics.photoCrop(for: layerRect, in: bounds.size) else { return }
        onCropChange?(crop)
    }
}
