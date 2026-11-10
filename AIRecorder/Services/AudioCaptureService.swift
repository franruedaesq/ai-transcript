@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias MeterHandler = @Sendable (Float, TimeInterval) -> Void
    typealias EventHandler = @Sendable (AudioCaptureEvent) -> Void

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "AIRecorder.AudioCapture", qos: .userInitiated)
    private let stateLock = NSLock()
    private var outputFile: AVAudioFile?
    private var recoveryFile: AVAudioFile?
    private var outputConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private var stopping = false
    private var installedTap = false
    private var bufferHandler: BufferHandler?
    private var meterHandler: MeterHandler?
    private var eventHandler: EventHandler?
    private var reportedFatalError = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var configurationObserver: NSObjectProtocol?

    var duration: TimeInterval {
        stateLock.withLock { Double(framesWritten) / (targetFormat?.sampleRate ?? 44_100) }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(
        destination: URL,
        recoveryDestination: URL,
        onBuffer: @escaping BufferHandler,
        onMeter: @escaping MeterHandler,
        onEvent: @escaping EventHandler
    ) throws {
        guard !engine.isRunning else { throw AppError.invalidState }
        var didStart = false
        defer {
            if !didStart { resetAfterFailedStart() }
        }
        eventHandler = onEvent
        reportedFatalError = false
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(44_100)
        try session.setActive(true)
        installAudioSessionObservers()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ) else { throw AppError.unsupportedAudio }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let recoverySettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        outputFile = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        recoveryFile = try AVAudioFile(forWriting: recoveryDestination, settings: recoverySettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        outputConverter = AVAudioConverter(from: inputFormat, to: fileFormat)
        targetFormat = fileFormat
        bufferHandler = onBuffer
        meterHandler = onMeter
        stateLock.withLock { framesWritten = 0; paused = false; stopping = false }

        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.processingQueue.async { self.process(copy) }
        }
        installedTap = true
        engine.prepare()
        try engine.start()
        didStart = true
        eventHandler?(.routeChanged(Self.currentRouteInfo()))
    }

    func pause() {
        stateLock.withLock { paused = true }
        engine.pause()
    }

    func resume() throws {
        stateLock.withLock { paused = false; stopping = false }
        if !engine.isRunning {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
    }

    func stop() async -> TimeInterval {
        stateLock.withLock { stopping = true }
        engine.stop()
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        await withCheckedContinuation { continuation in
            processingQueue.async { continuation.resume() }
        }
        stateLock.withLock { paused = true; stopping = false }
        outputFile = nil
        recoveryFile = nil
        outputConverter = nil
        removeAudioSessionObservers()
        eventHandler = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard !stateLock.withLock({ paused }), let format = targetFormat else { return }
        do {
            if outputConverter == nil || outputConverter?.inputFormat.isEqual(input.format) == false {
                outputConverter = AVAudioConverter(from: input.format, to: format)
            }
            guard let converter = outputConverter else { throw AppError.unsupportedAudio }
            guard let converted = try converter.convertedCopy(of: input, to: format) else { return }
            guard let outputFile, let recoveryFile else { throw AppError.invalidState }
            // CAF with linear PCM remains readable after an abrupt process
            // termination, unlike an M4A whose container was never finalized.
            try recoveryFile.write(from: converted)
            try outputFile.write(from: converted)
            stateLock.withLock { framesWritten += AVAudioFramePosition(converted.frameLength) }
            bufferHandler?(input)
            meterHandler?(input.rmsLevel, duration)
        } catch {
            reportFatalError(error)
        }
    }

    private func reportFatalError(_ error: Error) {
        let shouldReport = stateLock.withLock { guard !reportedFatalError else { return false }; reportedFatalError = true; return true }
        guard shouldReport else { return }
        eventHandler?(.failed(error.localizedDescription))
    }

    private func installAudioSessionObservers() {
        removeAudioSessionObservers()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.eventHandler?(type == .began ? .interruptionBegan : .interruptionEnded)
        }
        routeObserver = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in self?.eventHandler?(.routeChanged(Self.currentRouteInfo())) }
        configurationObserver = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in self?.handleEngineConfigurationChange() }
    }

    private func removeAudioSessionObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver); self.interruptionObserver = nil }
        if let routeObserver { center.removeObserver(routeObserver); self.routeObserver = nil }
        if let configurationObserver { center.removeObserver(configurationObserver); self.configurationObserver = nil }
    }

    private func resetAfterFailedStart() {
        engine.stop()
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        outputFile = nil
        recoveryFile = nil
        outputConverter = nil
        targetFormat = nil
        bufferHandler = nil
        meterHandler = nil
        removeAudioSessionObservers()
        eventHandler = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func currentRouteInfo() -> AudioRouteInfo? {
        guard let input = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        let image: String
        switch input.portType {
        case .bluetoothHFP, .bluetoothLE, .bluetoothA2DP: image = "airpodspro"
        case .headsetMic, .headphones: image = "headphones"
        case .usbAudio: image = "cable.connector"
        case .carAudio: image = "car.fill"
        default: image = "mic.fill"
        }
        return .init(name: input.portName, portType: input.portType.rawValue, systemImage: image)
    }

    private func handleEngineConfigurationChange() {
        eventHandler?(.routeChanged(Self.currentRouteInfo()))
        let shouldRun = stateLock.withLock { !paused && !stopping }
        guard shouldRun, !engine.isRunning else { return }
        do { try AVAudioSession.sharedInstance().setActive(true); engine.prepare(); try engine.start() }
        catch { reportFatalError(error) }
    }
}

struct AudioRouteInfo: Equatable, Sendable { let name: String; let portType: String; let systemImage: String }
enum AudioCaptureEvent: Sendable {
    case interruptionBegan
    case interruptionEnded
    case routeChanged(AudioRouteInfo?)
    case failed(String)
}

private extension AVAudioPCMBuffer {
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let buffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        for index in 0..<min(buffers.count, source.count) {
            guard let sourceData = source[index].mData, let destination = buffers[index].mData else { continue }
            memcpy(destination, sourceData, Int(source[index].mDataByteSize))
            buffers[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    var rmsLevel: Float {
        guard let channel = floatChannelData?.pointee, frameLength > 0 else { return -80 }
        var sum: Float = 0
        for index in 0..<Int(frameLength) { sum += channel[index] * channel[index] }
        let rms = sqrt(sum / Float(frameLength))
        return max(-80, 20 * log10(max(rms, 0.000_1)))
    }
}

private extension AVAudioConverter {
    func convertedCopy(of input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let inputState = AudioConversionInputState()
        var conversionError: NSError?
        convert(to: output, error: &conversionError) { _, status in
            if inputState.supplied { status.pointee = .noDataNow; return nil }
            inputState.supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return output
    }
}

private final class AudioConversionInputState: @unchecked Sendable {
    var supplied = false
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
