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
    private enum ScanState {
        case idle
        case recording
        case paused
    }

    private let arView = ARView(frame: .zero)
    private let viewModel = SceneReconstructionScanViewModel()
    private let captureRecorder = SceneCaptureRecorder()

    private let statusView = SceneReconstructionStatusView()
    private let primaryButton = UIButton(type: .system)
    private let saveResetButton = UIButton(type: .system)

    private var scanState: ScanState = .idle
    private var isRecordingImages = false
    private var canStartScan = true
    private var supportStatus = "Not checked"
    private var depthStatus = "Depth: unavailable"
    private var confidenceStatus = "Confidence: unavailable"

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

        title = "ARKit Depth Scan"
        view.backgroundColor = .black
        configureARView()
        configureUI()
        configureNavigation()
        evaluateDeviceSupport()
        updateStats()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pauseScanning()
    }

    private func configureARView() {
        arView.translatesAutoresizingMaskIntoConstraints = false
        arView.automaticallyConfigureSession = false
        arView.session.delegate = self
        arView.debugOptions = []

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

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            canStartScan = true
            supportStatus = "Supported: smoothed scene depth"
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            canStartScan = true
            supportStatus = "Supported: scene depth"
        } else {
            canStartScan = false
            supportStatus = "Unsupported: scene depth requires LiDAR"
        }
    }

    private func configureButtons() {
        primaryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        primaryButton.tintColor = .white
        primaryButton.layer.cornerRadius = 8
        primaryButton.addTarget(self, action: #selector(handlePrimaryButton), for: .touchUpInside)

        saveResetButton.setTitle("Save (Reset)", for: .normal)
        saveResetButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        saveResetButton.tintColor = .white
        saveResetButton.backgroundColor = .systemBlue
        saveResetButton.layer.cornerRadius = 8
        saveResetButton.addTarget(self, action: #selector(saveAndResetScan), for: .touchUpInside)

        let buttonStack = makeButtonRow([primaryButton, saveResetButton])
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

        updateButtonState()
    }

    private func makeButtonRow(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        return row
    }

    private func configureStatusPanel() {
        view.addSubview(statusView)

        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            statusView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
    }

    @objc private func handlePrimaryButton() {
        switch scanState {
        case .idle:
            startScanning()
        case .recording:
            pauseScanning()
        case .paused:
            continueScanning()
        }
    }

    @objc private func closeScanner() {
        dismiss(animated: true)
    }

    private func startScanning() {
        captureRecorder.reset()
        isRecordingImages = false
        depthStatus = "Depth: unavailable"
        confidenceStatus = "Confidence: unavailable"
        viewModel.resetScanDirectory()
        runScanSession(resetTracking: true)
    }

    private func continueScanning() {
        runScanSession(resetTracking: false)
    }

    private func runScanSession(resetTracking: Bool) {
        guard ARWorldTrackingConfiguration.isSupported else {
            canStartScan = false
            supportStatus = "Unsupported: world tracking unavailable"
            updateStats()
            return
        }

        let configuration = ARWorldTrackingConfiguration()

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
            supportStatus = "Supported: smoothed scene depth"
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            supportStatus = "Supported: scene depth"
        } else {
            canStartScan = false
            supportStatus = "Unsupported: scene depth requires LiDAR"
            scanState = .idle
            updateStats()
            return
        }

        configuration.environmentTexturing = .automatic

        do {
            let directory = try viewModel.currentScanDirectory()
            try captureRecorder.start(sessionDirectory: directory)
            isRecordingImages = true
            let options: ARSession.RunOptions = resetTracking ? [.resetTracking] : []
            arView.session.run(configuration, options: options)
            scanState = .recording
            updateStats()
        } catch {
            scanState = .idle
            isRecordingImages = false
            showAlert(title: "Scan Start Failed", message: error.localizedDescription)
            updateStats()
        }
    }

    private func pauseScanning() {
        guard scanState == .recording else { return }
        arView.session.pause()
        stopImageRecording()
        scanState = .paused
        updateStats()
    }

    private func stopImageRecording() {
        guard isRecordingImages else { return }
        captureRecorder.stop()
        isRecordingImages = false
        updateStats()
    }

    @objc private func saveAndResetScan() {
        if scanState == .recording {
            arView.session.pause()
            stopImageRecording()
        }
        captureRecorder.reset()
        isRecordingImages = false
        depthStatus = "Depth: unavailable"
        confidenceStatus = "Confidence: unavailable"
        viewModel.resetScanDirectory()
        scanState = .idle
        updateStats()
    }

    private func updateStats(trackingState: ARCamera.TrackingState? = nil) {
        updateButtonState()

        let recorderStatus = captureRecorder.status
        statusView.update(
            supportStatus: supportStatus,
            trackingStatus: trackingText(for: trackingState ?? arView.session.currentFrame?.camera.trackingState),
            depthStatus: depthStatus,
            confidenceStatus: confidenceStatus,
            savedImageCount: recorderStatus.savedImageCount,
            savedDepthFrameCount: recorderStatus.savedDepthFrameCount,
            imageDecision: recorderStatus.lastDecision
        )
    }

    private func updateButtonState() {
        primaryButton.isEnabled = canStartScan
        primaryButton.alpha = canStartScan ? 1 : 0.55

        switch scanState {
        case .idle:
            primaryButton.setTitle("Start Scan", for: .normal)
            primaryButton.backgroundColor = .systemGreen
            saveResetButton.isHidden = true
        case .recording:
            primaryButton.setTitle("Pause Scan", for: .normal)
            primaryButton.backgroundColor = .systemOrange
            saveResetButton.isHidden = false
        case .paused:
            primaryButton.setTitle("Continue Scan", for: .normal)
            primaryButton.backgroundColor = .systemGreen
            saveResetButton.isHidden = false
        }
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
        stopImageRecording()
        scanState = .paused
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
