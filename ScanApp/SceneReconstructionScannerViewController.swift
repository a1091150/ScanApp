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
    private let captureRecorder = SceneCaptureRecorder()

    private let statusPanel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let stackView = UIStackView()
    private let startStopButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let exportOBJButton = UIButton(type: .system)

    private let supportLabel = UILabel()
    private let trackingLabel = UILabel()
    private let anchorCountLabel = UILabel()
    private let vertexCountLabel = UILabel()
    private let faceCountLabel = UILabel()
    private let worldPointCountLabel = UILabel()
    private let depthLabel = UILabel()
    private let confidenceLabel = UILabel()
    private let imageCaptureLabel = UILabel()
    private let imageDecisionLabel = UILabel()

    private var isScanning = false
    private var isRecordingImages = false
    private var canStartScan = true
    private var supportStatus = "Not checked"
    private var depthStatus = "Depth: unavailable"
    private var confidenceStatus = "Confidence: unavailable"
    private var scanTimestamp: String?
    private var scanDirectory: URL?
    private var cameraMarkerAnchors: [AnchorEntity] = []

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override var shouldAutorotate: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Scene Reconstruction"
        view.backgroundColor = .black
        configureARView()
        configureCaptureRecorder()
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
        arView.debugOptions.insert(.showStatistics)
        arView.debugOptions.insert(.showWorldOrigin)

        view.addSubview(arView)
        NSLayoutConstraint.activate([
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureCaptureRecorder() {
        captureRecorder.onCaptureSaved = { [weak self] capture in
            self?.addCameraMarker(for: capture)
        }
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

        exportOBJButton.setTitle("Export OBJ", for: .normal)
        exportOBJButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        exportOBJButton.tintColor = .white
        exportOBJButton.backgroundColor = .systemBlue
        exportOBJButton.layer.cornerRadius = 8
        exportOBJButton.addTarget(self, action: #selector(exportOBJ), for: .touchUpInside)

        let buttonStack = makeButtonRow([startStopButton, resetButton, exportOBJButton])
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

    private func makeButtonRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        return row
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
            confidenceLabel,
            imageCaptureLabel,
            imageDecisionLabel
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
        captureRecorder.reset()
        removeCameraMarkers()
        isRecordingImages = false
        resetScanDirectory()

        do {
            let directory = try currentScanDirectory()
            try captureRecorder.start(sessionDirectory: directory)
            isRecordingImages = true
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            isScanning = true
            updateStats()
        } catch {
            isScanning = false
            isRecordingImages = false
            showAlert(title: "Scan Start Failed", message: error.localizedDescription)
            updateStats()
        }
    }

    private func stopScanning() {
        guard isScanning else { return }
        arView.session.pause()
        stopImageRecording()
        isScanning = false
        updateStats()
    }

    private func stopImageRecording() {
        guard isRecordingImages else { return }
        captureRecorder.stop()
        isRecordingImages = false
        updateStats()
    }

    @objc private func resetScan() {
        meshStore.reset()
        captureRecorder.reset()
        removeCameraMarkers()
        isRecordingImages = false
        depthStatus = "Depth: unavailable"
        confidenceStatus = "Confidence: unavailable"
        resetScanDirectory()

        if isScanning {
            isScanning = false
            startScanning()
        } else {
            updateStats()
        }
    }

    @objc private func exportOBJ() {
        do {
            let directory = try currentScanDirectory()
            let objURL = directory.appendingPathComponent("scene_reconstruction.obj")
            try meshStore.exportOBJ(to: objURL)
            showAlert(title: "OBJ Saved", message: objURL.path)
        } catch {
            showAlert(title: "OBJ Export Failed", message: error.localizedDescription)
        }
    }

    private func resetScanDirectory() {
        scanTimestamp = nil
        scanDirectory = nil
    }

    private func currentScanDirectory() throws -> URL {
        if let scanDirectory {
            return scanDirectory
        }

        let timestamp = scanTimestamp ?? makeExportTimestamp()
        scanTimestamp = timestamp
        let directory = try makeScanDirectory(timestamp: timestamp)
        scanDirectory = directory
        try writeSessionMetadata(to: directory, timestamp: timestamp)
        return directory
    }

    private func makeExportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private func makeScanDirectory(timestamp: String) throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDirectory = documentsDirectory
            .appendingPathComponent("SceneReconstructionScans", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        return exportDirectory
    }

    private func writeSessionMetadata(to directory: URL, timestamp: String) throws {
        let metadataURL = directory.appendingPathComponent("session.json")
        let metadata: [String: Any] = [
            "session_id": timestamp,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "image_orientation": "landscapeRight",
            "projection_orientation": "landscapeRight",
            "required_orientation": "landscapeRight",
            "dataset_layout": [
                "images": "images/frame_000001.jpg",
                "metadata": "metadata/frame_000001.json"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL, options: .atomic)
    }

    private func updateStats(trackingState: ARCamera.TrackingState? = nil) {
        startStopButton.setTitle(isScanning ? "Stop Scan" : "Start Scan", for: .normal)
        startStopButton.backgroundColor = isScanning ? .systemRed : .systemGreen
        startStopButton.isEnabled = canStartScan
        startStopButton.alpha = canStartScan ? 1 : 0.55

        let recorderStatus = captureRecorder.status
        supportLabel.text = "Support: \(supportStatus)"
        trackingLabel.text = "Tracking: \(trackingText(for: trackingState ?? arView.session.currentFrame?.camera.trackingState))"
        anchorCountLabel.text = "Mesh anchors: \(meshStore.anchorCount)"
        vertexCountLabel.text = "Vertices: \(meshStore.vertexCount)"
        faceCountLabel.text = "Faces: \(meshStore.faceCount)"
        worldPointCountLabel.text = "World points: \(meshStore.vertexCount)"
        depthLabel.text = depthStatus
        confidenceLabel.text = confidenceStatus
        imageCaptureLabel.text = "Saved images: \(recorderStatus.savedImageCount)"
        imageDecisionLabel.text = "Image recorder: \(recorderStatus.lastDecision)"
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

    private func addCameraMarker(for capture: SavedSceneCapture) {
        let anchor = AnchorEntity(world: capture.cameraTransform)
        let originMaterial = SimpleMaterial(color: .white, isMetallic: false)
        let forwardMaterial = SimpleMaterial(color: .systemBlue, isMetallic: false)
        let rightMaterial = SimpleMaterial(color: .systemRed, isMetallic: false)
        let upMaterial = SimpleMaterial(color: .systemGreen, isMetallic: false)

        let origin = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [originMaterial])
        let forward = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [forwardMaterial])
        let right = ModelEntity(mesh: .generateSphere(radius: 0.009), materials: [rightMaterial])
        let up = ModelEntity(mesh: .generateSphere(radius: 0.009), materials: [upMaterial])

        forward.position = SIMD3<Float>(0, 0, -0.11)
        right.position = SIMD3<Float>(0.07, 0, 0)
        up.position = SIMD3<Float>(0, 0.07, 0)

        anchor.name = "saved_camera_\(capture.imageName)"
        anchor.addChild(origin)
        anchor.addChild(forward)
        anchor.addChild(right)
        anchor.addChild(up)

        arView.scene.addAnchor(anchor)
        cameraMarkerAnchors.append(anchor)
    }

    private func removeCameraMarkers() {
        cameraMarkerAnchors.forEach { arView.scene.removeAnchor($0) }
        cameraMarkerAnchors.removeAll()
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
        captureRecorder.process(frame: frame, interfaceOrientation: currentInterfaceOrientation)
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

private extension SceneReconstructionScannerViewController {
    var currentInterfaceOrientation: UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? .landscapeRight
    }
}
