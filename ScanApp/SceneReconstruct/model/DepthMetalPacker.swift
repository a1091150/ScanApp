//
//  DepthMetalPacker.swift
//  ScanApp
//
//  Created by Codex on 2026/6/24.
//

import CoreVideo
import Foundation
import Metal

final class DepthMetalPacker {
    private struct Uniforms {
        var minDepth: Float
        var maxDepth: Float
        var invalidValue: UInt32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SceneCaptureRecorderError.videoWriterFailed("Metal device is unavailable for packed depth video.")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not create Metal command queue for packed depth video.")
        }
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "packDepthFloat32ToYUV10") else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not load packed depth Metal kernel.")
        }

        var textureCache: CVMetalTextureCache?
        let cacheResult = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard cacheResult == kCVReturnSuccess, textureCache != nil else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not create Metal texture cache for packed depth video.")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = try device.makeComputePipelineState(function: function)
        self.textureCache = textureCache
    }

    func pack(
        depthMap: CVPixelBuffer,
        into outputPixelBuffer: CVPixelBuffer,
        minDepth: Float,
        maxDepth: Float,
        invalidValue: UInt16
    ) throws {
        let depthPixelFormat = CVPixelBufferGetPixelFormatType(depthMap)
        guard depthPixelFormat == kCVPixelFormatType_DepthFloat32 || depthPixelFormat == kCVPixelFormatType_DisparityFloat32 else {
            throw SceneCaptureRecorderError.unsupportedDepthPixelFormat(depthPixelFormat)
        }
        guard CVPixelBufferGetWidth(depthMap) == CVPixelBufferGetWidth(outputPixelBuffer),
              CVPixelBufferGetHeight(depthMap) == CVPixelBufferGetHeight(outputPixelBuffer) else {
            throw SceneCaptureRecorderError.videoWriterFailed("Packed depth video dimensions do not match the depth map.")
        }

        guard let depthTexture = makeTexture(
            from: depthMap,
            pixelFormat: .r32Float,
            width: CVPixelBufferGetWidth(depthMap),
            height: CVPixelBufferGetHeight(depthMap),
            planeIndex: 0
        ),
        let yTexture = makeTexture(
            from: outputPixelBuffer,
            pixelFormat: .r16Uint,
            width: CVPixelBufferGetWidthOfPlane(outputPixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(outputPixelBuffer, 0),
            planeIndex: 0
        ),
        let cbcrTexture = makeTexture(
            from: outputPixelBuffer,
            pixelFormat: .rg16Uint,
            width: CVPixelBufferGetWidthOfPlane(outputPixelBuffer, 1),
            height: CVPixelBufferGetHeightOfPlane(outputPixelBuffer, 1),
            planeIndex: 1
        ) else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not create Metal textures for packed depth video.")
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw SceneCaptureRecorderError.videoWriterFailed("Could not create Metal command buffer for packed depth video.")
        }

        var uniforms = Uniforms(
            minDepth: minDepth,
            maxDepth: maxDepth,
            invalidValue: UInt32(invalidValue)
        )

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(depthTexture, index: 0)
        encoder.setTexture(yTexture, index: 1)
        encoder.setTexture(cbcrTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        let width = pipelineState.threadExecutionWidth
        let height = max(1, pipelineState.maxTotalThreadsPerThreadgroup / width)
        let threadsPerThreadgroup = MTLSize(width: width, height: height, depth: 1)
        let threadgroups = MTLSize(
            width: (CVPixelBufferGetWidth(depthMap) + width - 1) / width,
            height: (CVPixelBufferGetHeight(depthMap) + height - 1) / height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw SceneCaptureRecorderError.videoWriterFailed("Packed depth Metal kernel failed: \(error.localizedDescription)")
        }
    }

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) -> MTLTexture? {
        guard let textureCache else { return nil }

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard result == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
