//
//  ViewController.swift
//  ScanApp
//
//  Created by 楊敦富 on 2026/6/10.
//

import UIKit

class ViewController: UIViewController {
    private let scannerButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Scene Reconstruction Scanner", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.tintColor = .white
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let avFoundationCaptureButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("AVFoundation LiDAR Capture", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.tintColor = .white
        button.backgroundColor = .systemTeal
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let buttonStack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ScanApp"
        view.backgroundColor = .systemBackground
        configureButtons()
    }

    private func configureButtons() {
        scannerButton.addTarget(self, action: #selector(promptForSceneDepthRecording), for: .touchUpInside)
        avFoundationCaptureButton.addTarget(self, action: #selector(openAVFoundationCapture), for: .touchUpInside)

        buttonStack.axis = .vertical
        buttonStack.spacing = 14
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(scannerButton)
        buttonStack.addArrangedSubview(avFoundationCaptureButton)

        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            buttonStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scannerButton.heightAnchor.constraint(equalToConstant: 52),
            avFoundationCaptureButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    @objc private func promptForSceneDepthRecording() {
        let alert = UIAlertController(
            title: "Save Scene Depth?",
            message: "Depth will be saved as raw Float32 binary files aligned with captured keyframes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Save Depth", style: .default) { [weak self] _ in
            self?.openScanner(recordsDepthData: true)
        })
        alert.addAction(UIAlertAction(title: "Images Only", style: .default) { [weak self] _ in
            self?.openScanner(recordsDepthData: false)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func openScanner(recordsDepthData: Bool) {
        let scannerViewController = SceneReconstructionScannerViewController(recordsDepthData: recordsDepthData)
        open(viewController: scannerViewController)
    }

    @objc private func openAVFoundationCapture() {
        open(viewController: AVFoundationLiDARCaptureViewController())
    }

    private func open(viewController: UIViewController) {
        if let navigationController {
            navigationController.pushViewController(viewController, animated: true)
        } else {
            let navigationController = UINavigationController(rootViewController: viewController)
            navigationController.modalPresentationStyle = .fullScreen
            present(navigationController, animated: true)
        }
    }
}
