//
//  SceneCaptureRecorder.swift
//  ScanApp
//
//  Created by Codex on 2026/6/11.
//

import ARKit
import CoreImage
import Foundation
import ImageIO
import simd
import UIKit

struct SceneCaptureRecorderStatus {
    let savedImageCount: Int
    let lastDecision: String
}

final class SceneCaptureRecorder {
    private let ciContext = CIContext()
    private let hapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private let jpegQuality: CGFloat = 0.92
    private let minCaptureInterval: TimeInterval = 0.45
    private let minTranslationDelta: Float = 0.05
    private let minRotationDeltaRadians: Float = 7 * .pi / 180
    private let maxVelocity: Float = 0.5
    private let maxAngularVelocity: Float = 0.7

    private var sessionDirectory: URL?
    private var imagesDirectory: URL?
    private var metadataDirectory: URL?
    private var isRecording = false
    private var frameIndex = 0
    private var savedImageCount = 0
    private var lastSavedTimestamp: TimeInterval?
    private var lastSavedTransform: simd_float4x4?
    private var previousFrameTimestamp: TimeInterval?
    private var previousFrameTransform: simd_float4x4?
    private var lastDecision = "Recorder idle"

    var status: SceneCaptureRecorderStatus {
        SceneCaptureRecorderStatus(savedImageCount: savedImageCount, lastDecision: lastDecision)
    }

    func start(sessionDirectory: URL) throws {
        self.sessionDirectory = sessionDirectory
        imagesDirectory = sessionDirectory.appendingPathComponent("images", isDirectory: true)
        metadataDirectory = sessionDirectory.appendingPathComponent("metadata", isDirectory: true)

        if let imagesDirectory {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        }
        if let metadataDirectory {
            try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        }

        isRecording = true
        lastDecision = "Recorder started"
        prepareCaptureHaptic()
    }

    func stop() {
        isRecording = false
        lastDecision = "Recorder stopped"
    }

    func reset() {
        isRecording = false
        sessionDirectory = nil
        imagesDirectory = nil
        metadataDirectory = nil
        frameIndex = 0
        savedImageCount = 0
        lastSavedTimestamp = nil
        lastSavedTransform = nil
        previousFrameTimestamp = nil
        previousFrameTransform = nil
        lastDecision = "Recorder reset"
    }

    func process(frame: ARFrame, interfaceOrientation: UIInterfaceOrientation) {
        frameIndex += 1

        guard isRecording else { return }
        guard let imagesDirectory, let metadataDirectory else {
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

        do {
            let frameName = String(format: "frame_%06d", frameIndex)
            let imageName = "\(frameName).jpg"
            let metadataName = "\(frameName).json"
            let imageURL = imagesDirectory.appendingPathComponent(imageName)
            let metadataURL = metadataDirectory.appendingPathComponent(metadataName)
            try writeJPEG(from: frame.capturedImage, to: imageURL)

            let metadata = makeMetadata(
                frame: frame,
                imageRelativePath: "images/\(imageName)",
                metadataRelativePath: "metadata/\(metadataName)",
                interfaceOrientation: interfaceOrientation,
                motion: motion
            )
            try writeMetadata(metadata, to: metadataURL)

            savedImageCount += 1
            lastSavedTimestamp = frame.timestamp
            lastSavedTransform = frame.camera.transform
            lastDecision = "Saved \(imageName)"
            notifyCaptureSaved()
        } catch {
            lastDecision = "Save failed: \(error.localizedDescription)"
        }
    }

    private func shouldCapture(frame: ARFrame, motion: FrameMotion) -> (shouldCapture: Bool, reason: String) {
        guard case .normal = frame.camera.trackingState else {
            return (false, "Skipped: tracking not normal")
        }

        if savedImageCount == 0 {
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

    private func writeJPEG(from pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let data = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        ) else {
            throw SceneCaptureRecorderError.jpegEncodingFailed
        }

        try data.write(to: url, options: .atomic)
    }

    private func makeMetadata(
        frame: ARFrame,
        imageRelativePath: String,
        metadataRelativePath: String,
        interfaceOrientation: UIInterfaceOrientation,
        motion: FrameMotion
    ) -> [String: Any] {
        let camera = frame.camera
        let capturedImage = frame.capturedImage
        let cameraToWorld = camera.transform
        let worldToCamera = cameraToWorld.inverse
        let projection = camera.projectionMatrix(
            for: .landscapeRight,
            viewportSize: CGSize(width: CGFloat(CVPixelBufferGetWidth(capturedImage)), height: CGFloat(CVPixelBufferGetHeight(capturedImage))),
            zNear: 0.001,
            zFar: 100
        )

        return [
            "frame_index": frameIndex,
            "time": frame.timestamp,
            "image": imageRelativePath,
            "metadata": metadataRelativePath,
            "image_orientation": "landscapeRight",
            "projection_orientation": "landscapeRight",
            "required_orientation": "landscapeRight",
            "ui_orientation": interfaceOrientation.metadataName,
            "width": CVPixelBufferGetWidth(capturedImage),
            "height": CVPixelBufferGetHeight(capturedImage),
            "intrinsics": flatten3x3(camera.intrinsics),
            "camera_to_world": flatten4x4(cameraToWorld),
            "world_to_camera": flatten4x4(worldToCamera),
            "projectionMatrix": flatten4x4(projection),
            "exposureDuration": camera.exposureDuration,
            "exposureOffset": camera.exposureOffset,
            "averageVelocity": motion.velocity,
            "averageAngularVelocity": motion.angularVelocity,
            "motionQuality": motion.motionQuality,
            "trackingState": trackingText(for: camera.trackingState)
        ]
    }

    private func writeMetadata(_ object: [String: Any], to url: URL) throws {
        let jsonData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: url, options: .atomic)
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

private struct FrameMotion {
    let velocity: Float
    let angularVelocity: Float
    let motionQuality: Float
}

private enum SceneCaptureRecorderError: LocalizedError {
    case jpegEncodingFailed
    case metadataEncodingFailed

    var errorDescription: String? {
        switch self {
        case .jpegEncodingFailed:
            return "Could not encode the AR camera image as JPEG."
        case .metadataEncodingFailed:
            return "Could not encode frame metadata."
        }
    }
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
