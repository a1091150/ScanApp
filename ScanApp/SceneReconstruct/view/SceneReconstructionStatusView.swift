//
//  SceneReconstructionStatusView.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import UIKit

final class SceneReconstructionStatusView: UIVisualEffectView {
    private let stackView = UIStackView()
    private let supportLabel = UILabel()
    private let trackingLabel = UILabel()
    private let depthLabel = UILabel()
    private let confidenceLabel = UILabel()
    private let imageCaptureLabel = UILabel()
    private let imageDecisionLabel = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThinMaterialDark))
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        supportStatus: String,
        trackingStatus: String,
        depthStatus: String,
        confidenceStatus: String,
        savedImageCount: Int,
        savedDepthFrameCount: Int,
        imageDecision: String
    ) {
        supportLabel.text = "Support: \(supportStatus)"
        trackingLabel.text = "Tracking: \(trackingStatus)"
        depthLabel.text = depthStatus
        confidenceLabel.text = confidenceStatus
        imageCaptureLabel.text = "Saved RGB/depth: \(savedImageCount) / \(savedDepthFrameCount)"
        imageDecisionLabel.text = "Image recorder: \(imageDecision)"
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        layer.masksToBounds = true

        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        [
            supportLabel,
            trackingLabel,
            depthLabel,
            confidenceLabel,
            imageCaptureLabel,
            imageDecisionLabel
        ].forEach(configureStatusLabel(_:))

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    private func configureStatusLabel(_ label: UILabel) {
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        stackView.addArrangedSubview(label)
    }
}
