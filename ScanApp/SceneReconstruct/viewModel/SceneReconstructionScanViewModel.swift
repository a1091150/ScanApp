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
    private var scanMode: SceneCaptureMode?

    func resetScanDirectory() {
        scanTimestamp = nil
        scanDirectory = nil
        scanMode = nil
    }

    func currentScanDirectory(mode: SceneCaptureMode) throws -> URL {
        if let scanDirectory, scanMode == mode {
            return scanDirectory
        }

        let timestamp = scanTimestamp ?? makeExportTimestamp()
        scanTimestamp = timestamp
        scanMode = mode
        let directory = try makeScanDirectory(timestamp: timestamp, mode: mode)
        scanDirectory = directory
        try writeSessionMetadata(to: directory, timestamp: timestamp, mode: mode)
        return directory
    }

    private func makeExportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func makeScanDirectory(timestamp: String, mode: SceneCaptureMode) throws -> URL {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let scanDirectory = supportDirectory
            .appendingPathComponent(mode.directoryName, isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        return scanDirectory
    }

    private func writeSessionMetadata(to directory: URL, timestamp: String, mode: SceneCaptureMode) throws {
        let metadataURL = directory.appendingPathComponent("session.json")
        var metadata: [String: Any] = [
            "session_id": timestamp,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "capture_method": mode == .depthScan ? "ARKit scene reconstruction" : "ARKit face tracking",
            "image_orientation": mode.requiredOrientationName,
            "projection_orientation": mode.requiredOrientationName,
            "required_orientation": mode.requiredOrientationName,
            "records_depth_data": mode == .depthScan,
            "records_depth_bin": false,
            "records_frame_metadata": true,
            "records_face_metadata": mode == .faceScan,
            "capture_format": mode.captureFormat,
            "dataset_layout": [
                "rgb": "rgb.mov",
                "metadata": "metadata/frames_0000.jsonl"
            ]
        ]

        if mode == .depthScan {
            metadata["dataset_layout"] = [
                "rgb": "rgb.mov",
                "metadata": "metadata/frames_0000.jsonl",
                "depth_video": "depth/depth_packed_hevc.mov"
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
    }
}
