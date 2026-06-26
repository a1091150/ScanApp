//
//  SceneCaptureFrameSnapshot.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import ARKit
import CoreMedia
import CoreVideo
import Foundation
import simd

struct SceneLightEstimateSnapshot {
    let ambientIntensity: CGFloat
    let ambientColorTemperature: CGFloat
}

struct SceneFaceAnchorSnapshot {
    let identifier: String
    let isTracked: Bool
    let transform: simd_float4x4
    let leftEyeTransform: simd_float4x4
    let rightEyeTransform: simd_float4x4
    let lookAtPoint: SIMD3<Float>
    let blendShapes: [String: Double]
}

struct SceneCaptureFrameSnapshot {
    let captureMode: SceneCaptureMode
    let pixelBuffer: CVPixelBuffer
    let frameIndex: Int
    let frameName: String
    let timestamp: TimeInterval
    let sessionTime: TimeInterval
    let rgbURL: URL
    let rgbRelativePath: String
    let rgbPresentationTime: CMTime
    let depthVideoURL: URL
    let depthVideoRelativePath: String
    let width: Int
    let height: Int
    let imageOrientationName: String
    let projectionOrientationName: String
    let requiredOrientationName: String
    let interfaceOrientationName: String
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let worldToCamera: simd_float4x4
    let projectionMatrix: simd_float4x4
    let exposureDuration: TimeInterval
    let exposureOffset: Float
    let lightEstimate: SceneLightEstimateSnapshot?
    let motion: FrameMotion
    let trackingStateText: String
    let depthSnapshot: SceneDepthFrameSnapshot?
    let faceSnapshots: [SceneFaceAnchorSnapshot]
}
