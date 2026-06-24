//
//  SceneCaptureRecorderError.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import CoreVideo
import Foundation

enum SceneCaptureRecorderError: LocalizedError {
    case pixelBufferBaseAddressUnavailable
    case unsupportedDepthPixelFormat(OSType)
    case unsupportedConfidencePixelFormat(OSType)
    case invalidVideoDimensions(width: Int, height: Int)
    case videoWriterNotReady
    case videoWriterFailed(String)

    var errorDescription: String? {
        switch self {
        case .pixelBufferBaseAddressUnavailable:
            return "Could not read the depth pixel buffer."
        case .unsupportedDepthPixelFormat(let pixelFormat):
            return "Unsupported depth pixel format: \(pixelFormat)."
        case .unsupportedConfidencePixelFormat(let pixelFormat):
            return "Unsupported confidence pixel format: \(pixelFormat)."
        case .invalidVideoDimensions(let width, let height):
            return "Invalid RGB video dimensions: \(width) x \(height)."
        case .videoWriterNotReady:
            return "RGB video writer is not ready for another frame."
        case .videoWriterFailed(let message):
            return "RGB video writer failed: \(message)"
        }
    }
}
