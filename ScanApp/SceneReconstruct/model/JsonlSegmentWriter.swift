//
//  JsonlSegmentWriter.swift
//  ScanApp
//
//  Created by Codex on 2026/6/24.
//

import Foundation

final class JsonlSegmentWriter {
    private let directory: URL
    private let recordsPerSegment: Int
    private var segmentIndex = 0
    private var recordsInSegment = 0
    private var fileHandle: FileHandle?

    init(directory: URL, recordsPerSegment: Int = 10_000) throws {
        self.directory = directory
        self.recordsPerSegment = recordsPerSegment
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ object: [String: Any]) throws {
        try openSegmentIfNeeded()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try fileHandle?.write(contentsOf: data)
        try fileHandle?.write(contentsOf: Data([0x0A]))

        recordsInSegment += 1
        if recordsInSegment >= recordsPerSegment {
            try rotateSegment()
        }
    }

    func close() throws {
        try fileHandle?.close()
        fileHandle = nil
    }

    private func openSegmentIfNeeded() throws {
        guard fileHandle == nil else { return }

        let fileName = String(format: "frames_%04d.jsonl", segmentIndex)
        let url = directory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
        recordsInSegment = 0
    }

    private func rotateSegment() throws {
        try fileHandle?.close()
        fileHandle = nil
        segmentIndex += 1
        recordsInSegment = 0
    }
}
