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

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ScanApp"
        view.backgroundColor = .systemBackground
        configureScannerButton()
    }

    private func configureScannerButton() {
        scannerButton.addTarget(self, action: #selector(openScanner), for: .touchUpInside)
        view.addSubview(scannerButton)

        NSLayoutConstraint.activate([
            scannerButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            scannerButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            scannerButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            scannerButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    @objc private func openScanner() {
        let scannerViewController = SceneReconstructionScannerViewController()

        if let navigationController {
            navigationController.pushViewController(scannerViewController, animated: true)
        } else {
            let navigationController = UINavigationController(rootViewController: scannerViewController)
            navigationController.modalPresentationStyle = .fullScreen
            present(navigationController, animated: true)
        }
    }
}
