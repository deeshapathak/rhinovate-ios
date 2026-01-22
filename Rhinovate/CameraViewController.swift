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
import Vision

private enum SessionSetupResult: Sendable {
    case success
    case notAuthorized
    case configurationFailed
}

private struct ScanResponse: Sendable {
    let scanId: String
    let glbUrl: String
}

private struct FaceAnalysis {
    let landmarks: [CGPoint]
    let yawDegrees: Float?
    let pitchDegrees: Float?
    let rollDegrees: Float?
    let mouthOpenRatio: Float?
    let interocular: Float?
    let centroid: CGPoint?
}

private struct FrameCandidate {
    let points: [String]
    let pointCount: Int
    let depthValidRatio: Float
    let landmarks: [CGPoint]
    let yawDegrees: Float?
    let rollDegrees: Float?
    let mouthOpenRatio: Float?
    let interocular: Float?
    let landmarkRMS: Float?
    let deltaPose: Float?
    let deltaLandmarks: Float?
    let deltaCentroid: Float?
}

private enum CapturePose: Int, CaseIterable {
    case front = 0
    case left = 1
    case right = 2
    case down = 3
    case up = 4
    
    var name: String {
        switch self {
        case .front: return "Front"
        case .left: return "Left Profile"
        case .right: return "Right Profile"
        case .down: return "Looking Down"
        case .up: return "Looking Up"
        }
    }
    
    var instruction: String {
        switch self {
        case .front: return "Face forward, look straight ahead"
        case .left: return "Turn your head slowly to the left ~90°"
        case .right: return "Turn your head slowly to the right ~90°"
        case .down: return "Look down ~30°, keep head straight"
        case .up: return "Look up ~30°, keep head straight"
        }
    }
    
    var targetYaw: ClosedRange<Float> {
        switch self {
        case .front: return -10...10  // More lenient for front pose
        case .left: return -110...(-70)  // Wider range for side profiles
        case .right: return 70...110
        case .down: return -15...15  // Allow slight head movement
        case .up: return -15...15
        }
    }
    
    var targetPitch: ClosedRange<Float> {
        switch self {
        case .front: return -10...10  // More lenient
        case .left: return -15...15  // Side profiles can look slightly up/down
        case .right: return -15...15
        case .down: return -45...(-15)  // Wider range for looking down
        case .up: return 15...45  // Wider range for looking up
        }
    }
    
    var targetRoll: ClosedRange<Float> {
        switch self {
        case .front: return -20...20  // More lenient for natural head tilt
        case .left: return -25...25  // Side profiles can have more tilt
        case .right: return -25...25
        case .down: return -20...20
        case .up: return -20...20
        }
    }
}

private struct CapturedFrame {
    let pose: CapturePose
    let rgbImageJPEG: Data  // Store as JPEG data instead of pixel buffer
    let depthData: AVDepthData
    let timestamp: Date
    let yaw: Float?
    let pitch: Float?
    let roll: Float?
    let landmarks: [CGPoint]
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
    private var directionLabel: UILabel?
    private var faceFrameView: UIView?
    private var faceFrameLabel: UILabel?
    private var hapticGenerator: UIImpactFeedbackGenerator?
    private var depthHealthTimer: Timer?
    private var lastDepthFrameAt: Date?
    private var depthHealthStartAt: Date?
    private var hasSeenDepthFrame = false
    private var scanStartTime: Date?
    private var scanDuration: TimeInterval = 5.0
    private var scanTimer: Timer?
    private var lastPointCount: Int = 0
    private var lastValidDepthCount: Int = 0
    private var lastDepthPixelCount: Int = 0
    private var depthLowStreak: Int = 0
    
    // Frame capture for Gemini
    private var capturedFrames: [CapturedFrame] = []
    
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
        hapticGenerator = UIImpactFeedbackGenerator(style: .light)
        
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
            self.performCaptureWithFrames()
        }
    }
    
    private func performCaptureWithFrames() {
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
        scanDuration = 20.0  // Scan for front, left, right poses only
        scanStartTime = Date()
        startGuidanceTimer()
        
        // Collect frames with RGB images for Gemini
        collectMultiFramePLYWithImages(duration: scanDuration,
                                       interval: 0.4,  // Less frequent to reduce load
                                       strideStep: 4,
                                       maxPoints: 500_000) { result in
            DispatchQueue.main.async {
                // Show completion animation
                self.showScanCompleteAnimation()
                
                // Update UI based on result
                switch result {
                case .success:
                    self.guidanceTitleLabel?.text = "✨ Uploading..."
                    self.guidanceDetailLabel?.text = "Sending scan to server"
                case .failure(let error):
                    self.guidanceTitleLabel?.text = "❌ Scan Failed"
                    self.guidanceDetailLabel?.text = error.localizedDescription
                }
            }
            switch result {
            case .success(let (plyData, frames)):
                self.setCaptureButton(title: "Uploading...", isEnabled: false)
                self.uploadPLYWithFrames(data: plyData, frames: frames) { uploadResult in
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
        scanDuration = 25.0
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

        // Modern gradient background
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = UIColor.clear
        
        // Gradient layer for trendy look
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = [
            UIColor(red: 0.1, green: 0.1, blue: 0.15, alpha: 0.85).cgColor,
            UIColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 0.9).cgColor
        ]
        gradientLayer.cornerRadius = 20
        gradientLayer.masksToBounds = true
        container.layer.insertSublayer(gradientLayer, at: 0)
        
        // Blur effect for depth
        let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.layer.cornerRadius = 20
        blurView.clipsToBounds = true
        container.addSubview(blurView)
        
        // Update gradient frame when view lays out
        DispatchQueue.main.async {
            gradientLayer.frame = container.bounds
        }

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        title.textColor = .white
        title.text = "✨ 3D Face Scan"
        title.textAlignment = .center

        let detail = UILabel()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        detail.textColor = UIColor.white.withAlphaComponent(0.95)
        detail.numberOfLines = 0
        detail.text = "Center your face and tap to start"
        detail.textAlignment = .center

        // Modern progress bar with rounded corners
        let progress = UIProgressView(progressViewStyle: .default)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progress = 0.0
        progress.trackTintColor = UIColor.white.withAlphaComponent(0.15)
        // Gradient progress bar color
        progress.progressTintColor = UIColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
        progress.layer.cornerRadius = 4
        progress.clipsToBounds = true
        progress.transform = CGAffineTransform(scaleX: 1.0, y: 2.5)

        let distance = UILabel()
        distance.translatesAutoresizingMaskIntoConstraints = false
        distance.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        distance.textColor = UIColor.white.withAlphaComponent(0.9)
        distance.text = "📏 Distance: --"
        distance.textAlignment = .center

        let quality = UILabel()
        quality.translatesAutoresizingMaskIntoConstraints = false
        quality.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        quality.textColor = UIColor.white.withAlphaComponent(0.9)
        quality.text = "✨ Quality: --"
        quality.textAlignment = .center

        container.addSubview(blurView)
        container.addSubview(title)
        container.addSubview(detail)
        container.addSubview(progress)
        container.addSubview(distance)
        container.addSubview(quality)

        view.addSubview(container)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: container.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),

            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            progress.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14),
            progress.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            progress.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            distance.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            distance.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            distance.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            quality.topAnchor.constraint(equalTo: distance.bottomAnchor, constant: 6),
            quality.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            quality.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            quality.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        
        // Store gradient layer reference for frame updates
        container.layer.setValue(gradientLayer, forKey: "gradientLayer")

        guidanceContainer = container
        guidanceTitleLabel = title
        guidanceDetailLabel = detail
        guidanceProgress = progress
        guidanceDistanceLabel = distance
        guidanceQualityLabel = quality

        setupFaceFrameOverlay()
        setupDirectionLabel()
    }

    private func setupFaceFrameOverlay() {
        if faceFrameView != nil {
            return
        }

        let frameView = UIView()
        frameView.translatesAutoresizingMaskIntoConstraints = false
        frameView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        frameView.layer.borderWidth = 2.0
        frameView.layer.cornerRadius = 24
        frameView.backgroundColor = UIColor.clear

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Keep face inside frame (avoid shoulders)"
        label.textColor = UIColor.white.withAlphaComponent(0.85)
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center

        view.addSubview(frameView)
        view.addSubview(label)

        NSLayoutConstraint.activate([
            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            frameView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.62),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: 1.25),

            label.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            label.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 6),
        ])

        faceFrameView = frameView
        faceFrameLabel = label
    }

    private func setupDirectionLabel() {
        if directionLabel != nil {
            return
        }

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Align face in frame"
        label.textColor = UIColor.white
        label.font = UIFont.systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center

        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 140),
        ])

        directionLabel = label
    }


    private func startGuidanceTimer() {
        scanTimer?.invalidate()
        lastPointCount = 0
        guidanceProgress?.progress = 0.0
        
        // Smooth animation for progress bar
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            self.guidanceProgress?.alpha = 1.0
        }
        
        guidanceTitleLabel?.text = "✨ Scanning..."
        guidanceDetailLabel?.text = "Slowly turn your head: left → right → up → down"
        guidanceQualityLabel?.text = "✨ Quality: collecting..."
        directionLabel?.text = "🔄 Move your head naturally"

        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateGuidanceDuringScan()
        }
    }

    private func stopGuidanceTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
        guidanceProgress?.progress = 1.0
        
        // Animate progress completion
        UIView.animate(withDuration: 0.3) {
            self.guidanceProgress?.alpha = 0.7
        }
        
        guidanceTitleLabel?.text = "✨ 3D Face Scan"
        guidanceDetailLabel?.text = "Center your face and tap to start"
        guidanceQualityLabel?.text = "✨ Quality: --"
        directionLabel?.text = "👤 Align face in frame"
    }
    
    private func showScanCompleteAnimation() {
        // Celebration animation when scan completes
        let checkmark = UILabel()
        checkmark.text = "✓"
        checkmark.font = UIFont.systemFont(ofSize: 60, weight: .bold)
        checkmark.textColor = UIColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1.0)
        checkmark.textAlignment = .center
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        checkmark.alpha = 0
        checkmark.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
        
        view.addSubview(checkmark)
        NSLayoutConstraint.activate([
            checkmark.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            checkmark.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.8, options: .curveEaseOut) {
            checkmark.alpha = 1.0
            checkmark.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.5) {
                checkmark.alpha = 0
                checkmark.transform = CGAffineTransform(scaleX: 1.5, y: 1.5)
            } completion: { _ in
                checkmark.removeFromSuperview()
            }
        }
    }

    private func updateGuidanceDuringScan() {
        guard let scanStartTime else {
            return
        }
        let elapsed = Date().timeIntervalSince(scanStartTime)
        
        // Don't update if scan window has ended (finalize() handles that)
        guard elapsed < scanDuration else {
            return
        }
        
        let progress = min(Float(elapsed / scanDuration), 0.99) // Cap at 99% until finalize
        guidanceProgress?.progress = progress

        let cue = scanCueText(elapsed: elapsed, total: scanDuration)
        guidanceDetailLabel?.text = cue
        directionLabel?.text = scanDirectionText(elapsed: elapsed, total: scanDuration)

        let distance = estimateCenterDistanceMeters()
        if let distance {
            let cm = distance * 100.0
            let emoji = (cm >= 20 && cm <= 55) ? "✅" : "⚠️"
            guidanceDistanceLabel?.text = String(format: "%@ Distance: %.0f cm", emoji, cm)
        } else {
            guidanceDistanceLabel?.text = "📏 Distance: --"
        }
        
        // Update quality with emoji
        if let qualityText = guidanceQualityLabel?.text, qualityText.contains("Quality:") {
            let qualityValue = qualityText.replacingOccurrences(of: "✨ Quality: ", with: "")
            if qualityValue != "--" && qualityValue != "collecting..." {
                let emoji = qualityValue.contains("good") || qualityValue.contains("excellent") ? "✅" : "⚠️"
                guidanceQualityLabel?.text = String(format: "%@ Quality: %@", emoji, qualityValue)
            }
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
            return "Face forward, hold still"
        case segment..<(2 * segment):
            return "Slowly turn your head left"
        case (2 * segment)..<(3 * segment):
            return "Slowly turn your head right"
        case (3 * segment)..<(4 * segment):
            return "Look up slightly"
        default:
            return "Look down slightly, then return to center"
        }
    }

    private func scanDirectionText(elapsed: TimeInterval, total: TimeInterval) -> String {
        let segment = total / 5.0
        switch elapsed {
        case 0..<segment:
            return "⬆︎ Face forward"
        case segment..<(2 * segment):
            return "⬅︎ Turn left"
        case (2 * segment)..<(3 * segment):
            return "➡︎ Turn right"
        case (3 * segment)..<(4 * segment):
            return "⬆︎ Look up"
        default:
            return "⬇︎ Look down"
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
            } else {
                return scene.interfaceOrientation
            }
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            if #available(iOS 26.0, *) {
                return scene.effectiveGeometry.interfaceOrientation
            } else {
                return scene.interfaceOrientation
            }
        }
        return .portrait
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

    private func failConfiguration(_ message: String) {
        print("Session configuration failed: \(message)")
        setSetupResult(.configurationFailed)
        // TrueDepth warning removed
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
        // TrueDepth health timer removed
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        // TrueDepth health timer removed
        dataOutputQueue.async {
            self.renderingEnabled = false
        }
        let currentSetupResult = readSetupResult()
        sessionQueue.async {
            switch currentSetupResult {
            case .success:
                self.session.stopRunning()
                self.isSessionRunning = self.session.isRunning
            case .notAuthorized, .configurationFailed:
                break
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
            ?? AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        
        guard let videoDevice = defaultVideoDevice else {
            failConfiguration("TrueDepth camera not found. Ensure this is a TrueDepth device and no other camera apps are open.")
            return
        }
        
        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            failConfiguration("Failed to create TrueDepth camera input: \(error.localizedDescription)")
            return
        }
        
        session.beginConfiguration()
        
//        session.sessionPreset = AVCaptureSession.Preset.vga640x480
        session.sessionPreset = AVCaptureSession.Preset.hd1920x1080
        
        // Add a video input
        guard session.canAddInput(videoDeviceInput) else {
            failConfiguration("Could not add TrueDepth camera input to the session.")
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)
        
        // Add a video data output
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        } else {
            failConfiguration("Could not attach video output. The camera may be in use.")
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
                failConfiguration("Depth output connection not available.")
            }
        } else {
            failConfiguration("Could not attach depth output. TrueDepth may be unavailable.")
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

        guard let depthFormat = selectedFormat else {
            failConfiguration("No supported depth formats found for TrueDepth.")
            session.commitConfiguration()
            return
        }
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeDepthDataFormat = depthFormat
            videoDevice.unlockForConfiguration()
        } catch {
            failConfiguration("Unable to set depth format: \(error.localizedDescription)")
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
        // TrueDepth warning removed
        
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
            lastDepthFrameAt = Date()
            hasSeenDepthFrame = true
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

        let centerX = 0.5 * Float(depthWidth)
        let centerY = 0.45 * Float(depthHeight)
        let radiusX = 0.32 * Float(depthWidth)
        let radiusY = 0.38 * Float(depthHeight)

        for y in Swift.stride(from: 0, to: depthHeight, by: strideStep) {
            for x in Swift.stride(from: 0, to: depthWidth, by: strideStep) {
                let dx = (Float(x) - centerX) / radiusX
                let dy = (Float(y) - centerY) / radiusY
                if (dx * dx + dy * dy) > 1.0 {
                    continue
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

    private func collectMultiFramePLYWithImages(duration: TimeInterval,
                                                interval: TimeInterval,
                                                strideStep: Int,
                                                maxPoints: Int,
                                                completion: @escaping (Result<(Data, [CapturedFrame]), Error>) -> Void) {
        processingQueue.async {
            var candidates: [FrameCandidate] = []
            var rgbFrames: [CapturedFrame] = []
            var referenceLandmarks: [CGPoint]?
            var lastAnalysis: FaceAnalysis?
            let endTime = Date().addingTimeInterval(duration)

            func finalize() {
                // Stop guidance timer immediately when scan window ends
                DispatchQueue.main.async {
                    self.stopGuidanceTimer()
                    self.guidanceTitleLabel?.text = "✨ Processing..."
                    self.guidanceDetailLabel?.text = "Preparing your 3D scan"
                    self.guidanceProgress?.progress = 1.0
                    self.directionLabel?.text = "⏳ Please wait"
                }
                
                guard !candidates.isEmpty else {
                    DispatchQueue.main.async {
                        completion(.failure(CaptureError.noFrames))
                    }
                    return
                }

                // Move ALL heavy processing to background thread immediately
                // This prevents blocking the processing queue which could cause UI freeze
                DispatchQueue.global(qos: .userInitiated).async {
                    let filtered = candidates.filter { candidate in
                        let validOk = candidate.depthValidRatio >= 0.08 && candidate.pointCount >= 5000
                        let rollOk = candidate.rollDegrees.map { abs($0) < 15.0 } ?? true
                        let yawOk = candidate.yawDegrees.map { abs($0) < 35.0 } ?? true
                        let mouthOk = candidate.mouthOpenRatio.map { $0 < 0.06 } ?? true
                        let lmkOk = candidate.landmarkRMS.map { $0 < 0.02 } ?? true
                        let deltaPoseOk = candidate.deltaPose.map { $0 < 6.0 } ?? true
                        let deltaCentroidOk = candidate.deltaCentroid.map { $0 < 0.01 } ?? true
                        return validOk && rollOk && yawOk && mouthOk && lmkOk && deltaPoseOk && deltaCentroidOk
                    }

                    let pool = filtered.isEmpty ? candidates : filtered
                    let scored = pool.sorted { a, b in
                        self.scoreCandidate(a) > self.scoreCandidate(b)
                    }

                    // Select best frames for 5 poses automatically
                    let selectedFrames = self.selectBestFramesForPoses(scored: scored, rgbFrames: rgbFrames)
                    
                    // Log which poses were captured
                    let capturedPoses = selectedFrames.map { $0.pose }
                    let poseNames = capturedPoses.map { pose in
                        switch pose {
                        case .front: return "front"
                        case .left: return "left"
                        case .right: return "right"
                        case .down: return "down"
                        case .up: return "up"
                        }
                    }.joined(separator: ", ")
                    print("📸 Captured poses: \(poseNames) (\(selectedFrames.count)/5)")
                    
                    // Warn if missing poses
                    let allPoses: Set<CapturePose> = [.front, .left, .right, .down, .up]
                    let capturedPoseSet = Set(capturedPoses)
                    let missingPoses = allPoses.subtracting(capturedPoseSet)
                    if !missingPoses.isEmpty {
                        let missingNames = missingPoses.map { pose in
                            switch pose {
                            case .front: return "front"
                            case .left: return "left"
                            case .right: return "right"
                            case .down: return "down"
                            case .up: return "up"
                            }
                        }.joined(separator: ", ")
                        print("⚠️ Missing poses: \(missingNames)")
                    }

                    // Update UI immediately
                    DispatchQueue.main.async {
                        let poseInfo = selectedFrames.count == 5 ? "✅ All poses captured" : "⚠️ \(selectedFrames.count)/5 poses"
                        self.guidanceDetailLabel?.text = "Building 3D model... \(poseInfo)"
                    }
                    // Build points array on background thread
                    var points: [String] = []
                    points.reserveCapacity(min(maxPoints, scored.prefix(20).reduce(0) { $0 + $1.points.count }))
                    
                    for candidate in scored.prefix(20) {  // Use top 20 candidates for PLY
                        for point in candidate.points {
                            if points.count >= maxPoints {
                                break
                            }
                            points.append(point)
                        }
                        if points.count >= maxPoints {
                            break
                        }
                    }

                    guard points.count >= 1000 else {
                        DispatchQueue.main.async {
                            completion(.failure(CaptureError.sparsePoints(points.count)))
                        }
                        return
                    }
                    
                    // Update UI with point count
                    DispatchQueue.main.async {
                        self.guidanceDetailLabel?.text = "Building 3D model from \(points.count) points..."
                    }
                    
                    // Build PLY data
                    if let plyData = self.buildPLYData(from: points) {
                        DispatchQueue.main.async {
                            completion(.success((plyData, selectedFrames)))
                        }
                    } else {
                        DispatchQueue.main.async {
                            completion(.failure(CaptureError.insufficientPoints))
                        }
                    }
                }
            }

            func sampleNext() {
                if Date() >= endTime {
                    finalize()
                    return
                }

                if let candidate = self.captureFrameCandidate(strideStep: strideStep,
                                                              maxPoints: maxPoints,
                                                              referenceLandmarks: &referenceLandmarks,
                                                              lastAnalysis: &lastAnalysis) {
                    candidates.append(candidate)
                    self.lastPointCount = candidate.pointCount
                    
                    // Also capture RGB frame for Gemini (use same data as candidate)
                    var depthData: AVDepthData?
                    var colorBuffer: CVPixelBuffer?
                    self.latestFrameQueue.sync {
                        depthData = self.latestDepthData
                        colorBuffer = self.latestColorBuffer
                    }
                    
                    // Capture RGB frame for Gemini (less frequently to avoid freezing)
                    // Only capture every 3rd candidate to reduce processing load
                    if candidates.count % 3 == 0 && rgbFrames.count < 30 {
                        var depthData: AVDepthData?
                        var colorBuffer: CVPixelBuffer?
                        self.latestFrameQueue.sync {
                            depthData = self.latestDepthData
                            colorBuffer = self.latestColorBuffer
                        }
                        
                        if let depthData, let colorBuffer {
                            // Convert to JPEG on background thread to avoid UI freezing
                            let colorBufferCopy = colorBuffer
                            DispatchQueue.global(qos: .userInitiated).async {
                                guard let jpegData = self.convertPixelBufferToJPEG(colorBufferCopy, quality: 0.8) else {
                                    return
                                }
                                
                                let analysis = self.analyzeFace(in: colorBufferCopy)
                                let landmarks = analysis?.landmarks ?? []
                                
                                // Determine pose type from angles
                                let pose = self.determinePoseFromAngles(yaw: analysis?.yawDegrees, pitch: analysis?.pitchDegrees)
                                
                                let frame = CapturedFrame(
                                    pose: pose,
                                    rgbImageJPEG: jpegData,
                                    depthData: depthData,
                                    timestamp: Date(),
                                    yaw: analysis?.yawDegrees,
                                    pitch: analysis?.pitchDegrees,
                                    roll: analysis?.rollDegrees,
                                    landmarks: landmarks
                                )
                                
                                // Append thread-safely on processing queue
                                self.processingQueue.async {
                                    rgbFrames.append(frame)
                                }
                            }
                        }
                    }
                    
                    if candidate.depthValidRatio >= 0.1 && candidate.pointCount >= 10000 {
                        DispatchQueue.main.async {
                            self.hapticGenerator?.impactOccurred()
                            self.hapticGenerator?.prepare()
                        }
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                    self.processingQueue.async {
                        sampleNext()
                    }
                }
            }

            sampleNext()
        }
    }
    
    private func determinePoseFromAngles(yaw: Float?, pitch: Float?) -> CapturePose {
        guard let yaw = yaw, let pitch = pitch else {
            return .front
        }
        
        // Determine pose based on angles
        if abs(yaw) < 15 {
            if pitch < -20 {
                return .down
            } else if pitch > 20 {
                return .up
            } else {
                return .front
            }
        } else if yaw < -70 {
            return .left
        } else if yaw > 70 {
            return .right
        }
        
        return .front
    }
    
    private func selectBestFramesForPoses(scored: [FrameCandidate], rgbFrames: [CapturedFrame]) -> [CapturedFrame] {
        var selected: [CapturePose: CapturedFrame] = [:]
        
        // Group frames by pose
        for frame in rgbFrames {
            let pose = frame.pose
            if selected[pose] == nil {
                selected[pose] = frame
            } else if let current = selected[pose],
                      let currentYaw = current.yaw,
                      let frameYaw = frame.yaw {
                // Prefer frame closer to ideal angle
                let currentDist = abs(currentYaw - idealYawForPose(pose))
                let frameDist = abs(frameYaw - idealYawForPose(pose))
                if frameDist < currentDist {
                    selected[pose] = frame
                }
            }
        }
        
        // Return in order: front, left, right, down, up
        var result: [CapturedFrame] = []
        for pose in [CapturePose.front, .left, .right, .down, .up] {
            if let frame = selected[pose] {
                result.append(frame)
            }
        }
        
        return result
    }
    
    private func idealYawForPose(_ pose: CapturePose) -> Float {
        switch pose {
        case .front: return 0
        case .left: return -90
        case .right: return 90
        case .down: return 0
        case .up: return 0
        }
    }

    private func collectMultiFramePLY(duration: TimeInterval,
                                      interval: TimeInterval,
                                      strideStep: Int,
                                      maxPoints: Int,
                                      completion: @escaping (Result<Data, Error>) -> Void) {
        processingQueue.async {
            var candidates: [FrameCandidate] = []
            var referenceLandmarks: [CGPoint]?
            var lastAnalysis: FaceAnalysis?
            let endTime = Date().addingTimeInterval(duration)

            func finalize() {
                guard !candidates.isEmpty else {
                    completion(.failure(CaptureError.noFrames))
                    return
                }

                let filtered = candidates.filter { candidate in
                    let validOk = candidate.depthValidRatio >= 0.08 && candidate.pointCount >= 5000
                    let rollOk = candidate.rollDegrees.map { abs($0) < 15.0 } ?? true
                    let yawOk = candidate.yawDegrees.map { abs($0) < 35.0 } ?? true
                    let mouthOk = candidate.mouthOpenRatio.map { $0 < 0.06 } ?? true
                    let lmkOk = candidate.landmarkRMS.map { $0 < 0.02 } ?? true
                    let deltaPoseOk = candidate.deltaPose.map { $0 < 6.0 } ?? true
                    let deltaCentroidOk = candidate.deltaCentroid.map { $0 < 0.01 } ?? true
                    return validOk && rollOk && yawOk && mouthOk && lmkOk && deltaPoseOk && deltaCentroidOk
                }

                let pool = filtered.isEmpty ? candidates : filtered
                let scored = pool.sorted { a, b in
                    self.scoreCandidate(a) > self.scoreCandidate(b)
                }

                let selected = self.selectByYawBuckets(scored: scored, total: 8)

                var points: [String] = []
                for candidate in selected {
                    for point in candidate.points {
                        if points.count >= maxPoints {
                            break
                        }
                        points.append(point)
                    }
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
                if Date() >= endTime {
                    finalize()
                    return
                }

                if let candidate = self.captureFrameCandidate(strideStep: strideStep,
                                                              maxPoints: maxPoints,
                                                              referenceLandmarks: &referenceLandmarks,
                                                              lastAnalysis: &lastAnalysis) {
                    candidates.append(candidate)
                    self.lastPointCount = candidate.pointCount
                    if candidate.depthValidRatio >= 0.1 && candidate.pointCount >= 10000 {
                        DispatchQueue.main.async {
                            self.hapticGenerator?.impactOccurred()
                            self.hapticGenerator?.prepare()
                        }
                    }
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + interval) {
                    self.processingQueue.async {
                        sampleNext()
                    }
                }
            }

            sampleNext()
        }
    }

    private func scoreCandidate(_ candidate: FrameCandidate) -> Float {
        let validScore = min(max((candidate.depthValidRatio - 0.05) / 0.15, 0), 1)
        let pointScore = min(Float(candidate.pointCount) / 30_000.0, 1.0)
        let lmkScore = candidate.landmarkRMS.map { max(0.0, 1.0 - ($0 / 0.02)) } ?? 0.5
        let deltaScore = candidate.deltaLandmarks.map { max(0.0, 1.0 - ($0 / 0.02)) } ?? 0.5
        let rollScore = candidate.rollDegrees.map { max(0.0, 1.0 - (abs($0) / 15.0)) } ?? 0.5

        return (0.35 * validScore)
            + (0.30 * lmkScore)
            + (0.20 * deltaScore)
            + (0.10 * rollScore)
            + (0.05 * pointScore)
    }

    private func selectByYawBuckets(scored: [FrameCandidate], total: Int) -> [FrameCandidate] {
        let left = scored.filter { ($0.yawDegrees ?? 0) <= -10 && ($0.yawDegrees ?? 0) >= -25 }
        let center = scored.filter { abs($0.yawDegrees ?? 0) <= 8 }
        let right = scored.filter { ($0.yawDegrees ?? 0) >= 10 && ($0.yawDegrees ?? 0) <= 25 }

        var selected: [FrameCandidate] = []
        selected.append(contentsOf: center.prefix(3))
        selected.append(contentsOf: left.prefix(2))
        selected.append(contentsOf: right.prefix(2))

        if selected.count < total {
            let remaining = scored.filter { candidate in
                !selected.contains(where: { $0.pointCount == candidate.pointCount
                    && $0.depthValidRatio == candidate.depthValidRatio
                    && $0.yawDegrees == candidate.yawDegrees
                    && $0.rollDegrees == candidate.rollDegrees
                    && $0.mouthOpenRatio == candidate.mouthOpenRatio
                    && $0.landmarkRMS == candidate.landmarkRMS
                })
            }
            selected.append(contentsOf: remaining.prefix(total - selected.count))
        }
        if selected.isEmpty {
            return Array(scored.prefix(min(total, scored.count)))
        }
        return Array(selected.prefix(min(total, selected.count)))
    }

    private func captureFrameCandidate(strideStep: Int,
                                       maxPoints: Int,
                                       referenceLandmarks: inout [CGPoint]?,
                                       lastAnalysis: inout FaceAnalysis?) -> FrameCandidate? {
        var depthData: AVDepthData?
        var colorBuffer: CVPixelBuffer?
        latestFrameQueue.sync {
            depthData = latestDepthData
            colorBuffer = latestColorBuffer
        }
        guard let depthData, let colorBuffer else {
            return nil
        }

        guard let frame = buildFramePoints(depthData: depthData,
                                           colorBuffer: colorBuffer,
                                           strideStep: strideStep,
                                           maxPoints: maxPoints) else {
            return nil
        }

        let analysis = analyzeFace(in: colorBuffer)
        let landmarks = analysis?.landmarks ?? []
        if referenceLandmarks == nil, !landmarks.isEmpty {
            referenceLandmarks = landmarks
        }
        let landmarkRMS = referenceLandmarks.flatMap { ref in
            computeLandmarkRMS(current: landmarks, reference: ref)
        }
        let deltaLandmarks = lastAnalysis.flatMap { prev in
            computeLandmarkRMS(current: landmarks, reference: prev.landmarks)
        }
        let deltaPose = lastAnalysis.flatMap { prev -> Float? in
            guard let yawNow = analysis?.yawDegrees,
                  let rollNow = analysis?.rollDegrees,
                  let yawPrev = prev.yawDegrees,
                  let rollPrev = prev.rollDegrees else {
                return nil
            }
            return abs(yawNow - yawPrev) + abs(rollNow - rollPrev)
        }
        let deltaCentroid = lastAnalysis.flatMap { prev -> Float? in
            guard let nowCentroid = analysis?.centroid,
                  let prevCentroid = prev.centroid else {
                return nil
            }
            let dx = Float(nowCentroid.x - prevCentroid.x)
            let dy = Float(nowCentroid.y - prevCentroid.y)
            return sqrt(dx * dx + dy * dy)
        }
        lastAnalysis = analysis

        return FrameCandidate(points: frame.points,
                              pointCount: frame.points.count,
                              depthValidRatio: frame.depthValidRatio,
                              landmarks: landmarks,
                              yawDegrees: analysis?.yawDegrees,
                              rollDegrees: analysis?.rollDegrees,
                              mouthOpenRatio: analysis?.mouthOpenRatio,
                              interocular: analysis?.interocular,
                              landmarkRMS: landmarkRMS,
                              deltaPose: deltaPose,
                              deltaLandmarks: deltaLandmarks,
                              deltaCentroid: deltaCentroid)
    }

    private func buildFramePoints(depthData: AVDepthData,
                                  colorBuffer: CVPixelBuffer,
                                  strideStep: Int,
                                  maxPoints: Int) -> (points: [String], depthValidRatio: Float)? {
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

        let centerX = 0.5 * Float(depthWidth)
        let centerY = 0.45 * Float(depthHeight)
        let radiusX = 0.32 * Float(depthWidth)
        let radiusY = 0.38 * Float(depthHeight)

        var totalSamples = 0
        var validSamples = 0

        for y in Swift.stride(from: 0, to: depthHeight, by: strideStep) {
            for x in Swift.stride(from: 0, to: depthWidth, by: strideStep) {
                if vertices.count >= maxPoints {
                    break
                }
                let dx = (Float(x) - centerX) / radiusX
                let dy = (Float(y) - centerY) / radiusY
                if (dx * dx + dy * dy) > 1.0 {
                    continue
                }
                totalSamples += 1
                let depth = depthBuffer[y * depthWidth + x]
                if !depth.isFinite || depth <= 0 {
                    continue
                }
                validSamples += 1

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

        guard totalSamples > 0 else {
            return nil
        }
        let ratio = Float(validSamples) / Float(totalSamples)
        return (vertices, ratio)
    }

    private func analyzeFace(in colorBuffer: CVPixelBuffer) -> FaceAnalysis? {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: colorBuffer,
                                            orientation: .rightMirrored,
                                            options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let face = request.results?.first as? VNFaceObservation,
              let allPoints = face.landmarks?.allPoints else {
            return nil
        }

        let landmarks = convertLandmarks(allPoints, faceBoundingBox: face.boundingBox)
        var mouthOpen: Float?
        var interocular: Float?
        var centroid = CGPoint(x: 0.0, y: 0.0)
        if !landmarks.isEmpty {
            let sum = landmarks.reduce(CGPoint.zero) { acc, pt in
                CGPoint(x: acc.x + pt.x, y: acc.y + pt.y)
            }
            centroid = CGPoint(x: sum.x / CGFloat(landmarks.count), y: sum.y / CGFloat(landmarks.count))
        }

        if let leftEye = face.landmarks?.leftEye, let rightEye = face.landmarks?.rightEye {
            let leftPts = convertLandmarks(leftEye, faceBoundingBox: face.boundingBox)
            let rightPts = convertLandmarks(rightEye, faceBoundingBox: face.boundingBox)
            if let leftCenter = averagePoint(leftPts), let rightCenter = averagePoint(rightPts) {
                let dx = Float(leftCenter.x - rightCenter.x)
                let dy = Float(leftCenter.y - rightCenter.y)
                interocular = sqrt(dx * dx + dy * dy)
            }
        }
        if let outerLips = face.landmarks?.outerLips {
            let mouthPoints = convertLandmarks(outerLips, faceBoundingBox: face.boundingBox)
            if let minY = mouthPoints.map({ $0.y }).min(),
               let maxY = mouthPoints.map({ $0.y }).max() {
                let norm = max(interocular ?? Float(face.boundingBox.height), 1e-6)
                mouthOpen = Float((maxY - minY)) / norm
            }
        }
        let yawDeg = face.yaw.map { Float(truncating: $0) * (180.0 / .pi) }
        let pitchDeg = face.pitch.map { Float(truncating: $0) * (180.0 / .pi) }
        let rollDeg = face.roll.map { Float(truncating: $0) * (180.0 / .pi) }
        return FaceAnalysis(landmarks: landmarks,
                            yawDegrees: yawDeg,
                            pitchDegrees: pitchDeg,
                            rollDegrees: rollDeg,
                            mouthOpenRatio: mouthOpen,
                            interocular: interocular,
                            centroid: centroid)
    }

    private func averagePoint(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else {
            return nil
        }
        let sum = points.reduce(CGPoint.zero) { acc, pt in
            CGPoint(x: acc.x + pt.x, y: acc.y + pt.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func convertLandmarks(_ region: VNFaceLandmarkRegion2D,
                                  faceBoundingBox: CGRect) -> [CGPoint] {
        return region.normalizedPoints.map { point in
            CGPoint(x: faceBoundingBox.origin.x + CGFloat(point.x) * faceBoundingBox.size.width,
                    y: faceBoundingBox.origin.y + CGFloat(point.y) * faceBoundingBox.size.height)
        }
    }

    private func computeLandmarkRMS(current: [CGPoint], reference: [CGPoint]) -> Float? {
        guard !current.isEmpty, !reference.isEmpty else {
            return nil
        }
        let count = min(current.count, reference.count)
        var sum: CGFloat = 0
        for idx in 0..<count {
            let dx = current[idx].x - reference[idx].x
            let dy = current[idx].y - reference[idx].y
            sum += dx * dx + dy * dy
        }
        return Float(sqrt(sum / CGFloat(count)))
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

        let deadline = Date().addingTimeInterval(600)

        func checkStatus() {
            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(UploadError.serverError(self.describeServerResponse(response, data))))
                    return
                }

                let body = data ?? Data()
                if !(200...299).contains(httpResponse.statusCode) {
                    completion(.failure(UploadError.serverError(self.describeServerResponse(response, body))))
                    return
                }

                let payload = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any]
                if payload == nil {
                    completion(.failure(UploadError.serverError(self.describeServerResponse(response, body))))
                    return
                }
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
                    completion(.failure(UploadError.serverError("Processing timed out after 10 minutes. Try again.")))
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

    private func convertPixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.8) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        
        let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .rightMirrored)
        return uiImage.jpegData(compressionQuality: quality)
    }
    
    private func uploadPLYWithFrames(data: Data, frames: [CapturedFrame], completion: @escaping (Result<String, Error>) -> Void) {
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
        
        // Add PLY file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"ply\"; filename=\"scan.ply\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        
        // Add RGB frames as JPEG images (already converted to JPEG)
        let frameNames: [CapturePose: String] = [.front: "front", .left: "left", .right: "right", .down: "down", .up: "up"]
        for frame in frames {
            guard let fieldName = frameNames[frame.pose] else {
                continue
            }
            
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"image_\(fieldName)\"; filename=\"\(fieldName).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(frame.rgbImageJPEG)
            body.append("\r\n".data(using: .utf8)!)
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let timeoutItem = DispatchWorkItem {
            completion(.failure(UploadError.serverError("Upload timed out. Try Wi‑Fi or reduce scan size.")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: timeoutItem)

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true
        sessionConfig.timeoutIntervalForRequest = 300
        sessionConfig.timeoutIntervalForResource = 300
        let session = URLSession(configuration: sessionConfig)

        let task = session.uploadTask(with: request, from: body) { data, response, error in
            timeoutItem.cancel()
            
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(UploadError.serverError(self.describeServerResponse(response, data))))
                return
            }

            let responseBody = data ?? Data()
            if !(200...299).contains(httpResponse.statusCode) {
                completion(.failure(UploadError.serverError(self.describeServerResponse(response, responseBody))))
                return
            }

            do {
                let payload = try JSONSerialization.jsonObject(with: responseBody, options: []) as? [String: Any]
                if let scanId = payload?["scanId"] as? String {
                    completion(.success(scanId))
                } else {
                    completion(.failure(UploadError.serverError(self.describeServerResponse(response, responseBody))))
                }
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
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

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(UploadError.serverError(self.describeServerResponse(response, responseData))))
                return
            }

            let body = responseData ?? Data()

            if !(200...299).contains(httpResponse.statusCode) {
                completion(.failure(UploadError.serverError(self.describeServerResponse(response, body))))
                return
            }

            do {
                let payload = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any]
                if let scanId = payload?["scanId"] as? String {
                    completion(.success(scanId))
                } else {
                    completion(.failure(UploadError.serverError(self.describeServerResponse(response, body))))
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

    private func describeServerResponse(_ response: URLResponse?, _ data: Data?) -> String {
        let status = (response as? HTTPURLResponse)?.statusCode
        let statusText = status.map { "HTTP \($0)" } ?? "HTTP unavailable"
        let bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Invalid server response (\(statusText))."
        }
        let snippet = String(trimmed.prefix(400))
        return "Server response (\(statusText)): \(snippet)"
    }
    
}

