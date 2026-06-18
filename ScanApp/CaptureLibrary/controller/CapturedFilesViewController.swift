//
//  CapturedFilesViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import UIKit

final class CapturedFilesViewController: UITableViewController {
    private let library = CaptureLibrary()
    private var sessions: [CapturedScanSession] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Captured Files"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CapturedScanCell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(close)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(reloadSessions)
        )
        reloadSessions()
    }

    @objc private func close() {
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSessions()
    }

    @objc private func reloadSessions() {
        do {
            sessions = try library.loadSessions()
            tableView.reloadData()
            if sessions.isEmpty {
                setEmptyMessage("No captured scans yet.")
            } else {
                tableView.backgroundView = nil
            }
        } catch {
            showAlert(title: "Load Failed", message: error.localizedDescription)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sessions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CapturedScanCell", for: indexPath)
        let session = sessions[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = session.displayTitle
        content.secondaryText = session.id
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openPreview(for: sessions[indexPath.row])
    }

    private func openPreview(for session: CapturedScanSession) {
        let viewController = CapturePreviewViewController(session: session)
        navigationController?.pushViewController(viewController, animated: true)
    }

    private func setEmptyMessage(_ message: String) {
        let label = UILabel()
        label.text = message
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        tableView.backgroundView = label
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
