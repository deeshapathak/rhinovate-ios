/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Contains view controller code for previewing live-captured content.
*/

import UIKit
import AVFoundation
import CoreVideo
import MobileCoreServices
import Accelerate
import Photos  // luozc

private enum SessionSetupResult: Sendable {
    case success
    case notAuthorized
    case configurationFailed
}

private struct ScanResponse: Sendable {
    let scanId: String
    let glbUrl: String
}

// lzchao
// luozc: called in func wrapEstimateImageData()
func convertLensDistortionLookupTable(lookupTable: Data) -> [Float] {
    let tableLength = lookupTable.count / MemoryLayout<Float>.size
    var floatArray: [Float] = Array(repeating: 0, count: tableLength)
    _ = floatArray.withUnsafeMutableBytes{lookupTable.copyBytes(to: $0)}
    return floatArray
}

// luozc: called in func wrapEstimateImageData()
@available(iOS 14.0, *)
func convertDepthData(depthMap: CVPixelBuffer) -> [[Float]] {
    let width = CVPixelBufferGetWidth(depthMap)
    let height = CVPixelBufferGetHeight(depthMap)
    var convertedDepthMap: [[Float]] = Array(
        repeating: Array(repeating: 0, count: width),
        count: height
    )
    CVPixelBufferLockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 2))
    let floatBuffer = unsafeBitCast(
        CVPixelBufferGetBaseAddress(depthMap),
        to: UnsafeMutablePointer<Float>.self
    )
    for row in 0 ..< height {
        for col in 0 ..< width {
            convertedDepthMap[row][col] = Float(floatBuffer[width * row + col])
        }
    }
    CVPixelBufferUnlockBaseAddress(depthMap, CVPixelBufferLockFlags(rawValue: 2))
    return convertedDepthMap
}

@available(iOS 14.0, *)
func wrapEstimateImageData(
    depthMap: CVPixelBuffer,
    calibration: AVCameraCalibrationData?
) -> Data {
    var jsonDict: [String : Any]
    if let cali = calibration {
        jsonDict = [
            "calibration_data" : [
                "intrinsic_matrix" : (0 ..< 3).map{ x in
                    (0 ..< 3).map{ y in cali.intrinsicMatrix[x][y]}
                },
                "pixel_size" : cali.pixelSize,
                "intrinsic_matrix_reference_dimensions" : [
                    cali.intrinsicMatrixReferenceDimensions.width,
                    cali.intrinsicMatrixReferenceDimensions.height
                ],
                "lens_distortion_center" : [
                    cali.lensDistortionCenter.x,
                    cali.lensDistortionCenter.y
                ],
                "lens_distortion_lookup_table" : convertLensDistortionLookupTable(
                    lookupTable: cali.lensDistortionLookupTable!
                ),
                "inverse_lens_distortion_lookup_table" : convertLensDistortionLookupTable(
                    lookupTable: cali.inverseLensDistortionLookupTable!
                )
            ],
            "depth_data" : convertDepthData(depthMap: depthMap)
        ]
    } else {
        jsonDict = [
            "depth_data" : convertDepthData(depthMap: depthMap)
        ]
    }
    
    let jsonStringData = try! JSONSerialization.data(
        withJSONObject: jsonDict,
        options: .prettyPrinted
    )
    
    return jsonStringData
}
//lzchao

@available(iOS 11.1, *)
class CameraViewController: UIViewController, AVCaptureDataOutputSynchronizerDelegate {
    
    // MARK: - Properties
    
    @IBOutlet weak private var resumeButton: UIButton!
    
    @IBOutlet weak private var cameraUnavailableLabel: UILabel!
    
    @IBOutlet weak private var jetView: PreviewMetalView!
    
    @IBOutlet weak private var depthSmoothingSwitch: UISwitch!
    
    @IBOutlet weak private var mixFactorSlider: UISlider!
    
    @IBOutlet weak private var touchDepth: UILabel!
    
    @IBOutlet weak var autoPanningSwitch: UISwitch!
    
    @IBOutlet weak var autoSavingSwitch: UISwitch!
    
    
    private enum UploadError: LocalizedError {
        case invalidResponse
        case serverError(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid server response."
            case .serverError(let message):
                return message
            }
        }
    }
    
    private enum CaptureError: LocalizedError {
        case noFrames
        case insufficientPoints
        case sparsePoints(Int)
        
        var errorDescription: String? {
            switch self {
            case .noFrames:
                return "No depth frames available. Try again."
            case .insufficientPoints:
                return "Scan too sparse. Move closer and hold still."
            case .sparsePoints(let count):
                return "Collected only \(count) points. Move closer and improve lighting."
            }
        }
    }
    
    private var setupResult: SessionSetupResult = .success
    
    private let session = AVCaptureSession()
    
    private var isSessionRunning = false
    
    // Communicate with the session and other session objects on this queue.
    private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], autoreleaseFrequency: .workItem)
    private var videoDeviceInput: AVCaptureDeviceInput!
    
    private let dataOutputQueue = DispatchQueue(label: "video data queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
    private let processingQueue = DispatchQueue(label: "photo processing queue", attributes: [], autoreleaseFrequency: .workItem)
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?
    
    private let latestFrameQueue = DispatchQueue(label: "latest frame queue", attributes: [], autoreleaseFrequency: .workItem)
    private var latestDepthData: AVDepthData?
    private var latestColorBuffer: CVPixelBuffer?
    
    private var captureButton: UIButton?
    private var guidanceContainer: UIView?
    private var guidanceTitleLabel: UILabel?
    private var guidanceDetailLabel: UILabel?
    private var guidanceProgress: UIProgressView?
    private var guidanceDistanceLabel: UILabel?
    private var guidanceQualityLabel: UILabel?
    private var scanStartTime: Date?
    private var scanDuration: TimeInterval = 5.0
    private var scanTimer: Timer?
    private var lastPointCount: Int = 0
    private var lastValidDepthCount: Int = 0
    private var lastDepthPixelCount: Int = 0
    private var depthLowStreak: Int = 0
    
    private var renderingEnabled = true
    
    private var savingEnabled = false  // luozc
    
    lazy var context = CIContext()  //luozc
    
    private var videoData: Data?  // luozc
    private let photoDepthConverter = DepthToUintConverter() // lzchao
    
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera],
                                                                               mediaType: .video,
                                                                               position: .front)
    
    
    
    private var touchDetected = false
    
    private var touchCoordinates = CGPoint(x: 0, y: 0)
    
    @IBOutlet weak private var cloudView: PointCloudMetalView!
    
    @IBOutlet weak private var cloudToJETSegCtrl: UISegmentedControl!
    
    @IBOutlet weak private var smoothDepthLabel: UILabel!
    
    private var lastScale = Float(1.0)
    
    private var lastScaleDiff = Float(0.0)
    
    private var lastZoom = Float(0.0)
    
    private var lastXY = CGPoint(x: 0, y: 0)
    
    private var JETEnabled = true
    
    private var viewFrameSize = CGSize()
    
    private var autoPanningIndex = Int(0) // start with auto-panning on
    
    // MARK: - View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        viewFrameSize = self.view.frame.size
        
        let tapGestureJET = UITapGestureRecognizer(target: self, action: #selector(focusAndExposeTap))
        jetView.addGestureRecognizer(tapGestureJET)
        
        let pressGestureJET = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressJET))
        pressGestureJET.minimumPressDuration = 0.05
        pressGestureJET.cancelsTouchesInView = false
        jetView.addGestureRecognizer(pressGestureJET)
        
        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        cloudView.addGestureRecognizer(pinchGesture)
        
        let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.numberOfTouchesRequired = 1
        cloudView.addGestureRecognizer(doubleTapGesture)
        
        let rotateGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate))
        cloudView.addGestureRecognizer(rotateGesture)
        
        let panOneFingerGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanOneFinger))
        panOneFingerGesture.maximumNumberOfTouches = 1
        panOneFingerGesture.minimumNumberOfTouches = 1
        cloudView.addGestureRecognizer(panOneFingerGesture)
        
        setupCaptureButton()
        setupGuidanceOverlay()
        
        JETEnabled = false
        cloudToJETSegCtrl.selectedSegmentIndex = 1
        cloudToJETSegCtrl.isHidden = true
        jetView.isHidden = true
        depthSmoothingSwitch.isHidden = true
        mixFactorSlider.isHidden = true
        touchDepth.isHidden = true
        smoothDepthLabel.isHidden = true
        autoSavingSwitch.isHidden = true
        autoPanningSwitch.isHidden = true
        autoPanningIndex = -1
        
        // Check video authorization status, video access is required
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera
            break
            
        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant video access
             We suspend the session queue to delay session setup until the access request has completed
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    DispatchQueue.main.async {
                    self.setupResult = .notAuthorized
                    }
                }
                self.sessionQueue.resume()
            })
            
        default:
            // The user has previously denied access
            setupResult = .notAuthorized
        }
        
        /*
         Setup the capture session.
         In general it is not safe to mutate an AVCaptureSession or any of its
         inputs, outputs, or connections from multiple threads at the same time.
         
         Why not do all of this on the main queue?
         Because AVCaptureSession.startRunning() is a blocking call which can
         take a long time. We dispatch session setup to the sessionQueue so
         that the main queue isn't blocked, which keeps the UI responsive.
         */
        sessionQueue.async {
            self.configureSession()
        }
    }

    private func setupCaptureButton() {
        if captureButton != nil {
            return
        }

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.filled()
            configuration.title = "Capture PLY"
            configuration.baseBackgroundColor = .systemBlue
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .medium
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            button.configuration = configuration
        } else {
            button.setTitle("Capture PLY", for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor.systemBlue
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        }
        button.addTarget(self, action: #selector(capturePLY), for: .touchUpInside)

        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.widthAnchor.constraint(equalToConstant: 200),
            button.heightAnchor.constraint(equalToConstant: 56)
        ])
        let centerYConstraint = NSLayoutConstraint(item: button,
                                                   attribute: .centerY,
                                                   relatedBy: .equal,
                                                   toItem: view,
                                                   attribute: .bottom,
                                                   multiplier: 0.75,
                                                   constant: 0)
        centerYConstraint.isActive = true

        captureButton = button
        view.bringSubviewToFront(button)
    }

    @objc private func capturePLY(_ sender: UIButton) {
        setCaptureButton(title: "Hold still...", isEnabled: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.performCapture()
        }
    }

    private func performCapture() {
        updateDepthQuality()
        let distanceOk = isDistanceAcceptable()
        let depthOk = isDepthQualityAcceptable()
        if depthLowStreak >= 10 {
            setCaptureButton(title: "Capture PLY", isEnabled: true)
            presentSimpleAlert(title: "Rhinovate", message: "TrueDepth not available. Close other camera apps and restart the phone.")
            return
        }
        if !distanceOk || !depthOk {
            setCaptureButton(title: "Capture PLY", isEnabled: true)
            presentSimpleAlert(title: "Rhinovate", message: "Move to 20–55 cm and improve lighting. Depth quality is too low.")
            return
        }

        setCaptureButton(title: "Scanning...", isEnabled: false)
        scanDuration = 7.0
        scanStartTime = Date()
        startGuidanceTimer()
        collectMultiFramePLY(duration: scanDuration,
                             interval: 0.15,
                             strideStep: 4,
                             maxPoints: 500_000) { result in
            DispatchQueue.main.async {
                self.stopGuidanceTimer()
            }
            switch result {
            case .success(let plyData):
                self.setCaptureButton(title: "Uploading...", isEnabled: false)
                self.uploadPLY(data: plyData) { uploadResult in
                    DispatchQueue.main.async {
                        switch uploadResult {
                        case .success(let scanId):
                            self.setCaptureButton(title: "Processing...", isEnabled: false)
                            self.pollScanStatus(scanId: scanId) { statusResult in
                                DispatchQueue.main.async {
                                    self.setCaptureButton(title: "Capture PLY", isEnabled: true)
                                    switch statusResult {
                                    case .success:
                                        self.presentSimpleAlert(title: "Scan Ready",
                                                                message: "Opening web app with scan.")
                                        self.openFrontend(scanId: scanId)
                                    case .failure(let error):
                                        self.presentSimpleAlert(title: "Scan Failed",
                                                                message: error.localizedDescription)
                                    }
                                }
                            }
                        case .failure(let error):
                            self.setCaptureButton(title: "Capture PLY", isEnabled: true)
                            let _ = self.savePLY(data: plyData)
                            self.presentSimpleAlert(title: "Upload Failed",
                                                    message: "Saved PLY locally. Error: \(error.localizedDescription)")
                        }
                    }
                }
            case .failure(let error):
                self.setCaptureButton(title: "Capture PLY", isEnabled: true)
                self.presentSimpleAlert(title: "Rhinovate", message: error.localizedDescription)
            }
        }
    }

    private func setCaptureButton(title: String, isEnabled: Bool) {
        DispatchQueue.main.async {
            if #available(iOS 15.0, *) {
                var configuration = self.captureButton?.configuration ?? UIButton.Configuration.filled()
                configuration.title = title
                self.captureButton?.configuration = configuration
            } else {
                self.captureButton?.setTitle(title, for: .normal)
            }
            self.captureButton?.isEnabled = isEnabled
        }
    }

    private func setupGuidanceOverlay() {
        if guidanceContainer != nil {
            return
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        container.layer.cornerRadius = 12

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        title.text = "Capture Guidance"

        let detail = UILabel()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        detail.textColor = .white
        detail.numberOfLines = 0
        detail.text = "Set the phone down, center your face, and tap Capture."

        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progress = 0.0
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.2)
        progress.tintColor = UIColor.systemGreen

        let distance = UILabel()
        distance.translatesAutoresizingMaskIntoConstraints = false
        distance.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        distance.textColor = UIColor.white.withAlphaComponent(0.85)
        distance.text = "Distance: --"

        let quality = UILabel()
        quality.translatesAutoresizingMaskIntoConstraints = false
        quality.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        quality.textColor = UIColor.white.withAlphaComponent(0.85)
        quality.text = "Quality: --"

        container.addSubview(title)
        container.addSubview(detail)
        container.addSubview(progress)
        container.addSubview(distance)
        container.addSubview(quality)

        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            progress.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 10),
            progress.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            progress.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            distance.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 8),
            distance.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            distance.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            quality.topAnchor.constraint(equalTo: distance.bottomAnchor, constant: 4),
            quality.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            quality.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            quality.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        guidanceContainer = container
        guidanceTitleLabel = title
        guidanceDetailLabel = detail
        guidanceProgress = progress
        guidanceDistanceLabel = distance
        guidanceQualityLabel = quality
    }

    private func startGuidanceTimer() {
        scanTimer?.invalidate()
        lastPointCount = 0
        guidanceProgress?.progress = 0.0
        guidanceTitleLabel?.text = "Scanning..."
        guidanceDetailLabel?.text = "Front → Left 30° → Front → Right 30° → Front"
        guidanceQualityLabel?.text = "Quality: collecting..."

        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateGuidanceDuringScan()
        }
    }

    private func stopGuidanceTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
        guidanceProgress?.progress = 0.0
        guidanceTitleLabel?.text = "Capture Guidance"
        guidanceDetailLabel?.text = "Set the phone down, center your face, and tap Capture."
        guidanceQualityLabel?.text = "Quality: --"
    }

    private func updateGuidanceDuringScan() {
        guard let scanStartTime else {
            return
        }
        let elapsed = Date().timeIntervalSince(scanStartTime)
        let progress = min(Float(elapsed / scanDuration), 1.0)
        guidanceProgress?.progress = progress

        let cue = scanCueText(elapsed: elapsed, total: scanDuration)
        guidanceDetailLabel?.text = cue

        let distance = estimateCenterDistanceMeters()
        if let distance {
            let cm = distance * 100.0
            guidanceDistanceLabel?.text = String(format: "Distance: %.0f cm (target 20–55 cm)", cm)
        } else {
            guidanceDistanceLabel?.text = "Distance: -- (target 20–55 cm)"
        }

        updateDepthQuality()
        let quality = qualityText(pointCount: lastPointCount, distance: distance)
        let depthRatio = lastDepthPixelCount > 0 ? (Float(lastValidDepthCount) / Float(lastDepthPixelCount)) : 0
        let depthPercent = Int(depthRatio * 100)
        guidanceQualityLabel?.text = "\(quality) • depth \(depthPercent)% • pts \(lastPointCount)"
    }

    private func scanCueText(elapsed: TimeInterval, total: TimeInterval) -> String {
        let segment = total / 5.0
        switch elapsed {
        case 0..<segment:
            return "Hold steady: face front"
        case segment..<(2 * segment):
            return "Slowly turn left ~30°"
        case (2 * segment)..<(3 * segment):
            return "Return to center"
        case (3 * segment)..<(4 * segment):
            return "Slowly turn right ~30°"
        default:
            return "Return to center and hold"
        }
    }

    private func estimateCenterDistanceMeters() -> Float? {
        var depthData: AVDepthData?
        latestFrameQueue.sync {
            depthData = latestDepthData
        }
        guard let depthData else {
            return nil
        }
        let depthMap = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        let buffer = baseAddress.assumingMemoryBound(to: Float.self)

        let cx = width / 2
        let cy = height / 2
        var samples: [Float] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let x = min(max(cx + dx, 0), width - 1)
                let y = min(max(cy + dy, 0), height - 1)
                let depth = buffer[y * width + x]
                if depth.isFinite && depth > 0 {
                    samples.append(depth)
                }
            }
        }
        guard !samples.isEmpty else {
            return nil
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func qualityText(pointCount: Int, distance: Float?) -> String {
        let enoughPoints = pointCount >= 20000
        let distanceOk: Bool
        if let distance {
            distanceOk = distance >= 0.20 && distance <= 0.55
        } else {
            distanceOk = false
        }

        let depthOk = isDepthQualityAcceptable()
        if enoughPoints && distanceOk && depthOk {
            return "Quality: good"
        }
        if depthLowStreak >= 10 {
            return "Quality: TrueDepth unavailable"
        }
        if !distanceOk {
            return "Quality: adjust distance"
        }
        if !depthOk {
            return "Quality: improve lighting"
        }
        return "Quality: collecting..."
    }

    private func updateDepthQuality() {
        var depthData: AVDepthData?
        latestFrameQueue.sync {
            depthData = latestDepthData
        }
        guard let depthData else {
            lastValidDepthCount = 0
            lastDepthPixelCount = 0
            return
        }
        let depthMap = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        lastDepthPixelCount = width * height
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            lastValidDepthCount = 0
            return
        }
        let buffer = baseAddress.assumingMemoryBound(to: Float.self)
        var validCount = 0
        for i in 0..<(width * height) {
            let depth = buffer[i]
            if depth.isFinite && depth > 0 {
                validCount += 1
            }
        }
        lastValidDepthCount = validCount
        let ratio = lastDepthPixelCount > 0 ? Float(validCount) / Float(lastDepthPixelCount) : 0
        if ratio < 0.01 {
            depthLowStreak += 1
        } else {
            depthLowStreak = 0
        }
    }

    private func isDepthQualityAcceptable() -> Bool {
        if lastDepthPixelCount == 0 {
            return false
        }
        let ratio = Float(lastValidDepthCount) / Float(lastDepthPixelCount)
        return ratio >= 0.05
    }

    private func isDistanceAcceptable() -> Bool {
        guard let distance = estimateCenterDistanceMeters() else {
            return false
        }
        return distance >= 0.20 && distance <= 0.55
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = view.window?.windowScene {
            if #available(iOS 26.0, *) {
                return scene.effectiveGeometry.interfaceOrientation
            }
            return legacyInterfaceOrientation(scene)
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            if #available(iOS 26.0, *) {
                return scene.effectiveGeometry.interfaceOrientation
            }
            return legacyInterfaceOrientation(scene)
        }
        return .portrait
    }

    @available(iOS, deprecated: 26.0)
    private func legacyInterfaceOrientation(_ scene: UIWindowScene) -> UIInterfaceOrientation {
        scene.interfaceOrientation
    }

    private func previewRotation(interfaceOrientation: UIInterfaceOrientation,
                                 cameraPosition: AVCaptureDevice.Position) -> PreviewMetalView.Rotation {
        switch interfaceOrientation {
        case .portrait:
            return .rotate0Degrees
        case .portraitUpsideDown:
            return .rotate180Degrees
        case .landscapeLeft:
            return cameraPosition == .front ? .rotate270Degrees : .rotate90Degrees
        case .landscapeRight:
            return cameraPosition == .front ? .rotate90Degrees : .rotate270Degrees
        default:
            return .rotate0Degrees
        }
    }

    private func readSetupResult() -> SessionSetupResult {
        if Thread.isMainThread {
            return setupResult
        }
        var result: SessionSetupResult = .success
        DispatchQueue.main.sync {
            result = self.setupResult
        }
        return result
    }

    private func setSetupResult(_ result: SessionSetupResult) {
        DispatchQueue.main.async {
            self.setupResult = result
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let interfaceOrientation = currentInterfaceOrientation()
        
        let initialThermalState = ProcessInfo.processInfo.thermalState
        if initialThermalState == .serious || initialThermalState == .critical {
            showThermalState(state: initialThermalState)
        }
        
        let currentSetupResult = setupResult
        sessionQueue.async {
            switch currentSetupResult {
            case .success:
                // Only setup observers and start the session running if setup succeeded
                self.addObservers()
                let videoDevicePosition = self.videoDeviceInput.device.position
                self.jetView.mirroring = (videoDevicePosition == .front)
                self.jetView.rotation = self.previewRotation(interfaceOrientation: interfaceOrientation,
                                                             cameraPosition: videoDevicePosition)
                self.dataOutputQueue.async {
                    self.renderingEnabled = true
                }
                
                self.session.startRunning()
                self.isSessionRunning = self.session.isRunning
                
            case .notAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Rhinovate doesn't have permission to use the camera, please change privacy settings",
                                                    comment: "Alert message when the user has denied access to the camera")
                    let alertController = UIAlertController(title: "Rhinovate", message: message, preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"),
                                                            style: .cancel,
                                                            handler: nil))
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                                                            style: .`default`,
                                                            handler: { _ in
                                                                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!,
                                                                                          options: [:],
                                                                                          completionHandler: nil)
                    }))
                    
                    self.present(alertController, animated: true, completion: nil)
                }
                
            case .configurationFailed:
                DispatchQueue.main.async {
                    self.cameraUnavailableLabel.isHidden = false
                    self.cameraUnavailableLabel.alpha = 0.0
                    UIView.animate(withDuration: 0.25) {
                        self.cameraUnavailableLabel.alpha = 1.0
                    }
                }
            }
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        dataOutputQueue.async {
            self.renderingEnabled = false
        }
        let currentSetupResult = readSetupResult()
        sessionQueue.async {
            if currentSetupResult == .success {
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            }
        }
        
        super.viewWillDisappear(animated)
    }
    
    @objc
    func didEnterBackground(notification: NSNotification) {
        // Free up resources
        dataOutputQueue.async {
            self.renderingEnabled = false
            //            if let videoFilter = self.videoFilter {
            //                videoFilter.reset()
            //            }
            self.jetView.pixelBuffer = nil
            self.jetView.flushTextureCache()
        }
        processingQueue.async {
            self.photoDepthConverter.reset()
        }
    }
    
    @objc
    func willEnterForground(notification: NSNotification) {
        dataOutputQueue.async {
            self.renderingEnabled = true
        }
    }
    
    // You can use this opportunity to take corrective action to help cool the system down.
    @objc
    func thermalStateChanged(notification: NSNotification) {
        if let processInfo = notification.object as? ProcessInfo {
            showThermalState(state: processInfo.thermalState)
        }
    }
    
    func showThermalState(state: ProcessInfo.ThermalState) {
        DispatchQueue.main.async {
            var thermalStateString = "UNKNOWN"
            if state == .nominal {
                thermalStateString = "NOMINAL"
            } else if state == .fair {
                thermalStateString = "FAIR"
            } else if state == .serious {
                thermalStateString = "SERIOUS"
            } else if state == .critical {
                thermalStateString = "CRITICAL"
            }
            
            let message = NSLocalizedString("Thermal state: \(thermalStateString)", comment: "Alert message when thermal state has changed")
            let alertController = UIAlertController(title: "TrueDepthStreamer", message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
    }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .all
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate(alongsideTransition: { _ in
                let interfaceOrientation = self.currentInterfaceOrientation()
                self.sessionQueue.async {
                    /*
                     The photo orientation is based on the interface orientation. You could also set the orientation of the photo connection based
                     on the device orientation by observing UIDeviceOrientationDidChangeNotification.
                     */
                    self.jetView.rotation = self.previewRotation(interfaceOrientation: interfaceOrientation,
                                                                 cameraPosition: self.videoDeviceInput.device.position)
                }
        }, completion: nil)
    }
    
    // MARK: - KVO and Notifications
    
    private var sessionRunningContext = 0
    
    private func addObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(thermalStateChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification,	object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError),
                                               name: AVCaptureSession.runtimeErrorNotification, object: session)
        
        /*
         A session can only run when the app is full screen. It will be interrupted
         in a multi-app layout, introduced in iOS 9, see also the documentation of
         AVCaptureSessionInterruptionReason. Add observers to handle these session
         interruptions and show a preview is paused message. See the documentation
         of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
         */
        NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted),
                                               name: AVCaptureSession.wasInterruptedNotification,
                                               object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded),
                                               name: AVCaptureSession.interruptionEndedNotification,
                                               object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange),
                                               name: AVCaptureDevice.subjectAreaDidChangeNotification,
                                               object: videoDeviceInput.device)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Session Management
    
    // Call this on the session queue
    private func configureSession() {
        let currentSetupResult = readSetupResult()
        if currentSetupResult != .success {
            return
        }
        
        let defaultVideoDevice: AVCaptureDevice? = videoDeviceDiscoverySession.devices.first
        
        guard let videoDevice = defaultVideoDevice else {
            print("Could not find any video device")
            setSetupResult(.configurationFailed)
            return
        }
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            setSetupResult(.configurationFailed)
            return
        }
        
        session.beginConfiguration()
        
//        session.sessionPreset = AVCaptureSession.Preset.vga640x480
        session.sessionPreset = AVCaptureSession.Preset.hd1920x1080
        
        // Add a video input
        guard session.canAddInput(videoDeviceInput) else {
            print("Could not add video device input to the session")
            setSetupResult(.configurationFailed)
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)
        
        // Add a video data output
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        } else {
            print("Could not add video data output to the session")
            setSetupResult(.configurationFailed)
            session.commitConfiguration()
            return
        }
        
        // Add a depth data output
        if session.canAddOutput(depthDataOutput) {
            session.addOutput(depthDataOutput)
            depthDataOutput.isFilteringEnabled = true
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                print("No AVCaptureConnection")
            }
        } else {
            print("Could not add depth data output to the session")
            setSetupResult(.configurationFailed)
            session.commitConfiguration()
            return
        }
        
        // Search for highest resolution with half-point depth values
        let depthFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let filtered = depthFormats.filter({
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        })
        let selectedFormat = filtered.max(by: {
            first, second in CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeDepthDataFormat = selectedFormat
            videoDevice.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
            setSetupResult(.configurationFailed)
            session.commitConfiguration()
            return
        }
        
        // Use an AVCaptureDataOutputSynchronizer to synchronize the video data and depth data outputs.
        // The first output in the dataOutputs array, in this case the AVCaptureVideoDataOutput, is the "master" output.
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
        outputSynchronizer!.setDelegate(self, queue: dataOutputQueue)
        session.commitConfiguration()
    }
    
    private func focus(with focusMode: AVCaptureDevice.FocusMode,
                       exposureMode: AVCaptureDevice.ExposureMode,
                       at devicePoint: CGPoint,
                       monitorSubjectAreaChange: Bool) {
        sessionQueue.async {
            let videoDevice = self.videoDeviceInput.device
            
            do {
                try videoDevice.lockForConfiguration()
                if videoDevice.isFocusPointOfInterestSupported && videoDevice.isFocusModeSupported(focusMode) {
                    videoDevice.focusPointOfInterest = devicePoint
                    videoDevice.focusMode = focusMode
                }
                
                if videoDevice.isExposurePointOfInterestSupported && videoDevice.isExposureModeSupported(exposureMode) {
                    videoDevice.exposurePointOfInterest = devicePoint
                    videoDevice.exposureMode = exposureMode
                }
                
                videoDevice.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                videoDevice.unlockForConfiguration()
            } catch {
                print("Could not lock device for configuration: \(error)")
            }
        }
    }
    
    @IBAction private func changeMixFactor(_ sender: UISlider) {
        _ = sender.value
    }
    
    @IBAction private func changeDepthSmoothing(_ sender: UISwitch) {
        let smoothingEnabled = sender.isOn
        
        sessionQueue.async {
            self.depthDataOutput.isFilteringEnabled = smoothingEnabled
        }
    }
    
    @IBAction func changeCloudToJET(_ sender: UISegmentedControl) {
        JETEnabled = true
    }
    
    @IBAction private func focusAndExposeTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: jetView)
        guard let texturePoint = jetView.texturePointForView(point: location) else {
            return
        }
        
        let textureRect = CGRect(origin: texturePoint, size: .zero)
        let deviceRect = videoDataOutput.metadataOutputRectConverted(fromOutputRect: textureRect)
        focus(with: .autoFocus, exposureMode: .autoExpose, at: deviceRect.origin, monitorSubjectAreaChange: true)
    }
    
    @objc
    func subjectAreaDidChange(notification: NSNotification) {
        let devicePoint = CGPoint(x: 0.5, y: 0.5)
        focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
    }
    
    @objc
    func sessionWasInterrupted(notification: NSNotification) {
        // In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
        if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
            let reasonIntegerValue = userInfoValue.integerValue,
            let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
            print("Capture session was interrupted with reason \(reason)")
            
            if reason == .videoDeviceInUseByAnotherClient {
                // Simply fade-in a button to enable the user to try to resume the session running.
                resumeButton.isHidden = false
                resumeButton.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.resumeButton.alpha = 1.0
                }
            } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
                // Simply fade-in a label to inform the user that the camera is unavailable.
                cameraUnavailableLabel.isHidden = false
                cameraUnavailableLabel.alpha = 0.0
                UIView.animate(withDuration: 0.25) {
                    self.cameraUnavailableLabel.alpha = 1.0
                }
            }
        }
    }
    
    @objc
    func sessionInterruptionEnded(notification: NSNotification) {
        if !resumeButton.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.resumeButton.alpha = 0
            }, completion: { _ in
                self.resumeButton.isHidden = true
            }
            )
        }
        if !cameraUnavailableLabel.isHidden {
            UIView.animate(withDuration: 0.25,
                           animations: {
                            self.cameraUnavailableLabel.alpha = 0
            }, completion: { _ in
                self.cameraUnavailableLabel.isHidden = true
            }
            )
        }
    }
    
    @objc
    func sessionRuntimeError(notification: NSNotification) {
        guard let errorValue = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError else {
            return
        }
        
        let error = AVError(_nsError: errorValue)
        print("Capture session runtime error: \(error)")
        
        /*
         Automatically try to restart the session running if media services were
         reset and the last start running succeeded. Otherwise, enable the user
         to try to resume the session running.
         */
        if error.code == .mediaServicesWereReset {
            sessionQueue.async {
                if self.isSessionRunning {
                    self.session.startRunning()
                    self.isSessionRunning = self.session.isRunning
                } else {
                    DispatchQueue.main.async {
                        self.resumeButton.isHidden = false
                    }
                }
            }
        } else {
            resumeButton.isHidden = false
        }
    }
    
    @IBAction private func resumeInterruptedSession(_ sender: UIButton) {
        sessionQueue.async {
            /*
             The session might fail to start running. A failure to start the session running will be communicated via
             a session runtime error notification. To avoid repeatedly failing to start the session
             running, we only try to restart the session running in the session runtime error handler
             if we aren't trying to resume the session running.
             */
            self.session.startRunning()
            self.isSessionRunning = self.session.isRunning
            if !self.session.isRunning {
                DispatchQueue.main.async {
                    let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
                    let alertController = UIAlertController(title: "TrueDepthStreamer", message: message, preferredStyle: .alert)
                    let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
                    alertController.addAction(cancelAction)
                    self.present(alertController, animated: true, completion: nil)
                }
            } else {
                DispatchQueue.main.async {
                    self.resumeButton.isHidden = true
                }
            }
        }
    }
    
    // MARK: - Point cloud view gestures
    
    @IBAction private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.numberOfTouches != 2 {
            return
        }
        if gesture.state == .began {
            lastScale = 1
        } else if gesture.state == .changed {
            let scale = Float(gesture.scale)
            let diff: Float = scale - lastScale
            let factor: Float = 1e3
            if scale < lastScale {
                lastZoom = diff * factor
            } else {
                lastZoom = diff * factor
            }
            DispatchQueue.main.async {
                self.autoPanningSwitch.isOn = false
                self.autoPanningIndex = -1
            }
            cloudView.moveTowardCenter(lastZoom)
            lastScale = scale
        } else if gesture.state == .ended {
        } else {
        }
    }
    
    @IBAction private func handlePanOneFinger(gesture: UIPanGestureRecognizer) {
        if gesture.numberOfTouches != 1 {
            return
        }
        
        if gesture.state == .began {
            let pnt: CGPoint = gesture.translation(in: cloudView)
            lastXY = pnt
        } else if (.failed != gesture.state) && (.cancelled != gesture.state) {
            let pnt: CGPoint = gesture.translation(in: cloudView)
            DispatchQueue.main.async {
                self.autoPanningSwitch.isOn = false
                self.autoPanningIndex = -1
            }
            cloudView.yawAroundCenter(Float((pnt.x - lastXY.x) * 0.1))
            cloudView.pitchAroundCenter(Float((pnt.y - lastXY.y) * 0.1))
            lastXY = pnt
        }
    }
    
    @IBAction private func handleDoubleTap(gesture: UITapGestureRecognizer) {
        DispatchQueue.main.async {
            self.autoPanningSwitch.isOn = false
            self.autoPanningIndex = -1
        }
        cloudView.resetView()
    }
    
    @IBAction private func handleRotate(gesture: UIRotationGestureRecognizer) {
        if gesture.numberOfTouches != 2 {
            return
        }
        
        if gesture.state == .changed {
            let rot = Float(gesture.rotation)
            DispatchQueue.main.async {
                self.autoPanningSwitch.isOn = false
                self.autoPanningIndex = -1
            }
            cloudView.rollAroundCenter(rot * 60)
            gesture.rotation = 0
        }
    }
    
    // MARK: - JET view Depth label gesture
    
    @IBAction private func handleLongPressJET(gesture: UILongPressGestureRecognizer) {
        
        switch gesture.state {
        case .began:
            touchDetected = true
            let pnt: CGPoint = gesture.location(in: self.jetView)
            touchCoordinates = pnt
        case .changed:
            let pnt: CGPoint = gesture.location(in: self.jetView)
            touchCoordinates = pnt
        case .possible, .ended, .cancelled, .failed:
            touchDetected = false
            DispatchQueue.main.async {
                self.touchDepth.text = ""
            }
        @unknown default:
            print("Unknow gesture state.")
            touchDetected = false
        }
    }
    
    @IBAction func didAutoPanningChange(_ sender: Any) {
        if autoPanningSwitch.isOn {
            self.autoPanningIndex = 0
        } else {
            self.autoPanningIndex = -1
        }
    }
    
    // MARK: - Video + Depth Frame Processing
// luozc
    @IBAction func didAutoSavingChange(_ sender: Any) {
        let savingEnabled = autoSavingSwitch.isOn ? true : false
        processingQueue.async {
            self.savingEnabled = savingEnabled
        }
    }
    
    @available(iOS 14.0, *)
    func saveAllBufferInFrame(video videoPixelBuffer: CVPixelBuffer,
                              depth depthPixelBuffer: CVPixelBuffer) {
        let videoImage = CIImage(cvPixelBuffer: videoPixelBuffer)
        
        guard let perceptualColorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            videoData = nil
            return
        }
        videoData = context.pngRepresentation(of: videoImage, format: .BGRA8, colorSpace: perceptualColorSpace)
        
        if !self.photoDepthConverter.isPrepared {
            var depthFormatDescription: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: depthPixelBuffer,
                                                         formatDescriptionOut: &depthFormatDescription)
            
            /*
             outputRetainedBufferCountHint is the number of pixel buffers we expect to hold on to from the renderer.
             This value informs the renderer how to size its buffer pool and how many pixel buffers to preallocate.
             Allow 3 frames of latency to cover the dispatch_async call.
             */
            if let unwrappedDepthFormatDescription = depthFormatDescription {
                self.photoDepthConverter.prepare(with: unwrappedDepthFormatDescription, outputRetainedBufferCountHint: 3)
            }
        }
        
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges({
                    // Save Video Frame to Photos Library only if it was generated
                    if let videoData = self.videoData {
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        creationRequest.addResource(with: .photo,
                                                    data: videoData,
                                                    options: nil)
                    }
// lzchao
                    // TODO: lzchao save depth json to file manager
                    guard let convertedDepthPixelBuffer = self.photoDepthConverter.render(pixelBuffer: depthPixelBuffer) else {
                        print("Unable to convert depth pixel buffer")
                        return
                    }
                    
                    let wrappedDepthJson = wrapEstimateImageData(depthMap: convertedDepthPixelBuffer, calibration: nil)

                    if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "yy-MM-dd_HH-mm-ss"
                        formatter.locale = Locale.init(identifier: "en_US_POSIX")
                        let timeInterval = Date().timeIntervalSince1970
                        let msecond = CLongLong(round(timeInterval * 1000))
                        let FileName =  String(format: "/%@_\(msecond).json", formatter.string(from: Date()))

                        let pathWithFileName = documentDirectory.appendingPathComponent(String(FileName))
                        do {
                            try wrappedDepthJson.write(to: pathWithFileName)
                        } catch {
                            print("Could not write \(FileName) at dir: \(documentDirectory)")
                        }
                    }
// lzchao
                }, completionHandler: { _, error in
                    if let error = error {
                        print("Error occurred while saving photo to photo library: \(error)")
                    }
                }
                )
            } else {
                print("Without authorized")
            }
        }
    }
// luozc
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        
        if !renderingEnabled {
            return
        }
        
        // Read all outputs
        guard renderingEnabled,
            let syncedDepthData: AVCaptureSynchronizedDepthData =
            synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
            let syncedVideoData: AVCaptureSynchronizedSampleBufferData =
            synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else {
                // only work on synced pairs
                return
        }
        
        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            return
        }
        
        let depthData = syncedDepthData.depthData
        // TODO: choose 16bit or 32bit
        let depthPixelBuffer = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        let sampleBuffer = syncedVideoData.sampleBuffer
        guard let videoPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
        }
        
        latestFrameQueue.sync {
            latestDepthData = depthData
            latestColorBuffer = videoPixelBuffer
        }
        
// luozc
        if savingEnabled {
            processingQueue.async {
                self.saveAllBufferInFrame(video: videoPixelBuffer, depth: depthPixelBuffer)
            }
        }
// luozc
        
        if JETEnabled {
            jetView.pixelBuffer = videoPixelBuffer
        } else {
            // point cloud
            if self.autoPanningIndex >= 0 {
                
                // perform a circle movement
                let moves = 200
                
                let factor = 2.0 * .pi / Double(moves)
                
                let pitch = sin(Double(self.autoPanningIndex) * factor) * 2
                let yaw = cos(Double(self.autoPanningIndex) * factor) * 2
                self.autoPanningIndex = (self.autoPanningIndex + 1) % moves
                
                cloudView?.resetView()
                cloudView?.pitchAroundCenter(Float(pitch) * 10)
                cloudView?.yawAroundCenter(Float(yaw) * 10)
            }
            
            cloudView?.setDepthFrame(depthData, withTexture: videoPixelBuffer)
        }
    }
    
//    func updateDepthLabel(depthFrame: CVPixelBuffer, videoFrame: CVPixelBuffer) {
//
//        if touchDetected {
//            guard let texturePoint = jetView.texturePointForView(point: self.touchCoordinates) else {
//                DispatchQueue.main.async {
//                    self.touchDepth.text = ""
//                }
//                return
//            }
//
//            // scale
//            let scale = CGFloat(CVPixelBufferGetWidth(depthFrame)) / CGFloat(CVPixelBufferGetWidth(videoFrame))
//            let depthPoint = CGPoint(x: CGFloat(CVPixelBufferGetWidth(depthFrame)) - 1.0 - texturePoint.x * scale, y: texturePoint.y * scale)
//
//            assert(kCVPixelFormatType_DepthFloat16 == CVPixelBufferGetPixelFormatType(depthFrame))
//            CVPixelBufferLockBaseAddress(depthFrame, .readOnly)
//            let rowData = CVPixelBufferGetBaseAddress(depthFrame)! + Int(depthPoint.y) * CVPixelBufferGetBytesPerRow(depthFrame)
//            // swift does not have an Float16 data type. Use UInt16 instead, and then translate
//            var f16Pixel = rowData.assumingMemoryBound(to: Float16.self)[Int(depthPoint.x)]
//            var f32Pixel = Float(0.0)
//
//            CVPixelBufferUnlockBaseAddress(depthFrame, .readOnly)
//
//            withUnsafeMutablePointer(to: &f16Pixel) { f16RawPointer in
//                withUnsafeMutablePointer(to: &f32Pixel) { f32RawPointer in
//                    var src = vImage_Buffer(data: f16RawPointer, height: 1, width: 1, rowBytes: 2)
//                    var dst = vImage_Buffer(data: f32RawPointer, height: 1, width: 1, rowBytes: 4)
//                    vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
//                }
//            }
//
//            // Convert the depth frame format to cm
//            let depthString = String(format: "%.2f cm", f32Pixel * 100)
//
//            // Update the label
//            DispatchQueue.main.async {
//                self.touchDepth.textColor = UIColor.white
//                self.touchDepth.text = depthString
//                self.touchDepth.sizeToFit()
//            }
//        } else {
//            DispatchQueue.main.async {
//                self.touchDepth.text = ""
//            }
//        }
//    }
    
    // MARK: - PLY Export + Upload
    private func buildPLY(depthData: AVDepthData,
                          colorBuffer: CVPixelBuffer,
                          strideStep: Int) -> Data? {
        guard let calibration = depthData.cameraCalibrationData else {
            return nil
        }

        let depthMap = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let colorWidth = CVPixelBufferGetWidth(colorBuffer)
        let colorHeight = CVPixelBufferGetHeight(colorBuffer)

        var intrinsics = calibration.intrinsicMatrix
        let refSize = calibration.intrinsicMatrixReferenceDimensions
        let scaleX = Float(refSize.width) / Float(depthWidth)
        let scaleY = Float(refSize.height) / Float(depthHeight)
        intrinsics.columns.0.x /= scaleX
        intrinsics.columns.1.y /= scaleY
        intrinsics.columns.2.x /= scaleX
        intrinsics.columns.2.y /= scaleY

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(colorBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(colorBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap),
              let colorBaseAddress = CVPixelBufferGetBaseAddress(colorBuffer) else {
            return nil
        }

        let depthBuffer = depthBaseAddress.assumingMemoryBound(to: Float.self)
        let colorBytesPerRow = CVPixelBufferGetBytesPerRow(colorBuffer)
        let colorBufferPtr = colorBaseAddress.assumingMemoryBound(to: UInt8.self)

        var vertices: [String] = []
        vertices.reserveCapacity((depthWidth / strideStep) * (depthHeight / strideStep))

        let colorScaleX = Float(colorWidth) / Float(depthWidth)
        let colorScaleY = Float(colorHeight) / Float(depthHeight)

        for y in Swift.stride(from: 0, to: depthHeight, by: strideStep) {
            for x in Swift.stride(from: 0, to: depthWidth, by: strideStep) {
                let depth = depthBuffer[y * depthWidth + x]
                if !depth.isFinite || depth <= 0 {
                    continue
                }

                let xf = (Float(x) - cx) / fx * depth
                let yf = (Float(y) - cy) / fy * depth
                let zf = depth

                let colorX = min(max(Int(Float(x) * colorScaleX), 0), colorWidth - 1)
                let colorY = min(max(Int(Float(y) * colorScaleY), 0), colorHeight - 1)
                let colorOffset = colorY * colorBytesPerRow + colorX * 4

                let b = colorBufferPtr[colorOffset]
                let g = colorBufferPtr[colorOffset + 1]
                let r = colorBufferPtr[colorOffset + 2]

                vertices.append("\(xf) \(yf) \(zf) \(r) \(g) \(b)")
            }
        }

        if vertices.count < 1000 {
            return nil
        }

        var header = "ply\n"
        header += "format ascii 1.0\n"
        header += "element vertex \(vertices.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property uchar red\n"
        header += "property uchar green\n"
        header += "property uchar blue\n"
        header += "end_header\n"

        let body = vertices.joined(separator: "\n")
        let output = header + body + "\n"
        return output.data(using: .utf8)
    }

    private func collectMultiFramePLY(duration: TimeInterval,
                                      interval: TimeInterval,
                                      strideStep: Int,
                                      maxPoints: Int,
                                      completion: @escaping (Result<Data, Error>) -> Void) {
        processingQueue.async {
            var points: [String] = []
            let endTime = Date().addingTimeInterval(duration)
            var sawFrame = false

            func finalize() {
                guard sawFrame else {
                    completion(.failure(CaptureError.noFrames))
                    return
                }
                guard points.count >= 1000 else {
                    completion(.failure(CaptureError.sparsePoints(points.count)))
                    return
                }
                if let data = self.buildPLYData(from: points) {
                    completion(.success(data))
                } else {
                    completion(.failure(CaptureError.insufficientPoints))
                }
            }

            func sampleNext() {
                if Date() >= endTime || points.count >= maxPoints {
                    finalize()
                    return
                }

                var appended = false
                if self.appendPLYPointsFromLatest(strideStep: strideStep,
                                                  into: &points,
                                                  maxPoints: maxPoints) {
                    appended = true
                    sawFrame = true
                    self.lastPointCount = points.count
                }

                let delay = appended ? interval : interval * 0.5
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self.processingQueue.async {
                        sampleNext()
                    }
                }
            }

            sampleNext()
        }
    }

    private func buildPLYData(from points: [String]) -> Data? {
        var header = "ply\n"
        header += "format ascii 1.0\n"
        header += "element vertex \(points.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property uchar red\n"
        header += "property uchar green\n"
        header += "property uchar blue\n"
        header += "end_header\n"

        let body = points.joined(separator: "\n")
        let output = header + body + "\n"
        return output.data(using: .utf8)
    }

    private func appendPLYPointsFromLatest(strideStep: Int,
                                           into points: inout [String],
                                           maxPoints: Int) -> Bool {
        var depthData: AVDepthData?
        var colorBuffer: CVPixelBuffer?
        latestFrameQueue.sync {
            depthData = latestDepthData
            colorBuffer = latestColorBuffer
        }
        guard let depthData, let colorBuffer else {
            return false
        }
        return appendPLYPoints(depthData: depthData,
                               colorBuffer: colorBuffer,
                               strideStep: strideStep,
                               into: &points,
                               maxPoints: maxPoints)
    }

    private func appendPLYPoints(depthData: AVDepthData,
                                 colorBuffer: CVPixelBuffer,
                                 strideStep: Int,
                                 into points: inout [String],
                                 maxPoints: Int) -> Bool {
        guard let calibration = depthData.cameraCalibrationData else {
            return false
        }

        let depthMap = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let colorWidth = CVPixelBufferGetWidth(colorBuffer)
        let colorHeight = CVPixelBufferGetHeight(colorBuffer)

        var intrinsics = calibration.intrinsicMatrix
        let refSize = calibration.intrinsicMatrixReferenceDimensions
        let scaleX = Float(refSize.width) / Float(depthWidth)
        let scaleY = Float(refSize.height) / Float(depthHeight)
        intrinsics.columns.0.x /= scaleX
        intrinsics.columns.1.y /= scaleY
        intrinsics.columns.2.x /= scaleX
        intrinsics.columns.2.y /= scaleY

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(colorBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(colorBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap),
              let colorBaseAddress = CVPixelBufferGetBaseAddress(colorBuffer) else {
            return false
        }

        let depthBuffer = depthBaseAddress.assumingMemoryBound(to: Float.self)
        let colorBytesPerRow = CVPixelBufferGetBytesPerRow(colorBuffer)
        let colorBufferPtr = colorBaseAddress.assumingMemoryBound(to: UInt8.self)

        let colorScaleX = Float(colorWidth) / Float(depthWidth)
        let colorScaleY = Float(colorHeight) / Float(depthHeight)

        for y in Swift.stride(from: 0, to: depthHeight, by: strideStep) {
            for x in Swift.stride(from: 0, to: depthWidth, by: strideStep) {
                if points.count >= maxPoints {
                    return true
                }
                let depth = depthBuffer[y * depthWidth + x]
                if !depth.isFinite || depth <= 0 {
                    continue
                }

                let xf = (Float(x) - cx) / fx * depth
                let yf = (Float(y) - cy) / fy * depth
                let zf = depth

                let colorX = min(max(Int(Float(x) * colorScaleX), 0), colorWidth - 1)
                let colorY = min(max(Int(Float(y) * colorScaleY), 0), colorHeight - 1)
                let colorOffset = colorY * colorBytesPerRow + colorX * 4

                let b = colorBufferPtr[colorOffset]
                let g = colorBufferPtr[colorOffset + 1]
                let r = colorBufferPtr[colorOffset + 2]

                points.append("\(xf) \(yf) \(zf) \(r) \(g) \(b)")
            }
        }
        return true
    }

    private func pollScanStatus(scanId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "https://backend-for-rhinovate-ios-app-ply-to-glb.onrender.com/api/scans/\(scanId)/status") else {
            completion(.failure(UploadError.invalidResponse))
            return
        }

        let deadline = Date().addingTimeInterval(180)

        func checkStatus() {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data,
                      let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    completion(.failure(UploadError.invalidResponse))
                    return
                }

                let payload = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
                let status = ((payload?["state"] as? String) ?? (payload?["status"] as? String))?.lowercased() ?? "unknown"
                if let stage = payload?["stage"] as? String, status == "processing" {
                    self.setCaptureButton(title: "Processing: \(stage.capitalized)", isEnabled: false)
                }

                if status == "ready" {
                    completion(.success(()))
                    return
                }

                if status == "failed" {
                    let detail = (payload?["detail"] as? String)
                        ?? (payload?["message"] as? String)
                        ?? "Backend processing failed."
                    completion(.failure(UploadError.serverError(detail)))
                    return
                }

                if Date() > deadline {
                    completion(.failure(UploadError.serverError("Processing timed out. Try again.")))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                    checkStatus()
                }
            }
            task.resume()
        }

        checkStatus()
    }

    private func uploadPLY(data: Data, completion: @escaping (Result<String, Error>) -> Void) {
        var components = URLComponents(string: "https://backend-for-rhinovate-ios-app-ply-to-glb.onrender.com/api/scans")
        components?.queryItems = [
            URLQueryItem(name: "unit_scale", value: "1.0"),
            URLQueryItem(name: "units", value: "meters")
        ]
        guard let url = components?.url else {
            completion(.failure(UploadError.invalidResponse))
            return
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"ply\"; filename=\"scan.ply\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let timeoutItem = DispatchWorkItem {
            completion(.failure(UploadError.serverError("Upload timed out. Try Wi‑Fi or reduce scan size.")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeoutItem)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 300
        let session = URLSession(configuration: sessionConfig)

        let task = session.uploadTask(with: request, from: body) { responseData, response, error in
            timeoutItem.cancel()
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let responseData = responseData else {
                completion(.failure(UploadError.invalidResponse))
                return
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let message = String(data: responseData, encoding: .utf8) ?? "Server error."
                completion(.failure(UploadError.serverError(message)))
                return
            }

            do {
                let payload = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any]
                if let scanId = payload?["scanId"] as? String {
                    completion(.success(scanId))
                } else {
                    completion(.failure(UploadError.invalidResponse))
                }
            } catch {
                completion(.failure(error))
            }
        }

        task.resume()
    }

    private func savePLY(data: Data) -> URL? {
        let filename = "rhinovate-\(UUID().uuidString).ply"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func openFrontend(scanId: String) {
        guard let url = URL(string: "https://productfrontend-7hf.pages.dev/?scanId=\(scanId)") else {
            presentSimpleAlert(title: "Rhinovate", message: "Scan uploaded. ID: \(scanId)")
            return
        }

        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                self.presentSimpleAlert(title: "Rhinovate", message: "Scan uploaded. ID: \(scanId)")
            }
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
}

