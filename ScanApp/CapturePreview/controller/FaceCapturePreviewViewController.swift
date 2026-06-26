//
//  FaceCapturePreviewViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/26.
//

import AVFoundation
import UIKit
import simd

final class FaceCapturePreviewViewController: UIViewController {
    private struct FaceFrame {
        let sessionTime: Double
        let ptsSeconds: Double
        let width: CGFloat
        let height: CGFloat
        let projectionViewportWidth: CGFloat
        let projectionViewportHeight: CGFloat
        let projectionOrientationName: String
        let worldToCamera: simd_float4x4
        let projectionMatrix: simd_float4x4
        let faces: [FaceAnchor]
    }

    private struct FaceAnchor {
        let identifier: String
        let isTracked: Bool
        let transform: simd_float4x4
        let leftEyeTransform: simd_float4x4?
        let rightEyeTransform: simd_float4x4?
        let blendShapeCount: Int
    }

    private final class PlayerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    private final class FaceOverlayView: UIView {
        var faceFrames: [FaceFrame] = []
        var videoNaturalSize: CGSize = .zero
        var displayedVideoRect: CGRect = .zero {
            didSet { setNeedsDisplay() }
        }
        var rawVideoSize: CGSize = .zero
        var preferredTransform: CGAffineTransform = .identity
        var currentTime: Double = 0 {
            didSet { setNeedsDisplay() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ rect: CGRect) {
            guard let frame = nearestFrame(to: currentTime) else { return }
            let videoRect = displayedVideoRect.width > 0 && displayedVideoRect.height > 0
                ? displayedVideoRect
                : bounds
            guard videoRect.width > 0, videoRect.height > 0 else { return }

            let context = UIGraphicsGetCurrentContext()
            context?.setLineWidth(3)

            for face in frame.faces where face.isTracked {
                guard let point = projectedPoint(for: face, frame: frame, videoRect: videoRect) else { continue }
                let radius: CGFloat = 9
                let boxSize: CGFloat = 54
                let box = CGRect(
                    x: point.x - boxSize * 0.5,
                    y: point.y - boxSize * 0.5,
                    width: boxSize,
                    height: boxSize
                )

                UIColor.systemGreen.withAlphaComponent(0.92).setStroke()
                UIBezierPath(roundedRect: box, cornerRadius: 8).stroke()
                UIColor.systemGreen.setFill()
                UIBezierPath(ovalIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )).fill()

                let shortID = String(face.identifier.prefix(8))
                let label = "\(shortID) \(face.blendShapeCount)"
                drawLabel(label, at: CGPoint(x: box.minX, y: max(videoRect.minY, box.minY - 22)))
                drawEyes(for: face, frame: frame, videoRect: videoRect)
            }
        }

        private func nearestFrame(to time: Double) -> FaceFrame? {
            guard !faceFrames.isEmpty else { return nil }
            var low = 0
            var high = faceFrames.count - 1
            while low < high {
                let mid = (low + high) / 2
                if faceFrames[mid].ptsSeconds < time {
                    low = mid + 1
                } else {
                    high = mid
                }
            }

            if low == 0 { return faceFrames[0] }
            let previous = faceFrames[low - 1]
            let current = faceFrames[low]
            return abs(previous.ptsSeconds - time) <= abs(current.ptsSeconds - time) ? previous : current
        }

        private func projectedPoint(for face: FaceAnchor, frame: FaceFrame, videoRect: CGRect) -> CGPoint? {
            let translation = face.transform.columns.3
            let world = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
            return projectedPoint(for: world, frame: frame, videoRect: videoRect)
        }

        private func projectedPoint(
            for world: SIMD4<Float>,
            frame: FaceFrame,
            videoRect: CGRect
        ) -> CGPoint? {
            let clip = frame.projectionMatrix * frame.worldToCamera * world
            guard clip.w != 0 else { return nil }

            let ndcX = clip.x / clip.w
            let ndcY = clip.y / clip.w
            guard ndcX.isFinite, ndcY.isFinite else { return nil }

            let normalizedPoint = CGPoint(
                x: CGFloat((ndcX + 1) * 0.5),
                y: CGFloat((1 - ndcY) * 0.5)
            )
            let displayPoint = displayNormalizedPoint(normalizedPoint, frame: frame)
            let x = videoRect.minX + displayPoint.x * videoRect.width
            let y = videoRect.minY + displayPoint.y * videoRect.height
            let point = CGPoint(x: x, y: y)
            guard videoRect.insetBy(dx: -40, dy: -40).contains(point) else { return nil }
            return point
        }

        private func displayNormalizedPoint(_ point: CGPoint, frame: FaceFrame) -> CGPoint {
            switch frame.projectionOrientationName {
            case "portrait":
                return CGPoint(x: 1 - point.y, y: point.x)
            case "portraitUpsideDown":
                return CGPoint(x: point.y, y: 1 - point.x)
            default:
                break
            }

            let rawSize = rawVideoSize == .zero
                ? CGSize(width: frame.width, height: frame.height)
                : rawVideoSize
            guard rawSize.width > 0, rawSize.height > 0 else { return point }

            let rawPoint = CGPoint(x: point.x * rawSize.width, y: point.y * rawSize.height)
            return transformedVideoPoint(rawPoint, rawSize: rawSize)
        }

        private func transformedVideoPoint(_ point: CGPoint, rawSize: CGSize) -> CGPoint {
            guard preferredTransform != .identity else {
                return CGPoint(x: point.x / rawSize.width, y: point.y / rawSize.height)
            }

            let transformedBounds = CGRect(origin: .zero, size: rawSize).applying(preferredTransform)
            guard transformedBounds.width != 0, transformedBounds.height != 0 else {
                return CGPoint(x: point.x / rawSize.width, y: point.y / rawSize.height)
            }

            let transformedPoint = point.applying(preferredTransform)
            return CGPoint(
                x: (transformedPoint.x - transformedBounds.minX) / abs(transformedBounds.width),
                y: (transformedPoint.y - transformedBounds.minY) / abs(transformedBounds.height)
            )
        }

        private func drawEyes(for face: FaceAnchor, frame: FaceFrame, videoRect: CGRect) {
            drawEye(
                transform: face.leftEyeTransform,
                faceTransform: face.transform,
                frame: frame,
                videoRect: videoRect,
                color: .systemBlue,
                label: "L"
            )
            drawEye(
                transform: face.rightEyeTransform,
                faceTransform: face.transform,
                frame: frame,
                videoRect: videoRect,
                color: .systemYellow,
                label: "R"
            )
        }

        private func drawEye(
            transform eyeTransform: simd_float4x4?,
            faceTransform: simd_float4x4,
            frame: FaceFrame,
            videoRect: CGRect,
            color: UIColor,
            label: String
        ) {
            guard let eyeTransform else { return }
            let worldTransform = faceTransform * eyeTransform
            let translation = worldTransform.columns.3
            let world = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
            guard let point = projectedPoint(for: world, frame: frame, videoRect: videoRect) else { return }

            let radius: CGFloat = 6
            color.setFill()
            UIColor.black.withAlphaComponent(0.75).setStroke()
            let circle = UIBezierPath(ovalIn: CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            circle.lineWidth = 2
            circle.fill()
            circle.stroke()
            drawLabel(label, at: CGPoint(x: point.x + 7, y: point.y - 8))
        }

        private func drawLabel(_ text: String, at point: CGPoint) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor.white,
                .backgroundColor: UIColor.black.withAlphaComponent(0.65)
            ]
            NSString(string: text).draw(at: point, withAttributes: attributes)
        }
    }

    private let session: CapturedScanSession
    private let playerView = PlayerView()
    private let overlayView = FaceOverlayView()
    private let statusLabel = UILabel()
    private let metadataLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var duration: CMTime = .zero
    private var naturalSize: CGSize = .zero
    private var faceFrames: [FaceFrame] = []
    private var isScrubbing = false
    private var shareButton: UIBarButtonItem?

    init(session: CapturedScanSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeTimeObserver()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session.displayTitle
        view.backgroundColor = .systemBackground
        configureUI()
        configureNavigationItems()
        loadPreview()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.playerLayer.videoGravity = .resize
        overlayView.videoNaturalSize = naturalSize
        overlayView.displayedVideoRect = overlayView.bounds
    }

    private func configureUI() {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.backgroundColor = .black
        playerView.layer.cornerRadius = 8
        playerView.layer.masksToBounds = true
        playerView.playerLayer.videoGravity = .resize

        overlayView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Loading"
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.layer.cornerRadius = 6
        statusLabel.layer.masksToBounds = true
        statusLabel.textAlignment = .center

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setTitle("Play", for: .normal)
        playButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        playButton.tintColor = .white
        playButton.backgroundColor = .systemGreen
        playButton.layer.cornerRadius = 8
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.addTarget(self, action: #selector(beginScrubbing), for: .touchDown)
        slider.addTarget(self, action: #selector(updateScrubbing), for: .valueChanged)
        slider.addTarget(self, action: #selector(endScrubbing), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabel
        timeLabel.textAlignment = .right
        timeLabel.text = "0.00 / 0.00"

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        metadataLabel.numberOfLines = 0
        metadataLabel.textColor = .label

        view.addSubview(playerView)
        playerView.addSubview(overlayView)
        playerView.addSubview(statusLabel)
        view.addSubview(playButton)
        view.addSubview(slider)
        view.addSubview(timeLabel)
        view.addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            playerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            playerView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.58),

            overlayView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: playerView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: playerView.topAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            statusLabel.heightAnchor.constraint(equalToConstant: 30),

            playButton.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 14),
            playButton.widthAnchor.constraint(equalToConstant: 96),
            playButton.heightAnchor.constraint(equalToConstant: 38),

            slider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            slider.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            timeLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            timeLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 112),

            metadataLabel.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 16),
            metadataLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func configureNavigationItems() {
        let item = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareCurrentOutput)
        )
        navigationItem.rightBarButtonItem = item
        shareButton = item
    }

    private func loadPreview() {
        let videoURL = session.url.appendingPathComponent("rgb.mov")
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            playButton.isEnabled = false
            slider.isEnabled = false
            statusLabel.text = "No RGB"
            metadataLabel.text = "No rgb.mov found.\nSession: \(session.id)"
            return
        }

        let asset = AVURLAsset(url: videoURL)
        let track = asset.tracks(withMediaType: .video).first
        let rawSize = track?.naturalSize ?? .zero
        let preferredTransform = track?.preferredTransform ?? .identity
        let transformedSize = rawSize.applying(preferredTransform)
        naturalSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))
        duration = asset.duration
        faceFrames = loadFaceFrames()
        overlayView.faceFrames = faceFrames
        overlayView.videoNaturalSize = naturalSize
        overlayView.rawVideoSize = rawSize
        overlayView.preferredTransform = preferredTransform

        let item = AVPlayerItem(url: videoURL)
        let player = AVPlayer(playerItem: item)
        self.player = player
        playerView.playerLayer.player = player
        view.setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.overlayView.displayedVideoRect = self.overlayView.bounds
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        addTimeObserver()
        updateMetadata(videoURL: videoURL, track: track)
        updateTimeLabel(current: .zero, duration: duration)
        statusLabel.text = "Faces: \(faceFrames.count)"
    }

    private func loadFaceFrames() -> [FaceFrame] {
        let metadataDirectory = session.url.appendingPathComponent("metadata", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap(loadFaceFrames(from:))
            .sorted { $0.ptsSeconds < $1.ptsSeconds }
    }

    private func loadFaceFrames(from url: URL) -> [FaceFrame] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return makeFaceFrame(from: object)
        }
    }

    private func makeFaceFrame(from object: [String: Any]) -> FaceFrame? {
        guard let rgb = object["rgb"] as? [String: Any],
              let ptsSeconds = doubleValue(rgb["pts_seconds"]),
              let sessionTime = doubleValue(object["session_time"]),
              let width = doubleValue(object["width"]),
              let height = doubleValue(object["height"]),
              let worldToCamera = matrix4x4(from: object["world_to_camera"]),
              let projectionMatrix = matrix4x4(from: object["projectionMatrix"]) else {
            return nil
        }

        let projectionViewportWidth = doubleValue(object["projection_viewport_width"]) ?? width
        let projectionViewportHeight = doubleValue(object["projection_viewport_height"]) ?? height
        let projectionOrientationName = object["projection_orientation"] as? String ?? "unknown"
        let faces = (object["faces"] as? [[String: Any]] ?? []).compactMap(makeFaceAnchor(from:))
        return FaceFrame(
            sessionTime: sessionTime,
            ptsSeconds: ptsSeconds,
            width: CGFloat(width),
            height: CGFloat(height),
            projectionViewportWidth: CGFloat(projectionViewportWidth),
            projectionViewportHeight: CGFloat(projectionViewportHeight),
            projectionOrientationName: projectionOrientationName,
            worldToCamera: worldToCamera,
            projectionMatrix: projectionMatrix,
            faces: faces
        )
    }

    private func makeFaceAnchor(from object: [String: Any]) -> FaceAnchor? {
        guard let identifier = object["identifier"] as? String,
              let isTracked = object["is_tracked"] as? Bool,
              let transform = matrix4x4(from: object["transform"]) else {
            return nil
        }

        let blendShapeCount = (object["blend_shapes"] as? [String: Any])?.count ?? 0
        return FaceAnchor(
            identifier: identifier,
            isTracked: isTracked,
            transform: transform,
            leftEyeTransform: matrix4x4(from: object["left_eye_transform"]),
            rightEyeTransform: matrix4x4(from: object["right_eye_transform"]),
            blendShapeCount: blendShapeCount
        )
    }

    private func updateMetadata(videoURL: URL, track: AVAssetTrack?) {
        let fileSize = (try? videoURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let faceSamples = faceFrames.reduce(0) { $0 + $1.faces.count }
        let eyeSamples = faceFrames.reduce(0) { total, frame in
            total + frame.faces.reduce(0) { faceTotal, face in
                faceTotal + (face.leftEyeTransform == nil ? 0 : 1) + (face.rightEyeTransform == nil ? 0 : 1)
            }
        }
        metadataLabel.text = [
            "Preview: Face RGB + projected face/eye anchors",
            "File: rgb.mov",
            "Duration: \(format(seconds: duration.seconds))",
            String(format: "Size: %.0f x %.0f", naturalSize.width, naturalSize.height),
            "Transform: \(trackTransformText(track?.preferredTransform ?? .identity))",
            "Projection: \(faceFrames.first?.projectionOrientationName ?? "unknown")",
            String(format: "FPS: %.2f", track?.nominalFrameRate ?? 0),
            "Metadata frames: \(faceFrames.count)",
            "Face samples: \(faceSamples)",
            "Eye samples: \(eyeSamples)",
            "Bytes: \(fileSize.map(String.init) ?? "unknown")",
            "Session: \(session.id)"
        ].joined(separator: "\n")
    }

    private func addTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.updatePlaybackUI(current: time)
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func updatePlaybackUI(current: CMTime) {
        let durationSeconds = duration.seconds
        if durationSeconds.isFinite, durationSeconds > 0 {
            slider.value = Float(current.seconds / durationSeconds)
        }
        overlayView.currentTime = current.seconds
        updateTimeLabel(current: current, duration: duration)
    }

    @objc private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            updatePlayButton(isPlaying: false)
        } else {
            if let item = player.currentItem, item.currentTime() >= item.duration {
                player.seek(to: .zero)
            }
            player.play()
            updatePlayButton(isPlaying: true)
        }
    }

    @objc private func beginScrubbing() {
        isScrubbing = true
    }

    @objc private func updateScrubbing() {
        let target = CMTime(seconds: Double(slider.value) * duration.seconds, preferredTimescale: 600)
        overlayView.currentTime = target.seconds
        updateTimeLabel(current: target, duration: duration)
    }

    @objc private func endScrubbing() {
        guard let player else {
            isScrubbing = false
            return
        }
        let target = CMTime(seconds: Double(slider.value) * duration.seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.isScrubbing = false
        }
    }

    @objc private func playerItemDidFinish(_ notification: Notification) {
        player?.seek(to: .zero)
        overlayView.currentTime = 0
        updatePlayButton(isPlaying: false)
    }

    @objc private func shareCurrentOutput() {
        let activityViewController = UIActivityViewController(
            activityItems: [session.url],
            applicationActivities: nil
        )
        activityViewController.popoverPresentationController?.barButtonItem = shareButton
        present(activityViewController, animated: true)
    }

    private func updatePlayButton(isPlaying: Bool) {
        playButton.setTitle(isPlaying ? "Pause" : "Play", for: .normal)
        playButton.backgroundColor = isPlaying ? .systemOrange : .systemGreen
    }

    private func updateTimeLabel(current: CMTime, duration: CMTime) {
        timeLabel.text = "\(format(seconds: current.seconds)) / \(format(seconds: duration.seconds))"
    }

    private func format(seconds: Double) -> String {
        guard seconds.isFinite else { return "0.00" }
        return String(format: "%.2f", max(0, seconds))
    }

    private func trackTransformText(_ transform: CGAffineTransform) -> String {
        String(
            format: "[%.0f %.0f %.0f %.0f %.0f %.0f]",
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.tx,
            transform.ty
        )
    }

    private func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }

    private func matrix4x4(from value: Any?) -> simd_float4x4? {
        guard let values = value as? [Any], values.count == 16 else { return nil }
        let floats = values.compactMap { doubleValue($0).map(Float.init) }
        guard floats.count == 16 else { return nil }

        return simd_float4x4(
            SIMD4<Float>(floats[0], floats[4], floats[8], floats[12]),
            SIMD4<Float>(floats[1], floats[5], floats[9], floats[13]),
            SIMD4<Float>(floats[2], floats[6], floats[10], floats[14]),
            SIMD4<Float>(floats[3], floats[7], floats[11], floats[15])
        )
    }
}
