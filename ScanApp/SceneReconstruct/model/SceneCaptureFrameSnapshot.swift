//
//  SceneCaptureFrameSnapshot.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import ARKit
import CoreVideo
import Foundation
import simd

struct SceneCaptureFrameSnapshot {
    let pixelBuffer: CVPixelBuffer
    let imageURL: URL
    let imageRelativePath: String
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
