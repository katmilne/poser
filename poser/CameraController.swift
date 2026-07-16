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

    var symbol: String {
        switch self {
        case .off: "bolt.slash.fill"
        case .auto: "bolt.badge.a.fill"
        case .on: "bolt.fill"
        }
    }
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

    /// Tracks configuration here rather than reading `session.inputs`: the
    /// session is only ever touched on `sessionQueue`, so inspecting it from the
    /// main actor would race with the configuration it is meant to guard.
    @ObservationIgnored private var isConfigured = false
    @ObservationIgnored private var configuration: Task<Void, Error>?

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
            try await configureSessionIfNeeded()
            configurationErrorMessage = nil
            startSession()
        } catch {
            configurationErrorMessage = error.localizedDescription
        }
#endif
    }

    /// Configuration is now awaited rather than run inline, so leaving and
    /// re-entering the camera screen quickly can start a second attempt while
    /// the first is still in flight. Both would add the same inputs and outputs
    /// and the session would refuse them, so overlapping callers share one
    /// attempt. A failed attempt is discarded rather than cached: the next start
    /// should get a real retry.
    private func configureSessionIfNeeded() async throws {
        if let configuration { return try await configuration.value }

        let task = Task { try await configureSession() }
        configuration = task
        do {
            try await task.value
            isConfigured = true
        } catch {
            configuration = nil
            throw error
        }
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
        guard !isSwitching, isConfigured else { return }
        isSwitching = true
        hasProducedFrame = false
        defer { isSwitching = false }

        let next: CameraFacing = facing == .back ? .front : .back
        frameDelegate?.reset()

        // Swapping the input is the same slow AVFoundation work as the initial
        // configuration, so it belongs on the capture queue too — on the main
        // actor it stalls the whole screen mid-flip.
        try await onSessionQueue { [session, videoOutput] in
            guard let device = Self.cameraDevice(for: next) else { throw CameraError.unavailable }
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            let previous = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
            if let previous { session.removeInput(previous) }
            guard session.canAddInput(input) else {
                if let previous, session.canAddInput(previous) { session.addInput(previous) }
                session.commitConfiguration()
                throw CameraError.configurationFailed
            }
            session.addInput(input)
            Self.configureConnections(on: videoOutput, facing: next)
            session.commitConfiguration()
        }
        facing = next
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

    /// Building the session is slow — device discovery, opening the input, and
    /// committing the configuration together cost hundreds of milliseconds on a
    /// real phone — so none of it may happen on the main actor. It used to, and
    /// that is precisely why the camera screen arrived frozen: every control was
    /// unresponsive until AVFoundation was finished. All session mutation now
    /// happens on `sessionQueue` and the main actor only awaits the outcome.
    private func configureSession() async throws {
        let owner = WeakCameraBox(self)
        let delegate = FirstFrameDelegate {
            Task { @MainActor in owner.value?.hasProducedFrame = true }
        }
        frameDelegate = delegate

        let facing = facing
        try await onSessionQueue { [session, photoOutput, videoOutput, sessionQueue] in
            guard let device = Self.cameraDevice(for: facing) else { throw CameraError.unavailable }
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
            videoOutput.setSampleBufferDelegate(delegate, queue: sessionQueue)
            Self.configureConnections(on: videoOutput, facing: facing)
            session.commitConfiguration()
        }
    }

    /// Hands `work` to the capture queue and resumes the caller with its result,
    /// so callers can await session work without blocking the main actor.
    private func onSessionQueue<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let queue = sessionQueue
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private nonisolated static func configureConnections(
        on videoOutput: AVCaptureVideoDataOutput,
        facing: CameraFacing
    ) {
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

    private nonisolated static func cameraDevice(for facing: CameraFacing) -> AVCaptureDevice? {
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
