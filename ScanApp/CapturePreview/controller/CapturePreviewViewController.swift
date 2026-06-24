//
//  CapturePreviewViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import AVFoundation
import UIKit

final class CapturePreviewViewController: UIViewController {
    private enum PreviewKind: Int, CaseIterable {
        case rgb
        case depth

        var title: String {
            switch self {
            case .rgb:
                return "RGB"
            case .depth:
                return "Depth"
            }
        }

        var relativePath: String {
            switch self {
            case .rgb:
                return "rgb.mov"
            case .depth:
                return "depth/depth_packed_hevc.mov"
            }
        }
    }

    private struct VideoSummary {
        let kind: PreviewKind
        let url: URL
        let duration: CMTime
        let naturalSize: CGSize
        let frameRate: Float
        let fileSize: Int64?
    }

    private final class PlayerView: UIView {
        override static var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }
    }

    private let session: CapturedScanSession
    private let previewControl = UISegmentedControl(items: PreviewKind.allCases.map(\.title))
    private let playerView = PlayerView()
    private let statusLabel = UILabel()
    private let metadataLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()

    private var summaries: [PreviewKind: VideoSummary] = [:]
    private var selectedKind: PreviewKind = .rgb
    private var player: AVPlayer?
    private var timeObserver: Any?
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session.displayTitle
        view.backgroundColor = .systemBackground
        configureUI()
        configureNavigationItems()
        loadVideos()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerView.playerLayer.videoGravity = .resizeAspect
    }

    private func configureUI() {
        previewControl.translatesAutoresizingMaskIntoConstraints = false
        previewControl.selectedSegmentIndex = selectedKind.rawValue
        previewControl.addTarget(self, action: #selector(selectPreviewKind), for: .valueChanged)

        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.backgroundColor = .black
        playerView.layer.cornerRadius = 8
        playerView.layer.masksToBounds = true
        playerView.playerLayer.videoGravity = .resizeAspect

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
        slider.value = 0
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

        view.addSubview(previewControl)
        view.addSubview(playerView)
        view.addSubview(statusLabel)
        view.addSubview(playButton)
        view.addSubview(slider)
        view.addSubview(timeLabel)
        view.addSubview(metadataLabel)

        NSLayoutConstraint.activate([
            previewControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            previewControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            previewControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

            playerView.leadingAnchor.constraint(equalTo: previewControl.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: previewControl.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: previewControl.bottomAnchor, constant: 12),
            playerView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.55),

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

    private func loadVideos() {
        summaries = Dictionary(
            uniqueKeysWithValues: PreviewKind.allCases.compactMap { kind in
                guard let summary = makeVideoSummary(kind: kind) else { return nil }
                return (kind, summary)
            }
        )

        for kind in PreviewKind.allCases {
            previewControl.setEnabled(summaries[kind] != nil, forSegmentAt: kind.rawValue)
        }

        if summaries[selectedKind] == nil {
            selectedKind = summaries[.rgb] != nil ? .rgb : .depth
            previewControl.selectedSegmentIndex = selectedKind.rawValue
        }

        guard summaries[selectedKind] != nil else {
            playerView.playerLayer.player = nil
            playButton.isEnabled = false
            slider.isEnabled = false
            statusLabel.text = "No video"
            metadataLabel.text = [
                "No previewable video found.",
                "Expected: rgb.mov",
                "Expected: depth/depth_packed_hevc.mov",
                "Session: \(session.id)"
            ].joined(separator: "\n")
            return
        }

        playButton.isEnabled = true
        slider.isEnabled = true
        loadSelectedVideo(autoplay: false)
    }

    private func makeVideoSummary(kind: PreviewKind) -> VideoSummary? {
        let url = session.url.appendingPathComponent(kind.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first
        let naturalSize = track?.naturalSize.applying(track?.preferredTransform ?? .identity) ?? .zero
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)

        return VideoSummary(
            kind: kind,
            url: url,
            duration: asset.duration,
            naturalSize: CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height)),
            frameRate: track?.nominalFrameRate ?? 0,
            fileSize: fileSize
        )
    }

    private func loadSelectedVideo(autoplay: Bool) {
        guard let summary = summaries[selectedKind] else { return }

        removeTimeObserver()
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)

        let item = AVPlayerItem(url: summary.url)
        let player = AVPlayer(playerItem: item)
        playerView.playerLayer.player = player
        self.player = player

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidFinish(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )
        addTimeObserver()

        slider.value = 0
        updateTimeLabel(current: .zero, duration: summary.duration)
        updateMetadata(for: summary)
        statusLabel.text = summary.kind.title

        if autoplay {
            player.play()
            updatePlayButton(isPlaying: true)
        } else {
            updatePlayButton(isPlaying: false)
        }
    }

    private func updateMetadata(for summary: VideoSummary) {
        metadataLabel.text = [
            "Preview: \(summary.kind.title)",
            "File: \(summary.kind.relativePath)",
            "Duration: \(format(seconds: summary.duration.seconds))",
            String(format: "Size: %.0f x %.0f", summary.naturalSize.width, summary.naturalSize.height),
            String(format: "FPS: %.2f", summary.frameRate),
            "Bytes: \(summary.fileSize.map(String.init) ?? "unknown")",
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
            let duration = self.player?.currentItem?.duration ?? .zero
            let durationSeconds = duration.seconds
            if durationSeconds.isFinite, durationSeconds > 0 {
                self.slider.value = Float(time.seconds / durationSeconds)
            }
            self.updateTimeLabel(current: time, duration: duration)
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    @objc private func selectPreviewKind() {
        guard let kind = PreviewKind(rawValue: previewControl.selectedSegmentIndex) else { return }
        selectedKind = kind
        loadSelectedVideo(autoplay: player?.timeControlStatus == .playing)
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
        guard let duration = player?.currentItem?.duration else { return }
        let target = CMTime(seconds: Double(slider.value) * duration.seconds, preferredTimescale: 600)
        updateTimeLabel(current: target, duration: duration)
    }

    @objc private func endScrubbing() {
        guard let player, let duration = player.currentItem?.duration else {
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
}
