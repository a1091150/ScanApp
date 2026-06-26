//
//  FaceCapturedFilesViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/26.
//

import UIKit

final class FaceCapturedFilesViewController: UITableViewController {
    private let library = CaptureLibrary(mode: .faceScan)
    private var sessions: [CapturedScanSession] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Face Captures"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "FaceCapturedScanCell")
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSessions()
    }

    @objc private func close() {
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func reloadSessions() {
        do {
            sessions = try library.loadSessions()
            tableView.reloadData()
            tableView.backgroundView = sessions.isEmpty ? makeEmptyLabel("No face captures yet.") : nil
        } catch {
            showAlert(title: "Load Failed", message: error.localizedDescription)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sessions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "FaceCapturedScanCell", for: indexPath)
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
        navigationController?.pushViewController(
            FaceCapturePreviewViewController(session: sessions[indexPath.row]),
            animated: true
        )
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.confirmDeleteSession(at: indexPath, completion: completion)
        }
        deleteAction.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func confirmDeleteSession(
        at indexPath: IndexPath,
        completion: @escaping (Bool) -> Void
    ) {
        guard indexPath.row < sessions.count else {
            completion(false)
            return
        }

        let session = sessions[indexPath.row]
        let alert = UIAlertController(
            title: "Delete Face Capture?",
            message: "This will permanently delete \(session.displayTitle) and its RGB video and face metadata.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.deleteSession(session, at: indexPath, completion: completion)
        })
        present(alert, animated: true)
    }

    private func deleteSession(
        _ session: CapturedScanSession,
        at indexPath: IndexPath,
        completion: @escaping (Bool) -> Void
    ) {
        do {
            try library.deleteSession(session)
            guard indexPath.row < sessions.count, sessions[indexPath.row].id == session.id else {
                reloadSessions()
                completion(true)
                return
            }

            sessions.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)
            tableView.backgroundView = sessions.isEmpty ? makeEmptyLabel("No face captures yet.") : nil
            completion(true)
        } catch {
            completion(false)
            showAlert(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    private func makeEmptyLabel(_ message: String) -> UILabel {
        let label = UILabel()
        label.text = message
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
