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
    case missingVideoTrack
    case invalidVideoDuration
    case unableToAddTrackOutput
    case assetReaderFailedToStart(String)
    case unexpectedDeviceSource
    case failedToCreateVideoFormatDescription(OSStatus)
    case failedToAddStream(String)
    case failedToAddDevice(String)
    case invalidActiveFormatIndex(Int)
    case invalidFrameDuration(CMTime)

    var errorDescription: String? {
        switch self {
        case .missingBundledVideo:
            return "The bundled loop video was not found."
        case .missingVideoTrack:
            return "The bundled loop video does not contain a video track."
        case .invalidVideoDuration:
            return "The bundled loop video does not report a valid duration."
        case .unableToAddTrackOutput:
            return "The bundled loop video could not be connected to an asset reader output."
        case .assetReaderFailedToStart(let detail):
            return "The asset reader failed to start: \(detail)"
        case .unexpectedDeviceSource:
            return "The stream is attached to an unexpected device source."
        case .failedToCreateVideoFormatDescription(let status):
            return "Failed to create the video format description: \(status)"
        case .failedToAddStream(let detail):
            return "Failed to add the camera stream: \(detail)"
        case .failedToAddDevice(let detail):
            return "Failed to add the camera device: \(detail)"
        case .invalidActiveFormatIndex(let activeFormatIndex):
            return "The requested active stream format index is invalid: \(activeFormatIndex)"
        case .invalidFrameDuration(let frameDuration):
            return "The requested stream frame duration is unsupported: \(frameDuration.value)/\(frameDuration.timescale)"
        }
    }
}

private struct LoadedVideoAsset: @unchecked Sendable {
    let asset: AVAsset
    let videoTrack: AVAssetTrack
    let duration: CMTime
}

private struct AssetReaderState: @unchecked Sendable {
    let assetReader: AVAssetReader
    let trackOutput: AVAssetReaderTrackOutput
}

// MARK: - ExtensionDeviceSource

final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    // MARK: Lifecycle

    init(localizedName: String) throws {
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
            throw CameraExtensionError.failedToCreateVideoFormatDescription(formatDescriptionStatus)
        }

        let videoStreamFormat = CMIOExtensionStreamFormat(formatDescription: videoDescription,
                                                          maxFrameDuration: CameraExtensionConfiguration.frameDuration,
                                                          minFrameDuration: CameraExtensionConfiguration.frameDuration,
                                                          validFrameDurations: nil)

        _streamSource = ExtensionStreamSource(localizedName: CameraExtensionConfiguration.localizedStreamName,
                                              streamID: CameraExtensionConfiguration.streamID,
                                              streamFormat: videoStreamFormat,
                                              device: device)

        try addStream()
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
            _streamingCounter = 1
            streamGeneration &+= 1
            let generation = streamGeneration

            streamPreparationTask?.cancel()
            streamPreparationTask = Task { [weak self] in
                await self?.prepareAndStartStreaming(with: videoURL, generation: generation)
            }
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
    private var assetDuration: CMTime?
    private var videoTrack: AVAssetTrack?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var videoURL: URL?
    private var streamGeneration: UInt64 = 0
    private var streamPreparationTask: Task<Void, Never>?

    private var _timer: DispatchSourceTimer?
    private let _timerQueue = DispatchQueue(label: "com.garethpaul.GarethVideoCam.stream")

    private var lastPresentationTime: CMTime?
    private var timestampOffset: CMTime = .zero

    private func addStream() throws {
        do {
            try device.addStream(_streamSource.stream)
        } catch {
            throw CameraExtensionError.failedToAddStream(error.localizedDescription)
        }
    }

    private func prepareAndStartStreaming(with videoURL: URL, generation: UInt64) async {
        do {
            let loadedAsset = try await loadVideoAsset(from: videoURL)
            if Task.isCancelled { return }

            let readerState = try makeAssetReader(asset: loadedAsset.asset,
                                                  videoTrack: loadedAsset.videoTrack)
            if Task.isCancelled { return }

            _timerQueue.async { [weak self] in
                guard let self else { return }

                guard self.isCurrentStreamPreparation(generation: generation, videoURL: videoURL) else {
                    return
                }

                self.streamPreparationTask = nil
                self.asset = loadedAsset.asset
                self.assetDuration = loadedAsset.duration
                self.videoTrack = loadedAsset.videoTrack
                self.installAssetReaderState(readerState)
                self.startTimer()
                logger.info("Started stream with bundled video: \(videoURL.lastPathComponent, privacy: .public)")
            }
        } catch {
            _timerQueue.async { [weak self] in
                guard let self else { return }

                guard self.isCurrentStreamPreparation(generation: generation, videoURL: videoURL) else {
                    return
                }

                self.streamPreparationTask = nil
                logger.error("Failed to prepare bundled video: \(error.localizedDescription, privacy: .public)")
                self.stopStreamingSession()
            }
        }
    }

    private func loadVideoAsset(from videoURL: URL) async throws -> LoadedVideoAsset {
        let asset = AVURLAsset(url: videoURL,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        async let loadedTracks = asset.loadTracks(withMediaType: .video)
        async let loadedDuration = asset.load(.duration)

        let (tracks, duration) = try await (loadedTracks, loadedDuration)

        guard let videoTrack = tracks.first else {
            throw CameraExtensionError.missingVideoTrack
        }

        guard duration.flags.contains(.valid),
              !duration.flags.contains(.indefinite),
              CMTimeCompare(duration, .zero) > 0 else {
            throw CameraExtensionError.invalidVideoDuration
        }

        return LoadedVideoAsset(asset: asset,
                                videoTrack: videoTrack,
                                duration: duration)
    }

    private func makeAssetReader(asset: AVAsset, videoTrack: AVAssetTrack) throws -> AssetReaderState {
        do {
            let nextAssetReader = try AVAssetReader(asset: asset)

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(CameraExtensionConfiguration.pixelFormat)
            ]

            let nextTrackOutput = AVAssetReaderTrackOutput(track: videoTrack,
                                                           outputSettings: outputSettings)
            nextTrackOutput.alwaysCopiesSampleData = false

            guard nextAssetReader.canAdd(nextTrackOutput) else {
                throw CameraExtensionError.unableToAddTrackOutput
            }

            nextAssetReader.add(nextTrackOutput)

            guard nextAssetReader.startReading() else {
                throw CameraExtensionError.assetReaderFailedToStart(nextAssetReader.error?.localizedDescription ?? "unknown error")
            }

            return AssetReaderState(assetReader: nextAssetReader,
                                    trackOutput: nextTrackOutput)
        } catch {
            logger.error("Failed to initialize asset reader: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func installAssetReaderState(_ readerState: AssetReaderState) {
        assetReader = readerState.assetReader
        trackOutput = readerState.trackOutput
    }

    private func isCurrentStreamPreparation(generation: UInt64, videoURL: URL) -> Bool {
        return streamGeneration == generation && _streamingCounter > 0 && self.videoURL == videoURL
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
            logger.error("Asset reader failed while streaming: \(self.assetReader?.error?.localizedDescription ?? "unknown error", privacy: .public)")
            stopStreamingSession()
            return
        }

        guard let asset, let videoTrack else {
            logger.error("Unable to loop the bundled video because no loaded asset is available")
            stopStreamingSession()
            return
        }

        do {
            installAssetReaderState(try makeAssetReader(asset: asset, videoTrack: videoTrack))
        } catch {
            logger.error("Unable to loop the bundled video")
            stopStreamingSession()
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetDuration else {
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
        streamGeneration &+= 1
        streamPreparationTask?.cancel()
        streamPreparationTask = nil

        _timer?.setEventHandler {}
        _timer?.cancel()
        _timer = nil

        assetReader?.cancelReading()
        assetReader = nil
        asset = nil
        assetDuration = nil
        videoTrack = nil
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

    var activeFormatIndex: Int = 0

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
            guard activeFormatIndex == 0 else {
                logger.error("Invalid active format index: \(activeFormatIndex, privacy: .public)")
                throw CameraExtensionError.invalidActiveFormatIndex(activeFormatIndex)
            }

            self.activeFormatIndex = activeFormatIndex
        }

        if let frameDuration = streamProperties.frameDuration {
            guard frameDuration.flags.contains(.valid),
                  CMTimeCompare(frameDuration, CameraExtensionConfiguration.frameDuration) == 0 else {
                logger.error("Invalid frame duration: \(frameDuration.value, privacy: .public)/\(frameDuration.timescale, privacy: .public)")
                throw CameraExtensionError.invalidFrameDuration(frameDuration)
            }
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
            logger.error("Unexpected source type: \(String(describing: self.device.source), privacy: .public)")
            throw CameraExtensionError.unexpectedDeviceSource
        }

        return deviceSource
    }
}

// MARK: - ExtensionProviderSource

final class ExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    // MARK: Lifecycle

    init(clientQueue: DispatchQueue?) throws {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = try ExtensionDeviceSource(localizedName: CameraExtensionConfiguration.localizedDeviceName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            throw CameraExtensionError.failedToAddDevice(error.localizedDescription)
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
