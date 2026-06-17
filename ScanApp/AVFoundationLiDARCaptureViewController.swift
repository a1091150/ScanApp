//
//  AVFoundationLiDARCaptureViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import AVFoundation
import CoreImage
import CoreMotion
import UIKit

final class AVFoundationLiDARCaptureViewController: UIViewController {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dokidoki.ScanApp.avFoundationSession")
    private let dataOutputQueue = DispatchQueue(label: "dokidoki.ScanApp.avFoundationDataOutput")
    private let writerQueue = DispatchQueue(label: "dokidoki.ScanApp.avFoundationWriter", qos: .utility)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private let previewView = UIView()
    private let statusPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statusStack = UIStackView()
    private let startStopButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let supportLabel = UILabel()
    private let captureLabel = UILabel()
    private let depthLabel = UILabel()
    private let motionLabel = UILabel()
    private let decisionLabel = UILabel()
    private let motionManager = CMMotionManager()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private var canCapture = false
    private var isConfigured = false
    private var isCapturing = false
    private var sessionDirectory: URL?
    private var imageDirectory: URL?
    private var metadataDirectory: URL?
    private var depthDirectory: URL?
    private var frameIndex = 0
    private var savedFrameCount = 0
    private var savedDepthCount = 0
    private var pendingWriteCount = 0
    private var lastSavedTimestamp: TimeInterval?
    private var lastDecision = "Capture idle"
    private var supportStatus = "Checking LiDAR camera"
    private var depthStatus = "Depth: unavailable"
    private var lastMotion = AVFoundationCaptureMotion()

    private let minCaptureInterval: TimeInterval = 0.45
    private let maxAccelerationMagnitude: Double = 0.45
    private let maxAngularVelocity: Double = 0.9
    private let maxPendingWrites = 2
    private let jpegCompressionQuality: CGFloat = 0.92

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "AVFoundation LiDAR"
        view.backgroundColor = .black
        configurePreview()
        configureUI()
        configureNavigation()
        configureSessionAsync()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewView.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func configurePreview() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        previewView.layer.addSublayer(layer)
        previewLayer = layer
        setLandscapeRightOrientation(on: layer.connection)
    }

    private func configureUI() {
        startStopButton.setTitle("Start Capture", for: .normal)
        startStopButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startStopButton.tintColor = .white
        startStopButton.backgroundColor = .systemGreen
        startStopButton.layer.cornerRadius = 8
        startStopButton.addTarget(self, action: #selector(toggleCapture), for: .touchUpInside)

        resetButton.setTitle("Reset", for: .normal)
        resetButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        resetButton.tintColor = .white
        resetButton.backgroundColor = .systemOrange
        resetButton.layer.cornerRadius = 8
        resetButton.addTarget(self, action: #selector(resetCapture), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [startStopButton, resetButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.layer.cornerRadius = 8
        statusPanel.layer.masksToBounds = true
        statusStack.axis = .vertical
        statusStack.spacing = 4
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        [supportLabel, captureLabel, depthLabel, motionLabel, decisionLabel].forEach(configureStatusLabel(_:))

        view.addSubview(statusPanel)
        statusPanel.contentView.addSubview(statusStack)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 48),

            statusPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            statusPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            statusStack.leadingAnchor.constraint(equalTo: statusPanel.contentView.leadingAnchor, constant: 12),
            statusStack.trailingAnchor.constraint(equalTo: statusPanel.contentView.trailingAnchor, constant: -12),
            statusStack.topAnchor.constraint(equalTo: statusPanel.contentView.topAnchor, constant: 10),
            statusStack.bottomAnchor.constraint(equalTo: statusPanel.contentView.bottomAnchor, constant: -10)
        ])

        updateStatus()
    }

    private func configureStatusLabel(_ label: UILabel) {
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        statusStack.addArrangedSubview(label)
    }

    private func configureNavigation() {
        if navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeCapture)
            )
        }
    }

    private func configureSessionAsync() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            DispatchQueue.main.async {
                self.canCapture = false
                self.supportStatus = "Unsupported: LiDAR depth camera unavailable"
                self.updateStatus()
            }
            return
        }

        do {
            captureSession.beginConfiguration()
            captureSession.sessionPreset = .inputPriority

            try configureDepthFormat(for: device)

            let input = try AVCaptureDeviceInput(device: device)
            guard captureSession.canAddInput(input) else {
                throw AVFoundationLiDARCaptureError.cannotAddCameraInput
            }
            captureSession.addInput(input)

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            guard captureSession.canAddOutput(videoOutput) else {
                throw AVFoundationLiDARCaptureError.cannotAddVideoOutput
            }
            captureSession.addOutput(videoOutput)
            setLandscapeRightOrientation(on: videoOutput.connection(with: .video))

            depthOutput.isFilteringEnabled = true
            guard captureSession.canAddOutput(depthOutput) else {
                throw AVFoundationLiDARCaptureError.cannotAddDepthOutput
            }
            captureSession.addOutput(depthOutput)
            setLandscapeRightOrientation(on: depthOutput.connection(with: .depthData))

            let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            synchronizer.setDelegate(self, queue: dataOutputQueue)
            self.synchronizer = synchronizer

            captureSession.commitConfiguration()
            isConfigured = true

            DispatchQueue.main.async {
                self.canCapture = true
                self.supportStatus = "Supported: AVFoundation LiDAR depth camera"
                self.updateStatus()
            }
        } catch {
            captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.canCapture = false
                self.supportStatus = "Session setup failed: \(error.localizedDescription)"
                self.updateStatus()
            }
        }
    }

    private func configureDepthFormat(for device: AVCaptureDevice) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let supportedFormats = device.activeFormat.supportedDepthDataFormats
        if let depthFormat = supportedFormats
            .filter({ CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32 })
            .max(by: { depthFormatArea($0) < depthFormatArea($1) }) {
            device.activeDepthDataFormat = depthFormat
        }
    }

    private func depthFormatArea(_ format: AVCaptureDevice.Format) -> Int32 {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return dimensions.width * dimensions.height
    }

    @objc private func toggleCapture() {
        isCapturing ? stopCapture() : startCapture()
    }

    @objc private func resetCapture() {
        stopCapture()
        frameIndex = 0
        savedFrameCount = 0
        savedDepthCount = 0
        pendingWriteCount = 0
        lastSavedTimestamp = nil
        sessionDirectory = nil
        imageDirectory = nil
        metadataDirectory = nil
        depthDirectory = nil
        depthStatus = "Depth: unavailable"
        lastDecision = "Capture reset"
        updateStatus()
    }

    @objc private func closeCapture() {
        dismiss(animated: true)
    }

    private func startCapture() {
        guard canCapture else {
            showAlert(title: "LiDAR Unavailable", message: supportStatus)
            return
        }

        do {
            let directory = try makeCaptureDirectory()
            sessionDirectory = directory
            imageDirectory = directory.appendingPathComponent("images", isDirectory: true)
            metadataDirectory = directory.appendingPathComponent("metadata", isDirectory: true)
            depthDirectory = directory.appendingPathComponent("depth", isDirectory: true)
            try FileManager.default.createDirectory(at: imageDirectory!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataDirectory!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: depthDirectory!, withIntermediateDirectories: true)
            try writeSessionMetadata(to: directory)

            frameIndex = 0
            savedFrameCount = 0
            savedDepthCount = 0
            pendingWriteCount = 0
            lastSavedTimestamp = nil
            isCapturing = true
            lastDecision = "Capture started"
            startMotionUpdates()
            hapticGenerator.prepare()
            updateStatus()

            sessionQueue.async { [captureSession] in
                if !captureSession.isRunning {
                    captureSession.startRunning()
                }
            }
        } catch {
            showAlert(title: "Capture Start Failed", message: error.localizedDescription)
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }
        isCapturing = false
        lastDecision = "Capture stopped"
        motionManager.stopDeviceMotionUpdates()
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
        updateStatus()
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates()
    }

    private func makeCaptureDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documentsDirectory
            .appendingPathComponent("AVFoundationLiDARCaptures", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSessionMetadata(to directory: URL) throws {
        let metadata: [String: Any] = [
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "capture_method": "AVFoundation LiDAR depth camera",
            "motion_source": "CoreMotion deviceMotion",
            "depth_format": "float32_little_endian",
            "dataset_layout": [
                "images": "images/frame_000001.jpg",
                "metadata": "metadata/frame_000001.json",
                "depth": "depth/frame_000001_depth_f32.bin"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func processFrame(pixelBuffer: CVPixelBuffer, depthData: AVDepthData, timestamp: TimeInterval) {
        frameIndex += 1

        let convertedDepthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = convertedDepthData.depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        depthStatus = "Depth: \(depthWidth) x \(depthHeight)"
        lastMotion = currentMotion()

        guard isCapturing else {
            updateStatus()
            return
        }

        let decision = shouldCapture(timestamp: timestamp, motion: lastMotion)
        guard decision.shouldCapture else {
            lastDecision = decision.reason
            updateStatus()
            return
        }

        guard pendingWriteCount < maxPendingWrites else {
            lastDecision = "Skipped: writer queue busy"
            updateStatus()
            return
        }

        guard let imageDirectory, let metadataDirectory, let depthDirectory else {
            lastDecision = "Skipped: missing output directory"
            updateStatus()
            return
        }

        let frameName = String(format: "frame_%06d", frameIndex)
        let imageURL = imageDirectory.appendingPathComponent("\(frameName).jpg")
        let metadataURL = metadataDirectory.appendingPathComponent("\(frameName).json")
        let depthURL = depthDirectory.appendingPathComponent("\(frameName)_depth_f32.bin")
        let calibration = convertedDepthData.cameraCalibrationData
        let snapshot = AVFoundationCaptureSnapshot(
            pixelBuffer: pixelBuffer,
            depthMap: depthMap,
            imageURL: imageURL,
            imageRelativePath: "images/\(frameName).jpg",
            metadataURL: metadataURL,
            metadataRelativePath: "metadata/\(frameName).json",
            depthURL: depthURL,
            depthRelativePath: "depth/\(frameName)_depth_f32.bin",
            frameIndex: frameIndex,
            frameName: frameName,
            timestamp: timestamp,
            imageWidth: CVPixelBufferGetWidth(pixelBuffer),
            imageHeight: CVPixelBufferGetHeight(pixelBuffer),
            depthWidth: depthWidth,
            depthHeight: depthHeight,
            depthAccuracy: String(describing: convertedDepthData.depthDataAccuracy),
            depthQuality: String(describing: convertedDepthData.depthDataQuality),
            isDepthFiltered: convertedDepthData.isDepthDataFiltered,
            calibration: calibration,
            motion: lastMotion
        )

        pendingWriteCount += 1
        lastSavedTimestamp = timestamp
        lastDecision = "Queued \(frameName)"
        updateStatus()
        enqueueWrite(snapshot)
    }

    private func shouldCapture(timestamp: TimeInterval, motion: AVFoundationCaptureMotion) -> (shouldCapture: Bool, reason: String) {
        if savedFrameCount == 0 && pendingWriteCount == 0 {
            return (true, "Capture: first frame")
        }

        if let lastSavedTimestamp, timestamp - lastSavedTimestamp < minCaptureInterval {
            return (false, "Skipped: waiting for interval")
        }

        if motion.accelerationMagnitude > maxAccelerationMagnitude {
            return (false, String(format: "Skipped: accel %.2f", motion.accelerationMagnitude))
        }

        if motion.angularVelocity > maxAngularVelocity {
            return (false, String(format: "Skipped: angular %.2f", motion.angularVelocity))
        }

        return (true, "Capture: depth frame")
    }

    private func currentMotion() -> AVFoundationCaptureMotion {
        guard let motion = motionManager.deviceMotion else {
            return AVFoundationCaptureMotion()
        }

        let acceleration = motion.userAcceleration
        let rotationRate = motion.rotationRate
        let accelerationMagnitude = sqrt(
            acceleration.x * acceleration.x +
            acceleration.y * acceleration.y +
            acceleration.z * acceleration.z
        )
        let angularVelocity = sqrt(
            rotationRate.x * rotationRate.x +
            rotationRate.y * rotationRate.y +
            rotationRate.z * rotationRate.z
        )
        let accelerationScore = max(0, 1 - accelerationMagnitude / maxAccelerationMagnitude)
        let angularScore = max(0, 1 - angularVelocity / maxAngularVelocity)

        return AVFoundationCaptureMotion(
            acceleration: [acceleration.x, acceleration.y, acceleration.z],
            rotationRate: [rotationRate.x, rotationRate.y, rotationRate.z],
            accelerationMagnitude: accelerationMagnitude,
            angularVelocity: angularVelocity,
            motionQuality: min(accelerationScore, angularScore)
        )
    }

    private func enqueueWrite(_ snapshot: AVFoundationCaptureSnapshot) {
        writerQueue.async { [weak self] in
            let result = Result<Void, Error> {
                try self?.write(snapshot)
            }

            DispatchQueue.main.async {
                self?.finishWrite(result, frameName: snapshot.frameName)
            }
        }
    }

    private func write(_ snapshot: AVFoundationCaptureSnapshot) throws {
        let image = CIImage(cvPixelBuffer: snapshot.pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try ciContext.writeJPEGRepresentation(
            of: image,
            to: snapshot.imageURL,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegCompressionQuality]
        )

        try writeFloat32PixelBuffer(snapshot.depthMap, to: snapshot.depthURL)

        let metadataData = try JSONSerialization.data(
            withJSONObject: makeMetadata(from: snapshot),
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(to: snapshot.metadataURL, options: .atomic)
    }

    private func makeMetadata(from snapshot: AVFoundationCaptureSnapshot) -> [String: Any] {
        var metadata: [String: Any] = [
            "frame_index": snapshot.frameIndex,
            "frame_name": snapshot.frameName,
            "time": snapshot.timestamp,
            "image": snapshot.imageRelativePath,
            "metadata": snapshot.metadataRelativePath,
            "capture_method": "AVFoundation",
            "image_orientation": "landscapeRight",
            "width": snapshot.imageWidth,
            "height": snapshot.imageHeight,
            "depth": [
                "format": "float32_little_endian",
                "path": snapshot.depthRelativePath,
                "width": snapshot.depthWidth,
                "height": snapshot.depthHeight,
                "bytes_per_value": MemoryLayout<Float>.size,
                "accuracy": snapshot.depthAccuracy,
                "quality": snapshot.depthQuality,
                "filtered": snapshot.isDepthFiltered
            ],
            "userAcceleration": snapshot.motion.acceleration,
            "rotationRate": snapshot.motion.rotationRate,
            "accelerationMagnitude": snapshot.motion.accelerationMagnitude,
            "angularVelocity": snapshot.motion.angularVelocity,
            "motionQuality": snapshot.motion.motionQuality
        ]

        if let calibration = snapshot.calibration {
            let dimensions = calibration.intrinsicMatrixReferenceDimensions
            metadata["intrinsics"] = flatten3x3(calibration.intrinsicMatrix)
            metadata["intrinsicReferenceDimensions"] = [
                "width": dimensions.width,
                "height": dimensions.height
            ]
        }

        return metadata
    }

    private func finishWrite(_ result: Result<Void, Error>, frameName: String) {
        pendingWriteCount = max(0, pendingWriteCount - 1)

        switch result {
        case .success:
            savedFrameCount += 1
            savedDepthCount += 1
            lastDecision = "Saved \(frameName)"
            hapticGenerator.impactOccurred(intensity: 0.45)
            hapticGenerator.prepare()
        case .failure(let error):
            lastDecision = "Save failed: \(error.localizedDescription)"
        }

        updateStatus()
    }

    private func updateStatus() {
        startStopButton.setTitle(isCapturing ? "Stop Capture" : "Start Capture", for: .normal)
        startStopButton.backgroundColor = isCapturing ? .systemRed : .systemGreen
        startStopButton.isEnabled = canCapture
        startStopButton.alpha = canCapture ? 1 : 0.55

        supportLabel.text = "Support: \(supportStatus)"
        captureLabel.text = "Saved images/depth: \(savedFrameCount) / \(savedDepthCount)"
        depthLabel.text = depthStatus
        motionLabel.text = String(
            format: "Motion: accel %.2f g angular %.2f rad/s quality %.2f",
            lastMotion.accelerationMagnitude,
            lastMotion.angularVelocity,
            lastMotion.motionQuality
        )
        decisionLabel.text = "Capture: \(lastDecision)"
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension AVFoundationLiDARCaptureViewController: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard let videoData = synchronizedDataCollection.synchronizedData(for: videoOutput)
            as? AVCaptureSynchronizedSampleBufferData,
              let depthData = synchronizedDataCollection.synchronizedData(for: depthOutput)
            as? AVCaptureSynchronizedDepthData,
              !videoData.sampleBufferWasDropped,
              !depthData.depthDataWasDropped,
              let pixelBuffer = CMSampleBufferGetImageBuffer(videoData.sampleBuffer) else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoData.sampleBuffer).seconds
        let avDepthData = depthData.depthData

        DispatchQueue.main.async { [weak self] in
            self?.processFrame(pixelBuffer: pixelBuffer, depthData: avDepthData, timestamp: timestamp)
        }
    }
}

private struct AVFoundationCaptureSnapshot {
    let pixelBuffer: CVPixelBuffer
    let depthMap: CVPixelBuffer
    let imageURL: URL
    let imageRelativePath: String
    let metadataURL: URL
    let metadataRelativePath: String
    let depthURL: URL
    let depthRelativePath: String
    let frameIndex: Int
    let frameName: String
    let timestamp: TimeInterval
    let imageWidth: Int
    let imageHeight: Int
    let depthWidth: Int
    let depthHeight: Int
    let depthAccuracy: String
    let depthQuality: String
    let isDepthFiltered: Bool
    let calibration: AVCameraCalibrationData?
    let motion: AVFoundationCaptureMotion
}

private struct AVFoundationCaptureMotion {
    let acceleration: [Double]
    let rotationRate: [Double]
    let accelerationMagnitude: Double
    let angularVelocity: Double
    let motionQuality: Double

    init(
        acceleration: [Double] = [0, 0, 0],
        rotationRate: [Double] = [0, 0, 0],
        accelerationMagnitude: Double = 0,
        angularVelocity: Double = 0,
        motionQuality: Double = 1
    ) {
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.accelerationMagnitude = accelerationMagnitude
        self.angularVelocity = angularVelocity
        self.motionQuality = motionQuality
    }
}

private enum AVFoundationLiDARCaptureError: LocalizedError {
    case cannotAddCameraInput
    case cannotAddVideoOutput
    case cannotAddDepthOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddCameraInput:
            return "Could not add the LiDAR camera input."
        case .cannotAddVideoOutput:
            return "Could not add the video data output."
        case .cannotAddDepthOutput:
            return "Could not add the depth data output."
        }
    }
}

private func setLandscapeRightOrientation(on connection: AVCaptureConnection?) {
    guard let connection, connection.isVideoOrientationSupported else { return }
    connection.videoOrientation = .landscapeRight
}

private func flatten3x3(_ matrix: simd_float3x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2]
    ]
}
