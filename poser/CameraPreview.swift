import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let normalizedGuideRect: CGRect
    @Binding var normalizedPhotoCrop: NormalizedCrop

    init(
        session: AVCaptureSession,
        normalizedGuideRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        normalizedPhotoCrop: Binding<NormalizedCrop> = .constant(.full)
    ) {
        self.session = session
        self.normalizedGuideRect = normalizedGuideRect
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
        uiView.normalizedGuideRect = normalizedGuideRect
        uiView.onCropChange = context.coordinator.updateCrop
        uiView.setNeedsLayout()
        uiView.updatePhotoCrop()
    }

    final class Coordinator {
        private var normalizedPhotoCrop: Binding<NormalizedCrop>

        init(normalizedPhotoCrop: Binding<NormalizedCrop>) {
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
    var normalizedGuideRect = CGRect(x: 0, y: 0, width: 1, height: 1)
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

    func updatePhotoCrop() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layerRect = CGRect(
            x: normalizedGuideRect.minX * bounds.width,
            y: normalizedGuideRect.minY * bounds.height,
            width: normalizedGuideRect.width * bounds.width,
            height: normalizedGuideRect.height * bounds.height
        )
        let converted = previewLayer.metadataOutputRectConverted(fromLayerRect: layerRect)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !converted.isNull, !converted.isEmpty else { return }
        onCropChange?(NormalizedCrop(
            x: converted.minX,
            y: converted.minY,
            width: converted.width,
            height: converted.height
        ))
    }
}
