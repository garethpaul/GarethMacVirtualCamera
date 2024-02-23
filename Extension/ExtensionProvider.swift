//
//  ExtensionProvider.swift
//  Extension
//

import CoreMediaIO
import Foundation
import IOKit.audio
import os.log
import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics

let kWhiteStripeHeight: Int = 10
let kFrameRate: Int = 30

// MARK: - ExtensionDeviceSource

let logger = Logger(subsystem: "com.garethpaul.GarethVideoCam",
                    category: "Extension")

// MARK: - ExtensionDeviceSourceDelegate

protocol ExtensionDeviceSourceDelegate: NSObject {
    func bufferReceived(_ buffer: CMSampleBuffer)
}

// MARK: - ExtensionDeviceSource

class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // MARK: Lifecycle

    init(localizedName: String) {
        super.init()
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if bundleID.contains("EndToEnd") {
            _isExtension = false
        }
        let deviceID = UUID() // replace this with your device UUID
        self.device = CMIOExtensionDevice(localizedName: localizedName,
                                          deviceID: deviceID,
                                          legacyDeviceID: nil, source: self)

        // Optimize these dimensions based on your source video or desired output quality.
                let dims = CMVideoDimensions(width: 1920, height: 1080) // HD Resolution
                CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                               codecType: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, // Opt for high-quality video format
                                               width: dims.width, height: dims.height,
                                               extensions: nil,
                                               formatDescriptionOut: &_videoDescription)


        let pixelBufferAttributes: NSDictionary = [
                    kCVPixelBufferWidthKey: dims.width,
                    kCVPixelBufferHeightKey: dims.height,
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, // Match video format
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                    kCVPixelBufferMetalCompatibilityKey: true, // Ensure Metal compatibility for better performance
                ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes,
                                &_bufferPool)

        let videoStreamFormat =
                    CMIOExtensionStreamFormat(formatDescription: _videoDescription!,
                                              maxFrameDuration: CMTime(value: 1,  timescale: Int32(kFrameRate)), // Adjust based on your frame rate needs
                                              minFrameDuration: CMTime(value: 1, timescale:  Int32(kFrameRate)),
                                              validFrameDurations: nil)
                _bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]

        let videoID = UUID() // replace this with your video UUID
        _streamSource = ExtensionStreamSource(localizedName: "GarethVideoCam.Video",
                                              streamID: videoID,
                                              streamFormat: videoStreamFormat,
                                              device: device)
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    // MARK: Public

    public weak var extensionDeviceSourceDelegate: ExtensionDeviceSourceDelegate?

    // MARK: Internal

    private(set) var device: CMIOExtensionDevice!

    var imageIsClean = true

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "GarethVideoCam Model"
        }

        return deviceProperties
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {
        // Handle settable properties here.
    }
    
    private func send(sampleBuffer: CMSampleBuffer, with bufferPool: CVPixelBufferPool) {
        // Example placeholder function for handling the buffer send operation.
        // Implement sending the buffer to your stream source here.
        // This might involve converting CMSampleBuffer to a suitable format for your streaming needs.
    }
    
    
    /* Stream */
    // Assuming you have these properties defined in your class
    private var assetReader: AVAssetReader?
    private var asset: AVAsset?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var _timer: DispatchSourceTimer?
    private var _timerQueue = DispatchQueue(label: "com.yourcompany.timerqueue")
    
    private func setupAssetReader(with videoURL: URL) -> Bool {
        asset = AVAsset(url: videoURL)
        do {
            assetReader = try AVAssetReader(asset: asset!)
            guard let videoTrack = asset!.tracks(withMediaType: .video).first else {
                print("Failed to get video track")
                return false
            }
            
            let outputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)]
            trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
            if let trackOutput = trackOutput, assetReader?.canAdd(trackOutput) ?? false {
                assetReader?.add(trackOutput)
            } else {
                print("Can't add output reader")
                return false
            }
            
            return assetReader?.startReading() ?? false
        } catch {
            print("Failed to initialize the asset reader: \(error)")
            return false
        }
    }

    func restartAssetReader(with videoURL: URL) {
        _timer?.cancel() // Stop the timer before restarting
        _timer = nil // Ensure the timer is set to nil after cancelling
        assetReader = nil
        trackOutput = nil
        if setupAssetReader(with: videoURL) {
            startTimer(with: videoURL) // Encapsulate timer initialization and starting in a separate method
        } else {
            print("Failed to restart asset reader.")
        }
    }

    func startStreaming() {
        guard let videoURL = Bundle.main.url(forResource: "video", withExtension: "mp4") else {
            print("Video file not found in the bundle.")
            return
        }

        if !setupAssetReader(with: videoURL) {
            print("Failed to set up the asset reader initially.")
            return
        }
        
        startTimer(with: videoURL) // Start the timer with encapsulated initialization
    }

    private func startTimer(with videoURL: URL) {
        _timer?.cancel() // Cancel any existing timer
        _timer = nil // Reset the timer to ensure it's not reused

        _timer = DispatchSource.makeTimerSource(queue: _timerQueue)
        _timer?.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate))
        _timer?.setEventHandler { [weak self] in
            guard let self = self else { return }

            if let sampleBuffer = self.trackOutput?.copyNextSampleBuffer() {
                self.processSampleBuffer(sampleBuffer)
            } else {
                // When no more samples are available, restart the asset reader for looping
                DispatchQueue.main.async {
                    self.restartAssetReader(with: videoURL)
                }
            }
        }
        _timer?.resume() // Safely resume the new timer
    }
    /* End Stream */
    
    
    private var lastPresentationTime: CMTime = .negativeInfinity
    private var timestampOffset: CMTime = CMTime.zero
    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetDuration = self.asset?.duration else {
            // Handle the error: asset or its duration is unavailable
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.flags.contains(.valid) {
            if pts < lastPresentationTime {
                // Detected a loop, update the timestamp offset by adding the asset duration
                timestampOffset = CMTimeAdd(timestampOffset, assetDuration)
            }
            lastPresentationTime = pts

            // Adjust the PTS by the current timestamp offset
            let adjustedPTS = CMTimeAdd(pts, timestampOffset)
            let hostTimeInNanoseconds = UInt64(CMTimeGetSeconds(adjustedPTS) * Double(NSEC_PER_SEC))

            // Send the sample buffer with the adjusted PTS
            self._streamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTimeInNanoseconds)
        } else {
            // Handle invalid PTS if necessary
        }
    }


    func cancelStreaming() {
        if let timer = _timer {
            timer.cancel()
            _timer = nil
        }
        
        stopStreaming()

    }
    

    func stopStreaming() {
        if _streamingCounter > 1 {
            _streamingCounter -= 1
        } else {
            _streamingCounter = 0
            if let timer = _timer {
                timer.cancel()
                _timer = nil
            }
        }
    }

    // MARK: Private

    private var _isExtension: Bool = true
    private var _streamSource: ExtensionStreamSource!

    private var _streamingCounter: UInt32 = 0


    private var _videoDescription: CMFormatDescription!

    private var _bufferPool: CVPixelBufferPool!

    private var _bufferAuxAttributes: NSDictionary!

    private var _whiteStripeStartRow: UInt32 = 0

    private var _whiteStripeIsAscending: Bool = false
}

// MARK: - ExtensionStreamSource

class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    // MARK: Lifecycle

    init(localizedName: String, streamID: UUID,
         streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()
        self.stream = CMIOExtensionStream(localizedName: localizedName,
                                          streamID: streamID,
                                          direction: .source,
                                          clockType: .hostTime, source: self)
    }

    // MARK: Internal

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex >= 1 {
                os_log(.error, "Invalid index")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }


    
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
            streamProperties.frameDuration = frameDuration
        }

        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        // An opportunity to inspect the client info and decide if it should be allowed to start the stream.
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreaming()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreaming()
    }

    // MARK: Private

    private let _streamFormat: CMIOExtensionStreamFormat
}

// MARK: - ExtensionProviderSource

class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    // MARK: Lifecycle

    // CMIOExtensionProviderSource protocol methods (all are required)

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: "GarethVideoCam")

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    deinit {
        
    }

    // MARK: Internal

    private(set) var provider: CMIOExtensionProvider!

    var deviceSource: ExtensionDeviceSource!

    var availableProperties: Set<CMIOExtensionProperty> {
        // See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
        return [.providerManufacturer]
    }

    func connect(to _: CMIOExtensionClient) throws {
        // Handle client connect
    }

    func disconnect(from _: CMIOExtensionClient) {
        // Handle client disconnect
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let providerProperties =
            CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "GarethVideoCam Manufacturer"
        }
        return providerProperties
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {
        // Handle settable properties here.
    }

}
