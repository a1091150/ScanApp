//
//  CapturePreviewViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import UIKit
import RealityKit

final class CapturePreviewViewController: UIViewController {
    private let session: CapturedScanSession
    private let processor = CapturePointCloudProcessor()

    private let imageView = UIImageView()
    private let sceneContainerView = UIView()
    private let metadataLabel = UILabel()
    private let statusLabel = UILabel()
    private let processButton = UIButton(type: .system)

    private var latestResult: CapturePointCloudResult?
    private var realityView: ARView?
    private var previewAnchor: AnchorEntity?
    private var previewRootEntity: Entity?
    private var previewCamera: PerspectiveCamera?
    private var previewScale: Float = 1
    private var previewYaw: Float = 0
    private var previewPitch: Float = 0
    private var previewCameraDistance: Float = 1
    private var firstFrameCameraPose: CaptureCameraPose?
    private var shareButton: UIBarButtonItem?

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
        configureNavigationItems()
        loadSummary()
    }

    private func configureUI() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black

        sceneContainerView.translatesAutoresizingMaskIntoConstraints = false
        sceneContainerView.backgroundColor = .black
        sceneContainerView.isHidden = true

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

        processButton.setTitle("Create USDZ Preview", for: .normal)
        processButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        processButton.tintColor = .white
        processButton.backgroundColor = .systemBlue
        processButton.layer.cornerRadius = 8
        processButton.translatesAutoresizingMaskIntoConstraints = false
        processButton.addTarget(self, action: #selector(processPointCloud), for: .touchUpInside)

        view.addSubview(imageView)
        view.addSubview(sceneContainerView)
        view.addSubview(metadataLabel)
        view.addSubview(processButton)
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            imageView.heightAnchor.constraint(equalTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.52),

            sceneContainerView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            sceneContainerView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            sceneContainerView.topAnchor.constraint(equalTo: imageView.topAnchor),
            sceneContainerView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),

            statusLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 10),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            statusLabel.heightAnchor.constraint(equalToConstant: 30),

            metadataLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 14),

            processButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            processButton.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            processButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            processButton.heightAnchor.constraint(equalToConstant: 48),

            metadataLabel.bottomAnchor.constraint(lessThanOrEqualTo: processButton.topAnchor, constant: -12)
        ])
    }

    private func configureNavigationItems() {
        let item = UIBarButtonItem(
            barButtonSystemItem: .action,
            target: self,
            action: #selector(shareCurrentOutput)
        )
        item.isEnabled = true
        navigationItem.rightBarButtonItem = item
        shareButton = item
    }

    private func loadSummary() {
        latestResult = nil
        firstFrameCameraPose = nil
        hideUSDZPreview()

        let existingUSDZURL = findExistingUSDZURL()

        guard let summary = processor.loadFirstFrameSummary(session: session) else {
            if let existingUSDZURL {
                metadataLabel.text = [
                    "Preview: USDZ",
                    "Output: \(existingUSDZURL.lastPathComponent)",
                    "Session: \(session.id)"
                ].joined(separator: "\n")
                showUSDZPreview(url: existingUSDZURL)
                return
            }

            metadataLabel.text = "No previewable frames found."
            imageView.image = nil
            return
        }

        firstFrameCameraPose = summary.cameraPose
        imageView.image = UIImage(contentsOfFile: summary.imageURL.path)
        let previewText: String
        if let existingUSDZURL {
            previewText = "Preview: USDZ\nOutput: \(existingUSDZURL.lastPathComponent)"
        } else {
            previewText = "Preview: image"
        }
        metadataLabel.text = [
            "Frame: \(summary.frameName)",
            summary.cameraPositionText,
            summary.cameraForwardText,
            "Session: \(session.id)",
            previewText
        ].joined(separator: "\n")

        if let existingUSDZURL {
            showUSDZPreview(url: existingUSDZURL)
        }
    }

    @objc private func processPointCloud() {
        processButton.isEnabled = false
        processButton.alpha = 0.55
        latestResult = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.processor.process(session: self.session, outputFormat: .usdz) { message in
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
                    self.updatePreviewIfNeeded(for: result)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Failed"
                    self.processButton.isEnabled = true
                    self.processButton.alpha = 1
                    self.showAlert(title: "Process Failed", message: error.localizedDescription)
                }
            }
        }
    }

    @objc private func shareCurrentOutput() {
        let activityViewController = UIActivityViewController(
            activityItems: [session.url],
            applicationActivities: nil
        )
        activityViewController.popoverPresentationController?.barButtonItem = shareButton
        present(activityViewController, animated: true)
    }

    private func updatePreviewIfNeeded(for result: CapturePointCloudResult) {
        guard let usdzURL = result.outputURLs.first(where: { $0.pathExtension.lowercased() == "usdz" }) else {
            return
        }
        showUSDZPreview(url: usdzURL)
    }

    private func findExistingUSDZURL() -> URL? {
        let preferredURL = session.url
            .appendingPathComponent("processed", isDirectory: true)
            .appendingPathComponent("point_cloud.usdz")
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            return preferredURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: session.url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var newestURL: URL?
        var newestDate = Date.distantPast
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "usdz" {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true
            else {
                continue
            }

            let modificationDate = values.contentModificationDate ?? Date.distantPast
            if newestURL == nil || modificationDate > newestDate {
                newestURL = url
                newestDate = modificationDate
            }
        }
        return newestURL
    }

    private func showUSDZPreview(url: URL) {
        do {
            configureRealityViewIfNeeded()
            let entity = try Entity.load(contentsOf: url)
            displayRealityEntity(entity)
            imageView.isHidden = true
            sceneContainerView.isHidden = false
        } catch {
            hideUSDZPreview()
            statusLabel.text = "Preview failed"
            showAlert(title: "USDZ Preview Failed", message: error.localizedDescription)
        }
    }

    private func hideUSDZPreview() {
        previewAnchor.map { realityView?.scene.removeAnchor($0) }
        previewAnchor = nil
        previewRootEntity = nil
        previewCamera = nil
        imageView.isHidden = false
        sceneContainerView.isHidden = true
    }

    private func configureRealityViewIfNeeded() {
        guard realityView == nil else { return }

        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.environment.background = .color(.black)
        view.automaticallyConfigureSession = false
        view.cameraMode = .nonAR
        view.renderOptions.insert(.disableCameraGrain)
        view.renderOptions.insert(.disableAREnvironmentLighting)
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePreviewPan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePreviewPinch(_:))))
        sceneContainerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: sceneContainerView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: sceneContainerView.trailingAnchor),
            view.topAnchor.constraint(equalTo: sceneContainerView.topAnchor),
            view.bottomAnchor.constraint(equalTo: sceneContainerView.bottomAnchor)
        ])
        realityView = view
    }

    private func displayRealityEntity(_ entity: Entity) {
        guard let realityView else { return }

        previewAnchor.map { realityView.scene.removeAnchor($0) }

        let anchor = AnchorEntity(world: .zero)
        let root = Entity()
        anchor.addChild(root)
        root.addChild(entity)

        let originalCenter = centerEntity(entity)
        let radius = max(entity.visualBounds(recursive: true, relativeTo: root).boundingRadius, 0.1)
        previewScale = 1 / radius
        previewYaw = 0
        previewPitch = 0
        previewCameraDistance = 3
        updatePreviewRootTransform()

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 55
        configurePreviewCamera(
            camera,
            originalCenter: originalCenter,
            radius: radius,
            relativeTo: anchor
        )
        anchor.addChild(camera)

        let light = DirectionalLight()
        light.light.intensity = 3000
        light.look(at: .zero, from: SIMD3<Float>(0, 2, 3), relativeTo: anchor)
        anchor.addChild(light)

        realityView.scene.addAnchor(anchor)
        previewAnchor = anchor
        previewRootEntity = root
        previewCamera = camera
    }

    @discardableResult
    private func centerEntity(_ entity: Entity) -> SIMD3<Float> {
        let bounds = entity.visualBounds(recursive: true, relativeTo: nil)
        guard !bounds.isEmpty else { return .zero }
        entity.position -= bounds.center
        return bounds.center
    }

    private func configurePreviewCamera(
        _ camera: PerspectiveCamera,
        originalCenter: SIMD3<Float>,
        radius: Float,
        relativeTo anchor: AnchorEntity
    ) {
        guard
            let pose = firstFrameCameraPose,
            simd_length(pose.forward) > 0.0001
        else {
            camera.look(
                at: .zero,
                from: SIMD3<Float>(0, 0, previewCameraDistance),
                relativeTo: anchor
            )
            return
        }

        let previewPosition = (pose.position - originalCenter) / radius
        let previewTarget = previewPosition + simd_normalize(pose.forward)
        let upVector = simd_length(pose.up) > 0.0001 ? simd_normalize(pose.up) : SIMD3<Float>(0, 1, 0)
        camera.look(
            at: previewTarget,
            from: previewPosition,
            upVector: upVector,
            relativeTo: anchor
        )
    }

    private func updatePreviewRootTransform() {
        let yawRotation = simd_quatf(angle: previewYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitchRotation = simd_quatf(angle: previewPitch, axis: SIMD3<Float>(1, 0, 0))
        previewRootEntity?.transform = Transform(
            scale: SIMD3<Float>(repeating: previewScale),
            rotation: yawRotation * pitchRotation,
            translation: .zero
        )
    }

    @objc private func handlePreviewPan(_ recognizer: UIPanGestureRecognizer) {
        guard previewRootEntity != nil else { return }

        let translation = recognizer.translation(in: sceneContainerView)
        previewYaw += Float(translation.x) * 0.008
        previewPitch += Float(translation.y) * 0.008
        previewPitch = min(max(previewPitch, -.pi / 2), .pi / 2)
        recognizer.setTranslation(.zero, in: sceneContainerView)
        updatePreviewRootTransform()
    }

    @objc private func handlePreviewPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard previewRootEntity != nil else { return }

        previewScale *= Float(recognizer.scale)
        previewScale = min(max(previewScale, 0.05), 100)
        recognizer.scale = 1
        updatePreviewRootTransform()
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
