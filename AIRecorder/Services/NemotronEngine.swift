@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

actor NemotronEngine: StreamingTranscriptionEngine {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    private var manager: StreamingNemotronMultilingualAsrManager?
    private var lastPartial = ""
    private var isPaused = false

    init() {
        let pair = AsyncStream<TranscriptionEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        events = pair.stream
        continuation = pair.continuation
    }

    func prepare(language: TranscriptionLanguage) async throws {
        continuation.yield(.preparing)
        if let manager {
            await manager.setLanguage(language.nemotronCode)
            await installPartialCallback(on: manager)
            continuation.yield(.modelState(.ready))
            continuation.yield(.ready)
            return
        }
        do {
            continuation.yield(.modelState(.checking))
            continuation.yield(.modelProgress(0, "Comprobando acceso a Nemotron…"))
            if !Self.isLatinModelCached {
                try await Self.verifyRepositoryAccess()
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let modelDirectory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                // English routes to the Latin bundle, which also supports
                // automatic ES/EN/DE detection with a much smaller vocabulary.
                languageCode: "en-US",
                chunkMs: 1120,
            ) { [continuation] progress in
                switch progress.phase {
                case .listing:
                    continuation.yield(.modelState(.checking))
                    continuation.yield(.modelProgress(0, "Consultando los archivos del modelo…"))
                case .downloading(let completed, let total):
                    continuation.yield(.modelState(.downloading(progress.fractionCompleted)))
                    continuation.yield(.modelProgress(
                        progress.fractionCompleted,
                        "Descargando archivos · \(completed) de \(total)"
                    ))
                case .compiling(let modelName):
                    continuation.yield(.modelProgress(
                        progress.fractionCompleted,
                        "Preparando \(modelName)…"
                    ))
                }
            }
            continuation.yield(.modelState(.loading))
            continuation.yield(.modelProgress(1, "Cargando Nemotron en memoria…"))
            let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(
                from: modelDirectory,
                configuration: configuration
            )
            let manager = StreamingNemotronMultilingualAsrManager(configuration: configuration)
            try await manager.loadFromShared(shared)
            await manager.setLanguage(language.nemotronCode)
            await installPartialCallback(on: manager)
            self.manager = manager
            continuation.yield(.modelState(.ready))
            continuation.yield(.ready)
        } catch {
            let message = Self.friendlyModelError(error)
            continuation.yield(.modelState(.failed(message)))
            continuation.yield(.failed(message))
            throw AppError.modelUnavailable(message)
        }
    }

    func start() async throws {
        guard let manager else { throw AppError.invalidState }
        await manager.reset()
        await installPartialCallback(on: manager)
        lastPartial = ""
        isPaused = false
    }

    func consume(_ buffer: AVAudioPCMBuffer) async throws {
        guard !isPaused, let manager else { return }
        let partial = try await manager.process(audioBuffer: buffer)
        if partial != lastPartial {
            lastPartial = partial
            continuation.yield(.partial(partial))
        }
        if let language = await manager.detectedLanguage() {
            continuation.yield(.languageDetected(language))
        }
    }

    func pause() { isPaused = true }
    func resume() async throws { isPaused = false }

    func finish() async throws -> TranscriptionResult {
        guard let manager else { throw AppError.invalidState }
        let output = try await manager.finishWithTokenTimings()
        let detected = await manager.lastDecodeStats().detectedLanguage
        let tokens = output.timings.map {
            AppTokenTiming(token: $0.token, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }
        return .init(text: output.text, detectedLanguage: detected, tokens: tokens, cues: CueBuilder.build(from: tokens))
    }

    func reset() async {
        await manager?.reset()
        lastPartial = ""
        isPaused = false
    }

    private func installPartialCallback(
        on manager: StreamingNemotronMultilingualAsrManager
    ) async {
        await manager.setPartialCallback { [continuation] text in
            continuation.yield(.partial(text))
        }
    }

    private static func friendlyModelError(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("401") || text.contains("403") {
            return "No se pudo acceder a Nemotron. Verifica que tu cuenta tenga acceso y que HF_TOKEN esté configurado en el esquema de Xcode."
        }
        if text.localizedCaseInsensitiveContains("space") {
            return "No hay espacio suficiente para descargar Nemotron."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No hay conexión a internet. Conéctate y vuelve a intentarlo."
            case .timedOut:
                return "Hugging Face no respondió a tiempo. Comprueba la conexión y vuelve a intentarlo."
            default: break
            }
        }
        return "No se pudo preparar Nemotron: \(text)"
    }

    private static func verifyRepositoryAccess() async throws {
        let url = URL(string: "https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/main/multilingual/1120ms/metadata.json")!
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let token = ProcessInfo.processInfo.environment["HF_TOKEN"], !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "HuggingFace",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Hugging Face respondió HTTP \(http.statusCode)."]
            )
        }
    }


    private static var isLatinModelCached: Bool {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return false }
        let metadata = applicationSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.nemotronMultilingual.folderName, isDirectory: true)
            .appendingPathComponent("latin/1120ms/metadata.json")
        return FileManager.default.fileExists(atPath: metadata.path)
    }
}
