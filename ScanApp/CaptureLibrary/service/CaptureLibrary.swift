//
//  CaptureLibrary.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import Foundation

final class CaptureLibrary {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var scanRootDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
    }

    var publicExportRootDirectory: URL {
        documentsDirectory
            .appendingPathComponent("ScanAppExports", isDirectory: true)
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
    }

    func loadSessions() throws -> [CapturedScanSession] {
        try migrateLegacySessionsIfNeeded()

        guard fileManager.fileExists(atPath: scanRootDirectory.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: scanRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let metadataDate = readCreatedAt(from: url)
            let resourceDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            return CapturedScanSession(
                id: url.lastPathComponent,
                url: url,
                createdAt: metadataDate ?? resourceDate ?? parseTimestamp(url.lastPathComponent)
            )
        }
        .sorted { lhs, rhs in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
    }

    func exportToPublicDocuments(_ session: CapturedScanSession) throws -> URL {
        try fileManager.createDirectory(at: publicExportRootDirectory, withIntermediateDirectories: true)
        let destination = uniqueExportDestination(for: session)
        try fileManager.copyItem(at: session.url, to: destination)
        return destination
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var legacyScanRootDirectory: URL {
        documentsDirectory
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
    }

    private func migrateLegacySessionsIfNeeded() throws {
        guard fileManager.fileExists(atPath: legacyScanRootDirectory.path) else {
            return
        }

        try fileManager.createDirectory(at: scanRootDirectory, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: legacyScanRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let destination = scanRootDirectory.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                continue
            }

            try fileManager.copyItem(at: url, to: destination)
        }
    }

    private func uniqueExportDestination(for session: CapturedScanSession) -> URL {
        let base = publicExportRootDirectory.appendingPathComponent(session.id, isDirectory: true)
        guard fileManager.fileExists(atPath: base.path) else {
            return base
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let suffix = formatter.string(from: Date())
        return publicExportRootDirectory.appendingPathComponent("\(session.id)-export-\(suffix)", isDirectory: true)
    }

    private func readCreatedAt(from directory: URL) -> Date? {
        let metadataURL = directory.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let createdAt = object["created_at"] as? String else {
            return nil
        }
        return ISO8601DateFormatter().date(from: createdAt)
    }

    private func parseTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: value)
    }
}
