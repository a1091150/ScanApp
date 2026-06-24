//
//  SceneCaptureRecorder.swift
//  ScanApp
//
//  Created by Codex on 2026/6/11.
//

import ARKit
import AVFoundation
import CoreMedia
import Foundation
import simd

final class SceneCaptureRecorder {
    private let writerQueue = DispatchQueue(label: "dokidoki.ScanApp.sceneCaptureWriter", qos: .utility)
    private let maxVelocity: Float = 0.5
    private let maxAngularVelocity: Float = 0.7
    private let rgbVideoRelativePath = "rgb.mov"
    private let depthPackedVideoRelativePath = "depth/depth_packed_hevc.mov"
    private let rgbVideoTimescale: CMTimeScale = 600

    private var sessionDirectory: URL?
    private var metadataDirectory: URL?
    private var depthDirectory: URL?
    private var metadataWriter: JsonlSegmentWriter?
    private var rgbVideoWriter: RGBVideoWriter?
    private var depthPackedVideoWriter: DepthPackedVideoWriter?
    private var isRecording = false
    private var frameIndex = 0
    private var savedImageCount = 0
    private var savedDepthFrameCount = 0
    private var pendingWriteCount = 0
    private var recordingGeneration = 0
    private var firstFrameTimestamp: TimeInterval?
    private var previousFrameTimestamp: TimeInterval?
    private var previousFrameTransform: simd_float4x4?
    private var lastDecision = "Recorder idle"

    var onCaptureSaved: ((SavedSceneCapture) -> Void)?

    var status: SceneCaptureRecorderStatus {
        SceneCaptureRecorderStatus(
            savedImageCount: savedImageCount,
            savedDepthFrameCount: savedDepthFrameCount,
            lastDecision: lastDecision
        )
    }

    func start(sessionDirectory: URL) throws {
        writerQueue.sync {
            closeMetadataWriter()
            finishRGBVideoWriter()
            finishDepthPackedVideoWriter()
        }

        self.sessionDirectory = sessionDirectory
        metadataDirectory = sessionDirectory.appendingPathComponent("metadata", isDirectory: true)
        depthDirectory = sessionDirectory.appendingPathComponent("depth", isDirectory: true)

        try FileManager.default.createDirectory(at: metadataDirectory!, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: depthDirectory!, withIntermediateDirectories: true)
        metadataWriter = try JsonlSegmentWriter(directory: metadataDirectory!)

        isRecording = true
        recordingGeneration += 1
        firstFrameTimestamp = nil
        lastDecision = "Recorder started + RGB video + depth"
    }

    func stop() {
        isRecording = false
        lastDecision = "Recorder stopped"
        writerQueue.async { [weak self] in
            self?.closeMetadataWriter()
            self?.finishRGBVideoWriter()
            self?.finishDepthPackedVideoWriter()
        }
    }

    func reset() {
        isRecording = false
        sessionDirectory = nil
        metadataDirectory = nil
        depthDirectory = nil
        frameIndex = 0
        savedImageCount = 0
        savedDepthFrameCount = 0
        pendingWriteCount = 0
        recordingGeneration += 1
        firstFrameTimestamp = nil
        previousFrameTimestamp = nil
        previousFrameTransform = nil
        lastDecision = "Recorder reset"
        writerQueue.async { [weak self] in
            self?.closeMetadataWriter()
            self?.finishRGBVideoWriter()
            self?.finishDepthPackedVideoWriter()
        }
    }

    func process(frame: ARFrame, interfaceOrientation: UIInterfaceOrientation) {
        frameIndex += 1

        guard isRecording else { return }
        guard let sessionDirectory, metadataWriter != nil else {
            lastDecision = "Missing dataset directory"
            return
        }
        guard interfaceOrientation == .landscapeRight else {
            lastDecision = "Skipped: rotate to landscape right"
            return
        }

        let motion = estimateMotion(for: frame)
        let frameName = String(format: "frame_%06d", frameIndex)
        let depthSnapshot = makeDepthSnapshot(from: frame, frameName: frameName)
        let pixelBuffer = frame.capturedImage

        let camera = frame.camera
        let cameraTransform = camera.transform
        let worldToCamera = cameraTransform.inverse
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let firstTimestamp = firstFrameTimestamp ?? frame.timestamp
        firstFrameTimestamp = firstTimestamp
        let sessionTime = frame.timestamp - firstTimestamp
        let rgbPresentationTime = CMTime(seconds: sessionTime, preferredTimescale: rgbVideoTimescale)
        let projection = camera.projectionMatrix(
            for: .landscapeRight,
            viewportSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            zNear: 0.001,
            zFar: 100
        )

        let snapshot = SceneCaptureFrameSnapshot(
            pixelBuffer: pixelBuffer,
            frameIndex: frameIndex,
            frameName: frameName,
            timestamp: frame.timestamp,
            sessionTime: sessionTime,
            rgbURL: sessionDirectory.appendingPathComponent(rgbVideoRelativePath),
            rgbRelativePath: rgbVideoRelativePath,
            rgbPresentationTime: rgbPresentationTime,
            depthVideoURL: sessionDirectory.appendingPathComponent(depthPackedVideoRelativePath),
            depthVideoRelativePath: depthPackedVideoRelativePath,
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
        lastDecision = "Queued \(frameName) video frame"

        enqueueCaptureWrite(snapshot: snapshot, generation: recordingGeneration)
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
                guard let self else { return }
                try self.writeFrameAssets(snapshot)
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

    private func writeFrameAssets(_ snapshot: SceneCaptureFrameSnapshot) throws {
        let rgbWriter = try rgbVideoWriter(for: snapshot)
        try rgbWriter.append(snapshot.pixelBuffer, presentationTime: snapshot.rgbPresentationTime)
        let depthVideoFrameInfo = try writeDepthPackedVideoIfNeeded(snapshot)
        try writeConfidenceDataIfNeeded(snapshot.depthSnapshot)
        try metadataWriter?.append(makeMetadata(from: snapshot, depthVideoFrameInfo: depthVideoFrameInfo))
    }

    private func makeMetadata(
        from snapshot: SceneCaptureFrameSnapshot,
        depthVideoFrameInfo: DepthPackedVideoFrameInfo?
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "frame_index": snapshot.frameIndex,
            "frame_name": snapshot.frameName,
            "time": snapshot.timestamp,
            "arkit_timestamp": snapshot.timestamp,
            "session_time": snapshot.sessionTime,
            "image": snapshot.rgbRelativePath,
            "capture_output": "rgb_video",
            "rgb": [
                "path": snapshot.rgbRelativePath,
                "pts_seconds": snapshot.rgbPresentationTime.seconds,
                "pts_value": snapshot.rgbPresentationTime.value,
                "pts_timescale": snapshot.rgbPresentationTime.timescale
            ],
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

        if let depthSnapshot = snapshot.depthSnapshot,
           let confidenceRelativePath = depthSnapshot.confidenceRelativePath {
            metadata["confidence"] = [
                "path": confidenceRelativePath,
                "format": "uint8",
                "timestamp": snapshot.timestamp,
                "width": depthSnapshot.width,
                "height": depthSnapshot.height
            ]
        }

        if let depthVideoFrameInfo {
            metadata["depth_video"] = [
                "path": depthVideoFrameInfo.path,
                "encoding": depthVideoFrameInfo.encoding,
                "codec": depthVideoFrameInfo.codec,
                "min_depth": depthVideoFrameInfo.minDepth,
                "max_depth": depthVideoFrameInfo.maxDepth,
                "invalid_value": depthVideoFrameInfo.invalidValue,
                "width": depthVideoFrameInfo.width,
                "height": depthVideoFrameInfo.height,
                "pts_seconds": depthVideoFrameInfo.ptsSeconds,
                "pts_value": depthVideoFrameInfo.ptsValue,
                "pts_timescale": depthVideoFrameInfo.ptsTimescale
            ]
        }

        return metadata
    }

    private func makeDepthSnapshot(from frame: ARFrame, frameName: String) -> SceneDepthFrameSnapshot? {
        guard let depthDirectory else { return nil }
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

    private func rgbVideoWriter(for snapshot: SceneCaptureFrameSnapshot) throws -> RGBVideoWriter {
        if let rgbVideoWriter {
            return rgbVideoWriter
        }

        let writer = try RGBVideoWriter(
            url: snapshot.rgbURL,
            width: snapshot.width,
            height: snapshot.height
        )
        rgbVideoWriter = writer
        return writer
    }

    private func writeDepthPackedVideoIfNeeded(_ snapshot: SceneCaptureFrameSnapshot) throws -> DepthPackedVideoFrameInfo? {
        guard let depthSnapshot = snapshot.depthSnapshot else { return nil }
        let writer = try depthPackedVideoWriter(for: snapshot, depthSnapshot: depthSnapshot)
        return try writer.append(depthSnapshot.depthMap, presentationTime: snapshot.rgbPresentationTime)
    }

    private func depthPackedVideoWriter(
        for snapshot: SceneCaptureFrameSnapshot,
        depthSnapshot: SceneDepthFrameSnapshot
    ) throws -> DepthPackedVideoWriter {
        if let depthPackedVideoWriter {
            return depthPackedVideoWriter
        }

        let writer = try DepthPackedVideoWriter(
            url: snapshot.depthVideoURL,
            relativePath: snapshot.depthVideoRelativePath,
            width: depthSnapshot.width,
            height: depthSnapshot.height
        )
        depthPackedVideoWriter = writer
        return writer
    }

    private func writeConfidenceDataIfNeeded(_ snapshot: SceneDepthFrameSnapshot?) throws {
        guard let snapshot else { return }
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
            onCaptureSaved?(SavedSceneCapture(imageName: frameName, cameraTransform: cameraTransform))
        case .failure(let error):
            lastDecision = "Save failed: \(error.localizedDescription)"
        }
    }

    private func closeMetadataWriter() {
        try? metadataWriter?.close()
        metadataWriter = nil
    }

    private func finishRGBVideoWriter() {
        let writer = rgbVideoWriter
        rgbVideoWriter = nil
        writer?.finish {}
    }

    private func finishDepthPackedVideoWriter() {
        let writer = depthPackedVideoWriter
        depthPackedVideoWriter = nil
        writer?.finish {}
    }
}

fileprivate func flatten3x3(_ matrix: simd_float3x3) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2]
    ]
}

fileprivate func flatten4x4(_ matrix: simd_float4x4) -> [Float] {
    [
        matrix[0, 0], matrix[1, 0], matrix[2, 0], matrix[3, 0],
        matrix[0, 1], matrix[1, 1], matrix[2, 1], matrix[3, 1],
        matrix[0, 2], matrix[1, 2], matrix[2, 2], matrix[3, 2],
        matrix[0, 3], matrix[1, 3], matrix[2, 3], matrix[3, 3]
    ]
}

fileprivate func distanceBetweenTranslations(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
    let lhsTranslation = SIMD3<Float>(lhs.columns.3.x, lhs.columns.3.y, lhs.columns.3.z)
    let rhsTranslation = SIMD3<Float>(rhs.columns.3.x, rhs.columns.3.y, rhs.columns.3.z)
    return simd_distance(lhsTranslation, rhsTranslation)
}

fileprivate func rotationAngleBetween(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
    let lhsRotation = simd_quatf(lhs)
    let rhsRotation = simd_quatf(rhs)
    let dot = abs(simd_dot(lhsRotation.vector, rhsRotation.vector))
    return 2 * acos(min(1, max(-1, dot)))
}

fileprivate func trackingText(for trackingState: ARCamera.TrackingState) -> String {
    switch trackingState {
    case .notAvailable:
        return "notAvailable"
    case .normal:
        return "normal"
    case .limited(let reason):
        return "limited:\(reason)"
    }
}

fileprivate extension UIInterfaceOrientation {
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
