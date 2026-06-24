//
//  CapturePointCloudProcessor.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

enum CapturePointCloudOutputFormat: CaseIterable {
    case colorPLY
    case usdz

    var title: String {
        switch self {
        case .colorPLY:
            return "Color PLY"
        case .usdz:
            return "USDZ"
        }
    }
}

struct CapturePointCloudResult {
    let outputURLs: [URL]
    let pointCount: Int
    let frameCount: Int
}

final class CapturePointCloudProcessor {
    private let maxSampledPointCount = 262_144
    private let minimumDepthDiscontinuityThreshold: Float = 0.04
    private let relativeDepthDiscontinuityThreshold: Float = 0.08
    private let usdzBillboardSize: Float = 0.012
    private var depthVideoReaders: [String: DepthVideoFrameReader] = [:]

    func process(
        session: CapturedScanSession,
        outputFormat: CapturePointCloudOutputFormat,
        status: @escaping (String) -> Void
    ) throws -> CapturePointCloudResult {
        depthVideoReaders.removeAll()
        status("Loading metadata")
        let frames = try loadFrames(from: session.url)
        guard !frames.isEmpty else {
            throw CapturePreviewError.noFrames
        }

        let outputDirectory = session.url.appendingPathComponent("processed", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let outputURLs: [URL]
        let pointCount: Int
        let perFrameTargetPointCount = targetPointCountPerFrame(frameCount: frames.count)
        switch outputFormat {
        case .colorPLY:
            var points: [ColoredPoint] = []
            for (index, frame) in frames.enumerated() {
                status("Processing frame \(index + 1) / \(frames.count)")
                points.append(contentsOf: try makePoints(
                    from: frame,
                    sessionURL: session.url,
                    targetPointCount: perFrameTargetPointCount
                ))
            }
            points = limitedPoints(points, maxCount: maxSampledPointCount)

            let plyURL = outputDirectory.appendingPathComponent("point_cloud_color.ply")
            status("Writing Color PLY")
            try writePLY(points: points, to: plyURL)
            outputURLs = [plyURL]
            pointCount = points.count
        case .usdz:
            let usdzURL = outputDirectory.appendingPathComponent("point_cloud.usdz")
            status("Writing USDZ")
            pointCount = try writeUSDZ(
                frames: frames,
                sessionURL: session.url,
                targetPointCountPerFrame: perFrameTargetPointCount,
                to: usdzURL,
                status: status
            )
            outputURLs = [usdzURL]
        }
        status("Done: \(pointCount) points")

        return CapturePointCloudResult(
            outputURLs: outputURLs,
            pointCount: pointCount,
            frameCount: frames.count
        )
    }

    func loadFirstFrameSummary(session: CapturedScanSession) -> CaptureFrameSummary? {
        guard let frame = try? loadFrames(from: session.url).first else { return nil }
        return makeFrameSummary(frame: frame, sessionURL: session.url)
    }

    func loadFrameSummaries(session: CapturedScanSession) -> [CaptureFrameSummary] {
        guard let frames = try? loadFrames(from: session.url) else { return [] }
        return frames.map { makeFrameSummary(frame: $0, sessionURL: session.url) }
    }

    private func makeFrameSummary(frame: CaptureFrameMetadata, sessionURL: URL) -> CaptureFrameSummary {
        let cameraPosition = SIMD3<Float>(
            frame.cameraToWorld[3],
            frame.cameraToWorld[7],
            frame.cameraToWorld[11]
        )
        let cameraForward = SIMD3<Float>(
            -frame.cameraToWorld[2],
            -frame.cameraToWorld[6],
            -frame.cameraToWorld[10]
        )
        let cameraUp = SIMD3<Float>(
            frame.cameraToWorld[1],
            frame.cameraToWorld[5],
            frame.cameraToWorld[9]
        )
        return CaptureFrameSummary(
            frameName: frame.frameName,
            imageURL: sessionURL.appendingPathComponent(frame.imagePath),
            imagePTSValue: frame.rgbPTSValue,
            imagePTSTimescale: frame.rgbPTSTimescale,
            cameraPositionText: String(
                format: "Camera position: %.3f, %.3f, %.3f",
                cameraPosition.x,
                cameraPosition.y,
                cameraPosition.z
            ),
            cameraForwardText: String(
                format: "Camera forward: %.3f, %.3f, %.3f",
                cameraForward.x,
                cameraForward.y,
                cameraForward.z
            ),
            cameraPose: CaptureCameraPose(
                position: cameraPosition,
                forward: cameraForward,
                up: cameraUp
            )
        )
    }

    private func loadFrames(from sessionURL: URL) throws -> [CaptureFrameMetadata] {
        let metadataDirectory = sessionURL.appendingPathComponent("metadata", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let jsonlURLs = urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !jsonlURLs.isEmpty {
            return try jsonlURLs.flatMap(loadFrameMetadataLines(from:))
        }

        let jsonURLs = urls
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try jsonURLs.map(loadFrameMetadata(from:))
    }

    private func loadFrameMetadataLines(from url: URL) throws -> [CaptureFrameMetadata] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CapturePreviewError.invalidMetadata(url.lastPathComponent)
        }

        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                let data = Data(line.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CapturePreviewError.invalidMetadata(url.lastPathComponent)
                }
                return try loadFrameMetadata(from: object, name: url.lastPathComponent)
            }
    }

    private func loadFrameMetadata(from url: URL) throws -> CaptureFrameMetadata {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CapturePreviewError.invalidMetadata(url.lastPathComponent)
        }
        return try loadFrameMetadata(from: object, name: url.lastPathComponent)
    }

    private func loadFrameMetadata(from object: [String: Any], name: String) throws -> CaptureFrameMetadata {
        let rgb = object["rgb"] as? [String: Any]
        let depth = object["depth"] as? [String: Any]
        let depthVideo = object["depth_video"] as? [String: Any]
        guard let frameName = object["frame_name"] as? String,
              let imagePath = (object["image"] as? String) ?? (rgb?["path"] as? String),
              let width = object["width"] as? Int,
              let height = object["height"] as? Int,
              let intrinsics = object["intrinsics"] as? [NSNumber],
              let cameraToWorld = object["camera_to_world"] as? [NSNumber] else {
            throw CapturePreviewError.invalidMetadata(name)
        }
        let depthPath = depth?["path"] as? String
        let depthVideoPath = depthVideo?["path"] as? String
        let depthWidth = (depth?["width"] as? Int) ?? (depthVideo?["width"] as? Int)
        let depthHeight = (depth?["height"] as? Int) ?? (depthVideo?["height"] as? Int)
        guard let depthWidth, let depthHeight, depthPath != nil || depthVideoPath != nil else {
            throw CapturePreviewError.invalidMetadata(name)
        }

        return CaptureFrameMetadata(
            frameName: frameName,
            imagePath: imagePath,
            rgbPTSValue: (rgb?["pts_value"] as? NSNumber)?.int64Value,
            rgbPTSTimescale: (rgb?["pts_timescale"] as? NSNumber)?.int32Value,
            imageWidth: width,
            imageHeight: height,
            intrinsics: intrinsics.map(\.floatValue),
            cameraToWorld: cameraToWorld.map(\.floatValue),
            depthPath: depthPath,
            depthVideoPath: depthVideoPath,
            depthVideoPTSValue: (depthVideo?["pts_value"] as? NSNumber)?.int64Value,
            depthVideoPTSTimescale: (depthVideo?["pts_timescale"] as? NSNumber)?.int32Value,
            depthVideoMinDepth: (depthVideo?["min_depth"] as? NSNumber)?.floatValue,
            depthVideoMaxDepth: (depthVideo?["max_depth"] as? NSNumber)?.floatValue,
            depthVideoInvalidValue: (depthVideo?["invalid_value"] as? NSNumber)?.uint16Value,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
    }

    private func makePoints(
        from frame: CaptureFrameMetadata,
        sessionURL: URL,
        targetPointCount: Int
    ) throws -> [ColoredPoint] {
        let imageURL = sessionURL.appendingPathComponent(frame.imagePath)
        let image = try makeRGBAImage(from: frame, url: imageURL)
        let depthValues = try loadDepthValues(from: frame, sessionURL: sessionURL)

        let step = samplingStep(for: frame, targetPointCount: targetPointCount)
        let sx = Float(frame.depthWidth) / Float(frame.imageWidth)
        let sy = Float(frame.depthHeight) / Float(frame.imageHeight)
        let fx = frame.intrinsics[0] * sx
        let fy = frame.intrinsics[4] * sy
        let cx = frame.intrinsics[2] * sx
        let cy = frame.intrinsics[5] * sy

        var points: [ColoredPoint] = []
        points.reserveCapacity(min(targetPointCount, frame.depthWidth * frame.depthHeight))

        for y in stride(from: 0, to: frame.depthHeight, by: step) {
            for x in stride(from: 0, to: frame.depthWidth, by: step) {
                let depth = depthValues[y * frame.depthWidth + x]
                guard depth.isFinite, depth > 0 else { continue }

                let world = worldPoint(x: x, y: y, depth: depth, frame: frame, fx: fx, fy: fy, cx: cx, cy: cy)
                let color = image.colorAt(
                    x: Int(Float(x) * Float(image.width) / Float(frame.depthWidth)),
                    y: Int(Float(y) * Float(image.height) / Float(frame.depthHeight))
                )
                points.append(ColoredPoint(x: world[0], y: world[1], z: world[2], r: color.r, g: color.g, b: color.b))
            }
        }

        return points
    }

    private func makeRGBAImage(from frame: CaptureFrameMetadata, url: URL) throws -> RGBAImage {
        guard let ptsValue = frame.rgbPTSValue, let ptsTimescale = frame.rgbPTSTimescale else {
            return try RGBAImage(url: url)
        }

        return try RGBAImage(
            videoURL: url,
            time: CMTime(value: ptsValue, timescale: ptsTimescale)
        )
    }

    private func targetPointCountPerFrame(frameCount: Int) -> Int {
        max(1, Int(ceil(Double(maxSampledPointCount) / Double(max(1, frameCount)))))
    }

    private func samplingStep(for frame: CaptureFrameMetadata, targetPointCount: Int) -> Int {
        max(1, Int(floor(sqrt(Double(frame.depthWidth * frame.depthHeight) / Double(max(1, targetPointCount))))))
    }

    private func limitedPoints(_ points: [ColoredPoint], maxCount: Int) -> [ColoredPoint] {
        guard points.count > maxCount else { return points }
        return Array(points.prefix(maxCount))
    }

    private func readDepthValues(url: URL, expectedCount: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= expectedCount * MemoryLayout<Float>.size else {
            throw CapturePreviewError.invalidDepth(url.lastPathComponent)
        }

        var values = [Float](repeating: 0, count: expectedCount)
        let _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, count: expectedCount * MemoryLayout<Float>.size)
        }
        return values
    }

    private func loadDepthValues(from frame: CaptureFrameMetadata, sessionURL: URL) throws -> [Float] {
        if let depthPath = frame.depthPath {
            let depthURL = sessionURL.appendingPathComponent(depthPath)
            return try readDepthValues(url: depthURL, expectedCount: frame.depthWidth * frame.depthHeight)
        }

        guard let depthVideoPath = frame.depthVideoPath,
              let ptsValue = frame.depthVideoPTSValue,
              let ptsTimescale = frame.depthVideoPTSTimescale,
              let minDepth = frame.depthVideoMinDepth,
              let maxDepth = frame.depthVideoMaxDepth else {
            throw CapturePreviewError.invalidDepth(frame.frameName)
        }

        let reader = try depthVideoReader(path: depthVideoPath, sessionURL: sessionURL)
        return try reader.depthValues(
            at: CMTime(value: ptsValue, timescale: ptsTimescale),
            expectedWidth: frame.depthWidth,
            expectedHeight: frame.depthHeight,
            minDepth: minDepth,
            maxDepth: maxDepth,
            invalidValue: frame.depthVideoInvalidValue ?? 0
        )
    }

    private func depthVideoReader(path: String, sessionURL: URL) throws -> DepthVideoFrameReader {
        if let reader = depthVideoReaders[path] {
            return reader
        }
        let reader = try DepthVideoFrameReader(url: sessionURL.appendingPathComponent(path))
        depthVideoReaders[path] = reader
        return reader
    }

    private func transformPoint(_ point: [Float], by matrix: [Float]) -> [Float] {
        let x = matrix[0] * point[0] + matrix[1] * point[1] + matrix[2] * point[2] + matrix[3]
        let y = matrix[4] * point[0] + matrix[5] * point[1] + matrix[6] * point[2] + matrix[7]
        let z = matrix[8] * point[0] + matrix[9] * point[1] + matrix[10] * point[2] + matrix[11]
        return [x, y, z]
    }

    private func writePLY(points: [ColoredPoint], to url: URL) throws {
        var text = """
        ply
        format ascii 1.0
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """
        for point in points {
            text += "\(point.x) \(point.y) \(point.z) \(point.r) \(point.g) \(point.b)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeUSDZ(
        frames: [CaptureFrameMetadata],
        sessionURL: URL,
        targetPointCountPerFrame: Int,
        to url: URL,
        status: @escaping (String) -> Void
    ) throws -> Int {
        try writePointCloudUSDZ(
            frames: frames,
            sessionURL: sessionURL,
            targetPointCountPerFrame: targetPointCountPerFrame,
            to: url,
            status: status
        )
    }

    private func writePointCloudUSDZ(
        frames: [CaptureFrameMetadata],
        sessionURL: URL,
        targetPointCountPerFrame: Int,
        to url: URL,
        status: @escaping (String) -> Void
    ) throws -> Int {
        var billboardMeshes: [USDZBillboardMesh] = []
        var totalPointCount = 0

        for (index, frame) in frames.enumerated() {
            status("Building billboard frame \(index + 1) / \(frames.count)")
            let remainingPointCount = maxSampledPointCount - totalPointCount
            guard remainingPointCount > 0 else { break }
            let frameTargetPointCount = min(targetPointCountPerFrame, remainingPointCount)
            let points = try makePoints(
                from: frame,
                sessionURL: sessionURL,
                targetPointCount: frameTargetPointCount
            )
            let limitedFramePoints = limitedPoints(points, maxCount: remainingPointCount)
            guard !points.isEmpty else { continue }
            totalPointCount += limitedFramePoints.count
            billboardMeshes.append(
                makeBillboardMesh(
                    name: "frame_\(index)",
                    points: limitedFramePoints,
                    frame: frame
                )
            )
        }

        guard !billboardMeshes.isEmpty else {
            throw CapturePreviewError.emptyMesh
        }

        let usdaData = makeBillboardUSDAText(meshes: billboardMeshes).data(using: .utf8) ?? Data()
        try USDZPackageWriter.writeSingleFilePackage(fileData: usdaData, fileName: "model.usda", to: url)
        return totalPointCount
    }

    private func makeBillboardMesh(
        name: String,
        points: [ColoredPoint],
        frame: CaptureFrameMetadata
    ) -> USDZBillboardMesh {
        let right = normalized(SIMD3(frame.cameraToWorld[0], frame.cameraToWorld[4], frame.cameraToWorld[8]))
        let up = normalized(SIMD3(frame.cameraToWorld[1], frame.cameraToWorld[5], frame.cameraToWorld[9]))
        let halfSize = usdzBillboardSize / 2
        let rightOffset = right * halfSize
        let upOffset = up * halfSize

        var vertices: [USDZColoredVertex] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(points.count * 4)
        indices.reserveCapacity(points.count * 12)

        for point in points {
            let center = SIMD3(point.x, point.y, point.z)
            let color = SIMD3(
                Float(point.r) / 255,
                Float(point.g) / 255,
                Float(point.b) / 255
            )
            let baseIndex = UInt32(vertices.count)

            vertices.append(USDZColoredVertex(position: center - rightOffset - upOffset, color: color))
            vertices.append(USDZColoredVertex(position: center + rightOffset - upOffset, color: color))
            vertices.append(USDZColoredVertex(position: center + rightOffset + upOffset, color: color))
            vertices.append(USDZColoredVertex(position: center - rightOffset + upOffset, color: color))
            indices.append(contentsOf: [
                baseIndex, baseIndex + 1, baseIndex + 2,
                baseIndex, baseIndex + 2, baseIndex + 3,
                baseIndex + 2, baseIndex + 1, baseIndex,
                baseIndex + 3, baseIndex + 2, baseIndex
            ])
        }

        return USDZBillboardMesh(name: name, vertices: vertices, indices: indices)
    }

    private func writeDepthMeshUSDZ(
        frames: [CaptureFrameMetadata],
        sessionURL: URL,
        to url: URL,
        status: @escaping (String) -> Void
    ) throws -> Int {
        let fileManager = FileManager.default
        let workDirectory = url
            .deletingLastPathComponent()
            .appendingPathComponent("usdz_work_\(UUID().uuidString)", isDirectory: true)
        let textureDirectory = workDirectory.appendingPathComponent("textures", isDirectory: true)
        try fileManager.createDirectory(at: textureDirectory, withIntermediateDirectories: true)

        var frameMeshes: [USDZFrameMesh] = []
        var packageFiles: [USDZPackageWriter.PackageFile] = []
        var totalVertexCount = 0
        let perFrameTargetPointCount = targetPointCountPerFrame(frameCount: frames.count)

        for (index, frame) in frames.enumerated() {
            status("Meshing frame \(index + 1) / \(frames.count)")
            var vertices: [USDZMeshVertex] = []
            let remainingPointCount = maxSampledPointCount - totalVertexCount
            guard remainingPointCount > 0 else { break }
            let meshIndices = try appendDepthMesh(
                frame: frame,
                sessionURL: sessionURL,
                targetPointCount: min(perFrameTargetPointCount, remainingPointCount),
                vertices: &vertices
            )
            guard !meshIndices.isEmpty else { continue }
            totalVertexCount += vertices.count

            let textureFileName = "textures/\(safeUSDZFileName(frame.frameName)).\(textureFileExtension(for: frame))"
            let textureURL = workDirectory.appendingPathComponent(textureFileName)
            try fileManager.createDirectory(
                at: textureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try copyReplacingItem(
                from: sessionURL.appendingPathComponent(frame.imagePath),
                to: textureURL
            )

            frameMeshes.append(
                USDZFrameMesh(
                    name: "frame_\(index)",
                    materialName: "material_\(index)",
                    textureFileName: textureFileName,
                    vertices: vertices,
                    indices: meshIndices
                )
            )
            packageFiles.append(
                USDZPackageWriter.PackageFile(
                    data: try Data(contentsOf: textureURL),
                    fileName: textureFileName
                )
            )
        }

        guard !frameMeshes.isEmpty else {
            throw CapturePreviewError.emptyMesh
        }

        let usdaData = makeDepthMeshUSDAText(frameMeshes: frameMeshes).data(using: .utf8) ?? Data()
        packageFiles.insert(
            USDZPackageWriter.PackageFile(data: usdaData, fileName: "model.usda"),
            at: 0
        )
        try USDZPackageWriter.writePackage(files: packageFiles, to: url)
        try? fileManager.removeItem(at: workDirectory)
        return totalVertexCount
    }

    private func appendDepthMesh(
        frame: CaptureFrameMetadata,
        sessionURL: URL,
        targetPointCount: Int,
        vertices: inout [USDZMeshVertex]
    ) throws -> [UInt32] {
        let depthValues = try loadDepthValues(from: frame, sessionURL: sessionURL)
        let step = samplingStep(for: frame, targetPointCount: targetPointCount)
        let sampledX = Array(stride(from: 0, to: frame.depthWidth, by: step))
        let sampledY = Array(stride(from: 0, to: frame.depthHeight, by: step))
        guard sampledX.count > 1, sampledY.count > 1 else { return [] }

        let sx = Float(frame.depthWidth) / Float(frame.imageWidth)
        let sy = Float(frame.depthHeight) / Float(frame.imageHeight)
        let fx = frame.intrinsics[0] * sx
        let fy = frame.intrinsics[4] * sy
        let cx = frame.intrinsics[2] * sx
        let cy = frame.intrinsics[5] * sy

        var gridIndices = [UInt32?](repeating: nil, count: sampledX.count * sampledY.count)
        var gridDepths = [Float](repeating: 0, count: sampledX.count * sampledY.count)

        for (gridY, y) in sampledY.enumerated() {
            for (gridX, x) in sampledX.enumerated() {
                let gridIndex = gridY * sampledX.count + gridX
                let depth = depthValues[y * frame.depthWidth + x]
                guard depth.isFinite, depth > 0 else { continue }

                let world = worldPoint(x: x, y: y, depth: depth, frame: frame, fx: fx, fy: fy, cx: cx, cy: cy)
                let u = Float(x) / Float(max(frame.depthWidth - 1, 1))
                let v = 1 - (Float(y) / Float(max(frame.depthHeight - 1, 1)))
                let vertexIndex = UInt32(vertices.count)
                vertices.append(
                    USDZMeshVertex(
                        position: SIMD3(world[0], world[1], world[2]),
                        textureCoordinate: SIMD2(u, v)
                    )
                )
                gridIndices[gridIndex] = vertexIndex
                gridDepths[gridIndex] = depth
            }
        }

        var indices: [UInt32] = []
        for y in 0..<(sampledY.count - 1) {
            for x in 0..<(sampledX.count - 1) {
                let p00 = y * sampledX.count + x
                let p10 = y * sampledX.count + x + 1
                let p01 = (y + 1) * sampledX.count + x
                let p11 = (y + 1) * sampledX.count + x + 1
                guard let i00 = gridIndices[p00],
                      let i10 = gridIndices[p10],
                      let i01 = gridIndices[p01],
                      let i11 = gridIndices[p11],
                      canConnectDepths([
                          gridDepths[p00],
                          gridDepths[p10],
                          gridDepths[p01],
                          gridDepths[p11]
                      ]) else {
                    continue
                }

                appendDoubleSidedTriangle(i00, i10, i01, to: &indices)
                appendDoubleSidedTriangle(i10, i11, i01, to: &indices)
            }
        }
        return indices
    }

    private func makeBillboardUSDAText(meshes: [USDZBillboardMesh]) -> String {
        var text = """
        #usda 1.0
        (
            defaultPrim = "model"
            upAxis = "Y"
        )

        def Xform "model"
        {
            def Scope "Geom"
            {

        """

        for mesh in meshes {
            text += """
                    def Mesh "\(mesh.name)"
                    {
                        uniform bool doubleSided = 1
                        int[] faceVertexCounts = [\(repeatedUSDAInt(3, count: mesh.indices.count / 3))]
                        int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]
                        point3f[] points = [\(mesh.vertices.map { usdaPoint($0.position) }.joined(separator: ", "))]
                        color3f[] primvars:displayColor = [\(mesh.vertices.map { usdaColor($0.color) }.joined(separator: ", "))] (
                            interpolation = "vertex"
                        )
                        uniform token subdivisionScheme = "none"
                    }

            """
        }

        text += """
            }
        }

        """
        return text
    }

    private func makeDepthMeshUSDAText(frameMeshes: [USDZFrameMesh]) -> String {
        var text = """
        #usda 1.0
        (
            defaultPrim = "model"
            upAxis = "Y"
        )

        def Xform "model"
        {
            def Scope "Geom"
            {

        """

        for mesh in frameMeshes {
            text += """
                    def Mesh "\(mesh.name)" (
                        prepend apiSchemas = ["MaterialBindingAPI"]
                    )
                    {
                        uniform bool doubleSided = 1
                        rel material:binding = </model/Materials/\(mesh.materialName)>
                        int[] faceVertexCounts = [\(repeatedUSDAInt(3, count: mesh.indices.count / 3))]
                        int[] faceVertexIndices = [\(mesh.indices.map(String.init).joined(separator: ", "))]
                        point3f[] points = [\(mesh.vertices.map { usdaPoint($0.position) }.joined(separator: ", "))]
                        texCoord2f[] primvars:st = [\(mesh.vertices.map { usdaTexCoord($0.textureCoordinate) }.joined(separator: ", "))] (
                            interpolation = "vertex"
                        )
                        uniform token subdivisionScheme = "none"
                    }

            """
        }

        text += """
            }

            def Scope "Materials"
            {

        """

        for mesh in frameMeshes {
            text += """
                    def Material "\(mesh.materialName)"
                    {
                        token outputs:surface.connect = </model/Materials/\(mesh.materialName)/PreviewSurface.outputs:surface>

                        def Shader "PreviewSurface"
                        {
                            uniform token info:id = "UsdPreviewSurface"
                            color3f inputs:diffuseColor.connect = </model/Materials/\(mesh.materialName)/BaseColorTexture.outputs:rgb>
                            float inputs:roughness = 0.75
                            token outputs:surface
                        }

                        def Shader "BaseColorTexture"
                        {
                            uniform token info:id = "UsdUVTexture"
                            asset inputs:file = @\(mesh.textureFileName)@
                            float2 inputs:st.connect = </model/Materials/\(mesh.materialName)/PrimvarReader_st.outputs:result>
                            color3f outputs:rgb
                        }

                        def Shader "PrimvarReader_st"
                        {
                            uniform token info:id = "UsdPrimvarReader_float2"
                            token inputs:varname = "st"
                            float2 outputs:result
                        }
                    }

            """
        }

        text += """
            }
        }

        """
        return text
    }

    private func repeatedUSDAInt(_ value: Int, count: Int) -> String {
        Array(repeating: String(value), count: count).joined(separator: ", ")
    }

    private func usdaPoint(_ point: SIMD3<Float>) -> String {
        "(\(usdaFloat(point.x)), \(usdaFloat(point.y)), \(usdaFloat(point.z)))"
    }

    private func usdaColor(_ color: SIMD3<Float>) -> String {
        "(\(usdaFloat(color.x)), \(usdaFloat(color.y)), \(usdaFloat(color.z)))"
    }

    private func usdaTexCoord(_ uv: SIMD2<Float>) -> String {
        "(\(usdaFloat(uv.x)), \(usdaFloat(uv.y)))"
    }

    private func usdaFloat(_ value: Float) -> String {
        String(format: "%.6f", value)
    }

    private func textureFileExtension(for frame: CaptureFrameMetadata) -> String {
        let ext = (frame.imagePath as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "jpg" : ext
    }

    private func safeUSDZFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let fileName = String(scalars)
        return fileName.isEmpty ? UUID().uuidString : fileName
    }

    private func copyReplacingItem(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func appendDoubleSidedTriangle(
        _ a: UInt32,
        _ b: UInt32,
        _ c: UInt32,
        to indices: inout [UInt32]
    ) {
        indices.append(contentsOf: [a, b, c, c, b, a])
    }

    private func worldPoint(
        x: Int,
        y: Int,
        depth: Float,
        frame: CaptureFrameMetadata,
        fx: Float,
        fy: Float,
        cx: Float,
        cy: Float
    ) -> [Float] {
        let cameraX = (Float(x) - cx) * depth / fx
        let cameraY = -(Float(y) - cy) * depth / fy
        return transformPoint([cameraX, cameraY, -depth], by: frame.cameraToWorld)
    }

    private func canConnectDepths(_ depths: [Float]) -> Bool {
        guard let minDepth = depths.min(), let maxDepth = depths.max() else {
            return false
        }
        let threshold = max(minimumDepthDiscontinuityThreshold, minDepth * relativeDepthDiscontinuityThreshold)
        return maxDepth - minDepth <= threshold
    }

    private func normalized(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let length = sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
        guard length > 0 else { return value }
        return value / length
    }
}

struct CaptureFrameSummary {
    let frameName: String
    let imageURL: URL
    let imagePTSValue: Int64?
    let imagePTSTimescale: Int32?
    let cameraPositionText: String
    let cameraForwardText: String
    let cameraPose: CaptureCameraPose
}

struct CaptureCameraPose {
    let position: SIMD3<Float>
    let forward: SIMD3<Float>
    let up: SIMD3<Float>
}

private struct CaptureFrameMetadata {
    let frameName: String
    let imagePath: String
    let rgbPTSValue: Int64?
    let rgbPTSTimescale: Int32?
    let imageWidth: Int
    let imageHeight: Int
    let intrinsics: [Float]
    let cameraToWorld: [Float]
    let depthPath: String?
    let depthVideoPath: String?
    let depthVideoPTSValue: Int64?
    let depthVideoPTSTimescale: Int32?
    let depthVideoMinDepth: Float?
    let depthVideoMaxDepth: Float?
    let depthVideoInvalidValue: UInt16?
    let depthWidth: Int
    let depthHeight: Int
}

private struct ColoredPoint {
    let x: Float
    let y: Float
    let z: Float
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private struct USDZColoredVertex {
    let position: SIMD3<Float>
    let color: SIMD3<Float>
}

private struct USDZBillboardMesh {
    let name: String
    let vertices: [USDZColoredVertex]
    let indices: [UInt32]
}

private struct USDZMeshVertex {
    let position: SIMD3<Float>
    let textureCoordinate: SIMD2<Float>
}

private struct USDZFrameMesh {
    let name: String
    let materialName: String
    let textureFileName: String
    let vertices: [USDZMeshVertex]
    let indices: [UInt32]
}

private struct RGBAColor {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

private final class DepthVideoFrameReader {
    private let asset: AVURLAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var lastRequestedTime: CMTime?

    init(url: URL) throws {
        asset = AVURLAsset(url: url)
        try resetReader()
    }

    func depthValues(
        at time: CMTime,
        expectedWidth: Int,
        expectedHeight: Int,
        minDepth: Float,
        maxDepth: Float,
        invalidValue: UInt16
    ) throws -> [Float] {
        if let lastRequestedTime, time < lastRequestedTime {
            try resetReader()
        }
        lastRequestedTime = time

        guard let output else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        let tolerance = CMTime(value: 1, timescale: max(time.timescale, 600))
        while let sampleBuffer = output.copyNextSampleBuffer() {
            let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard sampleTime + tolerance >= time else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
            }
            return try decodeDepthValues(
                from: pixelBuffer,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                minDepth: minDepth,
                maxDepth: maxDepth,
                invalidValue: invalidValue
            )
        }

        throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
    }

    private func resetReader() throws {
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        self.reader = reader
        self.output = output
    }

    private func decodeDepthValues(
        from pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int,
        minDepth: Float,
        maxDepth: Float,
        invalidValue: UInt16
    ) throws -> [Float] {
        guard CVPixelBufferGetWidth(pixelBuffer) == expectedWidth,
              CVPixelBufferGetHeight(pixelBuffer) == expectedHeight else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let depthRange = maxDepth - minDepth
        var values = [Float](repeating: 0, count: expectedWidth * expectedHeight)

        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            for row in 0..<expectedHeight {
                let yRow = yBaseAddress.advanced(by: row * yBytesPerRow).assumingMemoryBound(to: UInt16.self)
                for column in 0..<expectedWidth {
                    let quantized = UInt16(littleEndian: yRow[column]) >> 6
                    values[row * expectedWidth + column] = depthValue(
                        quantized: quantized,
                        maxQuantized: 1023,
                        minDepth: minDepth,
                        depthRange: depthRange,
                        invalidValue: invalidValue
                    )
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            for row in 0..<expectedHeight {
                let yRow = yBaseAddress.advanced(by: row * yBytesPerRow).assumingMemoryBound(to: UInt8.self)
                for column in 0..<expectedWidth {
                    let quantized = UInt16(yRow[column]) * 1023 / 255
                    values[row * expectedWidth + column] = depthValue(
                        quantized: quantized,
                        maxQuantized: 1023,
                        minDepth: minDepth,
                        depthRange: depthRange,
                        invalidValue: invalidValue
                    )
                }
            }
        default:
            throw CapturePreviewError.invalidDepth(asset.url.lastPathComponent)
        }

        return values
    }

    private func depthValue(
        quantized: UInt16,
        maxQuantized: UInt16,
        minDepth: Float,
        depthRange: Float,
        invalidValue: UInt16
    ) -> Float {
        guard quantized != invalidValue else { return 0 }
        return minDepth + (Float(quantized) / Float(maxQuantized)) * depthRange
    }
}

private struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(url: URL) throws {
        guard let image = UIImage(contentsOfFile: url.path),
              let cgImage = image.cgImage else {
            throw CapturePreviewError.invalidImage(url.lastPathComponent)
        }

        width = cgImage.width
        height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CapturePreviewError.invalidImage(url.lastPathComponent)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = data
    }

    init(videoURL: URL, time: CMTime) throws {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cgImage: CGImage
        do {
            cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        } catch {
            throw CapturePreviewError.invalidImage(videoURL.lastPathComponent)
        }

        width = cgImage.width
        height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CapturePreviewError.invalidImage(videoURL.lastPathComponent)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = data
    }

    func colorAt(x: Int, y: Int) -> RGBAColor {
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let index = (clampedY * width + clampedX) * 4
        return RGBAColor(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2])
    }
}

enum CapturePreviewError: LocalizedError {
    case noFrames
    case invalidMetadata(String)
    case invalidDepth(String)
    case invalidImage(String)
    case emptyMesh

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "No metadata frames were found in this capture."
        case .invalidMetadata(let name):
            return "Invalid metadata file: \(name)."
        case .invalidDepth(let name):
            return "Invalid depth file: \(name)."
        case .invalidImage(let name):
            return "Invalid image file: \(name)."
        case .emptyMesh:
            return "No valid points or mesh triangles could be generated from the depth frames."
        }
    }
}
