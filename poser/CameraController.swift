@preconcurrency import AVFoundation
import Observation
import UIKit

enum FlashSetting: String, CaseIterable {
    case off
    case auto
    case on

    var next: FlashSetting {
        switch self {
        case .off: .auto
        case .auto: .on
        case .on: .off
        }
    }

    var symbol: String { self == .off ? "bolt.slash" : "bolt" }
}

@MainActor
@Observable
final class CameraController {
    enum CameraError: LocalizedError {
        case denied
        case unavailable
        case configurationFailed
        case captureFailed
        case noPhotoData

        var errorDescription: String? {
            switch self {
            case .denied: "Camera access is turned off."
            case .unavailable: "This camera isn't available right now."
            case .configurationFailed: "POSER couldn't start the camera."
            case .captureFailed: "The camera couldn't take that photo."
            case .noPhotoData: "The camera returned an empty photo."
            }
        }
    }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "space.concurrent.poser.camera", qos: .userInitiated)
    @ObservationIgnored private var frameDelegate: FirstFrameDelegate?
    @ObservationIgnored private var photoDelegate: PhotoDelegate?

    private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var isRunning = false
    private(set) var hasProducedFrame = false
    private(set) var isSwitching = false
    private(set) var facing: CameraFacing = .back
    private(set) var configurationErrorMessage: String?
    var flash: FlashSetting = .off

    var isReady: Bool { isRunning && hasProducedFrame && !isSwitching }

    func requestAccessAndStart() async {
#if targetEnvironment(simulator)
        // iOS Simulator has no camera capture source. Avoid asking AVFoundation
        // to discover one, which otherwise emits FigCaptureSourceRemote
        // assertions even though the unavailable-camera state is expected.
        authorizationStatus = .authorized
        configurationErrorMessage = CameraError.unavailable.localizedDescription
        return
#else
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            granted = false
        }
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard granted else { return }

        do {
            if session.inputs.isEmpty { try configureSession() }
            configurationErrorMessage = nil
            startSession()
        } catch {
            configurationErrorMessage = error.localizedDescription
        }
#endif
    }

    func stop() {
        let session = session
        sessionQueue.async { session.stopRunning() }
        isRunning = false
        hasProducedFrame = false
    }

    func switchCamera() async throws {
#if targetEnvironment(simulator)
        throw CameraError.unavailable
#else
        guard !isSwitching else { return }
        isSwitching = true
        hasProducedFrame = false
        defer { isSwitching = false }

        let next: CameraFacing = facing == .back ? .front : .back
        guard let device = cameraDevice(for: next) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        frameDelegate?.reset()

        session.beginConfiguration()
        let previous = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
        if let previous { session.removeInput(previous) }
        if session.canAddInput(input) {
            session.addInput(input)
            facing = next
        } else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }
        configureConnections()
        session.commitConfiguration()
#endif
    }

    func capturePhoto() async throws -> Data {
        guard isReady else { throw CameraError.captureFailed }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .quality
        if photoOutput.supportedFlashModes.contains(flash.avMode) {
            settings.flashMode = flash.avMode
        }

        return try await withCheckedThrowingContinuation { continuation in
            let owner = WeakCameraBox(self)
            let delegate = PhotoDelegate { result in
                Task { @MainActor in
                    owner.value?.photoDelegate = nil
                    continuation.resume(with: result)
                }
            }
            photoDelegate = delegate
            if let connection = photoOutput.connection(with: .video) {
                connection.videoRotationAngle = 90
                connection.isVideoMirrored = facing == .front
            }
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private func configureSession() throws {
        guard let device = cameraDevice(for: facing) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        session.addOutput(videoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        videoOutput.alwaysDiscardsLateVideoFrames = true

        let owner = WeakCameraBox(self)
        let delegate = FirstFrameDelegate {
            Task { @MainActor in owner.value?.hasProducedFrame = true }
        }
        frameDelegate = delegate
        videoOutput.setSampleBufferDelegate(delegate, queue: sessionQueue)
        configureConnections()
        session.commitConfiguration()
    }

    private func configureConnections() {
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = facing == .front
        }
    }

    private func startSession() {
        let session = session
        let owner = WeakCameraBox(self)
        sessionQueue.async {
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in owner.value?.isRunning = session.isRunning }
        }
    }

    private func cameraDevice(for facing: CameraFacing) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = facing == .front ? .front : .back
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first
    }
}

private extension FlashSetting {
    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: .off
        case .auto: .auto
        case .on: .on
        }
    }
}

private nonisolated final class FirstFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onFirstFrame: @Sendable () -> Void
    private var didFire = false
    private let lock = NSLock()

    init(onFirstFrame: @escaping @Sendable () -> Void) {
        self.onFirstFrame = onFirstFrame
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFire else { return }
        didFire = true
        onFirstFrame()
    }

    func reset() {
        lock.lock()
        didFire = false
        lock.unlock()
    }
}

private nonisolated final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            completion(.failure(error))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CameraController.CameraError.noPhotoData))
        }
    }
}

private nonisolated final class WeakCameraBox: @unchecked Sendable {
    weak var value: CameraController?

    init(_ value: CameraController) {
        self.value = value
    }
}
