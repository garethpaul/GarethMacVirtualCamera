//
//  ExtensionProvider.swift
//  Extension
//

import AVFoundation
import CoreGraphics
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

    static let frameRate: Int32 = 24
    static let dimensions = CMVideoDimensions(width: 1280, height: 720)
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let frameDuration = CMTime(value: 1, timescale: frameRate)

    static let deviceID = UUID(uuid: (0xc5, 0x63, 0x36, 0x37, 0x4c, 0xf7, 0x4c, 0x1c,
                                      0x92, 0x8e, 0x51, 0x3f, 0xea, 0x1c, 0xc2, 0xd3))
    static let streamID = UUID(uuid: (0xb6, 0x2b, 0xa4, 0x8a, 0x28, 0x56, 0x42, 0x7c,
                                      0xa1, 0xf1, 0x90, 0xfe, 0x58, 0xc6, 0xf9, 0x9c))
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
    case unexpectedVideoDimensions(Int32, Int32)
    case unexpectedVideoFrameRate(Float)
    case invalidActiveFormatIndex(Int)
    case invalidFrameDuration(CMTime)
    case tooManyStreamingClients

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
        case .unexpectedVideoDimensions(let width, let height):
            return "The bundled loop video dimensions \(width)x\(height) do not match the advertised stream dimensions \(CameraExtensionConfiguration.dimensions.width)x\(CameraExtensionConfiguration.dimensions.height)."
        case .unexpectedVideoFrameRate(let frameRate):
            return "The bundled loop video frame rate \(frameRate) does not match the advertised stream frame rate \(CameraExtensionConfiguration.frameRate)."
        case .invalidActiveFormatIndex(let activeFormatIndex):
            return "The requested active stream format index is invalid: \(activeFormatIndex)"
        case .invalidFrameDuration(let frameDuration):
            return "The requested stream frame duration is unsupported: \(frameDuration.value)/\(frameDuration.timescale)"
        case .tooManyStreamingClients:
            return "The camera stream has reached the maximum number of active clients."
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
                                                          validFrameDurations: [CameraExtensionConfiguration.frameDuration])

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
                guard _streamingCounter < UInt32.max else {
                    throw CameraExtensionError.tooManyStreamingClients
                }

                _streamingCounter += 1
                logger.info("Attached streaming client; active clients: \(self._streamingCounter, privacy: .public)")
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
            logger.info("Preparing stream with bundled video: \(videoURL.lastPathComponent, privacy: .public)")
        }
    }

    func stopStreaming() {
        _timerQueue.sync {
            guard _streamingCounter > 0 else { return }

            _streamingCounter -= 1
            if _streamingCounter == 0 {
                stopStreamingSession()
                logger.info("Stopped stream")
            } else {
                logger.info("Detached streaming client; active clients: \(self._streamingCounter, privacy: .public)")
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
    private var hostPresentationTimebase: CMTime?

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
                    logger.debug("Ignoring stale stream preparation completion")
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
                    logger.debug("Ignoring stale stream preparation failure")
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

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        try validateVideoTrack(naturalSize: naturalSize,
                               preferredTransform: preferredTransform,
                               nominalFrameRate: nominalFrameRate)

        guard duration.flags.contains(.valid),
              !duration.flags.contains(.indefinite),
              CMTimeCompare(duration, .zero) > 0 else {
            throw CameraExtensionError.invalidVideoDuration
        }

        return LoadedVideoAsset(asset: asset,
                                videoTrack: videoTrack,
                                duration: duration)
    }

    private func validateVideoTrack(naturalSize: CGSize,
                                    preferredTransform: CGAffineTransform,
                                    nominalFrameRate: Float) throws {
        let displayDimensions = Self.displayDimensions(naturalSize: naturalSize,
                                                       preferredTransform: preferredTransform)

        guard displayDimensions.width == CameraExtensionConfiguration.dimensions.width,
              displayDimensions.height == CameraExtensionConfiguration.dimensions.height else {
            throw CameraExtensionError.unexpectedVideoDimensions(displayDimensions.width, displayDimensions.height)
        }

        guard nominalFrameRate > 0,
              abs(nominalFrameRate - Float(CameraExtensionConfiguration.frameRate)) < 0.01 else {
            throw CameraExtensionError.unexpectedVideoFrameRate(nominalFrameRate)
        }
    }

    private static func displayDimensions(naturalSize: CGSize,
                                          preferredTransform: CGAffineTransform) -> CMVideoDimensions {
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CMVideoDimensions(width: Int32(abs(displayRect.width).rounded()),
                                 height: Int32(abs(displayRect.height).rounded()))
    }

    private func makeAssetReader(asset: AVAsset, videoTrack: AVAssetTrack) throws -> AssetReaderState {
        do {
            let nextAssetReader = try AVAssetReader(asset: asset)

            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(CameraExtensionConfiguration.pixelFormat),
                kCVPixelBufferWidthKey as String: Int(CameraExtensionConfiguration.dimensions.width),
                kCVPixelBufferHeightKey as String: Int(CameraExtensionConfiguration.dimensions.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
        guard _timer == nil else {
            logger.warning("Duplicate stream timer start ignored")
            return
        }

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

        guard let asset, let assetDuration, let videoTrack else {
            logger.error("Unable to loop the bundled video because no loaded asset is available")
            stopStreamingSession()
            return
        }

        do {
            advanceLoopTiming(by: assetDuration)
            installAssetReaderState(try makeAssetReader(asset: asset, videoTrack: videoTrack))
        } catch {
            logger.error("Unable to loop the bundled video: \(error.localizedDescription, privacy: .public)")
            stopStreamingSession()
        }
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let assetDuration else {
            logger.error("No asset duration is available for stream timing")
            return
        }

        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            logger.error("Skipping sample buffer that is not ready")
            return
        }

        guard validateSampleBufferPixelBuffer(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard Self.isFiniteTime(presentationTime) else {
            logger.error("Skipping sample buffer with invalid, indefinite, or infinite presentation timestamp")
            return
        }

        if let lastPresentationTime = lastPresentationTime, presentationTime < lastPresentationTime {
            timestampOffset = CMTimeAdd(timestampOffset, assetDuration)
        }
        lastPresentationTime = presentationTime

        let assetPresentationTime = CMTimeAdd(presentationTime, timestampOffset)
        guard Self.isFiniteTime(assetPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite adjusted presentation timestamp")
            return
        }

        let hostScaledAssetPresentationTime = CMTimeConvertScale(assetPresentationTime,
                                                                 timescale: CMTimeScale(NSEC_PER_SEC),
                                                                 method: .roundTowardZero)
        guard Self.isFiniteTime(hostScaledAssetPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite host-scaled presentation timestamp")
            return
        }

        guard let currentHostTime = currentHostTime() else {
            logger.error("Skipping sample buffer because host clock time is unavailable")
            return
        }

        guard let adjustedPresentationTime = hostPresentationTime(for: hostScaledAssetPresentationTime,
                                                                  currentHostTime: currentHostTime) else {
            logger.error("Skipping sample buffer with non-finite host presentation timestamp")
            return
        }

        guard let hostTimeInNanoseconds = hostTimeInNanoseconds(from: adjustedPresentationTime) else {
            logger.error("Skipping sample buffer with non-finite host-time nanoseconds")
            return
        }

        guard let retimedSampleBuffer = retimedSampleBuffer(from: sampleBuffer,
                                                           adjustedPresentationTime: adjustedPresentationTime,
                                                           originalPresentationTime: presentationTime) else {
            return
        }

        _streamSource.stream.send(retimedSampleBuffer,
                                  discontinuity: [],
                                  hostTimeInNanoseconds: hostTimeInNanoseconds)
    }

    private func validateSampleBufferPixelBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            logger.error("Skipping sample buffer without a CVPixelBuffer image buffer")
            return false
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer)
        guard pixelFormat == CameraExtensionConfiguration.pixelFormat else {
            logger.error("Skipping sample buffer with unexpected pixel format: \(pixelFormat, privacy: .public)")
            return false
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard width == Int(CameraExtensionConfiguration.dimensions.width),
              height == Int(CameraExtensionConfiguration.dimensions.height) else {
            logger.error("Skipping sample buffer with unexpected pixel buffer dimensions: \(width, privacy: .public)x\(height, privacy: .public)")
            return false
        }

        return true
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

        timing.duration = CameraExtensionConfiguration.frameDuration
        timing.presentationTimeStamp = adjustedPresentationTime

        if timing.decodeTimeStamp.flags.contains(.valid) {
            guard Self.isFiniteTime(timing.decodeTimeStamp) else {
                logger.error("Skipping sample buffer with non-finite decode timestamp")
                return nil
            }

            let decodeOffset = CMTimeSubtract(timing.decodeTimeStamp, originalPresentationTime)
            let adjustedDecodeTime = CMTimeAdd(adjustedPresentationTime, decodeOffset)
            guard Self.isFiniteTime(adjustedDecodeTime) else {
                logger.error("Skipping sample buffer with non-finite adjusted decode timestamp")
                return nil
            }

            timing.decodeTimeStamp = adjustedDecodeTime
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

    private func currentHostTime() -> CMTime? {
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard Self.isFiniteTime(hostTime),
              CMTimeCompare(hostTime, .zero) > 0 else {
            return nil
        }

        let nanoseconds = CMTimeConvertScale(hostTime,
                                             timescale: CMTimeScale(NSEC_PER_SEC),
                                             method: .roundTowardZero)
        guard Self.isFiniteTime(nanoseconds), nanoseconds.value > 0 else {
            return nil
        }

        return nanoseconds
    }

    private func hostPresentationTime(for assetPresentationTime: CMTime,
                                      currentHostTime: CMTime) -> CMTime? {
        if let hostPresentationTimebase {
            let hostPresentationTime = CMTimeAdd(hostPresentationTimebase, assetPresentationTime)
            guard Self.isFiniteTime(hostPresentationTime),
                  CMTimeCompare(hostPresentationTime, .zero) > 0 else {
                return nil
            }

            return hostPresentationTime
        }

        let basePresentationTime = CMTimeSubtract(currentHostTime, assetPresentationTime)
        guard Self.isFiniteTime(basePresentationTime) else {
            return nil
        }

        hostPresentationTimebase = basePresentationTime
        return currentHostTime
    }

    private func hostTimeInNanoseconds(from hostTime: CMTime) -> UInt64? {
        let nanoseconds = CMTimeConvertScale(hostTime,
                                             timescale: CMTimeScale(NSEC_PER_SEC),
                                             method: .roundTowardZero)
        guard Self.isFiniteTime(nanoseconds), nanoseconds.value > 0 else {
            return nil
        }

        return UInt64(nanoseconds.value)
    }

    private static func isFiniteTime(_ time: CMTime) -> Bool {
        return time.isNumeric
    }

    private func resetTiming() {
        lastPresentationTime = nil
        timestampOffset = .zero
        hostPresentationTimebase = nil
    }

    private func advanceLoopTiming(by duration: CMTime) {
        timestampOffset = CMTimeAdd(timestampOffset, duration)
        lastPresentationTime = nil
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
            streamProperties.activeFormatIndex = activeFormatIndex
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
            guard frameDuration.isNumeric,
                  frameDuration.flags.contains(.valid),
                  !frameDuration.flags.contains(.indefinite),
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
