//
//  SceneCaptureRecorder.swift
//  ScanApp
//
//  Created by Codex on 2026/6/11.
//

import ARKit
import AVFoundation
import CoreImage
import Foundation
import simd
import UIKit

struct SceneCaptureRecorderStatus {
    let savedImageCount: Int
    let savedDepthFrameCount: Int
    let lastDecision: String
}

struct SavedSceneCapture {
    let imageName: String
    let cameraTransform: simd_float4x4
}

final class SceneCaptureRecorder {
    private let writerQueue = DispatchQueue(label: "dokidoki.ScanApp.sceneCaptureWriter", qos: .utility)
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let outputMode: SceneCaptureOutputMode = .images
    private let videoFileName = "capture.mp4"
    private let jpegCompressionQuality: CGFloat = 0.92
    private let minCaptureInterval: TimeInterval = 0.45
    private let minTranslationDelta: Float = 0.05
    private let minRotationDeltaRadians: Float = 7 * .pi / 180
    private let maxVelocity: Float = 0.5
    private let maxAngularVelocity: Float = 0.7
    private let maxPendingWrites = 2

    private var sessionDirectory: URL?
    private var imageDirectory: URL?
    private var metadataDirectory: URL?
    private var depthDirectory: URL?
    private var videoURL: URL?
    private var isRecording = false
    private var isRecordingDepth = false
    private var frameIndex = 0
    private var savedImageCount = 0
    private var savedDepthFrameCount = 0
    private var pendingWriteCount = 0
    private var acceptedCaptureCount = 0
    private var recordingGeneration = 0
    private var lastSavedTimestamp: TimeInterval?
    private var lastSavedTransform: simd_float4x4?
    private var previousFrameTimestamp: TimeInterval?
    private var previousFrameTransform: simd_float4x4?
    private var lastDecision = "Recorder idle"

    private var videoWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstVideoTimestamp: TimeInterval?

    var onCaptureSaved: ((SavedSceneCapture) -> Void)?

    var status: SceneCaptureRecorderStatus {
        SceneCaptureRecorderStatus(
            savedImageCount: savedImageCount,
            savedDepthFrameCount: savedDepthFrameCount,
            lastDecision: lastDecision
        )
    }

    func start(sessionDirectory: URL, recordsDepthData: Bool = false) throws {
        self.sessionDirectory = sessionDirectory
        imageDirectory = sessionDirectory.appendingPathComponent("images", isDirectory: true)
        metadataDirectory = sessionDirectory.appendingPathComponent("metadata", isDirectory: true)
        depthDirectory = recordsDepthData
            ? sessionDirectory.appendingPathComponent("depth", isDirectory: true)
            : nil
        videoURL = sessionDirectory.appendingPathComponent(videoFileName)

        if let imageDirectory {
            try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        }
        if let metadataDirectory {
            try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        }
        if let depthDirectory {
            try FileManager.default.createDirectory(at: depthDirectory, withIntermediateDirectories: true)
        }
        if outputMode == .video, let videoURL, FileManager.default.fileExists(atPath: videoURL.path) {
            try FileManager.default.removeItem(at: videoURL)
        }

        isRecording = true
        isRecordingDepth = recordsDepthData
        recordingGeneration += 1
        lastDecision = recordsDepthData ? "Recorder started + depth" : "Recorder started"
        prepareCaptureHaptic()
    }

    func stop() {
        isRecording = false
        isRecordingDepth = false
        lastDecision = "Recorder stopped"
        finishVideoWriter()
    }

    func reset() {
        isRecording = false
        sessionDirectory = nil
        imageDirectory = nil
        metadataDirectory = nil
        depthDirectory = nil
        videoURL = nil
        isRecordingDepth = false
        frameIndex = 0
        savedImageCount = 0
        savedDepthFrameCount = 0
        pendingWriteCount = 0
        acceptedCaptureCount = 0
        recordingGeneration += 1
        lastSavedTimestamp = nil
        lastSavedTransform = nil
        previousFrameTimestamp = nil
        previousFrameTransform = nil
        lastDecision = "Recorder reset"
        finishVideoWriter()
    }

    func process(frame: ARFrame, interfaceOrientation: UIInterfaceOrientation) {
        frameIndex += 1

        guard isRecording else { return }
        guard let imageDirectory, let metadataDirectory else {
            lastDecision = "Missing dataset directory"
            return
        }
        guard interfaceOrientation == .landscapeRight else {
            lastDecision = "Skipped: rotate to landscape right"
            return
        }

        let motion = estimateMotion(for: frame)
        let decision = shouldCapture(frame: frame, motion: motion)
        guard decision.shouldCapture else {
            lastDecision = decision.reason
            return
        }

        guard pendingWriteCount < maxPendingWrites else {
            lastDecision = "Skipped: writer queue busy"
            return
        }

        let captureIndex = acceptedCaptureCount
        let frameName = String(format: "frame_%06d", frameIndex)
        let imageName = "\(frameName).jpg"
        let metadataName = "\(frameName).json"
        let imageURL = imageDirectory.appendingPathComponent(imageName)
        let metadataURL = metadataDirectory.appendingPathComponent(metadataName)
        let depthSnapshot = makeDepthSnapshot(from: frame, frameName: frameName)
        let pixelBuffer = frame.capturedImage
        let camera = frame.camera
        let cameraTransform = camera.transform
        let worldToCamera = cameraTransform.inverse
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let projection = camera.projectionMatrix(
            for: .landscapeRight,
            viewportSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            zNear: 0.001,
            zFar: 100
        )

        let snapshot = SceneCaptureFrameSnapshot(
            pixelBuffer: pixelBuffer,
            outputMode: outputMode,
            imageURL: imageURL,
            imageRelativePath: "images/\(imageName)",
            videoURL: videoURL,
            videoRelativePath: videoFileName,
            videoFrameIndex: captureIndex,
            frameIndex: frameIndex,
            frameName: frameName,
            metadataRelativePath: "metadata/\(metadataName)",
            metadataURL: metadataURL,
            timestamp: frame.timestamp,
            width: width,
            height: height,
            interfaceOrientationName: interfaceOrientation.metadataName,
            intrinsics: camera.intrinsics,
            cameraTransform: cameraTransform,
            worldToCamera: worldToCamera,
            projectionMatrix: projection,
            exposureDuration: camera.exposureDuration,
            exposureOffset: camera.exposureOffset,
            motion: motion,
            trackingStateText: trackingText(for: camera.trackingState),
            depthSnapshot: depthSnapshot
        )

        pendingWriteCount += 1
        acceptedCaptureCount += 1
        lastSavedTimestamp = frame.timestamp
        lastSavedTransform = cameraTransform
        lastDecision = "Queued \(frameName)"

        enqueueCaptureWrite(snapshot: snapshot, generation: recordingGeneration)
    }

    private func shouldCapture(frame: ARFrame, motion: FrameMotion) -> (shouldCapture: Bool, reason: String) {
        guard case .normal = frame.camera.trackingState else {
            return (false, "Skipped: tracking not normal")
        }

        if acceptedCaptureCount == 0 {
            return (true, "Capture: first frame")
        }

        if let lastSavedTimestamp, frame.timestamp - lastSavedTimestamp < minCaptureInterval {
            return (false, "Skipped: waiting for interval")
        }

        if motion.velocity > maxVelocity {
            return (false, String(format: "Skipped: velocity %.2f", motion.velocity))
        }

        if motion.angularVelocity > maxAngularVelocity {
            return (false, String(format: "Skipped: angular %.2f", motion.angularVelocity))
        }

        let translationDelta = lastSavedTransform.map { distanceBetweenTranslations(frame.camera.transform, $0) } ?? .greatestFiniteMagnitude
        let rotationDelta = lastSavedTransform.map { rotationAngleBetween(frame.camera.transform, $0) } ?? .greatestFiniteMagnitude

        if translationDelta < minTranslationDelta && rotationDelta < minRotationDeltaRadians {
            return (false, "Skipped: viewpoint too similar")
        }

        return (true, "Capture: keyframe")
    }

    private func estimateMotion(for frame: ARFrame) -> FrameMotion {
        defer {
            previousFrameTimestamp = frame.timestamp
            previousFrameTransform = frame.camera.transform
        }

        guard let previousFrameTimestamp, let previousFrameTransform else {
            return FrameMotion(velocity: 0, angularVelocity: 0, motionQuality: 1)
        }

        let deltaTime = max(Float(frame.timestamp - previousFrameTimestamp), 0.001)
        let translation = distanceBetweenTranslations(frame.camera.transform, previousFrameTransform)
        let rotation = rotationAngleBetween(frame.camera.transform, previousFrameTransform)
        let velocity = translation / deltaTime
        let angularVelocity = rotation / deltaTime
        let velocityScore = max(0, 1 - velocity / maxVelocity)
        let angularScore = max(0, 1 - angularVelocity / maxAngularVelocity)

        return FrameMotion(
            velocity: velocity,
            angularVelocity: angularVelocity,
            motionQuality: min(velocityScore, angularScore)
        )
    }

    private func enqueueCaptureWrite(snapshot: SceneCaptureFrameSnapshot, generation: Int) {
        writerQueue.async { [weak self] in
            let result = Result<Void, Error> {
                try self?.writeCapture(snapshot)
            }

            DispatchQueue.main.async {
                self?.finishCaptureWrite(
                    result,
                    frameName: snapshot.frameName,
                    cameraTransform: snapshot.cameraTransform,
                    generation: generation,
                    hasDepthSnapshot: snapshot.depthSnapshot != nil
                )
            }
        }
    }

    private func writeCapture(_ snapshot: SceneCaptureFrameSnapshot) throws {
        switch snapshot.outputMode {
        case .images:
            try writeImageAndMetadata(snapshot)
        case .video:
            try appendVideoFrameAndWriteMetadata(snapshot)
        }
    }

    private func writeImageAndMetadata(_ snapshot: SceneCaptureFrameSnapshot) throws {
        let image = CIImage(cvPixelBuffer: snapshot.pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try ciContext.writeJPEGRepresentation(
            of: image,
            to: snapshot.imageURL,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegCompressionQuality]
        )

        let metadata = makeMetadata(from: snapshot)
        try writeDepthDataIfNeeded(snapshot.depthSnapshot)
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: snapshot.metadataURL, options: .atomic)
    }

    private func appendVideoFrameAndWriteMetadata(_ snapshot: SceneCaptureFrameSnapshot) throws {
        guard let videoURL = snapshot.videoURL else {
            throw SceneCaptureRecorderError.videoWriterUnavailable
        }
        try ensureVideoWriter(for: snapshot)

        guard let videoInput, let pixelBufferAdaptor else {
            throw SceneCaptureRecorderError.videoWriterUnavailable
        }
        guard videoInput.isReadyForMoreMediaData else {
            throw SceneCaptureRecorderError.videoInputNotReady
        }
        guard let firstVideoTimestamp else {
            throw SceneCaptureRecorderError.videoWriterUnavailable
        }

        let presentationTime = CMTime(
            seconds: max(0, snapshot.timestamp - firstVideoTimestamp),
            preferredTimescale: 600
        )

        guard pixelBufferAdaptor.append(snapshot.pixelBuffer, withPresentationTime: presentationTime) else {
            throw videoWriter?.error ?? SceneCaptureRecorderError.videoAppendFailed
        }

        let metadata = makeMetadata(from: snapshot)
        try writeDepthDataIfNeeded(snapshot.depthSnapshot)
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: snapshot.metadataURL, options: .atomic)
    }

    private func ensureVideoWriter(for snapshot: SceneCaptureFrameSnapshot) throws {
        if videoWriter != nil { return }

        guard let videoURL = snapshot.videoURL else {
            throw SceneCaptureRecorderError.videoWriterUnavailable
        }

        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: snapshot.width,
            AVVideoHeightKey: snapshot.height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(snapshot.pixelBuffer),
            kCVPixelBufferWidthKey as String: snapshot.width,
            kCVPixelBufferHeightKey as String: snapshot.height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else {
            throw SceneCaptureRecorderError.videoWriterUnavailable
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SceneCaptureRecorderError.videoWriterUnavailable
        }

        firstVideoTimestamp = snapshot.timestamp
        writer.startSession(atSourceTime: .zero)
        videoWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
    }

    private func makeMetadata(from snapshot: SceneCaptureFrameSnapshot) -> [String: Any] {
        var metadata: [String: Any] = [
            "frame_index": snapshot.frameIndex,
            "frame_name": snapshot.frameName,
            "time": snapshot.timestamp,
            "image": snapshot.imageRelativePath,
            "metadata": snapshot.metadataRelativePath,
            "capture_output": snapshot.outputMode.rawValue,
            "image_orientation": "landscapeRight",
            "projection_orientation": "landscapeRight",
            "required_orientation": "landscapeRight",
            "ui_orientation": snapshot.interfaceOrientationName,
            "width": snapshot.width,
            "height": snapshot.height,
            "intrinsics": flatten3x3(snapshot.intrinsics),
            "camera_to_world": flatten4x4(snapshot.cameraTransform),
            "world_to_camera": flatten4x4(snapshot.worldToCamera),
            "projectionMatrix": flatten4x4(snapshot.projectionMatrix),
            "exposureDuration": snapshot.exposureDuration,
            "exposureOffset": snapshot.exposureOffset,
            "averageVelocity": snapshot.motion.velocity,
            "averageAngularVelocity": snapshot.motion.angularVelocity,
            "motionQuality": snapshot.motion.motionQuality,
            "trackingState": snapshot.trackingStateText
        ]

        if snapshot.outputMode == .video, let videoRelativePath = snapshot.videoRelativePath {
            metadata["video"] = videoRelativePath
            metadata["video_frame_index"] = snapshot.videoFrameIndex
            metadata["derived_image"] = snapshot.imageRelativePath
        }

        if let depthSnapshot = snapshot.depthSnapshot {
            var depthMetadata: [String: Any] = [
                "format": "float32_little_endian",
                "path": depthSnapshot.depthRelativePath,
                "width": depthSnapshot.width,
                "height": depthSnapshot.height,
                "bytes_per_value": MemoryLayout<Float>.size
            ]
            if let confidenceRelativePath = depthSnapshot.confidenceRelativePath {
                depthMetadata["confidence_path"] = confidenceRelativePath
                depthMetadata["confidence_format"] = "uint8"
            }
            metadata["depth"] = depthMetadata
        }

        return metadata
    }

    private func makeDepthSnapshot(from frame: ARFrame, frameName: String) -> SceneDepthFrameSnapshot? {
        guard isRecordingDepth, let depthDirectory else { return nil }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }

        let depthMap = depthData.depthMap
        let depthName = "\(frameName)_depth_f32.bin"
        let confidenceName = "\(frameName)_confidence_u8.bin"
        let confidenceMap = depthData.confidenceMap

        return SceneDepthFrameSnapshot(
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            depthURL: depthDirectory.appendingPathComponent(depthName),
            depthRelativePath: "depth/\(depthName)",
            confidenceURL: confidenceMap == nil ? nil : depthDirectory.appendingPathComponent(confidenceName),
            confidenceRelativePath: confidenceMap == nil ? nil : "depth/\(confidenceName)",
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap)
        )
    }

    private func writeDepthDataIfNeeded(_ snapshot: SceneDepthFrameSnapshot?) throws {
        guard let snapshot else { return }
        try writeFloat32PixelBuffer(snapshot.depthMap, to: snapshot.depthURL)
        if let confidenceMap = snapshot.confidenceMap, let confidenceURL = snapshot.confidenceURL {
            try writeUInt8PixelBuffer(confidenceMap, to: confidenceURL)
        }
    }

    private func finishCaptureWrite(
        _ result: Result<Void, Error>,
        frameName: String,
        cameraTransform: simd_float4x4,
        generation: Int,
        hasDepthSnapshot: Bool
    ) {
        guard generation == recordingGeneration else { return }

        pendingWriteCount = max(0, pendingWriteCount - 1)

        switch result {
        case .success:
            savedImageCount += 1
            if hasDepthSnapshot {
                savedDepthFrameCount += 1
            }
            lastDecision = "Saved \(frameName)"
            notifyCaptureSaved()
            onCaptureSaved?(SavedSceneCapture(imageName: frameName, cameraTransform: cameraTransform))
        case .failure(let error):
            lastDecision = "Save failed: \(error.localizedDescription)"
        }
    }

    private func finishVideoWriter() {
        writerQueue.async { [weak self] in
            guard let self, let writer = self.videoWriter else { return }
            self.videoInput?.markAsFinished()
            writer.finishWriting { }
            self.videoWriter = nil
            self.videoInput = nil
            self.pixelBufferAdaptor = nil
            self.firstVideoTimestamp = nil
        }
    }

    private func prepareCaptureHaptic() {
        DispatchQueue.main.async { [hapticGenerator] in
            hapticGenerator.prepare()
        }
    }

    private func notifyCaptureSaved() {
        DispatchQueue.main.async { [hapticGenerator] in
            hapticGenerator.impactOccurred(intensity: 0.45)
            hapticGenerator.prepare()
        }
    }
}

private struct SceneCaptureFrameSnapshot {
    let pixelBuffer: CVPixelBuffer
    let outputMode: SceneCaptureOutputMode
    let imageURL: URL
    let imageRelativePath: String
    let videoURL: URL?
    let videoRelativePath: String?
    let videoFrameIndex: Int
    let frameIndex: Int
    let frameName: String
    let metadataRelativePath: String
    let metadataURL: URL
    let timestamp: TimeInterval
    let width: Int
    let height: Int
    let interfaceOrientationName: String
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let worldToCamera: simd_float4x4
    let projectionMatrix: simd_float4x4
    let exposureDuration: TimeInterval
    let exposureOffset: Float
    let motion: FrameMotion
    let trackingStateText: String
    let depthSnapshot: SceneDepthFrameSnapshot?
}

private struct SceneDepthFrameSnapshot {
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let depthURL: URL
    let depthRelativePath: String
    let confidenceURL: URL?
    let confidenceRelativePath: String?
    let width: Int
    let height: Int
}

private enum SceneCaptureOutputMode: String {
    case images
    case video
}

private struct FrameMotion {
    let velocity: Float
    let angularVelocity: Float
    let motionQuality: Float
}

private enum SceneCaptureRecorderError: LocalizedError {
    case videoWriterUnavailable
    case videoInputNotReady
    case videoAppendFailed
    case pixelBufferBaseAddressUnavailable
    case unsupportedDepthPixelFormat(OSType)
    case unsupportedConfidencePixelFormat(OSType)

    var errorDescription: String? {
        switch self {
        case .videoWriterUnavailable:
            return "Could not create the video writer."
        case .videoInputNotReady:
            return "The video writer is not ready for another frame."
        case .videoAppendFailed:
            return "Could not append the AR camera frame to the video."
        case .pixelBufferBaseAddressUnavailable:
            return "Could not read the depth pixel buffer."
        case .unsupportedDepthPixelFormat(let pixelFormat):
            return "Unsupported depth pixel format: \(pixelFormat)."
        case .unsupportedConfidencePixelFormat(let pixelFormat):
            return "Unsupported confidence pixel format: \(pixelFormat)."
        }
    }
}

func writeFloat32PixelBuffer(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard pixelFormat == kCVPixelFormatType_DepthFloat32 || pixelFormat == kCVPixelFormatType_DisparityFloat32 else {
        throw SceneCaptureRecorderError.unsupportedDepthPixelFormat(pixelFormat)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw SceneCaptureRecorderError.pixelBufferBaseAddressUnavailable
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let rowByteCount = width * MemoryLayout<Float>.size
    var data = Data()
    data.reserveCapacity(rowByteCount * height)

    for row in 0..<height {
        let rowStart = baseAddress.advanced(by: row * bytesPerRow)
        data.append(contentsOf: UnsafeRawBufferPointer(start: rowStart, count: rowByteCount))
    }

    try data.write(to: url, options: .atomic)
}

private func writeUInt8PixelBuffer(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
    let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
    guard pixelFormat == kCVPixelFormatType_OneComponent8 else {
        throw SceneCaptureRecorderError.unsupportedConfidencePixelFormat(pixelFormat)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw SceneCaptureRecorderError.pixelBufferBaseAddressUnavailable
    }

    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    var data = Data()
    data.reserveCapacity(width * height)

    for row in 0..<height {
        let rowStart = baseAddress.advanced(by: row * bytesPerRow)
        data.append(contentsOf: UnsafeRawBufferPointer(start: rowStart, count: width))
    }

    try data.write(to: url, options: .atomic)
}

private func flatten3x3(_ matrix: simd_float3x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2]
    ]
}

private func flatten4x4(_ matrix: simd_float4x4) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0], matrix[3, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1], matrix[3, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2], matrix[3, 2],
        matrix[0, 3], matrix[1, 3], matrix[2, 3], matrix[3, 3]
    ]
}

private func distanceBetweenTranslations(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
    let lhsTranslation = SIMD3<Float>(lhs.columns.3.x, lhs.columns.3.y, lhs.columns.3.z)
    let rhsTranslation = SIMD3<Float>(rhs.columns.3.x, rhs.columns.3.y, rhs.columns.3.z)
    return simd_distance(lhsTranslation, rhsTranslation)
}

private func rotationAngleBetween(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
    let lhsRotation = simd_quatf(lhs)
    let rhsRotation = simd_quatf(rhs)
    let dot = abs(simd_dot(lhsRotation.vector, rhsRotation.vector))
    return 2 * acos(min(1, max(-1, dot)))
}

private func trackingText(for trackingState: ARCamera.TrackingState) -> String {
    switch trackingState {
    case .notAvailable:
        return "notAvailable"
    case .normal:
        return "normal"
    case .limited(let reason):
        return "limited:\(reason)"
    }
}

private extension UIInterfaceOrientation {
    var metadataName: String {
        switch self {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}
