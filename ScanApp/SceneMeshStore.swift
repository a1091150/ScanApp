//
//  SceneMeshStore.swift
//  ScanApp
//
//  Created by Codex on 2026/6/10.
//

import ARKit
import Foundation
import Metal
import ModelIO
import simd

struct ScenePoint {
    let position: SIMD3<Float>
}

final class SceneMeshStore {
    private(set) var meshAnchors: [UUID: ARMeshAnchor] = [:]

    var anchorCount: Int {
        meshAnchors.count
    }

    var vertexCount: Int {
        meshAnchors.values.reduce(0) { count, anchor in
            count + anchor.geometry.vertices.count
        }
    }

    var faceCount: Int {
        meshAnchors.values.reduce(0) { count, anchor in
            count + anchor.geometry.faces.count
        }
    }

    func addOrUpdate(_ anchor: ARMeshAnchor) {
        meshAnchors[anchor.identifier] = anchor
    }

    func remove(_ anchor: ARMeshAnchor) {
        meshAnchors.removeValue(forKey: anchor.identifier)
    }

    func reset() {
        meshAnchors.removeAll()
    }

    func buildWorldPointCloud(maxPointsPerAnchor: Int? = nil) -> [ScenePoint] {
        meshAnchors.values.flatMap { anchor in
            worldVertices(from: anchor, maxPoints: maxPointsPerAnchor).map(ScenePoint.init(position:))
        }
    }

    func exportOBJ(to fileURL: URL) throws {
        guard MDLAsset.canExportFileExtension(fileURL.pathExtension) else {
            throw SceneMeshExportError.unsupportedFileExtension(fileURL.pathExtension)
        }

        let asset = MDLAsset()
        var exportedMeshCount = 0

        for anchor in meshAnchors.values.sorted(by: { $0.identifier.uuidString < $1.identifier.uuidString }) {
            guard let mesh = makeModelIOMesh(from: anchor) else { continue }
            asset.add(mesh)
            exportedMeshCount += 1
        }

        guard exportedMeshCount > 0 else {
            throw SceneMeshExportError.noExportableMeshes
        }

        try asset.export(to: fileURL)
    }
}

enum SceneMeshExportError: LocalizedError {
    case noExportableMeshes
    case unsupportedFileExtension(String)

    var errorDescription: String? {
        switch self {
        case .noExportableMeshes:
            return "No mesh anchors could be converted to a ModelIO mesh."
        case .unsupportedFileExtension(let fileExtension):
            return "ModelIO cannot export .\(fileExtension) files on this device."
        }
    }
}

func worldVertices(from anchor: ARMeshAnchor, maxPoints: Int? = nil) -> [SIMD3<Float>] {
    let geometry = anchor.geometry
    let vertices = geometry.vertices

    guard vertices.format == .float3 else {
        print("Skipping ARMeshAnchor \(anchor.identifier): unsupported vertex format \(vertices.format.rawValue)")
        return []
    }

    let count = vertices.count
    guard count > 0 else { return [] }

    let stride = vertices.stride
    let offset = vertices.offset
    let contents = vertices.buffer.contents()
    let transform = anchor.transform
    let sampleStep: Int
    let outputLimit: Int

    if let maxPoints, maxPoints > 0, count > maxPoints {
        sampleStep = Int(ceil(Double(count) / Double(maxPoints)))
        outputLimit = maxPoints
    } else {
        sampleStep = 1
        outputLimit = count
    }

    var worldVertices: [SIMD3<Float>] = []
    worldVertices.reserveCapacity(min(count, outputLimit))

    var index = 0
    while index < count && worldVertices.count < outputLimit {
        let vertexPointer = contents
            .advanced(by: offset + index * stride)
            .assumingMemoryBound(to: SIMD3<Float>.self)
        let local = vertexPointer.pointee
        let world4 = transform * SIMD4<Float>(local.x, local.y, local.z, 1)
        worldVertices.append(SIMD3<Float>(world4.x, world4.y, world4.z))
        index += sampleStep
    }

    return worldVertices
}

func triangleFaces(from anchor: ARMeshAnchor) -> [(Int, Int, Int)] {
    let faces = anchor.geometry.faces

    guard faces.primitiveType == .triangle else {
        print("Skipping faces for ARMeshAnchor \(anchor.identifier): unsupported primitive type \(faces.primitiveType.rawValue)")
        return []
    }

    guard faces.indexCountPerPrimitive == 3 else {
        print("Skipping faces for ARMeshAnchor \(anchor.identifier): expected triangles, got \(faces.indexCountPerPrimitive) indices")
        return []
    }

    let faceCount = faces.count
    guard faceCount > 0 else { return [] }

    let bytesPerIndex = faces.bytesPerIndex
    let contents = faces.buffer.contents()
    var triangleFaces: [(Int, Int, Int)] = []
    triangleFaces.reserveCapacity(faceCount)

    for faceIndex in 0..<faceCount {
        let facePointer = contents.advanced(by: faceIndex * faces.indexCountPerPrimitive * bytesPerIndex)

        switch bytesPerIndex {
        case MemoryLayout<UInt16>.size:
            let indices = facePointer.assumingMemoryBound(to: UInt16.self)
            triangleFaces.append((Int(indices[0]), Int(indices[1]), Int(indices[2])))
        case MemoryLayout<UInt32>.size:
            let indices = facePointer.assumingMemoryBound(to: UInt32.self)
            triangleFaces.append((Int(indices[0]), Int(indices[1]), Int(indices[2])))
        default:
            print("Skipping faces for ARMeshAnchor \(anchor.identifier): unsupported index size \(bytesPerIndex)")
            return []
        }
    }

    return triangleFaces
}

private func makeModelIOMesh(from anchor: ARMeshAnchor) -> MDLMesh? {
    let vertices = worldVertices(from: anchor)
    let faces = triangleFaces(from: anchor)

    guard !vertices.isEmpty, !faces.isEmpty else { return nil }

    let vertexData = Data(bytes: vertices, count: vertices.count * MemoryLayout<SIMD3<Float>>.stride)
    let vertexBuffer = MDLMeshBufferData(type: .vertex, data: vertexData)

    var indices: [UInt32] = []
    indices.reserveCapacity(faces.count * 3)

    for face in faces {
        indices.append(UInt32(face.0))
        indices.append(UInt32(face.1))
        indices.append(UInt32(face.2))
    }

    let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.stride)
    let indexBuffer = MDLMeshBufferData(type: .index, data: indexData)
    let submesh = MDLSubmesh(
        indexBuffer: indexBuffer,
        indexCount: indices.count,
        indexType: .uInt32,
        geometryType: .triangles,
        material: nil
    )

    let vertexDescriptor = MDLVertexDescriptor()
    vertexDescriptor.attributes[0] = MDLVertexAttribute(
        name: MDLVertexAttributePosition,
        format: .float3,
        offset: 0,
        bufferIndex: 0
    )
    vertexDescriptor.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<SIMD3<Float>>.stride)

    let mesh = MDLMesh(
        vertexBuffer: vertexBuffer,
        vertexCount: vertices.count,
        descriptor: vertexDescriptor,
        submeshes: [submesh]
    )
    mesh.name = "mesh_anchor_\(anchor.identifier.uuidString)"
    return mesh
}
