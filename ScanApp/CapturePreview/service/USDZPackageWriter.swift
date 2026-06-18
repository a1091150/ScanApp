//
//  USDZPackageWriter.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import Foundation

enum USDZPackageWriter {
    struct PackageFile {
        let data: Data
        let fileName: String
    }

    static func writeSingleFilePackage(fileData: Data, fileName: String, to url: URL) throws {
        try writePackage(files: [PackageFile(data: fileData, fileName: fileName)], to: url)
    }

    static func writePackage(files: [PackageFile], to url: URL) throws {
        guard !files.isEmpty, files.count <= Int(UInt16.max) else {
            throw USDZPackageError.invalidPackage
        }

        struct CentralDirectoryEntry {
            let fileNameData: Data
            let checksum: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
        }

        var zip = Data()
        var centralDirectoryEntries: [CentralDirectoryEntry] = []

        for file in files {
            guard file.data.count <= Int(UInt32.max),
                  zip.count <= Int(UInt32.max) else {
                throw USDZPackageError.fileTooLarge
            }

            let fileNameData = Data(file.fileName.utf8)
            let extraData = makeAlignmentExtraData(
                currentOffset: zip.count,
                fileNameLength: fileNameData.count
            )
            let checksum = crc32(file.data)
            let size = UInt32(file.data.count)
            let localHeaderOffset = UInt32(zip.count)

            zip.appendLittleEndianUInt32(0x04034B50)
            zip.appendLittleEndianUInt16(20)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt32(checksum)
            zip.appendLittleEndianUInt32(size)
            zip.appendLittleEndianUInt32(size)
            zip.appendLittleEndianUInt16(UInt16(fileNameData.count))
            zip.appendLittleEndianUInt16(UInt16(extraData.count))
            zip.append(fileNameData)
            zip.append(extraData)
            zip.append(file.data)

            centralDirectoryEntries.append(
                CentralDirectoryEntry(
                    fileNameData: fileNameData,
                    checksum: checksum,
                    size: size,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        guard zip.count <= Int(UInt32.max) else {
            throw USDZPackageError.fileTooLarge
        }
        let centralDirectoryOffset = UInt32(zip.count)
        for entry in centralDirectoryEntries {
            zip.appendLittleEndianUInt32(0x02014B50)
            zip.appendLittleEndianUInt16(20)
            zip.appendLittleEndianUInt16(20)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt32(entry.checksum)
            zip.appendLittleEndianUInt32(entry.size)
            zip.appendLittleEndianUInt32(entry.size)
            zip.appendLittleEndianUInt16(UInt16(entry.fileNameData.count))
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt16(0)
            zip.appendLittleEndianUInt32(0)
            zip.appendLittleEndianUInt32(entry.localHeaderOffset)
            zip.append(entry.fileNameData)
        }

        let centralDirectorySize = UInt32(zip.count) - centralDirectoryOffset
        let fileCount = UInt16(centralDirectoryEntries.count)
        zip.appendLittleEndianUInt32(0x06054B50)
        zip.appendLittleEndianUInt16(0)
        zip.appendLittleEndianUInt16(0)
        zip.appendLittleEndianUInt16(fileCount)
        zip.appendLittleEndianUInt16(fileCount)
        zip.appendLittleEndianUInt32(centralDirectorySize)
        zip.appendLittleEndianUInt32(centralDirectoryOffset)
        zip.appendLittleEndianUInt16(0)

        try zip.write(to: url, options: .atomic)
    }

    private static func makeAlignmentExtraData(currentOffset: Int, fileNameLength: Int) -> Data {
        let baseDataOffset = currentOffset + 30 + fileNameLength
        let padding = (64 - (baseDataOffset % 64)) % 64
        guard padding > 0 else {
            return Data()
        }

        let paddedLength = padding >= 4 ? padding : padding + 64
        var data = Data()
        data.appendLittleEndianUInt16(0xFFFF)
        data.appendLittleEndianUInt16(UInt16(paddedLength - 4))
        data.append(Data(repeating: 0, count: paddedLength - 4))
        return data
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var checksum = UInt32(i)
            for _ in 0..<8 {
                checksum = (checksum & 1) == 1 ? 0xEDB88320 ^ (checksum >> 1) : checksum >> 1
            }
            table[i] = checksum
        }

        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            checksum = table[Int((checksum ^ UInt32(byte)) & 0xFF)] ^ (checksum >> 8)
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

enum USDZPackageError: LocalizedError {
    case fileTooLarge
    case invalidPackage

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "The generated USD file is too large for the USDZ package writer."
        case .invalidPackage:
            return "The USDZ package has no files or too many files."
        }
    }
}

private extension Data {
    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
