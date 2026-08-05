@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
    typealias MeterHandler = @Sendable (Float, TimeInterval) -> Void

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "AIRecorder.AudioCapture", qos: .userInitiated)
    private let stateLock = NSLock()
    private var outputFile: AVAudioFile?
    private var outputConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private var installedTap = false
    private var bufferHandler: BufferHandler?
    private var meterHandler: MeterHandler?

    var duration: TimeInterval {
        stateLock.withLock { Double(framesWritten) / (targetFormat?.sampleRate ?? 44_100) }
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(
        destination: URL,
        onBuffer: @escaping BufferHandler,
        onMeter: @escaping MeterHandler
    ) throws {
        guard !engine.isRunning else { throw AppError.invalidState }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(44_100)
        try session.setActive(true)

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
        outputFile = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        outputConverter = AVAudioConverter(from: inputFormat, to: fileFormat)
        targetFormat = fileFormat
        bufferHandler = onBuffer
        meterHandler = onMeter
        framesWritten = 0
        paused = false

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let copy = buffer.deepCopy() else { return }
            self.processingQueue.async { self.process(copy) }
        }
        installedTap = true
        engine.prepare()
        try engine.start()
    }

    func pause() {
        stateLock.withLock { paused = true }
        engine.pause()
    }

    func resume() throws {
        stateLock.withLock { paused = false }
        if !engine.isRunning {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        }
    }

    func stop() -> TimeInterval {
        stateLock.withLock { paused = true }
        engine.stop()
        if installedTap {
            engine.inputNode.removeTap(onBus: 0)
            installedTap = false
        }
        processingQueue.sync {}
        outputFile = nil
        outputConverter = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard !stateLock.withLock({ paused }), let converter = outputConverter, let format = targetFormat else { return }
        do {
            guard let converted = try converter.convertedCopy(of: input, to: format) else { return }
            try outputFile?.write(from: converted)
            stateLock.withLock { framesWritten += AVAudioFramePosition(converted.frameLength) }
            bufferHandler?(input)
            meterHandler?(input.rmsLevel, duration)
        } catch {
            // The controller receives model errors separately; a write failure
            // will be detected when finalizing the file.
        }
    }
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
