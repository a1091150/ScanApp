//
//  DepthPackedVideoWriter.swift
//  ScanApp
//
//  Created by Codex on 2026/6/24.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

struct DepthPackedVideoFrameInfo {
    let path: String
    let encoding: String
    let codec: String
    let minDepth: Float
    let maxDepth: Float
    let invalidValue: UInt16
    let width: Int
    let height: Int
    let ptsValue: Int64
    let ptsTimescale: Int32
    let ptsSeconds: Double
}

final class DepthPackedVideoWriter {
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let relativePath: String
    private let minDepth: Float
    private let maxDepth: Float
    private let invalidValue: UInt16 = 0
    private var isFinished = false

    init(url: URL, relativePath: String, width: Int, height: Int, minDepth: Float = 0, maxDepth: Float = 5) throws {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw SceneCaptureRecorderError.invalidVideoDimensions(width: width, height: height)
        }

        self.relativePath = relativePath
        self.minDepth = minDepth
        self.maxDepth = maxDepth

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoQualityKey: 1.0
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard assetWriter.canAdd(input) else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not add packed depth video input.")
        }
        assetWriter.add(input)

        guard assetWriter.startWriting() else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "Could not start packed depth video writer.")
        }
        assetWriter.startSession(atSourceTime: .zero)
    }

    func append(_ depthMap: CVPixelBuffer, presentationTime: CMTime) throws -> DepthPackedVideoFrameInfo {
        guard !isFinished else {
            return makeFrameInfo(
                presentationTime: presentationTime,
                width: CVPixelBufferGetWidth(depthMap),
                height: CVPixelBufferGetHeight(depthMap)
            )
        }
        guard assetWriter.status == .writing else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "Packed depth video writer is not writing.")
        }
        guard input.isReadyForMoreMediaData else {
            throw SceneCaptureRecorderError.videoWriterNotReady
        }
        guard let pixelBufferPool = adaptor.pixelBufferPool else {
            throw SceneCaptureRecorderError.videoWriterFailed("Packed depth video pixel buffer pool is unavailable.")
        }

        var outputPixelBuffer: CVPixelBuffer?
        let createResult = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &outputPixelBuffer)
        guard createResult == kCVReturnSuccess, let outputPixelBuffer else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not allocate packed depth video pixel buffer.")
        }

        try packDepth(depthMap, into: outputPixelBuffer)

        guard adaptor.append(outputPixelBuffer, withPresentationTime: presentationTime) else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "Could not append packed depth frame.")
        }

        return makeFrameInfo(
            presentationTime: presentationTime,
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap)
        )
    }

    func finish(completion: @escaping () -> Void) {
        guard !isFinished else {
            completion()
            return
        }

        isFinished = true
        input.markAsFinished()
        assetWriter.finishWriting(completionHandler: completion)
    }

    private func makeFrameInfo(presentationTime: CMTime, width: Int, height: Int) -> DepthPackedVideoFrameInfo {
        DepthPackedVideoFrameInfo(
            path: relativePath,
            encoding: "linear_uint10",
            codec: "hevc",
            minDepth: minDepth,
            maxDepth: maxDepth,
            invalidValue: invalidValue,
            width: width,
            height: height,
            ptsValue: presentationTime.value,
            ptsTimescale: presentationTime.timescale,
            ptsSeconds: presentationTime.seconds
        )
    }

    private func packDepth(_ depthMap: CVPixelBuffer, into outputPixelBuffer: CVPixelBuffer) throws {
        let depthPixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
        guard depthPixelFormat == kCVPixelFormatType_DepthFloat32 || depthPixelFormat == kCVPixelFormatType_DisparityFloat32 else {
            throw SceneCaptureRecorderError.unsupportedDepthPixelFormat(depthPixelFormat)
        }
        guard CVPixelBufferGetWidth(depthMap) == CVPixelBufferGetWidth(outputPixelBuffer),
              CVPixelBufferGetHeight(depthMap) == CVPixelBufferGetHeight(outputPixelBuffer) else {
            throw SceneCaptureRecorderError.videoWriterFailed("Packed depth video dimensions do not match the depth map.")
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(outputPixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(outputPixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap),
              let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0),
              let cbcrBaseAddress = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1) else {
            throw SceneCaptureRecorderError.pixelBufferBaseAddressUnavailable
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0)
        let cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1)
        let scale = Float(1023) / max(maxDepth - minDepth, .leastNonzeroMagnitude)

        for row in 0..<height {
            let depthRow = depthBaseAddress.advanced(by: row * depthBytesPerRow).assumingMemoryBound(to: Float.self)
            let yRow = yBaseAddress.advanced(by: row * yBytesPerRow).assumingMemoryBound(to: UInt16.self)

            for column in 0..<width {
                let depth = depthRow[column]
                let quantized: UInt16
                if depth.isFinite, depth > minDepth {
                    let value = min(max((depth - minDepth) * scale, 1), 1023)
                    quantized = UInt16(value.rounded())
                } else {
                    quantized = invalidValue
                }
                yRow[column] = (quantized << 6).littleEndian
            }
        }

        let neutralChroma = UInt16(512 << 6).littleEndian
        let chromaHeight = CVPixelBufferGetHeightOfPlane(outputPixelBuffer, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(outputPixelBuffer, 1)
        for row in 0..<chromaHeight {
            let cbcrRow = cbcrBaseAddress.advanced(by: row * cbcrBytesPerRow).assumingMemoryBound(to: UInt16.self)
            for column in 0..<(chromaWidth * 2) {
                cbcrRow[column] = neutralChroma
            }
        }
    }
}
