//
//  CapturedScanSession.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import Foundation

struct CapturedScanSession {
    let id: String
    let url: URL
    let createdAt: Date?

    var displayTitle: String {
        if let createdAt {
            return CapturedScanSession.displayFormatter.string(from: createdAt)
        }
        return id
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
