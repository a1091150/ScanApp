//
//  SceneDepthFrameSnapshot.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import CoreVideo
import Foundation

struct SceneDepthFrameSnapshot {
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let depthURL: URL
    let depthRelativePath: String
    let confidenceURL: URL?
    let confidenceRelativePath: String?
    let width: Int
    let height: Int
}
