//
//  PixelBufferBinaryWriter.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import CoreVideo
import Foundation

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

func writeUInt8PixelBuffer(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
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
