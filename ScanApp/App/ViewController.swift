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
        button.setTitle("ARKit Depth Scanner", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.tintColor = .white
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let capturedFilesButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Captured Files", for: .normal)
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
        scannerButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)
        capturedFilesButton.addTarget(self, action: #selector(openCapturedFiles), for: .touchUpInside)

        buttonStack.axis = .vertical
        buttonStack.spacing = 14
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.addArrangedSubview(scannerButton)
        buttonStack.addArrangedSubview(capturedFilesButton)

        view.addSubview(buttonStack)

        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            buttonStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scannerButton.heightAnchor.constraint(equalToConstant: 52),
            capturedFilesButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    @objc private func openScanner() {
        let scannerViewController = SceneReconstructionScannerViewController()
        open(viewController: scannerViewController)
    }

    @objc private func openCapturedFiles() {
        open(viewController: CapturedFilesViewController())
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
