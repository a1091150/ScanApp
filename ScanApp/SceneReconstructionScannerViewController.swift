//
//  SceneReconstructionScannerViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/10.
//

import ARKit
import RealityKit
import UIKit

final class SceneReconstructionScannerViewController: UIViewController {
    private let arView = ARView(frame: .zero)
    private let meshStore = SceneMeshStore()

    private let statusPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let stackView = UIStackView()
    private let startStopButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)

    private let supportLabel = UILabel()
    private let trackingLabel = UILabel()
    private let anchorCountLabel = UILabel()
    private let vertexCountLabel = UILabel()
    private let faceCountLabel = UILabel()
    private let worldPointCountLabel = UILabel()
    private let depthLabel = UILabel()
    private let confidenceLabel = UILabel()

    private var isScanning = false
    private var canStartScan = true
    private var supportStatus = "Not checked"
    private var depthStatus = "Depth: unavailable"
    private var confidenceStatus = "Confidence: unavailable"

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Scene Reconstruction"
        view.backgroundColor = .black
        configureARView()
        configureUI()
        configureNavigation()
        evaluateDeviceSupport()
        updateStats()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    private func configureARView() {
        arView.translatesAutoresizingMaskIntoConstraints = false
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.debugOptions.insert(.showFeaturePoints)
        arView.debugOptions.insert(.showWorldOrigin)

        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureUI() {
        configureButtons()
        configureStatusPanel()
    }

    private func configureNavigation() {
        if navigationController?.presentingViewController != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: self,
                action: #selector(closeScanner)
            )
        }
    }

    private func evaluateDeviceSupport() {
        guard ARWorldTrackingConfiguration.isSupported else {
            canStartScan = false
            supportStatus = "Unsupported: world tracking unavailable"
            return
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            canStartScan = true
            supportStatus = "Supported: mesh with classification"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            canStartScan = true
            supportStatus = "Supported: mesh"
        } else {
            canStartScan = false
            supportStatus = "Unsupported: scene reconstruction requires LiDAR"
        }
    }

    private func configureButtons() {
        startStopButton.setTitle("Start Scan", for: .normal)
        startStopButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startStopButton.tintColor = .white
        startStopButton.backgroundColor = .systemGreen
        startStopButton.layer.cornerRadius = 8
        startStopButton.addTarget(self, action: #selector(toggleScan), for: .touchUpInside)

        resetButton.setTitle("Reset", for: .normal)
        resetButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        resetButton.tintColor = .white
        resetButton.backgroundColor = .systemOrange
        resetButton.layer.cornerRadius = 8
        resetButton.addTarget(self, action: #selector(resetScan), for: .touchUpInside)

        exportButton.setTitle("Export OBJ", for: .normal)
        exportButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        exportButton.tintColor = .white
        exportButton.backgroundColor = .systemBlue
        exportButton.layer.cornerRadius = 8
        exportButton.addTarget(self, action: #selector(exportOBJ), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [startStopButton, resetButton, exportButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 10
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            buttonStack.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func configureStatusPanel() {
        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.layer.cornerRadius = 8
        statusPanel.layer.masksToBounds = true

        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        [
            supportLabel,
            trackingLabel,
            anchorCountLabel,
            vertexCountLabel,
            faceCountLabel,
            worldPointCountLabel,
            depthLabel,
            confidenceLabel
        ].forEach(configureStatusLabel(_:))

        view.addSubview(statusPanel)
        statusPanel.contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            statusPanel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusPanel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            statusPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            stackView.leadingAnchor.constraint(equalTo: statusPanel.contentView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: statusPanel.contentView.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: statusPanel.contentView.topAnchor, constant: 10),
            stackView.bottomAnchor.constraint(equalTo: statusPanel.contentView.bottomAnchor, constant: -10)
        ])
    }

    private func configureStatusLabel(_ label: UILabel) {
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 0
        stackView.addArrangedSubview(label)
    }

    @objc private func toggleScan() {
        isScanning ? stopScanning() : startScanning()
    }

    @objc private func closeScanner() {
        dismiss(animated: true)
    }

    private func startScanning() {
        guard ARWorldTrackingConfiguration.isSupported else {
            canStartScan = false
            supportStatus = "Unsupported: world tracking unavailable"
            updateStats()
            return
        }

        let configuration = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            supportStatus = "Supported: mesh with classification"
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            supportStatus = "Supported: mesh"
        } else {
            canStartScan = false
            supportStatus = "Unsupported: scene reconstruction requires LiDAR"
            isScanning = false
            updateStats()
            return
        }

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        configuration.environmentTexturing = .automatic
        meshStore.reset()
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isScanning = true
        updateStats()
    }

    private func stopScanning() {
        guard isScanning else { return }
        arView.session.pause()
        isScanning = false
        updateStats()
    }

    @objc private func resetScan() {
        meshStore.reset()
        depthStatus = "Depth: unavailable"
        confidenceStatus = "Confidence: unavailable"

        if isScanning {
            isScanning = false
            startScanning()
        } else {
            updateStats()
        }
    }

    @objc private func exportOBJ() {
        guard meshStore.vertexCount > 0 else {
            showAlert(title: "No Mesh Data", message: "Start scanning and collect mesh anchors before exporting.")
            return
        }

        let timestamp = makeExportTimestamp()

        do {
            let exportDirectory = try makeExportDirectory(timestamp: timestamp)
            let fileURL = exportDirectory.appendingPathComponent(makeOBJFileName(timestamp: timestamp))
            try meshStore.exportOBJ(to: fileURL)
            let activityController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityController.popoverPresentationController?.sourceView = exportButton
            activityController.popoverPresentationController?.sourceRect = exportButton.bounds
            present(activityController, animated: true)
        } catch {
            showAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    private func makeExportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func makeExportDirectory(timestamp: String) throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDirectory = documentsDirectory
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
    }

    private func makeOBJFileName(timestamp: String) -> String {
        "scene_reconstruction_\(timestamp).obj"
    }

    private func updateStats(trackingState: ARCamera.TrackingState? = nil) {
        startStopButton.setTitle(isScanning ? "Stop Scan" : "Start Scan", for: .normal)
        startStopButton.backgroundColor = isScanning ? .systemRed : .systemGreen
        startStopButton.isEnabled = canStartScan
        startStopButton.alpha = canStartScan ? 1 : 0.55
        exportButton.isEnabled = meshStore.vertexCount > 0
        exportButton.alpha = exportButton.isEnabled ? 1 : 0.55

        supportLabel.text = "Support: \(supportStatus)"
        trackingLabel.text = "Tracking: \(trackingText(for: trackingState ?? arView.session.currentFrame?.camera.trackingState))"
        anchorCountLabel.text = "Mesh anchors: \(meshStore.anchorCount)"
        vertexCountLabel.text = "Vertices: \(meshStore.vertexCount)"
        faceCountLabel.text = "Faces: \(meshStore.faceCount)"
        worldPointCountLabel.text = "World points: \(meshStore.vertexCount)"
        depthLabel.text = depthStatus
        confidenceLabel.text = confidenceStatus
    }

    private func updateDepthStatus(from frame: ARFrame) {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            depthStatus = "Depth: unavailable"
            confidenceStatus = "Confidence: unavailable"
            return
        }

        let depthMap = depthData.depthMap
        depthStatus = "Depth: \(CVPixelBufferGetWidth(depthMap)) x \(CVPixelBufferGetHeight(depthMap))"
        confidenceStatus = "Confidence: \(depthData.confidenceMap == nil ? "no" : "yes")"
    }

    private func trackingText(for trackingState: ARCamera.TrackingState?) -> String {
        guard let trackingState else { return "not available" }

        switch trackingState {
        case .notAvailable:
            return "not available"
        case .normal:
            return "normal"
        case .limited(let reason):
            return "limited (\(trackingReasonText(for: reason)))"
        }
    }

    private func trackingReasonText(for reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .excessiveMotion:
            return "excessive motion"
        case .insufficientFeatures:
            return "insufficient features"
        case .initializing:
            return "initializing"
        case .relocalizing:
            return "relocalizing"
        @unknown default:
            return "unknown"
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension SceneReconstructionScannerViewController: ARSessionDelegate {
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARMeshAnchor }.forEach(meshStore.addOrUpdate(_:))
        updateStats()
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARMeshAnchor }.forEach(meshStore.addOrUpdate(_:))
        updateStats()
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARMeshAnchor }.forEach(meshStore.remove(_:))
        updateStats()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        updateDepthStatus(from: frame)
        updateStats(trackingState: frame.camera.trackingState)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        updateStats(trackingState: camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        supportStatus = "Session error: \(error.localizedDescription)"
        isScanning = false
        updateStats()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        supportStatus = "Session interrupted"
        updateStats()
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        supportStatus = "Session interruption ended"
        updateStats()
    }
}
