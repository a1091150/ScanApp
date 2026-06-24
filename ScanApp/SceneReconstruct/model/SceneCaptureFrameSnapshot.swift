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

struct SceneCaptureFrameSnapshot {
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
}
