//
//  RGBVideoWriter.swift
//  ScanApp
//
//  Created by Codex on 2026/6/24.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class RGBVideoWriter {
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var isFinished = false

    init(url: URL, width: Int, height: Int, transform: CGAffineTransform = .identity) throws {
        guard width > 0, height > 0 else {
            throw SceneCaptureRecorderError.invalidVideoDimensions(width: width, height: height)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mov)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = transform

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard assetWriter.canAdd(input) else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not add RGB video input.")
        }
        assetWriter.add(input)

        guard assetWriter.startWriting() else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "Could not start RGB video writer.")
        }
        assetWriter.startSession(atSourceTime: .zero)
    }

    func append(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        guard !isFinished else { return }
        guard assetWriter.status == .writing else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "RGB video writer is not writing.")
        }
        guard input.isReadyForMoreMediaData else {
            throw SceneCaptureRecorderError.videoWriterNotReady
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw SceneCaptureRecorderError.videoWriterFailed(assetWriter.error?.localizedDescription ?? "Could not append RGB frame.")
        }
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
} 
