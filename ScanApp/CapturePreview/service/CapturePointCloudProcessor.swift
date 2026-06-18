//
//  CapturePointCloudProcessor.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import CoreGraphics
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
    private let maxPointsPerFrame = 8_192
    private let minimumDepthDiscontinuityThreshold: Float = 0.04
    private let relativeDepthDiscontinuityThreshold: Float = 0.08
    private let usdzBillboardSize: Float = 0.012

    func process(
        session: CapturedScanSession,
        outputFormat: CapturePointCloudOutputFormat,
        status: @escaping (String) -> Void
    ) throws -> CapturePointCloudResult {
        status("Loading metadata")
        let frames = try loadFrames(from: session.url)
        guard !frames.isEmpty else {
            throw CapturePreviewError.noFrames
        }

        let outputDirectory = session.url.appendingPathComponent("processed", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let outputURLs: [URL]
        let pointCount: Int
        switch outputFormat {
        case .colorPLY:
            var points: [ColoredPoint] = []
            for (index, frame) in frames.enumerated() {
                status("Processing frame \(index + 1) / \(frames.count)")
                points.append(contentsOf: try makePoints(from: frame, sessionURL: session.url))
            }

            let plyURL = outputDirectory.appendingPathComponent("point_cloud_color.ply")
            status("Writing Color PLY")
            try writePLY(points: points, to: plyURL)
            outputURLs = [plyURL]
            pointCount = points.count
        case .usdz:
            let usdzURL = outputDirectory.appendingPathComponent("point_cloud.usdz")
            status("Writing USDZ")
            pointCount = try writeUSDZ(frames: frames, sessionURL: session.url, to: usdzURL, status: status)
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
        return CaptureFrameSummary(
            frameName: frame.frameName,
            imageURL: session.url.appendingPathComponent(frame.imagePath),
            cameraPositionText: String(
                format: "Camera position: %.3f, %.3f, %.3f",
                frame.cameraToWorld[3],
                frame.cameraToWorld[7],
                frame.cameraToWorld[11]
            ),
            cameraForwardText: String(
                format: "Camera forward: %.3f, %.3f, %.3f",
                -frame.cameraToWorld[2],
                -frame.cameraToWorld[6],
                -frame.cameraToWorld[10]
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
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try urls.map(loadFrameMetadata(from:))
    }

    private func loadFrameMetadata(from url: URL) throws -> CaptureFrameMetadata {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frameName = object["frame_name"] as? String,
              let imagePath = object["image"] as? String,
              let width = object["width"] as? Int,
              let height = object["height"] as? Int,
              let intrinsics = object["intrinsics"] as? [NSNumber],
              let cameraToWorld = object["camera_to_world"] as? [NSNumber],
              let depth = object["depth"] as? [String: Any],
              let depthPath = depth["path"] as? String,
              let depthWidth = depth["width"] as? Int,
              let depthHeight = depth["height"] as? Int else {
            throw CapturePreviewError.invalidMetadata(url.lastPathComponent)
        }

        return CaptureFrameMetadata(
            frameName: frameName,
            imagePath: imagePath,
            imageWidth: width,
            imageHeight: height,
            intrinsics: intrinsics.map(\.floatValue),
            cameraToWorld: cameraToWorld.map(\.floatValue),
            depthPath: depthPath,
            depthWidth: depthWidth,
            depthHeight: depthHeight
        )
    }

    private func makePoints(from frame: CaptureFrameMetadata, sessionURL: URL) throws -> [ColoredPoint] {
        let imageURL = sessionURL.appendingPathComponent(frame.imagePath)
        let depthURL = sessionURL.appendingPathComponent(frame.depthPath)
        let image = try RGBAImage(url: imageURL)
        let depthValues = try readDepthValues(url: depthURL, expectedCount: frame.depthWidth * frame.depthHeight)

        let step = samplingStep(for: frame)
        let sx = Float(frame.depthWidth) / Float(frame.imageWidth)
        let sy = Float(frame.depthHeight) / Float(frame.imageHeight)
        let fx = frame.intrinsics[0] * sx
        let fy = frame.intrinsics[4] * sy
        let cx = frame.intrinsics[2] * sx
        let cy = frame.intrinsics[5] * sy

        var points: [ColoredPoint] = []
        points.reserveCapacity(min(maxPointsPerFrame, frame.depthWidth * frame.depthHeight))

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

    private func samplingStep(for frame: CaptureFrameMetadata) -> Int {
        max(1, Int(ceil(sqrt(Double(frame.depthWidth * frame.depthHeight) / Double(maxPointsPerFrame)))))
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
        to url: URL,
        status: @escaping (String) -> Void
    ) throws -> Int {
        try writePointCloudUSDZ(frames: frames, sessionURL: sessionURL, to: url, status: status)
    }

    private func writePointCloudUSDZ(
        frames: [CaptureFrameMetadata],
        sessionURL: URL,
        to url: URL,
        status: @escaping (String) -> Void
    ) throws -> Int {
        var billboardMeshes: [USDZBillboardMesh] = []
        var totalPointCount = 0

        for (index, frame) in frames.enumerated() {
            status("Building billboard frame \(index + 1) / \(frames.count)")
            let points = try makePoints(from: frame, sessionURL: sessionURL)
            guard !points.isEmpty else { continue }
            totalPointCount += points.count
            billboardMeshes.append(
                makeBillboardMesh(
                    name: "frame_\(index)",
                    points: points,
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
        indices.reserveCapacity(points.count * 6)

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
                baseIndex, baseIndex + 2, baseIndex + 3
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

        for (index, frame) in frames.enumerated() {
            status("Meshing frame \(index + 1) / \(frames.count)")
            var vertices: [USDZMeshVertex] = []
            let meshIndices = try appendDepthMesh(
                frame: frame,
                sessionURL: sessionURL,
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
        vertices: inout [USDZMeshVertex]
    ) throws -> [UInt32] {
        let depthURL = sessionURL.appendingPathComponent(frame.depthPath)
        let depthValues = try readDepthValues(url: depthURL, expectedCount: frame.depthWidth * frame.depthHeight)
        let step = samplingStep(for: frame)
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
    let cameraPositionText: String
    let cameraForwardText: String
}

private struct CaptureFrameMetadata {
    let frameName: String
    let imagePath: String
    let imageWidth: Int
    let imageHeight: Int
    let intrinsics: [Float]
    let cameraToWorld: [Float]
    let depthPath: String
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
