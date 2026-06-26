//
//  SceneCaptureMode.swift
//  ScanApp
//
//  Created by Codex on 2026/6/26.
//

import UIKit

enum SceneCaptureMode: Int {
    case depthScan = 0
    case faceScan = 1

    var title: String {
        switch self {
        case .depthScan:
            return "Depth"
        case .faceScan:
            return "Face"
        }
    }

    var directoryName: String {
        switch self {
        case .depthScan:
            return "SceneReconstructionScans"
        case .faceScan:
            return "FaceTrackingScans"
        }
    }

    var captureFormat: String {
        switch self {
        case .depthScan:
            return "arkit_rgb_depth_video_jsonl_metal_v1"
        case .faceScan:
            return "arkit_face_rgb_depth_video_jsonl_v1"
        }
    }

    var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch self {
        case .depthScan:
            return .landscapeRight
        case .faceScan:
            return .landscapeRight
        }
    }

    var preferredInterfaceOrientation: UIInterfaceOrientation {
        switch self {
        case .depthScan:
            return .landscapeRight
        case .faceScan:
            return .landscapeRight
        }
    }

    var requiredOrientationName: String {
        preferredInterfaceOrientation.metadataName
    }
}

extension UIInterfaceOrientation {
    var metadataName: String {
        switch self {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}
