//
//  ExtensionProvider.swift
//  Extension
//

import AVFoundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os.log

private enum CameraExtensionConfiguration {
    static let localizedDeviceName = "Gareth Video Cam"
    static let localizedStreamName = "Gareth Video Cam Stream"
    static let manufacturer = "Gareth Paul"
    static let model = "Gareth Video Cam"
    static let bundledVideoName = "video"
    static let bundledVideoExtension = "mp4"

    static let frameRate: Int32 = 30
    static let dimensions = CMVideoDimensions(width: 1920, height: 1080)
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let frameDuration = CMTime(value: 1, timescale: frameRate)

    static let deviceID = UUID(uuidString: "c5633637-4cf7-4c1c-928e-513fea1cc2d3")!
    static let streamID = UUID(uuidString: "b62ba48a-2856-427c-a1f1-90fe58c6f99c")!
}

private let logger = Logger(subsystem: "com.garethpaul.GarethVideoCam",
                            category: "Extension")

private enum CameraExtensionError: LocalizedError {
    case missingBundledVideo
    case failedToStartAssetReader
    case unexpectedDeviceSource

    var errorDescription: String? {
        switch self {
        case .missingBundledVideo:
            return "The bundled loop video was not found."
        case .failedToStartAssetReader:
            return "The bundled loop video could not be read."
        case .unexpectedDeviceSource:
            return "The stream is attached to an unexpected device source."
        }
    }
}

// MARK: - ExtensionDeviceSource

final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    // MARK: Lifecycle

    init(localizedName: String) {
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName,
                                     deviceID: CameraExtensionConfiguration.deviceID,
                                     legacyDeviceID: nil,
                                     source: self)

        let formatDescriptionStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                                     codecType: CameraExtensionConfiguration.pixelFormat,
                                                                     width: CameraExtensionConfiguration.dimensions.width,
                                                                     height: CameraExtensionConfiguration.dimensions.height,
                                                                     extensions: nil,
                                                                     formatDescriptionOut: &_videoDescription)

        guard formatDescriptionStatus == noErr, let videoDescription = _videoDescription else {
            fatalError("Failed to create the video format description: \(formatDescriptionStatus)")
        }

        let videoStreamFormat = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                                          maxFrameDuration: CameraExtensionConfiguration.frameDuration,
                                                          minFrameDuration: CameraExtensionConfiguration.frameDuration,
                                                          validFrameDurations: nil)

        _streamSource = ExtensionStreamSource(localizedName: CameraExtensionConfiguration.localizedStreamName,
                                              streamID: CameraExtensionConfiguration.streamID,
                                              streamFormat: videoStreamFormat,
                                              device: device)

        do {
            try device.addStream(_streamSource.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    private(set) var device: CMIOExtensionDevice!

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])

        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }

        if properties.contains(.deviceModel) {
            deviceProperties.model = CameraExtensionConfiguration.model
        }

        return deviceProperties
    }

    func setDeviceProperties(_: CMIOExtensionDeviceProperties) throws {
        // This virtual camera does not currently expose writable device properties.
    }

    func startStreaming() throws {
        try _timerQueue.sync {
            if _streamingCounter > 0 {
                _streamingCounter += 1
                return
            }

            guard let videoURL = Bundle.main.url(forResource: CameraExtensionConfiguration.bundledVideoName,
                                                 withExtension: CameraExtensionConfiguration.bundledVideoExtension) else {
                throw CameraExtensionError.missingBundledVideo
            }

            resetTiming()
            self.videoURL = videoURL

            guard setupAssetReader(with: videoURL) else {
                self.videoURL = nil
                throw CameraExtensionError.failedToStartAssetReader
            }

            _streamingCounter = 1
            startTimer()
            logger.info("Started stream with bundled video: \(videoURL.lastPathComponent, privacy: .public)")
        }
    }

    func stopStreaming() {
        _timerQueue.sync {
            guard _streamingCounter > 0 else { return }

            _streamingCounter -= 1
            if _streamingCounter == 0 {
                stopStreamingSession()
                logger.info("Stopped stream")
            }
        }
    }

    // MARK: Private

    private var _streamSource: ExtensionStreamSource!
    private var _streamingCounter: UInt32 = 0
    private var _videoDescription: CMFormatDescription!

    private var assetReader: AVAssetReader?
    private var asset: AVAsset?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var videoURL: URL?

    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(label: "com.garethpaul.GarethVideoCam.stream")

    private var lastPresentationTime: CMTime?
    private var timestampOffset: CMTime = .zero

    private func setupAssetReader(with videoURL: URL) -> Bool {
        let nextAsset = AVAsset(url: videoURL)

        do {
            let nextAssetReader = try AVAssetReader(asset: nextAsset)

            guard let videoTrack = nextAsset.tracks(withMediaType: .video).first else {
                logger.error("Bundled video does not contain a video track")
                return false
            }

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(CameraExtensionConfiguration.pixelFormat)
            ]

            let nextTrackOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                           outputSettings: outputSettings)
            nextTrackOutput.alwaysCopiesSampleData = false

            guard nextAssetReader.canAdd(nextTrackOutput) else {
                logger.error("Asset reader cannot add the configured track output")
                return false
            }

            nextAssetReader.add(nextTrackOutput)

            guard nextAssetReader.startReading() else {
                logger.error("Asset reader failed to start: \(nextAssetReader.error?.localizedDescription ?? "unknown error", privacy: .public)")
                return false
            }

            asset = nextAsset
            assetReader = nextAssetReader
            trackOutput = nextTrackOutput
            return true
        } catch {
            logger.error("Failed to initialize asset reader: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func startTimer() {
        let interval = DispatchTimeInterval.nanoseconds(Int(Double(NSEC_PER_SEC) / Double(CameraExtensionConfiguration.frameRate)))
        let timer = DispatchSource.makeTimerSource(queue: _timerQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.emitNextFrame()
        }
        _timer = timer
        timer.resume()
    }

    private func emitNextFrame() {
        if let sampleBuffer = trackOutput?.copyNextSampleBuffer() {
            processSampleBuffer(sampleBuffer)
            return
        }

        if assetReader?.status == .failed {
            logger.error("Asset reader failed while streaming: \(assetReader?.error?.localizedDescription ?? "unknown error", privacy: .public)")
            stopStreamingSession()
            return
        }

        guard let videoURL = videoURL, setupAssetReader(with: videoURL) else {
            logger.error("Unable to loop the bundled video")
            stopStreamingSession()
            return
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetDuration = asset?.duration else {
            logger.error("No asset duration is available for stream timing")
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.flags.contains(.valid) else {
            logger.error("Skipping sample buffer with invalid presentation timestamp")
            return
        }

        if let lastPresentationTime = lastPresentationTime, presentationTime < lastPresentationTime {
            timestampOffset = CMTimeAdd(timestampOffset, assetDuration)
        }
        lastPresentationTime = presentationTime

        let adjustedPresentationTime = CMTimeAdd(presentationTime, timestampOffset)
        guard let retimedSampleBuffer = retimedSampleBuffer(from: sampleBuffer,
                                                           adjustedPresentationTime: adjustedPresentationTime,
                                                           originalPresentationTime: presentationTime) else {
            return
        }

        _streamSource.stream.send(retimedSampleBuffer,
                                  discontinuity: [],
                                  hostTimeInNanoseconds: currentHostTimeInNanoseconds())
    }

    private func retimedSampleBuffer(from sampleBuffer: CMSampleBuffer,
                                     adjustedPresentationTime: CMTime,
                                     originalPresentationTime: CMTime) -> CMSampleBuffer? {
        guard CMSampleBufferGetNumSamples(sampleBuffer) == 1 else {
            logger.error("Skipping sample buffer with unexpected sample count")
            return nil
        }

        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(sampleBuffer,
                                                            at: 0,
                                                            timingInfoOut: &timing)
        guard timingStatus == noErr else {
            logger.error("Failed to read sample timing info: \(timingStatus, privacy: .public)")
            return nil
        }

        if !timing.duration.flags.contains(.valid) {
            timing.duration = CameraExtensionConfiguration.frameDuration
        }

        timing.presentationTimeStamp = adjustedPresentationTime

        if timing.decodeTimeStamp.flags.contains(.valid) {
            let decodeOffset = CMTimeSubtract(timing.decodeTimeStamp, originalPresentationTime)
            timing.decodeTimeStamp = CMTimeAdd(adjustedPresentationTime, decodeOffset)
        }

        var copiedSampleBuffer: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                               sampleBuffer: sampleBuffer,
                                                               sampleTimingEntryCount: 1,
                                                               sampleTimingArray: &timing,
                                                               sampleBufferOut: &copiedSampleBuffer)
        guard copyStatus == noErr, let retimedSampleBuffer = copiedSampleBuffer else {
            logger.error("Failed to retime sample buffer: \(copyStatus, privacy: .public)")
            return nil
        }

        return retimedSampleBuffer
    }

    private func currentHostTimeInNanoseconds() -> UInt64 {
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(hostTime)

        guard seconds.isFinite, seconds > 0 else {
            return 0
        }

        return UInt64(seconds * Double(NSEC_PER_SEC))
    }

    private func resetTiming() {
        lastPresentationTime = nil
        timestampOffset = .zero
    }

    private func stopStreamingSession() {
        _timer?.setEventHandler {}
        _timer?.cancel()
        _timer = nil

        assetReader?.cancelReading()
        assetReader = nil
        asset = nil
        trackOutput = nil
        videoURL = nil
        _streamingCounter = 0
    }
}

// MARK: - ExtensionStreamSource

final class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    // MARK: Lifecycle

    init(localizedName: String,
         streamID: UUID,
         streamFormat: CMIOExtensionStreamFormat,
         device: CMIOExtensionDevice) {
        self.device = device
        self._streamFormat = streamFormat
        super.init()

        stream = CMIOExtensionStream(localizedName: localizedName,
                                     streamID: streamID,
                                     direction: .source,
                                     clockType: .hostTime,
                                     source: self)
    }

    // MARK: Internal

    private(set) var stream: CMIOExtensionStream!

    let device: CMIOExtensionDevice

    var formats: [CMIOExtensionStreamFormat] {
        return [_streamFormat]
    }

    var activeFormatIndex: Int = 0 {
        didSet {
            if activeFormatIndex != 0 {
                logger.error("Invalid active format index: \(self.activeFormatIndex, privacy: .public)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])

        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }

        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CameraExtensionConfiguration.frameDuration
        }

        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for _: CMIOExtensionClient) -> Bool {
        return true
    }

    func startStream() throws {
        try extensionDeviceSource().startStreaming()
    }

    func stopStream() throws {
        try extensionDeviceSource().stopStreaming()
    }

    // MARK: Private

    private let _streamFormat: CMIOExtensionStreamFormat

    private func extensionDeviceSource() throws -> ExtensionDeviceSource {
        guard let deviceSource = device.source as? ExtensionDeviceSource else {
            logger.error("Unexpected source type: \(String(describing: device.source), privacy: .public)")
            throw CameraExtensionError.unexpectedDeviceSource
        }

        return deviceSource
    }
}

// MARK: - ExtensionProviderSource

final class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    // MARK: Lifecycle

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = ExtensionDeviceSource(localizedName: CameraExtensionConfiguration.localizedDeviceName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add device: \(error.localizedDescription)")
        }
    }

    // MARK: Internal

    private(set) var provider: CMIOExtensionProvider!

    var deviceSource: ExtensionDeviceSource!

    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }

    func connect(to _: CMIOExtensionClient) throws {
        logger.info("Client connected")
    }

    func disconnect(from _: CMIOExtensionClient) {
        logger.info("Client disconnected")
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])

        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = CameraExtensionConfiguration.manufacturer
        }

        return providerProperties
    }

    func setProviderProperties(_: CMIOExtensionProviderProperties) throws {
        // This provider does not currently expose writable provider properties.
    }
}
