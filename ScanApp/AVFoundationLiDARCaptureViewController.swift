//
//  AVFoundationLiDARCaptureViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import AVFoundation
import CoreImage
import CoreMotion
import simd
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
    private let poseLabel = UILabel()
    private let decisionLabel = UILabel()
    private let motionManager = CMMotionManager()
    private let motionPoseEstimator = AVFoundationMotionPoseEstimator()
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
    private var calibrationDirectory: URL?
    private var frameIndex = 0
    private var savedFrameCount = 0
    private var savedDepthCount = 0
    private var pendingWriteCount = 0
    private var lastSavedTimestamp: TimeInterval?
    private var lastDecision = "Capture idle"
    private var supportStatus = "Checking LiDAR camera"
    private var depthStatus = "Depth: unavailable"
    private var lastMotion = AVFoundationCaptureMotion()
    private var motionReferenceFrameName = "unavailable"

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
        [supportLabel, captureLabel, depthLabel, motionLabel, poseLabel, decisionLabel].forEach(configureStatusLabel(_:))

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
            configureVideoConnection(videoOutput.connection(with: .video))

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
        calibrationDirectory = nil
        depthStatus = "Depth: unavailable"
        lastDecision = "Capture reset"
        motionPoseEstimator.reset()
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
            calibrationDirectory = directory.appendingPathComponent("calibration", isDirectory: true)
            motionReferenceFrameName = motionManager.isDeviceMotionAvailable
                ? motionReferenceFrameDisplayName(preferredMotionReferenceFrame())
                : "unavailable"
            try FileManager.default.createDirectory(at: imageDirectory!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataDirectory!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: depthDirectory!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: calibrationDirectory!, withIntermediateDirectories: true)
            try writeSessionMetadata(to: directory)

            frameIndex = 0
            savedFrameCount = 0
            savedDepthCount = 0
            pendingWriteCount = 0
            lastSavedTimestamp = nil
            isCapturing = true
            lastDecision = "Capture started"
            motionPoseEstimator.reset()
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
        let referenceFrame = preferredMotionReferenceFrame()
        motionReferenceFrameName = motionReferenceFrameDisplayName(referenceFrame)
        motionManager.startDeviceMotionUpdates(using: referenceFrame)
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
            "motion_reference_frame": motionReferenceFrameName,
            "pose_note": "AVFoundation calibration extrinsics are relative to the calibration reference camera, not an ARKit SLAM world. CoreMotion pose is experimental and drift-prone.",
            "depth_format": "float32_little_endian",
            "dataset_layout": [
                "images": "images/frame_000001.jpg",
                "metadata": "metadata/frame_000001.json",
                "depth": "depth/frame_000001_depth_f32.bin",
                "calibration": "calibration/frame_000001_lens_distortion_f32.bin"
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
        let calibration = makeCalibrationSnapshot(
            from: convertedDepthData.cameraCalibrationData,
            frameName: frameName
        )
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
            videoStabilizationMode: videoStabilizationModeName(videoOutput.connection(with: .video)?.activeVideoStabilizationMode),
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
        let gravity = motion.gravity
        let attitude = motion.attitude
        let quaternion = attitude.quaternion
        let rotationMatrix = flattenRotationMatrix(attitude.rotationMatrix)
        let experimentalPose = motionPoseEstimator.update(
            motion: motion,
            referenceFrameName: motionReferenceFrameName
        )
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
            gravity: [gravity.x, gravity.y, gravity.z],
            accelerationMagnitude: accelerationMagnitude,
            angularVelocity: angularVelocity,
            motionQuality: min(accelerationScore, angularScore),
            attitudeQuaternion: [quaternion.x, quaternion.y, quaternion.z, quaternion.w],
            attitudeRotationMatrix: rotationMatrix,
            attitudeReferenceFrame: motionReferenceFrameName,
            timestamp: motion.timestamp,
            experimentalPose: experimentalPose
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
        try writeCalibrationLookupTablesIfNeeded(snapshot.calibration)

        let metadataData = try JSONSerialization.data(
            withJSONObject: makeMetadata(from: snapshot),
            options: [.prettyPrinted, .sortedKeys]
        )
        try metadataData.write(to: snapshot.metadataURL, options: .atomic)
    }

    private func makeCalibrationSnapshot(
        from calibration: AVCameraCalibrationData?,
        frameName: String
    ) -> AVFoundationCalibrationSnapshot? {
        guard let calibration else { return nil }

        let dimensions = calibration.intrinsicMatrixReferenceDimensions
        let lensDistortionData = calibration.lensDistortionLookupTable.map { Data($0) }
        let inverseLensDistortionData = calibration.inverseLensDistortionLookupTable.map { Data($0) }
        let lensDistortionName = "\(frameName)_lens_distortion_f32.bin"
        let inverseLensDistortionName = "\(frameName)_inverse_lens_distortion_f32.bin"
        let lensDistortionURL = lensDistortionData == nil
            ? nil
            : calibrationDirectory?.appendingPathComponent(lensDistortionName)
        let inverseLensDistortionURL = inverseLensDistortionData == nil
            ? nil
            : calibrationDirectory?.appendingPathComponent(inverseLensDistortionName)

        return AVFoundationCalibrationSnapshot(
            intrinsics: flatten3x3(calibration.intrinsicMatrix),
            intrinsicReferenceWidth: Double(dimensions.width),
            intrinsicReferenceHeight: Double(dimensions.height),
            extrinsicMatrix3x4: flatten4x3(calibration.extrinsicMatrix),
            cameraToReferenceMeters: cameraToReference4x4Meters(calibration.extrinsicMatrix),
            pixelSizeMillimeters: calibration.pixelSize,
            lensDistortionCenter: [
                Double(calibration.lensDistortionCenter.x),
                Double(calibration.lensDistortionCenter.y)
            ],
            lensDistortionLookupTableURL: lensDistortionURL,
            lensDistortionLookupTableRelativePath: lensDistortionURL == nil
                ? nil
                : "calibration/\(lensDistortionName)",
            lensDistortionLookupTableData: lensDistortionData,
            inverseLensDistortionLookupTableURL: inverseLensDistortionURL,
            inverseLensDistortionLookupTableRelativePath: inverseLensDistortionURL == nil
                ? nil
                : "calibration/\(inverseLensDistortionName)",
            inverseLensDistortionLookupTableData: inverseLensDistortionData
        )
    }

    private func writeCalibrationLookupTablesIfNeeded(_ calibration: AVFoundationCalibrationSnapshot?) throws {
        guard let calibration else { return }
        if let url = calibration.lensDistortionLookupTableURL,
           let data = calibration.lensDistortionLookupTableData {
            try data.write(to: url, options: .atomic)
        }
        if let url = calibration.inverseLensDistortionLookupTableURL,
           let data = calibration.inverseLensDistortionLookupTableData {
            try data.write(to: url, options: .atomic)
        }
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
            "video_stabilization": [
                "active_mode": snapshot.videoStabilizationMode,
                "note": "Calibration intrinsics/extrinsics should be used with stabilization disabled."
            ],
            "userAcceleration": snapshot.motion.acceleration,
            "rotationRate": snapshot.motion.rotationRate,
            "gravity": snapshot.motion.gravity,
            "accelerationMagnitude": snapshot.motion.accelerationMagnitude,
            "angularVelocity": snapshot.motion.angularVelocity,
            "motionQuality": snapshot.motion.motionQuality,
            "motion_pose": motionPoseMetadata(from: snapshot.motion)
        ]

        if let calibration = snapshot.calibration {
            metadata["intrinsics"] = calibration.intrinsics
            metadata["intrinsicReferenceDimensions"] = [
                "width": calibration.intrinsicReferenceWidth,
                "height": calibration.intrinsicReferenceHeight
            ]
            var calibrationMetadata: [String: Any] = [
                "intrinsics": calibration.intrinsics,
                "intrinsic_reference_dimensions": [
                    "width": calibration.intrinsicReferenceWidth,
                    "height": calibration.intrinsicReferenceHeight
                ],
                "extrinsic_matrix_3x4": calibration.extrinsicMatrix3x4,
                "extrinsic_translation_unit": "millimeters",
                "extrinsic_semantics": "camera_to_calibration_reference_camera",
                "camera_to_reference_meters": calibration.cameraToReferenceMeters,
                "pixel_size_millimeters": calibration.pixelSizeMillimeters,
                "lens_distortion_center": calibration.lensDistortionCenter
            ]
            if let path = calibration.lensDistortionLookupTableRelativePath {
                calibrationMetadata["lens_distortion_lookup_table"] = [
                    "path": path,
                    "format": "float32_little_endian",
                    "value_count": calibration.lensDistortionLookupTableData.map { $0.count / MemoryLayout<Float>.size } ?? 0
                ]
            }
            if let path = calibration.inverseLensDistortionLookupTableRelativePath {
                calibrationMetadata["inverse_lens_distortion_lookup_table"] = [
                    "path": path,
                    "format": "float32_little_endian",
                    "value_count": calibration.inverseLensDistortionLookupTableData.map { $0.count / MemoryLayout<Float>.size } ?? 0
                ]
            }
            metadata["avfoundation_calibration"] = calibrationMetadata
        }

        return metadata
    }

    private func motionPoseMetadata(from motion: AVFoundationCaptureMotion) -> [String: Any] {
        var metadata: [String: Any] = [
            "source": "CoreMotion deviceMotion attitude",
            "reference_frame": motion.attitudeReferenceFrame,
            "quality": motion.hasAttitude
                ? "experimental_dead_reckoning_unbounded_drift"
                : "unavailable",
            "has_world_orientation": motion.hasAttitude,
            "has_metric_world_position": false,
            "attitude_quaternion_xyzw": motion.attitudeQuaternion,
            "attitude_rotation_matrix_3x3": motion.attitudeRotationMatrix,
            "note": "This is a CoreMotion-only dead-reckoning probe. It is useful for debugging orientation/relative drift, but is not an ARKit-quality SLAM world pose."
        ]

        if let timestamp = motion.timestamp {
            metadata["timestamp"] = timestamp
        }
        if let pose = motion.experimentalPose {
            metadata["experimental_position_meters"] = pose.positionMeters
            metadata["experimental_velocity_meters_per_second"] = pose.velocityMetersPerSecond
            metadata["experimental_device_to_motion_world"] = pose.deviceToMotionWorld
            metadata["experimental_motion_world_to_device"] = pose.motionWorldToDevice
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
        let poseDistance = lastMotion.experimentalPose?.positionMagnitudeMeters ?? 0
        poseLabel.text = String(
            format: "Pose: %@, drift probe %.3f m",
            lastMotion.hasAttitude ? lastMotion.attitudeReferenceFrame : "unavailable",
            poseDistance
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
    let videoStabilizationMode: String
    let calibration: AVFoundationCalibrationSnapshot?
    let motion: AVFoundationCaptureMotion
}

private struct AVFoundationCaptureMotion {
    let acceleration: [Double]
    let rotationRate: [Double]
    let gravity: [Double]
    let accelerationMagnitude: Double
    let angularVelocity: Double
    let motionQuality: Double
    let attitudeQuaternion: [Double]
    let attitudeRotationMatrix: [Double]
    let attitudeReferenceFrame: String
    let timestamp: TimeInterval?
    let experimentalPose: AVFoundationExperimentalPose?

    var hasAttitude: Bool {
        attitudeQuaternion.count == 4 && attitudeRotationMatrix.count == 9
    }

    init(
        acceleration: [Double] = [0, 0, 0],
        rotationRate: [Double] = [0, 0, 0],
        gravity: [Double] = [0, 0, 0],
        accelerationMagnitude: Double = 0,
        angularVelocity: Double = 0,
        motionQuality: Double = 1,
        attitudeQuaternion: [Double] = [],
        attitudeRotationMatrix: [Double] = [],
        attitudeReferenceFrame: String = "unavailable",
        timestamp: TimeInterval? = nil,
        experimentalPose: AVFoundationExperimentalPose? = nil
    ) {
        self.acceleration = acceleration
        self.rotationRate = rotationRate
        self.gravity = gravity
        self.accelerationMagnitude = accelerationMagnitude
        self.angularVelocity = angularVelocity
        self.motionQuality = motionQuality
        self.attitudeQuaternion = attitudeQuaternion
        self.attitudeRotationMatrix = attitudeRotationMatrix
        self.attitudeReferenceFrame = attitudeReferenceFrame
        self.timestamp = timestamp
        self.experimentalPose = experimentalPose
    }
}

private struct AVFoundationCalibrationSnapshot {
    let intrinsics: [Float]
    let intrinsicReferenceWidth: Double
    let intrinsicReferenceHeight: Double
    let extrinsicMatrix3x4: [Float]
    let cameraToReferenceMeters: [Float]
    let pixelSizeMillimeters: Float
    let lensDistortionCenter: [Double]
    let lensDistortionLookupTableURL: URL?
    let lensDistortionLookupTableRelativePath: String?
    let lensDistortionLookupTableData: Data?
    let inverseLensDistortionLookupTableURL: URL?
    let inverseLensDistortionLookupTableRelativePath: String?
    let inverseLensDistortionLookupTableData: Data?
}

private struct AVFoundationExperimentalPose {
    let positionMeters: [Double]
    let velocityMetersPerSecond: [Double]
    let deviceToMotionWorld: [Double]
    let motionWorldToDevice: [Double]

    var positionMagnitudeMeters: Double {
        sqrt(
            positionMeters[0] * positionMeters[0] +
            positionMeters[1] * positionMeters[1] +
            positionMeters[2] * positionMeters[2]
        )
    }
}

private final class AVFoundationMotionPoseEstimator {
    private let gravityMetersPerSecondSquared = 9.80665
    private let maxDeltaTime = 1.0 / 15.0
    private let velocityDampingPerSecond = 0.55
    private let stillAccelerationThreshold = 0.025

    private var lastTimestamp: TimeInterval?
    private var position = SIMD3<Double>(repeating: 0)
    private var velocity = SIMD3<Double>(repeating: 0)

    func reset() {
        lastTimestamp = nil
        position = SIMD3<Double>(repeating: 0)
        velocity = SIMD3<Double>(repeating: 0)
    }

    func update(motion: CMDeviceMotion, referenceFrameName: String) -> AVFoundationExperimentalPose {
        defer { lastTimestamp = motion.timestamp }

        let rotationRows = rotationRowsFromCMRotationMatrix(motion.attitude.rotationMatrix)
        if let lastTimestamp {
            let deltaTime = min(max(motion.timestamp - lastTimestamp, 0), maxDeltaTime)
            let accelerationDevice = SIMD3<Double>(
                motion.userAcceleration.x,
                motion.userAcceleration.y,
                motion.userAcceleration.z
            ) * gravityMetersPerSecondSquared
            let accelerationWorld = multiply(rotationRows, accelerationDevice)
            velocity += accelerationWorld * deltaTime
            velocity *= pow(velocityDampingPerSecond, deltaTime)

            if simd_length(accelerationDevice) < stillAccelerationThreshold {
                velocity *= 0.5
            }

            position += velocity * deltaTime
        }

        let deviceToWorld = makePoseMatrix(rotationRows: rotationRows, translation: position)
        return AVFoundationExperimentalPose(
            positionMeters: [position.x, position.y, position.z],
            velocityMetersPerSecond: [velocity.x, velocity.y, velocity.z],
            deviceToMotionWorld: deviceToWorld,
            motionWorldToDevice: inverseRigid4x4(deviceToWorld)
        )
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

private func configureVideoConnection(_ connection: AVCaptureConnection?) {
    setLandscapeRightOrientation(on: connection)
    connection?.preferredVideoStabilizationMode = .off
}

private func flatten3x3(_ matrix: simd_float3x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2]
    ]
}

private func flatten4x3(_ matrix: matrix_float4x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0], matrix[3, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1], matrix[3, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2], matrix[3, 2]
    ]
}

private func cameraToReference4x4Meters(_ matrix: matrix_float4x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0], matrix[3, 0] / 1_000,
        matrix[0, 1], matrix[1, 1], matrix[2, 1], matrix[3, 1] / 1_000,
        matrix[0, 2], matrix[1, 2], matrix[2, 2], matrix[3, 2] / 1_000,
        0, 0, 0, 1
    ]
}

private func preferredMotionReferenceFrame() -> CMAttitudeReferenceFrame {
    let available = CMMotionManager.availableAttitudeReferenceFrames()
    if available.contains(.xArbitraryCorrectedZVertical) {
        return .xArbitraryCorrectedZVertical
    }
    if available.contains(.xArbitraryZVertical) {
        return .xArbitraryZVertical
    }
    return .xArbitraryZVertical
}

private func motionReferenceFrameDisplayName(_ frame: CMAttitudeReferenceFrame) -> String {
    switch frame {
    case .xArbitraryCorrectedZVertical:
        return "xArbitraryCorrectedZVertical"
    case .xArbitraryZVertical:
        return "xArbitraryZVertical"
    case .xMagneticNorthZVertical:
        return "xMagneticNorthZVertical"
    case .xTrueNorthZVertical:
        return "xTrueNorthZVertical"
    default:
        return "unknown"
    }
}

private func videoStabilizationModeName(_ mode: AVCaptureVideoStabilizationMode?) -> String {
    switch mode {
    case .off:
        return "off"
    case .standard:
        return "standard"
    case .cinematic:
        return "cinematic"
    case .cinematicExtended:
        return "cinematicExtended"
    case .cinematicExtendedEnhanced:
        return "cinematicExtendedEnhanced"
    case .auto:
        return "auto"
    case .none:
        return "unknown"
    @unknown default:
        return "unknown"
    }
}

private func flattenRotationMatrix(_ matrix: CMRotationMatrix) -> [Double] {
    [
        matrix.m11, matrix.m12, matrix.m13,
        matrix.m21, matrix.m22, matrix.m23,
        matrix.m31, matrix.m32, matrix.m33
    ]
}

private func rotationRowsFromCMRotationMatrix(_ matrix: CMRotationMatrix) -> [SIMD3<Double>] {
    [
        SIMD3<Double>(matrix.m11, matrix.m12, matrix.m13),
        SIMD3<Double>(matrix.m21, matrix.m22, matrix.m23),
        SIMD3<Double>(matrix.m31, matrix.m32, matrix.m33)
    ]
}

private func multiply(_ rows: [SIMD3<Double>], _ vector: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3<Double>(
        simd_dot(rows[0], vector),
        simd_dot(rows[1], vector),
        simd_dot(rows[2], vector)
    )
}

private func makePoseMatrix(rotationRows: [SIMD3<Double>], translation: SIMD3<Double>) -> [Double] {
    [
        rotationRows[0].x, rotationRows[0].y, rotationRows[0].z, translation.x,
        rotationRows[1].x, rotationRows[1].y, rotationRows[1].z, translation.y,
        rotationRows[2].x, rotationRows[2].y, rotationRows[2].z, translation.z,
        0, 0, 0, 1
    ]
}

private func inverseRigid4x4(_ matrix: [Double]) -> [Double] {
    let r00 = matrix[0], r01 = matrix[1], r02 = matrix[2]
    let r10 = matrix[4], r11 = matrix[5], r12 = matrix[6]
    let r20 = matrix[8], r21 = matrix[9], r22 = matrix[10]
    let tx = matrix[3], ty = matrix[7], tz = matrix[11]
    return [
        r00, r10, r20, -(r00 * tx + r10 * ty + r20 * tz),
        r01, r11, r21, -(r01 * tx + r11 * ty + r21 * tz),
        r02, r12, r22, -(r02 * tx + r12 * ty + r22 * tz),
        0, 0, 0, 1
    ]
}
