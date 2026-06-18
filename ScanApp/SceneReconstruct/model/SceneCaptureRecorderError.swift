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

    var errorDescription: String? {
        switch self {
        case .pixelBufferBaseAddressUnavailable:
            return "Could not read the depth pixel buffer."
        case .unsupportedDepthPixelFormat(let pixelFormat):
            return "Unsupported depth pixel format: \(pixelFormat)."
        case .unsupportedConfidencePixelFormat(let pixelFormat):
            return "Unsupported confidence pixel format: \(pixelFormat)."
        }
    }
}
