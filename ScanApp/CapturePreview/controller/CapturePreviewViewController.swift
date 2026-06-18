//
//  CapturePreviewViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import UIKit

final class CapturePreviewViewController: UIViewController {
    private let session: CapturedScanSession
    private let processor = CapturePointCloudProcessor()

    private let imageView = UIImageView()
    private let metadataLabel = UILabel()
    private let statusLabel = UILabel()
    private let outputFormatControl = UISegmentedControl(items: CapturePointCloudOutputFormat.allCases.map(\.title))
    private let processButton = UIButton(type: .system)
    private let shareOutputButton = UIButton(type: .system)

    private var latestResult: CapturePointCloudResult?
    private var selectedOutputFormat: CapturePointCloudOutputFormat {
        CapturePointCloudOutputFormat.allCases[outputFormatControl.selectedSegmentIndex]
    }

    init(session: CapturedScanSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = session.displayTitle
        view.backgroundColor = .systemBackground
        configureUI()
        loadSummary()
    }

    private func configureUI() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black

        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        metadataLabel.numberOfLines = 0

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Ready"
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        statusLabel.layer.cornerRadius = 6
        statusLabel.layer.masksToBounds = true
        statusLabel.textAlignment = .center

        outputFormatControl.selectedSegmentIndex = 0
        outputFormatControl.translatesAutoresizingMaskIntoConstraints = false

        processButton.setTitle("Process Point Cloud", for: .normal)
        processButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        processButton.tintColor = .white
        processButton.backgroundColor = .systemBlue
        processButton.layer.cornerRadius = 8
        processButton.translatesAutoresizingMaskIntoConstraints = false
        processButton.addTarget(self, action: #selector(processPointCloud), for: .touchUpInside)

        shareOutputButton.setTitle("Share Processed Output", for: .normal)
        shareOutputButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        shareOutputButton.tintColor = .white
        shareOutputButton.backgroundColor = .systemTeal
        shareOutputButton.layer.cornerRadius = 8
        shareOutputButton.translatesAutoresizingMaskIntoConstraints = false
        shareOutputButton.isEnabled = false
        shareOutputButton.alpha = 0.55
        shareOutputButton.addTarget(self, action: #selector(shareProcessedOutput), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [processButton, shareOutputButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(imageView)
        view.addSubview(metadataLabel)
        view.addSubview(outputFormatControl)
        view.addSubview(buttonStack)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            imageView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.52),

            statusLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            statusLabel.heightAnchor.constraint(equalToConstant: 30),

            metadataLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 14),

            outputFormatControl.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            outputFormatControl.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            outputFormatControl.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -10),
            outputFormatControl.heightAnchor.constraint(equalToConstant: 34),

            buttonStack.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 48),

            metadataLabel.bottomAnchor.constraint(lessThanOrEqualTo: outputFormatControl.topAnchor, constant: -12)
        ])
    }

    private func loadSummary() {
        guard let summary = processor.loadFirstFrameSummary(session: session) else {
            metadataLabel.text = "No previewable frames found."
            imageView.image = nil
            return
        }

        imageView.image = UIImage(contentsOfFile: summary.imageURL.path)
        metadataLabel.text = [
            "Frame: \(summary.frameName)",
            summary.cameraPositionText,
            summary.cameraForwardText,
            "Session: \(session.id)"
        ].joined(separator: "\n")
    }

    @objc private func processPointCloud() {
        processButton.isEnabled = false
        processButton.alpha = 0.55
        shareOutputButton.isEnabled = false
        shareOutputButton.alpha = 0.55
        outputFormatControl.isEnabled = false
        latestResult = nil
        let outputFormat = selectedOutputFormat

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.processor.process(session: self.session, outputFormat: outputFormat) { message in
                    DispatchQueue.main.async {
                        self.statusLabel.text = message
                    }
                }
                DispatchQueue.main.async {
                    self.latestResult = result
                    self.metadataLabel.text = [
                        self.metadataLabel.text ?? "",
                        "",
                        "Processed frames: \(result.frameCount)",
                        "Point count: \(result.pointCount)",
                        "Output: \(result.outputURLs.map(\.lastPathComponent).joined(separator: ", "))"
                    ].joined(separator: "\n")
                    self.processButton.isEnabled = true
                    self.processButton.alpha = 1
                    self.shareOutputButton.isEnabled = true
                    self.shareOutputButton.alpha = 1
                    self.outputFormatControl.isEnabled = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Failed"
                    self.processButton.isEnabled = true
                    self.processButton.alpha = 1
                    self.outputFormatControl.isEnabled = true
                    self.showAlert(title: "Process Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func shareProcessedOutput() {
        guard let latestResult else { return }
        let activityViewController = UIActivityViewController(
            activityItems: latestResult.outputURLs,
            applicationActivities: nil
        )
        activityViewController.popoverPresentationController?.sourceView = shareOutputButton
        activityViewController.popoverPresentationController?.sourceRect = shareOutputButton.bounds
        present(activityViewController, animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
