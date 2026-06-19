//
//  CapturePreviewViewController.swift
//  ScanApp
//
//  Created by Codex on 2026/6/18.
//

import UIKit
import RealityKit
import SDWebImage
import simd

final class CapturePreviewViewController: UIViewController {
    private let session: CapturedScanSession
    private let processor = CapturePointCloudProcessor()

    private let imageView = UIImageView()
    private let sceneContainerView = UIView()
    private let framesCollectionView: UICollectionView
    private let metadataLabel = UILabel()
    private let statusLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let processButton = UIButton(type: .system)
    private let playbackFrameDuration: TimeInterval = 0.1

    private var latestResult: CapturePointCloudResult?
    private var realityView: ARView?
    private var previewAnchor: AnchorEntity?
    private var previewRootEntity: Entity?
    private var previewContentEntity: Entity?
    private var previewCamera: PerspectiveCamera?
    private var previewScale: Float = 1
    private var previewYaw: Float = 0
    private var previewPitch: Float = 0
    private var previewCameraDistance: Float = 1
    private var previewOriginalCenter: SIMD3<Float> = .zero
    private var previewRadius: Float = 1
    private var frameSummaries: [CaptureFrameSummary] = []
    private var selectedFrameIndex: Int?
    private var shareButton: UIBarButtonItem?
    private var isPlaying = false

    init(session: CapturedScanSession) {
        self.session = session
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.itemSize = CGSize(width: 72, height: 54)
        framesCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        CameraPlaybackRuntime.registerIfNeeded()
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

        framesCollectionView.translatesAutoresizingMaskIntoConstraints = false
        framesCollectionView.backgroundColor = .clear
        framesCollectionView.showsHorizontalScrollIndicator = false
        framesCollectionView.dataSource = self
        framesCollectionView.delegate = self
        framesCollectionView.register(CaptureFrameThumbnailCell.self, forCellWithReuseIdentifier: CaptureFrameThumbnailCell.reuseIdentifier)

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

        playButton.setTitle("Play", for: .normal)
        playButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        playButton.tintColor = .white
        playButton.backgroundColor = .systemGreen
        playButton.layer.cornerRadius = 8
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        processButton.setTitle("Create USDZ Preview", for: .normal)
        processButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        processButton.tintColor = .white
        processButton.backgroundColor = .systemBlue
        processButton.layer.cornerRadius = 8
        processButton.translatesAutoresizingMaskIntoConstraints = false
        processButton.addTarget(self, action: #selector(processPointCloud), for: .touchUpInside)

        view.addSubview(imageView)
        view.addSubview(sceneContainerView)
        view.addSubview(framesCollectionView)
        view.addSubview(metadataLabel)
        view.addSubview(playButton)
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

            framesCollectionView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            framesCollectionView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            framesCollectionView.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10),
            framesCollectionView.heightAnchor.constraint(equalToConstant: 62),

            playButton.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: framesCollectionView.bottomAnchor, constant: 12),
            playButton.widthAnchor.constraint(equalToConstant: 96),
            playButton.heightAnchor.constraint(equalToConstant: 38),

            metadataLabel.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 12),

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
        selectedFrameIndex = nil
        stopPlayback(resetButton: true)
        frameSummaries = processor.loadFrameSummaries(session: session)
        framesCollectionView.reloadData()
        framesCollectionView.isHidden = frameSummaries.isEmpty
        playButton.isEnabled = frameSummaries.count > 1
        playButton.alpha = frameSummaries.count > 1 ? 1 : 0.45
        hideUSDZPreview()

        let existingUSDZURL = findExistingUSDZURL()

        guard let summary = frameSummaries.first else {
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

        selectFrame(at: 0, updateRealityCamera: false)
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

    private func selectFrame(
        at index: Int,
        updateRealityCamera: Bool = true,
        resetPlayback: Bool = false,
        cameraAnimationDuration: TimeInterval = 0
    ) {
        guard frameSummaries.indices.contains(index) else { return }

        if resetPlayback {
            stopPlayback(resetButton: true)
        }
        selectedFrameIndex = index
        let summary = frameSummaries[index]
        if sceneContainerView.isHidden {
            imageView.image = UIImage(contentsOfFile: summary.imageURL.path)
        }
        framesCollectionView.selectItem(
            at: IndexPath(item: index, section: 0),
            animated: true,
            scrollPosition: .centeredHorizontally
        )

        metadataLabel.text = [
            "Frame: \(summary.frameName)",
            summary.cameraPositionText,
            summary.cameraForwardText,
            "Session: \(session.id)",
            previewModeText()
        ].joined(separator: "\n")

        if updateRealityCamera {
            movePreviewCamera(to: summary.cameraPose, animatedDuration: cameraAnimationDuration)
        }
    }

    private func previewModeText() -> String {
        if let usdzURL = findExistingUSDZURL() {
            return "Preview: USDZ\nOutput: \(usdzURL.lastPathComponent)"
        }
        return "Preview: image"
    }

    @objc private func processPointCloud() {
        stopPlayback(resetButton: true)
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
        stopPlayback(resetButton: true)
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
        stopPlayback(resetButton: true)
        previewAnchor.map { realityView?.scene.removeAnchor($0) }
        previewAnchor = nil
        previewRootEntity = nil
        previewContentEntity = nil
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
        previewOriginalCenter = originalCenter
        previewRadius = radius
        previewScale = 1 / radius
        previewYaw = 0
        previewPitch = 0
        previewCameraDistance = 3
        updatePreviewRootTransform()

        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 55
        configureDefaultPreviewCamera(camera, relativeTo: anchor)
        anchor.addChild(camera)

        let light = DirectionalLight()
        light.light.intensity = 3000
        light.look(at: .zero, from: SIMD3<Float>(0, 2, 3), relativeTo: anchor)
        anchor.addChild(light)

        realityView.scene.addAnchor(anchor)
        previewAnchor = anchor
        previewRootEntity = root
        previewContentEntity = entity
        previewCamera = camera
    }

    @discardableResult
    private func centerEntity(_ entity: Entity) -> SIMD3<Float> {
        let bounds = entity.visualBounds(recursive: true, relativeTo: nil)
        guard !bounds.isEmpty else { return .zero }
        entity.position -= bounds.center
        return bounds.center
    }

    private func configureDefaultPreviewCamera(
        _ camera: PerspectiveCamera,
        relativeTo anchor: AnchorEntity
    ) {
        camera.look(
            at: .zero,
            from: SIMD3<Float>(0, 0, previewCameraDistance),
            relativeTo: anchor
        )
    }

    private func configurePreviewCamera(
        _ camera: PerspectiveCamera,
        previewPose: CaptureCameraPose?,
        relativeTo anchor: AnchorEntity,
        animatedDuration: TimeInterval = 0
    ) {
        guard let previewPose else {
            camera.look(
                at: .zero,
                from: SIMD3<Float>(0, 0, previewCameraDistance),
                relativeTo: anchor
            )
            return
        }

        let currentTransform = camera.transform
        camera.look(
            at: previewPose.position + previewPose.forward,
            from: previewPose.position,
            upVector: previewPose.up,
            relativeTo: anchor
        )
        guard animatedDuration > 0 else { return }

        let targetTransform = camera.transform
        camera.transform = currentTransform
        camera.move(
            to: targetTransform,
            relativeTo: camera.parent,
            duration: animatedDuration,
            timingFunction: .easeInOut
        )
    }

    private func movePreviewCamera(to pose: CaptureCameraPose, animatedDuration: TimeInterval = 0) {
        guard let previewCamera, let previewAnchor else { return }
        let convertedPose = previewPose(from: pose)
        configurePreviewCamera(
            previewCamera,
            previewPose: convertedPose,
            relativeTo: previewAnchor,
            animatedDuration: animatedDuration
        )
        if let convertedPose {
            statusLabel.text = String(
                format: "Camera %.2f %.2f %.2f",
                convertedPose.position.x,
                convertedPose.position.y,
                convertedPose.position.z
            )
        }
    }

    private func previewPose(from pose: CaptureCameraPose?) -> CaptureCameraPose? {
        guard let pose, simd_length(pose.forward) > 0.0001 else { return nil }

        guard
            let previewContentEntity,
            let previewAnchor
        else {
            let rotation = currentPreviewRotation()
            let centeredPosition = pose.position - previewOriginalCenter
            let position = simd_act(rotation, centeredPosition * previewScale)
            let forward = simd_act(rotation, simd_normalize(pose.forward))
            let up = simd_length(pose.up) > 0.0001
                ? simd_act(rotation, simd_normalize(pose.up))
                : SIMD3<Float>(0, 1, 0)
            return CaptureCameraPose(position: position, forward: forward, up: up)
        }

        let transform = previewContentEntity.transformMatrix(relativeTo: previewAnchor)
        let position4 = transform * SIMD4<Float>(pose.position.x, pose.position.y, pose.position.z, 1)
        let forward4 = transform * SIMD4<Float>(pose.forward.x, pose.forward.y, pose.forward.z, 0)
        let up4 = transform * SIMD4<Float>(pose.up.x, pose.up.y, pose.up.z, 0)

        let position = SIMD3<Float>(position4.x, position4.y, position4.z)
        let forward = SIMD3<Float>(forward4.x, forward4.y, forward4.z)
        let up = simd_length(pose.up) > 0.0001
            ? SIMD3<Float>(up4.x, up4.y, up4.z)
            : SIMD3<Float>(0, 1, 0)

        guard simd_length(forward) > 0.0001 else { return nil }
        return CaptureCameraPose(
            position: position,
            forward: simd_normalize(forward),
            up: simd_length(up) > 0.0001 ? simd_normalize(up) : SIMD3<Float>(0, 1, 0)
        )
    }

    private func currentPreviewRotation() -> simd_quatf {
        let yawRotation = simd_quatf(angle: previewYaw, axis: SIMD3<Float>(0, 1, 0))
        let pitchRotation = simd_quatf(angle: previewPitch, axis: SIMD3<Float>(1, 0, 0))
        return yawRotation * pitchRotation
    }

    private func updatePreviewRootTransform() {
        previewRootEntity?.transform = Transform(
            scale: SIMD3<Float>(repeating: previewScale),
            rotation: currentPreviewRotation(),
            translation: .zero
        )
    }

    @objc private func togglePlayback() {
        if isPlaying {
            stopPlayback(resetButton: true)
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard frameSummaries.count > 1, let previewCamera else { return }

        if selectedFrameIndex == nil || selectedFrameIndex == frameSummaries.count - 1 {
            selectFrame(at: 0, updateRealityCamera: true)
        }

        let startIndex = selectedFrameIndex ?? 0
        guard let component = makePlaybackComponent(startIndex: startIndex) else { return }
        previewCamera.components[CameraPlaybackComponent.self] = component
        isPlaying = true
        playButton.setTitle("Pause", for: .normal)
        playButton.backgroundColor = .systemOrange
    }

    private func stopPlayback(resetButton: Bool) {
        isPlaying = false
        previewCamera?.components[CameraPlaybackComponent.self]?.isPlaying = false
        guard resetButton else { return }
        playButton.setTitle("Play", for: .normal)
        playButton.backgroundColor = .systemGreen
    }

    private func makePlaybackComponent(startIndex: Int) -> CameraPlaybackComponent? {
        guard
            let previewCamera,
            let previewAnchor
        else {
            return nil
        }

        let originalTransform = previewCamera.transform
        var keyframes: [CameraPlaybackKeyframe] = []
        keyframes.reserveCapacity(frameSummaries.count)

        for (index, summary) in frameSummaries.enumerated() {
            guard let convertedPose = previewPose(from: summary.cameraPose) else { continue }
            configurePreviewCamera(previewCamera, previewPose: convertedPose, relativeTo: previewAnchor)
            keyframes.append(
                CameraPlaybackKeyframe(
                    time: TimeInterval(index) * playbackFrameDuration,
                    frameIndex: index,
                    transform: previewCamera.transform
                )
            )
        }

        previewCamera.transform = originalTransform
        guard keyframes.count > 1 else { return nil }
        if let firstKeyframe = keyframes.first {
            keyframes.append(
                CameraPlaybackKeyframe(
                    time: TimeInterval(keyframes.count) * playbackFrameDuration,
                    frameIndex: firstKeyframe.frameIndex,
                    transform: firstKeyframe.transform
                )
            )
        }

        let startTime = keyframes.first(where: { $0.frameIndex == startIndex })?.time ?? keyframes[0].time
        return CameraPlaybackComponent(
            keyframes: keyframes,
            elapsedTime: startTime,
            isPlaying: true
        )
    }

    @objc private func handlePreviewPan(_ recognizer: UIPanGestureRecognizer) {
        guard previewRootEntity != nil else { return }
        if recognizer.state == .began {
            stopPlayback(resetButton: true)
        }

        let translation = recognizer.translation(in: sceneContainerView)
        previewYaw += Float(translation.x) * 0.008
        previewPitch += Float(translation.y) * 0.008
        previewPitch = min(max(previewPitch, -.pi / 2), .pi / 2)
        recognizer.setTranslation(.zero, in: sceneContainerView)
        updatePreviewRootTransform()
    }

    @objc private func handlePreviewPinch(_ recognizer: UIPinchGestureRecognizer) {
        guard previewRootEntity != nil else { return }
        if recognizer.state == .began {
            stopPlayback(resetButton: true)
        }

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

extension CapturePreviewViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        frameSummaries.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CaptureFrameThumbnailCell.reuseIdentifier,
            for: indexPath
        )
        guard let thumbnailCell = cell as? CaptureFrameThumbnailCell else { return cell }
        thumbnailCell.configure(with: frameSummaries[indexPath.item].imageURL)
        return thumbnailCell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectFrame(at: indexPath.item, resetPlayback: true)
    }
}

private enum CameraPlaybackRuntime {
    private static var isRegistered = false

    static func registerIfNeeded() {
        guard !isRegistered else { return }
        CameraPlaybackComponent.registerComponent()
        CameraPlaybackSystem.registerSystem()
        isRegistered = true
    }
}

private struct CameraPlaybackKeyframe {
    let time: TimeInterval
    let frameIndex: Int
    let transform: Transform
}

private struct CameraPlaybackComponent: Component {
    var keyframes: [CameraPlaybackKeyframe]
    var elapsedTime: TimeInterval
    var isPlaying: Bool
}

private struct CameraPlaybackSystem: System {
    private static let query = EntityQuery(where: .has(CameraPlaybackComponent.self))

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard
                var component = entity.components[CameraPlaybackComponent.self],
                component.isPlaying,
                component.keyframes.count > 1,
                let lastTime = component.keyframes.last?.time,
                lastTime > 0
            else {
                continue
            }

            component.elapsedTime += context.deltaTime
            if component.elapsedTime > lastTime {
                component.elapsedTime = component.elapsedTime.truncatingRemainder(dividingBy: lastTime)
            }

            entity.transform = interpolatedTransform(
                at: component.elapsedTime,
                keyframes: component.keyframes
            )
            entity.components[CameraPlaybackComponent.self] = component
        }
    }

    private func interpolatedTransform(
        at time: TimeInterval,
        keyframes: [CameraPlaybackKeyframe]
    ) -> Transform {
        guard let first = keyframes.first else { return Transform() }
        guard let nextIndex = keyframes.firstIndex(where: { $0.time >= time }) else {
            return keyframes.last?.transform ?? first.transform
        }

        if nextIndex == 0 {
            return first.transform
        }

        let previous = keyframes[nextIndex - 1]
        let next = keyframes[nextIndex]
        let duration = max(next.time - previous.time, 0.0001)
        let t = Float(min(max((time - previous.time) / duration, 0), 1))
        return Transform(
            scale: mix(previous.transform.scale, next.transform.scale, t),
            rotation: simd_slerp(previous.transform.rotation, next.transform.rotation, t),
            translation: mix(previous.transform.translation, next.transform.translation, t)
        )
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a * (1 - t) + b * t
    }
}

private final class CaptureFrameThumbnailCell: UICollectionViewCell {
    static let reuseIdentifier = "CaptureFrameThumbnailCell"

    private let imageView = UIImageView()
    private var representedURL: URL?

    override var isSelected: Bool {
        didSet {
            contentView.layer.borderColor = (isSelected ? UIColor.systemGreen : UIColor.clear).cgColor
            contentView.layer.borderWidth = isSelected ? 3 : 0
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = 6
        contentView.layer.masksToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        imageView.sd_cancelCurrentImageLoad()
        imageView.image = nil
    }

    func configure(with imageURL: URL) {
        representedURL = imageURL
        let targetSize = CGSize(width: 144, height: 108)
        imageView.sd_setImage(
            with: imageURL,
            placeholderImage: nil,
            options: [.scaleDownLargeImages],
            context: [.imageThumbnailPixelSize: targetSize]
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
