//
//  SceneReconstructionScanViewModel.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import Foundation

final class SceneReconstructionScanViewModel {
    private var scanTimestamp: String?
    private var scanDirectory: URL?

    func resetScanDirectory() {
        scanTimestamp = nil
        scanDirectory = nil
    }

    func currentScanDirectory() throws -> URL {
        if let scanDirectory {
            return scanDirectory
        }

        let timestamp = scanTimestamp ?? makeExportTimestamp()
        scanTimestamp = timestamp
        let directory = try makeScanDirectory(timestamp: timestamp)
        scanDirectory = directory
        try writeSessionMetadata(to: directory, timestamp: timestamp)
        return directory
    }

    private func makeExportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func makeScanDirectory(timestamp: String) throws -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let scanDirectory = supportDirectory
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        return scanDirectory
    }

    private func writeSessionMetadata(to directory: URL, timestamp: String) throws {
        let metadataURL = directory.appendingPathComponent("session.json")
        let metadata: [String: Any] = [
            "session_id": timestamp,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "capture_method": "ARKit scene reconstruction",
            "image_orientation": "landscapeRight",
            "projection_orientation": "landscapeRight",
            "required_orientation": "landscapeRight",
            "records_depth_data": true,
            "records_depth_bin": false,
            "capture_format": "arkit_rgb_video_jsonl_v1",
            "dataset_layout": [
                "rgb": "rgb.mov",
                "metadata": "metadata/frames_0000.jsonl",
                "depth_video": "depth/depth_packed_hevc.mov",
                "confidence": "depth/frame_000001_confidence_u8.bin"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
    }
}
