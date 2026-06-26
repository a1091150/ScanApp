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
    private let minimumPreviewWarmupDuration: TimeInterval = 0.35

    private let statusView = SceneReconstructionStatusView()
    private let modeControl = UISegmentedControl(items: [
        SceneCaptureMode.depthScan.title,
        SceneCaptureMode.faceScan.title
    ])
    private let primaryButton = UIButton(type: .system)
    private let saveResetButton = UIButton(type: .system)

    private var scanState: ScanState = .idle
    private var isRecordingImages = false
    private var canStartScan = true
    private var supportStatus = "Not checked"
    private var depthStatus = "Depth: unavailable"
    private var confidenceStatus = "Confidence: unavailable"
    private var isPreviewSessionRunning = false
    private var previewSessionMode: SceneCaptureMode?
    private var previewStartedAt: TimeInterval?
    private var hasReceivedPreviewFrame = false

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        selectedCaptureMode.supportedInterfaceOrientations
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        selectedCaptureMode.preferredInterfaceOrientation
    }

    override var shouldAutorotate: Bool {
        false
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "ARKit Scan"
        view.backgroundColor = .black
        configureARView()
        configureUI()
        configureNavigation()
        evaluateDeviceSupport()
        updateStats()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestRequiredOrientation()
        startPreviewSession(resetTracking: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPreviewSession()
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
        configureModeControl()
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
        switch selectedCaptureMode {
        case .depthScan:
            evaluateDepthScanSupport()
        case .faceScan:
            evaluateFaceScanSupport()
        }
    }

    private func evaluateDepthScanSupport() {
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

    private func evaluateFaceScanSupport() {
        guard ARFaceTrackingConfiguration.isSupported else {
            canStartScan = false
            supportStatus = "Unsupported: face tracking unavailable"
            return
        }

        canStartScan = true
        supportStatus = ARFaceTrackingConfiguration.supportsWorldTracking
            ? "Supported: face tracking + world tracking"
            : "Supported: face tracking"
    }

    private func configureModeControl() {
        modeControl.selectedSegmentIndex = SceneCaptureMode.depthScan.rawValue
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentTintColor = .systemBlue
        modeControl.addTarget(self, action: #selector(handleModeChanged), for: .valueChanged)

        view.addSubview(modeControl)
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            modeControl.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            modeControl.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -74),
            modeControl.heightAnchor.constraint(equalToConstant: 36)
        ])
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

    @objc private func handleModeChanged() {
        guard scanState == .idle else { return }
        viewModel.resetScanDirectory()
        depthStatus = selectedCaptureMode == .depthScan ? "Depth: unavailable" : "Face: unavailable"
        confidenceStatus = selectedCaptureMode == .depthScan ? "Confidence: unavailable" : "Face metadata: unavailable"
        evaluateDeviceSupport()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        requestRequiredOrientation()
        startPreviewSession(resetTracking: true)
        updateStats()
    }

    @objc private func closeScanner() {
        dismiss(animated: true)
    }

    private func startScanning() {
        captureRecorder.reset()
        isRecordingImages = false
        depthStatus = selectedCaptureMode == .depthScan ? "Depth: unavailable" : "Face: unavailable"
        confidenceStatus = selectedCaptureMode == .depthScan ? "Confidence: unavailable" : "Face metadata: unavailable"
        viewModel.resetScanDirectory()
        startRecording()
    }

    private func continueScanning() {
        startRecording()
    }

    private func startPreviewSession(resetTracking: Bool) {
        let mode = selectedCaptureMode
        evaluateDeviceSupport()
        guard canStartScan else {
            isPreviewSessionRunning = false
            previewSessionMode = nil
            updateStats()
            return
        }

        if isPreviewSessionRunning, previewSessionMode == mode, !resetTracking {
            return
        }

        let configuration: ARConfiguration

        switch mode {
        case .depthScan:
            configuration = makeDepthScanConfiguration()
        case .faceScan:
            configuration = makeFaceScanConfiguration()
        }

        let options: ARSession.RunOptions = resetTracking ? [.resetTracking] : []
        arView.session.run(configuration, options: options)
        isPreviewSessionRunning = true
        previewSessionMode = mode
        previewStartedAt = Date.timeIntervalSinceReferenceDate
        hasReceivedPreviewFrame = false
        updateStats()
    }

    private func stopPreviewSession() {
        stopImageRecording()
        arView.session.pause()
        isPreviewSessionRunning = false
        previewSessionMode = nil
        previewStartedAt = nil
        hasReceivedPreviewFrame = false

        if scanState == .recording {
            scanState = .paused
        }

        updateStats()
    }

    private func startRecording() {
        let mode = selectedCaptureMode
        evaluateDeviceSupport()
        guard canStartScan else {
            scanState = .idle
            updateStats()
            return
        }

        if !isPreviewSessionRunning || previewSessionMode != mode {
            startPreviewSession(resetTracking: true)
        }

        guard isPreviewReadyForRecording else {
            updateStats()
            return
        }

        do {
            let directory = try viewModel.currentScanDirectory(mode: mode)
            try captureRecorder.start(sessionDirectory: directory, mode: mode)
            isRecordingImages = true
            scanState = .recording
            updateStats()
        } catch {
            scanState = .idle
            isRecordingImages = false
            showAlert(title: "Scan Start Failed", message: error.localizedDescription)
            updateStats()
        }
    }

    private func makeDepthScanConfiguration() -> ARWorldTrackingConfiguration {
        guard ARWorldTrackingConfiguration.isSupported else {
            canStartScan = false
            supportStatus = "Unsupported: world tracking unavailable"
            return ARWorldTrackingConfiguration()
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
            return configuration
        }

        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true
        return configuration
    }

    private func makeFaceScanConfiguration() -> ARFaceTrackingConfiguration {
        let configuration = ARFaceTrackingConfiguration()
        if ARFaceTrackingConfiguration.supportsWorldTracking {
            configuration.isWorldTrackingEnabled = true
        }
        configuration.isLightEstimationEnabled = true
        return configuration
    }

    private func pauseScanning() {
        guard scanState == .recording else { return }
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
            stopImageRecording()
        }
        captureRecorder.reset()
        isRecordingImages = false
        depthStatus = selectedCaptureMode == .depthScan ? "Depth: unavailable" : "Face: unavailable"
        confidenceStatus = selectedCaptureMode == .depthScan ? "Confidence: unavailable" : "Face metadata: unavailable"
        viewModel.resetScanDirectory()
        scanState = .idle
        evaluateDeviceSupport()
        startPreviewSession(resetTracking: false)
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
        let canUsePrimaryButton = canStartScan && (scanState != .idle || isPreviewReadyForRecording)
        primaryButton.isEnabled = canUsePrimaryButton
        primaryButton.alpha = canUsePrimaryButton ? 1 : 0.55
        modeControl.isEnabled = scanState == .idle

        switch scanState {
        case .idle:
            primaryButton.setTitle("Start \(selectedCaptureMode.title)", for: .normal)
            primaryButton.backgroundColor = .systemGreen
            saveResetButton.isHidden = true
        case .recording:
            primaryButton.setTitle("Pause \(selectedCaptureMode.title)", for: .normal)
            primaryButton.backgroundColor = .systemOrange
            saveResetButton.isHidden = false
        case .paused:
            primaryButton.setTitle("Continue \(selectedCaptureMode.title)", for: .normal)
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

    private func updateFaceStatus(from frame: ARFrame) {
        let faceCount = frame.anchors.compactMap { $0 as? ARFaceAnchor }.count
        depthStatus = "Face: \(faceCount)"
        if let depthMap = frame.capturedDepthData?.depthDataMap {
            confidenceStatus = "Face depth: \(CVPixelBufferGetWidth(depthMap)) x \(CVPixelBufferGetHeight(depthMap))"
        } else {
            confidenceStatus = "Face depth: unavailable"
        }
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

    private func requestRequiredOrientation() {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        guard let windowScene = view.window?.windowScene else { return }
        if #available(iOS 16.0, *) {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: selectedCaptureMode.supportedInterfaceOrientations))
        } else {
            UIDevice.current.setValue(selectedCaptureMode.preferredInterfaceOrientation.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

}

extension SceneReconstructionScannerViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if isPreviewSessionRunning, previewSessionMode == selectedCaptureMode {
            hasReceivedPreviewFrame = true
        }

        switch selectedCaptureMode {
        case .depthScan:
            updateDepthStatus(from: frame)
        case .faceScan:
            updateFaceStatus(from: frame)
        }
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
    var selectedCaptureMode: SceneCaptureMode {
        SceneCaptureMode(rawValue: modeControl.selectedSegmentIndex) ?? .depthScan
    }

    var currentInterfaceOrientation: UIInterfaceOrientation {
        view.window?.windowScene?.interfaceOrientation ?? selectedCaptureMode.preferredInterfaceOrientation
    }

    var isPreviewReadyForRecording: Bool {
        guard isPreviewSessionRunning,
              previewSessionMode == selectedCaptureMode,
              hasReceivedPreviewFrame,
              let previewStartedAt else {
            return false
        }

        return Date.timeIntervalSinceReferenceDate - previewStartedAt >= minimumPreviewWarmupDuration
    }
}
